#!/usr/bin/env python3
"""Shared ELF dependency resolver for the relocatable stack.

Used by relocate/validate.sh and relocate/prune.sh so the two agree by
construction rather than by two hand-written implementations drifting apart.

Why pure Python rather than readelf/objdump: binutils is on conda/prune.list,
so it is gone by the time the post-slim gate runs, and the builder image
deliberately ships no dev packages.  This module is run with the miniforge
base interpreter ($CONDA_HOME/bin/python), which lives outside the stack, is
never pruned and is never shipped -- so it is available at every point in the
pipeline regardless of what has been stripped out of $STACK.

Parsing goes through the PROGRAM headers (PT_DYNAMIC), not the section
headers.  Section headers are optional and get stripped; program headers are
what the loader itself uses, so this sees what ld.so sees.

Usage:
    depsolve.py info   <file>...            per-file JSON
    depsolve.py scan   --root <stack>       whole-tree JSON report
"""

import argparse
import json
import os
import stat
import struct
import sys

# --- ELF constants -----------------------------------------------------------
PT_LOAD, PT_DYNAMIC, PT_INTERP = 1, 2, 3
DT_NEEDED, DT_STRTAB, DT_SONAME = 1, 5, 14
DT_RPATH, DT_STRSZ, DT_RUNPATH = 15, 10, 29
DT_VERNEED, DT_VERNEEDNUM = 0x6FFFFFFE, 0x6FFFFFFF

# Libraries permitted to resolve OUTSIDE the tree: core glibc and the loader.
# Everything else must come from within $STACK.  Deliberately short -- each
# addition is a new assumption about the customer's host.
CORE_ALLOWLIST = {
    "libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0",
    "librt.so.1", "libutil.so.1", "libresolv.so.2", "libnsl.so.1",
    "libcrypt.so.1", "linux-vdso.so.1", "ld-linux-x86-64.so.2",
    "ld-linux-aarch64.so.1", "ld-linux.so.2", "libanl.so.1",
}

# Must resolve INSIDE the tree, never from the host.  Getting the host's
# libstdc++ is the single failure that works on the build machine and breaks
# everywhere else.
MUST_BE_INTERNAL = {"libstdc++.so.6", "libgcc_s.so.1", "libgfortran.so.5"}

# Libraries that are host-provided BY DESIGN and legitimately absent.
#
# GPU driver libraries ship with the driver, are version-locked to the kernel
# module, and are not redistributable -- we could not bundle libcuda.so.1 even
# if we wanted to.  UCX builds its CUDA transports as separate dlopen-ed
# plugins under lib/ucx/ precisely so they can be missing: it probes at startup
# and silently skips the ones that will not load.
#
# So these are not "unresolved dependencies" in the sense rule 1 cares about --
# they are optional capability that lights up on a GPU host and stays dark
# elsewhere.  Flagging them would train us to ignore the validator.  They are
# reported separately instead, and SLIM_PROFILE=runtime drops the plugins
# outright since single-node MPI has no use for a GPU transport.
OPTIONAL_HOST = {
    "libcuda.so.1", "libcudart.so.12", "libcudart.so.11.0",
    "libnvidia-ml.so.1", "libnvToolsExt.so.1", "libcudnn.so.8",
}


class NotELF(Exception):
    pass


class ELF:
    """Minimal ELF reader: dynamic entries and version requirements."""

    def __init__(self, path):
        self.path = path
        with open(path, "rb") as fh:
            self.data = fh.read()
        d = self.data
        if len(d) < 64 or d[:4] != b"\x7fELF":
            raise NotELF(path)

        self.is64 = d[4] == 2
        little = d[5] == 1
        self.end = "<" if little else ">"
        self.elf_type = self._u16(16)
        self.machine = self._u16(18)

        if self.is64:
            e_phoff = self._u64(32)
            e_phentsize, e_phnum = self._u16(54), self._u16(56)
        else:
            e_phoff = self._u32(28)
            e_phentsize, e_phnum = self._u16(42), self._u16(44)

        self.loads = []      # (vaddr, memsz, offset)
        self.dyn_off = None
        self.interp = None
        for i in range(e_phnum):
            o = e_phoff + i * e_phentsize
            if o + e_phentsize > len(d):
                break
            p_type = self._u32(o)
            if self.is64:
                p_offset, p_vaddr = self._u64(o + 8), self._u64(o + 16)
                p_filesz, p_memsz = self._u64(o + 32), self._u64(o + 40)
            else:
                p_offset, p_vaddr = self._u32(o + 4), self._u32(o + 8)
                p_filesz, p_memsz = self._u32(o + 16), self._u32(o + 20)
            if p_type == PT_LOAD:
                self.loads.append((p_vaddr, p_memsz, p_offset))
            elif p_type == PT_DYNAMIC:
                self.dyn_off = p_offset
            elif p_type == PT_INTERP:
                self.interp = d[p_offset:p_offset + p_filesz].split(b"\0")[0].decode(
                    "utf-8", "replace")

        self._read_dynamic()

    # --- primitives ---
    def _u16(self, o):
        return struct.unpack_from(self.end + "H", self.data, o)[0]

    def _u32(self, o):
        return struct.unpack_from(self.end + "I", self.data, o)[0]

    def _u64(self, o):
        return struct.unpack_from(self.end + "Q", self.data, o)[0]

    def _addr(self, o):
        return self._u64(o) if self.is64 else self._u32(o)

    def _v2o(self, vaddr):
        """Virtual address -> file offset, via the PT_LOAD map."""
        for base, memsz, off in self.loads:
            if base <= vaddr < base + memsz:
                return off + (vaddr - base)
        return None

    def _cstr(self, off):
        if off is None or off >= len(self.data):
            return ""
        end = self.data.index(b"\0", off)
        return self.data[off:end].decode("utf-8", "replace")

    # --- dynamic section ---
    def _read_dynamic(self):
        self.needed, self.rpath, self.runpath = [], [], []
        self.soname = None
        self.verneed = {}
        if self.dyn_off is None:
            return

        step = 16 if self.is64 else 8
        entries, o = [], self.dyn_off
        while o + step <= len(self.data):
            tag = self._addr(o)
            val = self._addr(o + step // 2)
            if tag == 0:                      # DT_NULL
                break
            entries.append((tag, val))
            o += step

        strtab_v = next((v for t, v in entries if t == DT_STRTAB), None)
        strtab = self._v2o(strtab_v) if strtab_v is not None else None
        if strtab is None:
            return

        for tag, val in entries:
            if tag == DT_NEEDED:
                self.needed.append(self._cstr(strtab + val))
            elif tag == DT_SONAME:
                self.soname = self._cstr(strtab + val)
            elif tag == DT_RPATH:
                self.rpath = [p for p in self._cstr(strtab + val).split(":") if p]
            elif tag == DT_RUNPATH:
                self.runpath = [p for p in self._cstr(strtab + val).split(":") if p]

        vn_v = next((v for t, v in entries if t == DT_VERNEED), None)
        vn_n = next((v for t, v in entries if t == DT_VERNEEDNUM), 0)
        if vn_v is not None:
            self._read_verneed(self._v2o(vn_v), vn_n, strtab)

    def _read_verneed(self, off, count, strtab):
        """Collect required symbol versions, e.g. {'libc.so.6': ['GLIBC_2.28']}."""
        if off is None:
            return
        for _ in range(count):
            if off + 16 > len(self.data):
                return
            cnt = self._u16(off + 2)
            file_off = self._u32(off + 4)
            aux = self._u32(off + 8)
            nxt = self._u32(off + 12)
            fname = self._cstr(strtab + file_off)
            a = off + aux
            for _ in range(cnt):
                if a + 16 > len(self.data):
                    break
                name = self._cstr(strtab + self._u32(a + 8))
                self.verneed.setdefault(fname, []).append(name)
                anext = self._u32(a + 12)
                if not anext:
                    break
                a += anext
            if not nxt:
                return
            off += nxt


def version_tuple(v):
    """'GLIBC_2.28' -> (2, 28); unparseable -> (0, 0)."""
    try:
        return tuple(int(x) for x in v.split("_", 1)[1].split("."))
    except (IndexError, ValueError):
        return (0, 0)


def expand_origin(entry, origin):
    return (entry.replace("$ORIGIN", origin)
                 .replace("${ORIGIN}", origin))


def resolve(elf, root):
    """Resolve each DT_NEEDED the way ld.so would, restricted to the tree.

    DT_RPATH is searched before DT_RUNPATH because that is the loader's own
    precedence, and this stack sets RPATH deliberately (see plan S4).
    """
    origin = os.path.dirname(os.path.abspath(elf.path))
    search = [expand_origin(p, origin) for p in (elf.rpath + elf.runpath)]
    out = {}
    for name in elf.needed:
        hit = None
        for d in search:
            cand = os.path.join(d, name)
            if os.path.exists(cand):
                hit = os.path.realpath(cand)
                break
        out[name] = hit
    return out


def iter_elf(root):
    """Yield every ELF object under root, skipping symlinks and archives."""
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            if os.path.islink(p) or fn.endswith((".a", ".la", ".py", ".pyc")):
                continue
            try:
                if not stat.S_ISREG(os.lstat(p).st_mode):
                    continue
                with open(p, "rb") as fh:
                    if fh.read(4) != b"\x7fELF":
                        continue
            except OSError:
                continue
            yield p


def info(path, root=None):
    elf = ELF(path)
    d = {
        "path": path,
        "soname": elf.soname,
        "interp": elf.interp,
        "needed": elf.needed,
        "rpath": elf.rpath,
        "runpath": elf.runpath,
        "verneed": elf.verneed,
    }
    maxv, maxs = (0, 0), None
    for _lib, vers in elf.verneed.items():
        for v in vers:
            if v.startswith("GLIBC_") and version_tuple(v) > maxv:
                maxv, maxs = version_tuple(v), v
    d["glibc_max"] = maxs
    if root:
        d["resolved"] = resolve(elf, root)
    return d


def scan(root):
    root = os.path.abspath(root)
    files, unresolved, external, internal_needed = [], [], [], []
    optional = []
    glibc_max, glibc_who = (0, 0), None

    for p in iter_elf(root):
        try:
            d = info(p, root)
        except (NotELF, struct.error, ValueError):
            continue
        rel = os.path.relpath(p, root)
        d["rel"] = rel
        files.append(d)

        if d["glibc_max"] and version_tuple(d["glibc_max"]) > glibc_max:
            glibc_max, glibc_who = version_tuple(d["glibc_max"]), rel

        for name, hit in d.get("resolved", {}).items():
            if hit is None:
                if name in CORE_ALLOWLIST:
                    external.append({"file": rel, "lib": name})
                elif name in OPTIONAL_HOST:
                    optional.append({"file": rel, "lib": name})
                else:
                    unresolved.append({"file": rel, "lib": name})
            elif not hit.startswith(root + os.sep):
                unresolved.append({"file": rel, "lib": name, "escaped_to": hit})
            if name in MUST_BE_INTERNAL:
                internal_needed.append({"file": rel, "lib": name,
                                        "inside": hit is not None})

    return {
        "root": root,
        "elf_count": len(files),
        "glibc_max": ".".join(str(x) for x in glibc_max) if glibc_who else None,
        "glibc_max_file": glibc_who,
        "unresolved": unresolved,
        "external_core": external,
        "optional_host": optional,
        "must_be_internal": internal_needed,
        "files": files,
    }


def snapshot(root):
    """Record the load-bearing dynamic facts about every ELF in the tree.

    Taken before and after patchelf so the two can be compared.  See compare().
    """
    root = os.path.abspath(root)
    out = {}
    for p in iter_elf(root):
        rel = os.path.relpath(p, root)
        try:
            elf = ELF(p)
        except (NotELF, struct.error, ValueError) as exc:
            out[rel] = {"parse_error": str(exc) or exc.__class__.__name__}
            continue
        out[rel] = {
            "soname": elf.soname,
            "needed": sorted(elf.needed),
            "interp": elf.interp,
            "type": elf.elf_type,
            "machine": elf.machine,
        }
    return out


def compare(before, after):
    """Diff two snapshots.  Any difference is damage, not intent.

    patchelf is only ever asked to change DT_RPATH/DT_RUNPATH, which this
    snapshot deliberately does not record.  So SONAME, DT_NEEDED, the
    interpreter, the ELF type and the machine must all come through untouched,
    and every file that parsed before must still parse.  Anything else means
    the rewrite damaged the object -- whatever the cause.
    """
    problems = []
    for rel, b in before.items():
        a = after.get(rel)
        if a is None:
            problems.append({"file": rel, "problem": "disappeared"})
            continue
        if "parse_error" in a and "parse_error" not in b:
            problems.append({"file": rel, "problem": "no longer parses as ELF",
                             "detail": a["parse_error"]})
            continue
        if "parse_error" in b:
            continue
        for key in ("soname", "needed", "interp", "type", "machine"):
            if a.get(key) != b.get(key):
                problems.append({"file": rel, "problem": f"{key} changed",
                                 "before": b.get(key), "after": a.get(key)})
    return problems


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_snap = sub.add_parser("snapshot", help="record dynamic facts for later comparison")
    p_snap.add_argument("--root", required=True)

    p_cmp = sub.add_parser("compare", help="diff two snapshots; non-zero on damage")
    p_cmp.add_argument("before")
    p_cmp.add_argument("after")

    p_info = sub.add_parser("info", help="per-file dynamic info as JSON")
    p_info.add_argument("files", nargs="+")
    p_info.add_argument("--root")

    p_scan = sub.add_parser("scan", help="whole-tree report as JSON")
    p_scan.add_argument("--root", required=True)
    p_scan.add_argument("--brief", action="store_true",
                        help="omit the per-file list")

    a = ap.parse_args(argv)

    if a.cmd == "info":
        out = []
        for f in a.files:
            try:
                out.append(info(f, a.root))
            except NotELF:
                out.append({"path": f, "elf": False})
        json.dump(out, sys.stdout, indent=2)
    elif a.cmd == "snapshot":
        json.dump(snapshot(a.root), sys.stdout, indent=2)
    elif a.cmd == "compare":
        with open(a.before) as fh:
            before = json.load(fh)
        with open(a.after) as fh:
            after = json.load(fh)
        problems = compare(before, after)
        if problems:
            print(f"{len(problems)} object(s) damaged by the rewrite:",
                  file=sys.stderr)
            for p in problems[:25]:
                print(f"  {p['file']}: {p['problem']}", file=sys.stderr)
            return 1
        print(f"integrity OK: {len(before)} objects unchanged apart from RPATH")
        return 0
    else:
        rep = scan(a.root)
        if a.brief:
            rep.pop("files", None)
        json.dump(rep, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
