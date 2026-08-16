#!/usr/bin/env python3
"""Scan every ELF object for instructions above the declared ISA baseline.

The failure this exists to catch is the worst kind: a stack built on a modern
build host that dies with SIGILL on the customer's older CPU, at some arbitrary
point during a run, in a library nobody suspected.  Nothing else in the
pipeline would notice -- the tree relocates correctly, resolves correctly, and
runs perfectly well on the machine that built it.

Two things make this worth doing as a scan of the ARTIFACT rather than trusting
the compiler flags:

  1. Most of the tree was not compiled by us.  ~58 conda-forge packages arrive
     prebuilt, and no amount of care with our own CFLAGS says anything about
     them.  (conda-forge does target a conservative baseline -- '-march=nocona'
     on x86-64, nothing at all on aarch64, where gcc defaults to armv8-a -- but
     that is a policy we do not control and cannot enforce.)
  2. '-march' is last-wins on a gcc command line and CFLAGS are injected first,
     so any build system that appends its own -march silently beats the
     baseline.  Kokkos autodetecting the host architecture is the canonical
     example, and it is coming with Trilinos.

RUNTIME DISPATCH is the subtlety.  OpenBLAS (DYNAMIC_ARCH), MKL, and OpenSSL
deliberately ship AVX-512 kernels selected by a CPUID check at startup.  Those
are correct and must not be flagged -- doing so would train us to ignore this
check, on exactly the libraries where a hit is expected.  They are allowlisted
by SONAME and reported separately so they stay visible.

Detection is by disassembly, because it is the only thing that observes what
was actually emitted.  '.note.gnu.property' carries an x86 ISA level only when
built with '-march=x86-64-vN' specifically, so it misses '-march=haswell' and
everything like it.
"""

import argparse
import concurrent.futures
import json
import multiprocessing
import os
import re
import shutil
import subprocess
import sys

# --- x86-64 microarchitecture levels -----------------------------------------
# v1 baseline: SSE, SSE2.  v2 adds SSE3/SSSE3/SSE4.1/SSE4.2/POPCNT.
# v3 adds AVX, AVX2, BMI1/2, FMA, F16C, LZCNT, MOVBE.  v4 adds AVX-512.
#
# The x86 patterns are PREFIX-FACTORED, and the factoring must preserve the
# accepted language EXACTLY.  Python's re tries every top-level branch at every
# position, so the flat 21-branch X86_V3 cost 58.7 s per GB per pattern -- 84%
# of the linux-64 scan -- where the aarch64 patterns cost 4.4.  Grouping
# branches under shared prefixes, with the whole-word mnemonics behind one
# leading \b, measured 6.4x cheaper on 896 MB of real x86 instruction text
# with byte-identical match spans.  Equivalence is not taken on faith: every
# original branch keeps a positive case in X86_BRANCH_CASES, every merge gap
# carries a negative ('blsm' is the canonical one -- a draft factoring
# 'bls[imr]' accepted it, and no corpus test could notice because the mnemonic
# does not exist), and isa-bench.py --compare-patterns diffs any two versions
# of this file per-file over a real tree.
X86_V4 = re.compile(
    # %zmm | {%k0..%k7} | v + one of: pternlog pcompress pexpand pconflict
    # gatherpf scatter rangep reducep fpclass -- the same 11 branches as the
    # flat form, all prefix-matching (no trailing \b), 'p(...)' collecting the
    # vp* four and 'r(...)' the vr* two.
    r"%zmm|\{%k[0-7]\}|"
    r"\bv(?:p(?:ternlog|compress|expand|conflict)|gatherpf|scatter|"
    r"r(?:angep|educep)|fpclass)")
# NOTE: 'tzcnt' is deliberately absent, and it is the interesting case.  It
# encodes as F3 0F BC, which a pre-BMI CPU decodes as 'rep bsf' -- the REP
# prefix is ignored and it executes correctly as plain BSF.  The two differ only
# for a zero operand, where __builtin_ctz is undefined anyway, which is exactly
# why gcc emits it even at -march=nocona.  It looks like a v3 instruction in
# disassembly and is not a portability hazard.  libquadmath's 8 tzcnt were this
# scanner's last false positive on x86-64.
#
# 'lzcnt' stays: it decodes as 'rep bsr' on older CPUs, which also does not
# fault, but bsr returns the index of the highest set bit where lzcnt returns
# the count of leading zeros -- so it is silently WRONG rather than merely
# undefined at zero.  gcc only emits it with -mlzcnt/-mabm, so its presence is
# a real signal.  Silent wrong answers deserve a failure at least as much as a
# crash does.
X86_V3 = re.compile(
    # %ymm | vf{madd,msub,nmadd,nmsub} = vf n? m {add,sub} | vperm2i128 |
    # vpbroadcast (those six prefix-matching, as before) | the fourteen
    # whole-word mnemonics: bzhi blsi blsr blsmsk pdep pext mulx rorx sarx
    # shlx shrx andn lzcnt movbe.  The word group keeps ONE leading and ONE
    # trailing \b; every alternative inside is all word characters, so the
    # boundaries distribute over the alternation exactly.  'bls(?:[ir]|msk)'
    # and NOT 'bls[imr]': the latter also accepts 'blsm', which no CPU has.
    r"%ymm|\bv(?:f(?:n?m(?:add|sub))|perm2i128|pbroadcast)|"
    r"\b(?:b(?:zhi|ls(?:[ir]|msk))|p(?:dep|ext)|mulx|rorx|s(?:arx|h[lr]x)|"
    r"andn|lzcnt|movbe)\b")
X86_V2 = re.compile(
    # popcnt pcmpgtq pblend* ptest pmov{z,s}x* group under one leading \bp,
    # and each alternative keeps its OWN trailing anchor -- popcnt, pcmpgtq
    # and ptest end at a word boundary exactly as before, blend and mov[sz]x
    # stay prefixes (pblendw, pblendvb, pmovzxbw, ...).
    r"\bp(?:opcnt\b|cmpgtq\b|blend|test\b|mov[sz]x)|"
    r"\bround[ps][sd]\b|\bcrc32\b|\bcmpxchg16b\b")

# --- aarch64 --------------------------------------------------------------
# armv8-a is the baseline and is universal.  SVE/SVE2 and SME are the real
# hazards: hardware support is far from universal, and unlike x86 there is no
# widely-used runtime-dispatch convention for them.
ARM_SVE = re.compile(
    r"\bz\d+\.[bhsdq]\b|\bp\d+/[mz]\b|\bptrue\b|\bwhilel[oet]\b|"
    r"\bcnt[bhwd]\b|\brdvl\b|\bsmstart\b|\bsmstop\b")
# armv8.2-a extensions.  Broadly available on server parts, so informational.
ARM_82 = re.compile(r"\b[su]dot\b|\bfmlal\b|\bbfdot\b|\bbfmmla\b|\b[su]mmla\b")
# armv8.1-a large-system atomics.  Present on essentially every server core;
# recorded but never fatal.
ARM_LSE = re.compile(r"\bld(add|clr|eor|set|smax|smin|umax|umin)\b|\bcas[ap]?\b|\bswp[ap]?\b")

X86_LEVELS = ["x86-64", "x86-64-v2", "x86-64-v3", "x86-64-v4"]
ARM_LEVELS = ["armv8-a", "armv8.1-a", "armv8.2-a", "armv8-a+sve"]

# Runtime CPU-feature dispatch, DETECTED rather than listed.
#
# A library that selects its kernels at startup legitimately carries
# instructions above the baseline: OpenBLAS (DYNAMIC_ARCH), MKL, OpenSSL, but
# also -- as the first x86-64 scan showed -- libgfortran's multiversioned
# matmul, MPICH's yaksa pack/unpack kernels, and libstdc++.  A hand-maintained
# list of library NAMES would have to grow to cover all of those, and would
# still be wrong for the next package someone adds.
#
# The mechanism leaves a signature instead.  On x86, every dispatch scheme --
# ifunc resolvers, GCC's __builtin_cpu_supports, hand-rolled feature tests --
# bottoms out in the CPUID instruction.  So an object containing CPUID is
# reported as dispatching rather than as a hazard.
#
# This is a heuristic and is treated as one: such objects are reported in their
# own bucket rather than silently passed, so a library that has CPUID for some
# unrelated reason AND genuinely unguarded AVX-512 still shows up to be looked
# at.  It is much better than a name list, and it generalises to packages we
# have not written yet.
CPUID = re.compile(r"\bcpuid\b")


EM_X86_64, EM_AARCH64 = 62, 183

def elf_machine(path):
    """Return e_machine, or None if this is not an ELF.

    Knowing the architecture matters: applying the x86 patterns to an aarch64
    object produced confident nonsense the first time this ran ("x86-64-v2" on
    libz.so), because aarch64 disassembly happens to contain matching text.
    """
    try:
        with open(path, "rb") as fh:
            head = fh.read(20)
    except OSError:
        return None
    if len(head) < 20 or head[:4] != b"\x7fELF":
        return None
    little = head[5] == 1
    return int.from_bytes(head[18:20], "little" if little else "big")


# An instruction line from 'objdump -d --no-show-raw-insn' looks like:
#     "  4004ec:\tbl\t400430 <printf@plt>"
# Everything up to the first tab is the address; everything inside <> is a
# symbol annotation, not code.  Matching the raw line means matching symbol
# NAMES -- which is how "crc32" in <crc32_z@plt> got read as a crc32
# instruction, and how an aarch64 library was reported as needing x86-64-v2.
INSN_LINE = re.compile(r"^\s*[0-9a-f]+:\t(.*)$")
ANNOTATION = re.compile(r"<[^>]*>|//.*$|;.*$|#.*$")


def instructions(text):
    """Yield just the mnemonic+operand text of each disassembled instruction."""
    out = []
    for line in text.splitlines():
        m = INSN_LINE.match(line)
        if m:
            out.append(ANNOTATION.sub("", m.group(1)))
    return "\n".join(out)


def scan_one(args):
    path, root, objdump, machine = args
    rel = os.path.relpath(path, root)
    try:
        out = subprocess.run(
            [objdump, "-d", "--no-show-raw-insn", path],
            capture_output=True, text=True, errors="replace", timeout=600)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return rel, {"error": str(exc) or type(exc).__name__}
    if not out.stdout:
        return rel, {"error": "no disassembly (stripped of .text?)"}
    text = instructions(out.stdout)

    found = []
    dispatch = bool(CPUID.search(text)) if machine == EM_X86_64 else False
    if machine == EM_X86_64:
        if X86_V4.search(text):
            found.append("x86-64-v4")
        if X86_V3.search(text):
            found.append("x86-64-v3")
        if X86_V2.search(text):
            found.append("x86-64-v2")
    elif machine == EM_AARCH64:
        if ARM_SVE.search(text):
            found.append("armv8-a+sve")
        if ARM_82.search(text):
            found.append("armv8.2-a")
        if ARM_LSE.search(text):
            found.append("armv8.1-a")
    return rel, {"features": sorted(found), "cpuid_dispatch": dispatch}


def highest(features, levels):
    best = levels[0]
    for f in features:
        if f in levels and levels.index(f) > levels.index(best):
            best = f
    return best


# Representative objdump output, in the AT&T syntax objdump emits by default.
# This exists because the x86 patterns cannot be exercised on an aarch64
# development machine: without it, "0 objects above baseline" on x86-64 would be
# indistinguishable from "the regexes never matched anything".  The aarch64
# patterns are covered the same way and additionally against real compiler
# output (see the PR).  Run with --self-test.
SELF_TEST = [
    # (sample line, expected feature or None)
    ("  401136:\tvaddpd %ymm0,%ymm1,%ymm2", "x86-64-v3"),
    ("  401140:\tvfmadd213sd %xmm2,%xmm1,%xmm0", "x86-64-v3"),
    ("  401150:\tbzhi   %eax,%ebx,%ecx", "x86-64-v3"),
    ("  401160:\tvaddpd %zmm1,%zmm2,%zmm3{%k1}", "x86-64-v4"),
    ("  401170:\tvpternlogd $0xff,%zmm0,%zmm0,%zmm0", "x86-64-v4"),
    ("  401180:\tpopcnt %eax,%edx", "x86-64-v2"),
    ("  401190:\tpcmpgtq %xmm1,%xmm0", "x86-64-v2"),
    ("  4011a0:\taddsd  %xmm1,%xmm0", None),
    ("  4011b0:\tmovaps %xmm0,(%rax)", None),
    # tzcnt is 'rep bsf' on pre-BMI hardware: executes correctly, not a hazard
    ("  4011b8:\ttzcnt  %rcx,%rdx", None),
    ("  4011c0:\tld1w   {z0.s},p0/z,[x0]", "armv8-a+sve"),
    ("  4011d0:\tptrue  p0.d", "armv8-a+sve"),
    ("  4011e0:\tsdot   v0.4s,v1.16b,v2.16b", "armv8.2-a"),
    ("  4011f0:\tldadd  w1,w2,[x0]", "armv8.1-a"),
    ("  401200:\tfadd   d0,d1,d2", None),
]


# Lines that must NOT match anything.  These are the false positives the first
# run of this scanner actually produced: symbol names inside <> annotations were
# being read as instructions, which is how an aarch64 libz.so came back
# "requiring x86-64-v2".  Every one of these is a real line shape from objdump.
SELF_TEST_NEGATIVE = [
    "  400430:\tbl\t400abc <crc32_z@plt>",
    "  400440:\tbl\t400b00 <__popcountdi2@plt>",
    "  400450:\tadrp\tx0, 411000 <ptest_data>",
    "  400460:\tb\t400c00 <sve_helper>",
    "  400470:\tcall   401050 <lzcnt_table>",
    "  400480:\tmov    %rax,%rbx  # ymm not used here",
]


# The factored x86 patterns, exercised branch by branch: one positive case per
# branch of the ORIGINAL flat alternations, and a negative in every gap a
# too-wide factoring would open -- 'blsm' is the one a draft patch actually
# opened, via 'bls[imr]', and no corpus could catch it because no compiler
# emits a mnemonic that does not exist.  These are mnemonic-level cases checked
# against ONE pattern each; the line-shape regression cases (symbol names,
# comments) stay in SELF_TEST / SELF_TEST_NEGATIVE above.  A few operands are
# synthetic so a case exercises exactly one branch -- vperm2i128 really takes
# %ymm operands, which would satisfy the %ymm branch before the one under test.
X86_BRANCH_CASES = [
    ("x86-64-v4", X86_V4,
     # must match: one per branch
     ["vaddpd %zmm1,%zmm2,%zmm3",
      "vpaddd %xmm0,%xmm1,%xmm2{%k3}",
      "vpternlogd $0x96,%xmm1,%xmm2,%xmm0",
      "vpcompressd %xmm0,(%rdi)",
      "vpexpandd (%rsi),%xmm0",
      "vpconflictd %xmm0,%xmm1",
      "vgatherpf0dps (%rax)",
      "vscatterdps %xmm0,(%rax)",
      "vrangepd $0x2,%xmm1,%xmm2,%xmm0",
      "vreduceps $0xb,%xmm1,%xmm0",
      "vfpclasspd $0x30,%xmm0,%k0"],
     # must not match
     ["vgatherdpd (%rax,%xmm0,8),%xmm1",  # AVX2 gather: 'gather', not 'gatherpf'
      "kmovw %k1,%eax",                   # a bare mask register is not a {%k_} mask
      "vprangepd $0x2,%xmm1,%xmm2,%xmm0", # 'rangep' wrongly grouped under 'vp'
      "vternlogd $0x96,%xmm1,%xmm2,%xmm0"]),  # 'pternlog' with the p made optional
    ("x86-64-v3", X86_V3,
     ["vaddpd %ymm0,%ymm1,%ymm2",
      "vfmadd213sd %xmm2,%xmm1,%xmm0",
      "vfmsub132ps %xmm1,%xmm2,%xmm0",
      "vfnmadd231sd %xmm2,%xmm1,%xmm0",
      "vfnmsub213ss %xmm2,%xmm1,%xmm0",
      "vperm2i128 $0x20,(%rax)",
      "vpbroadcastb %xmm0,%xmm1",
      "bzhi %eax,%ebx,%ecx",
      "pdep %eax,%ebx,%ecx",
      "pext %rax,%rbx,%rcx",
      "mulx %rax,%rbx,%rcx",
      "rorx $0x8,%eax,%ebx",
      "sarx %eax,%ebx,%ecx",
      "shlx %rax,%rbx,%rcx",
      "shrx %rcx,%rdx,%rax",
      "andn %eax,%ebx,%ecx",
      "blsi %eax,%ebx",
      "blsr %rax,%rbx",
      "blsmsk %eax,%ebx",
      "lzcnt %eax,%ebx",
      "movbe (%rax),%ebx"],
     ["blsm %eax,%ebx",                # the trap: 'bls[imr]' accepts it
      "bls %eax",                      # truncation of the shared prefix itself
      "vfmul213sd %xmm2,%xmm1,%xmm0",  # vf+m but neither add nor sub
      "vfnadd132pd %xmm1,%xmm2,%xmm0", # n without the m
      "sharx %eax,%ebx",               # 's[ah][lr]?x'-style sloppiness
      "shx %eax",                      # 'sh[lr]?x' with the class made optional
      "pdext %eax,%ebx",               # 'pd?ext'-style sloppiness
      "movb $0x1,(%rax)",              # movbe truncated is a baseline instruction
      "lzcn %eax",
      "ymm0"]),                        # the register class without the %
    ("x86-64-v2", X86_V2,
     ["popcnt %eax,%edx",
      "pcmpgtq %xmm1,%xmm0",
      "pblendw $0xf0,%xmm1,%xmm0",
      "ptest %xmm1,%xmm0",
      "roundsd $0x9,%xmm1,%xmm0",
      "roundps $0x8,%xmm1,%xmm0",      # both [ps][sd] classes, both corners
      "pmovzxbw %xmm1,%xmm0",
      "pmovsxwd %xmm1,%xmm0",
      "crc32 (%rdx),%eax",
      "cmpxchg16b (%rdi)"],
     ["vpopcntd %xmm0,%xmm1",          # AVX-512 vpopcnt: no boundary before the p
      "vptestmb %xmm0,%xmm1",          # 'ptest' with its trailing \b dropped
      "pmovmskb %xmm0,%eax",           # SSE2 baseline: 'pmov' + m, not [sz]
      "roundpp $0x1,%xmm1,%xmm0",      # second class widened beyond [sd]
      "cmpxchg8b (%rsi)"]),            # baseline compare-exchange
]


def self_test():
    checks = [(X86_V4, "x86-64-v4"), (X86_V3, "x86-64-v3"), (X86_V2, "x86-64-v2"),
              (ARM_SVE, "armv8-a+sve"), (ARM_82, "armv8.2-a"), (ARM_LSE, "armv8.1-a")]

    def verdict(raw):
        text = instructions(raw)
        return next((name for rx, name in checks if rx.search(text)), None)

    failures = 0
    print("  -- must match --")
    for line, want in SELF_TEST:
        got = verdict(line)
        if got != want:
            failures += 1
        print(f"  {'ok  ' if got == want else 'FAIL'} {line.strip():44} -> {got}")
    print("  -- must NOT match (symbol names are not instructions) --")
    for line in SELF_TEST_NEGATIVE:
        got = verdict(line)
        if got is not None:
            failures += 1
        print(f"  {'ok  ' if got is None else 'FAIL'} {line.strip():44} -> {got}")

    total = len(SELF_TEST) + len(SELF_TEST_NEGATIVE)
    print("  -- per-branch: every original alternation branch, every merge gap --")
    for name, rx, positives, negatives in X86_BRANCH_CASES:
        for case, want in [(c, True) for c in positives] + \
                          [(c, False) for c in negatives]:
            total += 1
            got = bool(rx.search(case))
            if got != want:
                failures += 1
            tag = "match" if want else "no-match"
            print(f"  {'ok  ' if got == want else 'FAIL'} {name}  "
                  f"{tag:8} {case}")
    print(f"self-test: {total - failures}/{total} passed")
    return 1 if failures else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true",
                    help="check the instruction patterns against known objdump output")
    ap.add_argument("--root")
    ap.add_argument("--objdump", default=None,
                    help="defaults to <root>/bin/*-objdump, then PATH")
    ap.add_argument("--out", help="where to write the JSON report")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    a = ap.parse_args(argv)

    if a.self_test:
        return self_test()
    if not a.root or not a.out:
        ap.error("--root and --out are required unless --self-test")

    root = os.path.abspath(a.root)
    objdump = a.objdump
    if not objdump:
        import glob
        cand = sorted(glob.glob(os.path.join(root, "bin", "*-objdump")))
        objdump = cand[0] if cand else shutil.which("objdump")
    if not objdump:
        # Deliberately not fatal.  This scan runs during 'relocate', when
        # binutils is still present; if someone runs it later, after prune has
        # removed binutils, saying so beats failing the build.
        print("isa-scan: no objdump available; skipping", file=sys.stderr)
        json.dump({"skipped": "no objdump"}, open(a.out, "w"))
        return 0

    targets = []
    for dirpath, _d, filenames in os.walk(root):
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            if os.path.islink(p) or fn.endswith((".a", ".la", ".py", ".pyc")):
                continue
            m = elf_machine(p)
            if m in (EM_X86_64, EM_AARCH64):
                targets.append((p, root, objdump, m))

    # PROCESSES, not threads.  subprocess.run(objdump) releases the GIL and
    # parallelises fine, but instructions() and the regex searches after it are
    # pure Python and hold it -- so under threads that half ran serially however
    # many workers were asked for.  Measured on the real stack, 4 vCPU, by
    # relocate/isa-bench.py:
    #
    #                     aarch64   linux-64
    #   objects             906       915
    #   disassembly        4.0 GB    4.2 GB
    #   objdump alone       45 s      60 s
    #   python            127 s    1207 s     <- 95% of linux-64's wall time
    #   threads (before)  172 s    1267 s
    #   processes (after)  80 s     596 s
    #
    # 11 minutes off every linux-64 build, 1.5 off aarch64, and the bench
    # confirmed the two executors produce IDENTICAL results on both -- which is
    # the only reason a correctness gate gets to be made faster.
    #
    # fork explicitly: scan_one lives in __main__ here, and wrappers/selftest.sh
    # loads this file through importlib, so a spawned child re-importing it is
    # a needless variable.  Linux is where this runs.
    try:
        mp_context = multiprocessing.get_context("fork")
    except ValueError:                       # not POSIX; let the default decide
        mp_context = None

    results = {}
    with concurrent.futures.ProcessPoolExecutor(max_workers=a.jobs,
                                                mp_context=mp_context) as pool:
        for rel, info in pool.map(scan_one, targets):
            results[rel] = info

    report = {
        "root": root,
        "objdump": objdump,
        "scanned": len(results),
        "files": results,
    }
    with open(a.out, "w") as fh:
        json.dump(report, fh, indent=1, sort_keys=True)

    n_flagged = sum(1 for v in results.values() if v.get("features"))
    print(f"isa-scan: {len(results)} objects scanned, "
          f"{n_flagged} carry above-baseline instructions -> {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
