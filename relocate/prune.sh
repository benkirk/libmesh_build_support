#!/usr/bin/env bash
# relocate/prune.sh -- remove build-only conda packages from the redistributable.
#
# Removal is driven by each package's conda-meta file list, never by path
# globbing, so it is exactly as precise as the installation was.  Whole-package
# granularity is not a stylistic choice: dlopen'ed plugins (MKL's dispatch
# kernels, OpenBLAS threading layers, Hydra/PMI helpers, hwloc and UCX
# providers) are invisible to any dependency closure, so anything finer than
# "the package" risks deleting a file nothing appears to reference and that
# turns out to be load-bearing only at runtime, only after relocation.
#
# Two safety rails, in order of how much they would hurt:
#
#   1. Files also owned by a RETAINED package are never deleted.  conda does not
#      normally let two packages own the same path, but a prune that got this
#      wrong would silently gut a package we meant to keep.
#   2. Files listed in etc/source-files.txt -- installed by a source build, not
#      by conda -- are never deleted.  A source package that overwrites a
#      conda-owned path would otherwise lose that file when its original owner
#      is pruned.  See amendment A10.  (Written by the source build stage; when
#      absent, as it is for a conda-only tree, the check is a no-op.)
#
# The risk profile here is the whole reason this design beat the harvest one:
# the question is "did I delete something needed?", which is bounded and which
# distcheck answers, rather than "did I copy everything?", which is not.
set -euo pipefail

: "${STACK:?}"
SHIP_PYTHON="${SHIP_PYTHON:-no}"
TOPDIR="${TOPDIR:-$PWD}"
LIST="${PRUNE_LIST:-${TOPDIR}/conda/prune.list}"
PY="${CONDA_HOME:-}/bin/python"
[ -x "${PY}" ] || PY="$(command -v python3)"

[ -r "${LIST}" ] || { echo "no prune list at ${LIST}" >&2; exit 1; }
[ -d "${STACK}/conda-meta" ] || { echo "no conda-meta in ${STACK}" >&2; exit 1; }

"${PY}" - "${STACK}" "${LIST}" "${SHIP_PYTHON}" <<'PY'
import fnmatch, glob, json, os, sys

stack, listfile, ship_python = sys.argv[1], sys.argv[2], sys.argv[3]

# --- the prune list -----------------------------------------------------------
patterns, python_only, in_python_section = [], [], False
for raw in open(listfile):
    line = raw.strip()
    if line.startswith("#@python-only"):
        in_python_section = True
        continue
    if not line or line.startswith("#"):
        continue
    (python_only if in_python_section else patterns).append(line)

if ship_python == "no":
    patterns += python_only
else:
    print(f"  keeping the python stack (SHIP_PYTHON={ship_python}): "
          f"{len(python_only)} package(s) retained")

# --- what conda thinks is installed -------------------------------------------
meta = {}
for j in glob.glob(os.path.join(stack, "conda-meta", "*.json")):
    try:
        d = json.load(open(j))
    except (OSError, ValueError):
        continue
    name = d.get("name")
    if not name:
        continue
    files = [p["_path"] for p in d.get("paths_data", {}).get("paths", [])] \
        or d.get("files", [])
    meta[name] = {"json": j, "files": files}

doomed = sorted(n for n in meta
                if any(fnmatch.fnmatchcase(n, p) for p in patterns))
kept = [n for n in meta if n not in doomed]

if not doomed:
    print("  nothing matched the prune list")
    raise SystemExit(0)

# --- safety rail 1: paths a retained package also claims ----------------------
kept_paths = set()
for n in kept:
    kept_paths.update(meta[n]["files"])

# --- safety rail 2: paths installed from source, not by conda -----------------
source_paths = set()
src_manifest = os.path.join(stack, "etc", "source-files.txt")
if os.path.exists(src_manifest):
    source_paths = {l.strip() for l in open(src_manifest) if l.strip()}
    print(f"  {len(source_paths)} source-installed path(s) protected")

total = 0
shared_skips = 0
for name in doomed:
    freed = n_removed = 0
    for rel in meta[name]["files"]:
        if rel in kept_paths or rel in source_paths:
            shared_skips += 1
            continue
        p = os.path.join(stack, rel)
        try:
            freed += os.lstat(p).st_size
            os.unlink(p)
            n_removed += 1
        except FileNotFoundError:
            pass          # slim.sh got there first; fine
        except OSError as exc:
            print(f"    warn: {rel}: {exc}")
    try:
        os.unlink(meta[name]["json"])
    except OSError:
        pass
    total += freed
    print(f"  {name:<52} {freed / 1e6:9.1f} MB  ({n_removed} files)")

if shared_skips:
    print(f"  {shared_skips} path(s) skipped: claimed by a retained or source package")

# --- tidy up the directories the removals emptied -----------------------------
emptied = 0
for dirpath, dirnames, filenames in os.walk(stack, topdown=False):
    if dirpath == stack or dirnames or filenames:
        continue
    try:
        os.rmdir(dirpath)
        emptied += 1
    except OSError:
        pass

# --- and finally, links left pointing at nothing ------------------------------
#
# This has to be the LAST thing the slim+prune stage does.  slim removes files,
# prune removes packages, and prune then removes directories those left empty --
# each of which can strand a symlink (lib/terminfo -> share/terminfo, and
# lib/icu/current -> a version directory emptied a step earlier).  A dangling
# symlink is a validator failure, and rightly so: it is indistinguishable from a
# file deleted by mistake.  Sweeping earlier just means the next step makes more.
dangling = 0
for dirpath, _dirnames, filenames in os.walk(stack):
    for fn in filenames:
        p = os.path.join(dirpath, fn)
        if os.path.islink(p) and not os.path.exists(p):
            os.unlink(p)
            dangling += 1
for dirpath, dirnames, _f in os.walk(stack):
    for dn in list(dirnames):
        p = os.path.join(dirpath, dn)
        if os.path.islink(p) and not os.path.exists(p):
            os.unlink(p)
            dangling += 1

print(f"  ---")
print(f"  pruned {len(doomed)} package(s), {total / 1e6:.0f} MB, "
      f"{emptied} empty directories removed")
if dangling:
    print(f"  {dangling} symlink(s) left dangling by slim+prune removed")
print(f"  {len(kept)} package(s) retained")
PY
