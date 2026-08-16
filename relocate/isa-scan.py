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
# These alternations are PREFIX-FACTORED.  Python's re does not factor a shared
# prefix across '|' branches -- given 'vpternlog|vpcompress|...' it re-tries the
# 'v', then the 'p', at every position for every branch -- so the searches were
# 84% of the linux-64 scan (454 s of 538).  Hoisting the shared prefix into a
# single group lets the engine fail the whole family on one character.  Measured
# 7.15x on X86_V3 over 66 MB of real instruction text; ~4.6x realised over the
# whole scan.
#
# Factoring a match gate is only safe if it preserves the accepted language
# EXACTLY: a pattern that accepts one mnemonic more is a worse gate, not a
# faster one.  So every group below is argued to be equivalent to the flat
# alternation it replaces, branch by branch, and the equivalence is checked two
# ways that no corpus can fake -- relocate/isa-bench.py --verify-factoring
# (every one-character mutation, nine contexts) and --compare-patterns (span for
# span over a built stack).  The near-miss each factoring must NOT open has a
# negative in SELF_TEST_NEGATIVE.
#
# X86_V4: %zmm and the {%kN} mask-operand marker stand alone (no shared prefix).
# The rest are all '\bv' instructions; four continue 'vp' (vpternlog, vpcompress,
# vpexpand, vpconflict) and factor once more.  '\bv(p(ternlog|compress|expand|
# conflict)|gatherpf|scatter|rangep|reducep|fpclass)' spells exactly those nine
# mnemonics and nothing shorter -- e.g. 'vp' with no listed continuation is not a
# branch, so bare 'vp'/'vpx' stay non-matches.  No trailing \b, as before, so the
# suffixed real forms (vpternlogd, vrangeps, ...) still match.
X86_V4 = re.compile(
    r"%zmm|\{%k[0-7]\}|"
    r"\bv(?:p(?:ternlog|compress|expand|conflict)|"
    r"gatherpf|scatter|rangep|reducep|fpclass)")
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
# X86_V3, 21 flat branches -> three groups by anchor shape:
#   %ymm                                       stands alone.
#   the '\bv' FMA/permute mnemonics, no trailing \b (they carry operand-size
#     suffixes: vfmadd213sd, vpbroadcastd):
#       vfmadd|vfmsub|vfnmadd|vfnmsub  ==  vf(m|nm)(add|sub)  -- the four cross
#         products of {m,nm}x{add,sub}, and only those four;
#       vperm2i128|vpbroadcast          ==  vp(erm2i128|broadcast).
#   the BMI/misc mnemonics, each \b-anchored on BOTH sides -- '\ba\b|\bb\b' is
#     exactly '\b(a|b)\b', so they share one wrapper.  Inside, grouped by first
#     letter: b(zhi|ls(i|r|msk)), m(ulx|ovbe), p(dep|ext), s(arx|h(lx|rx)), and
#     andn/lzcnt/rorx alone.  Note 'ls(i|r|msk)' lists the three suffixes i, r,
#     msk -- it is NOT 'bls[imr]', which would also accept 'blsm' (see
#     SELF_TEST_NEGATIVE); the only 'm' here is the first letter of 'msk'.
X86_V3 = re.compile(
    r"%ymm|"
    r"\bv(?:f(?:m|nm)(?:add|sub)|p(?:erm2i128|broadcast))|"
    r"\b(?:andn|b(?:zhi|ls(?:i|r|msk))|lzcnt|m(?:ulx|ovbe)|"
    r"p(?:dep|ext)|rorx|s(?:arx|h(?:lx|rx)))\b")
# X86_V2: six of the nine branches start '\bp', but with MIXED trailing anchors
# -- popcnt/pcmpgtq/ptest end in \b, while pblend/pmovzx/pmovsx do not (they take
# suffixes: pblendw, pmovzxbw).  Factoring the shared '\bp' keeps each branch's
# own trailing anchor inside the group: p(opcnt\b|cmpgtq\b|blend|test\b|mov[sz]x),
# where 'mov[sz]x' is exactly pmovzx|pmovsx.  round[ps][sd] is unchanged;
# crc32|cmpxchg16b share only 'c' and factor to c(rc32|mpxchg16b), both \b-tailed
# -- so 'crc32\b' still declines the memory-operand forms crc32b/crc32q exactly
# as before (a pre-existing, deliberately preserved false negative).
X86_V2 = re.compile(
    r"\bp(?:opcnt\b|cmpgtq\b|blend|test\b|mov[sz]x)|"
    r"\bround[ps][sd]\b|\bc(?:rc32|mpxchg16b)\b")

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
#
# One positive per FACTORED BRANCH: when the patterns were flat alternations
# this list exercised about three of X86_V3's twenty-one branches, which is fine
# for "do the regexes fire at all" but blind to a factoring that drops a branch
# on the floor.  Now every alternative a group spells has a line here that must
# resolve to it, and the near-miss each factoring must NOT accept has a line in
# SELF_TEST_NEGATIVE.  The x86 lines pick forms that isolate one branch (e.g.
# ymm-form AVX-512 so the vp-family branches, not %zmm, decide the verdict).
SELF_TEST = [
    # (sample line, expected feature or None)
    # -- X86_V4, one per branch --
    ("  401300:\tvmovaps %zmm0,%zmm1", "x86-64-v4"),                    # %zmm
    ("  401308:\tvpaddq %ymm0,%ymm1,%ymm2{%k1}", "x86-64-v4"),         # {%kN} mask
    ("  401310:\tvpternlogd $0xff,%ymm0,%ymm0,%ymm0", "x86-64-v4"),    # vpternlog
    ("  401318:\tvpcompressd %xmm0,%xmm1", "x86-64-v4"),               # vpcompress
    ("  401320:\tvpexpandd %xmm0,%xmm1", "x86-64-v4"),                 # vpexpand
    ("  401328:\tvpconflictd %xmm0,%xmm1", "x86-64-v4"),               # vpconflict
    ("  401330:\tvgatherpf0dps 0x0(%rax)", "x86-64-v4"),               # vgatherpf
    ("  401338:\tvscatterdps %xmm0,0x0(%rax)", "x86-64-v4"),           # vscatter
    ("  401340:\tvrangepd $0x0,%xmm0,%xmm1,%xmm2", "x86-64-v4"),       # vrangep
    ("  401348:\tvreducepd $0x0,%xmm0,%xmm1", "x86-64-v4"),            # vreducep
    ("  401350:\tvfpclasspd $0x0,%xmm0,%k0", "x86-64-v4"),             # vfpclass
    # -- X86_V3, one per branch --
    ("  401200:\tvaddpd %ymm0,%ymm1,%ymm2", "x86-64-v3"),              # %ymm
    ("  401208:\tvfmadd213sd %xmm2,%xmm1,%xmm0", "x86-64-v3"),         # vfmadd
    ("  401210:\tvfmsub231ps %xmm2,%xmm1,%xmm0", "x86-64-v3"),         # vfmsub
    ("  401218:\tvfnmadd213sd %xmm2,%xmm1,%xmm0", "x86-64-v3"),        # vfnmadd
    ("  401220:\tvfnmsub231ps %xmm2,%xmm1,%xmm0", "x86-64-v3"),        # vfnmsub
    ("  401228:\tvperm2i128 $0x20,%ymm1,%ymm2,%ymm3", "x86-64-v3"),    # vperm2i128
    ("  401230:\tvpbroadcastd %xmm0,%ymm1", "x86-64-v3"),             # vpbroadcast
    ("  401238:\tbzhi   %eax,%ebx,%ecx", "x86-64-v3"),                 # bzhi
    ("  401240:\tpdep   %edx,%eax,%ecx", "x86-64-v3"),                 # pdep
    ("  401248:\tpext   %edx,%eax,%ecx", "x86-64-v3"),                 # pext
    ("  401250:\tmulx   %edx,%eax,%ecx", "x86-64-v3"),                 # mulx
    ("  401258:\trorx   $0x10,%eax,%ebx", "x86-64-v3"),                # rorx
    ("  401260:\tsarx   %eax,%ebx,%ecx", "x86-64-v3"),                 # sarx
    ("  401268:\tshlx   %eax,%ebx,%ecx", "x86-64-v3"),                 # shlx
    ("  401270:\tshrx   %eax,%ebx,%ecx", "x86-64-v3"),                 # shrx
    ("  401278:\tandn   %eax,%ebx,%ecx", "x86-64-v3"),                 # andn
    ("  401280:\tblsi   %eax,%ebx", "x86-64-v3"),                      # blsi
    ("  401288:\tblsr   %eax,%ebx", "x86-64-v3"),                      # blsr
    ("  401290:\tblsmsk %eax,%ebx", "x86-64-v3"),                      # blsmsk
    ("  401298:\tlzcnt  %eax,%ebx", "x86-64-v3"),                      # lzcnt
    ("  4012a0:\tmovbe  (%rax),%ebx", "x86-64-v3"),                    # movbe
    # -- X86_V2, one per branch (both round[ps][sd] endpoints) --
    ("  401100:\tpopcnt %eax,%edx", "x86-64-v2"),                      # popcnt
    ("  401108:\tpcmpgtq %xmm1,%xmm0", "x86-64-v2"),                   # pcmpgtq
    ("  401110:\tpblendw $0x0,%xmm1,%xmm0", "x86-64-v2"),              # pblend
    ("  401118:\tptest  %xmm1,%xmm0", "x86-64-v2"),                    # ptest
    ("  401120:\troundps $0x0,%xmm1,%xmm0", "x86-64-v2"),              # round[ps][sd]
    ("  401128:\troundsd $0x0,%xmm1,%xmm0", "x86-64-v2"),              # round[ps][sd]
    ("  401130:\tpmovzxbw %xmm0,%xmm1", "x86-64-v2"),                  # pmovzx
    ("  401138:\tpmovsxbd %xmm0,%xmm1", "x86-64-v2"),                  # pmovsx
    ("  401140:\tcrc32  %eax,%ebx", "x86-64-v2"),                      # crc32 (register form)
    ("  401148:\tcmpxchg16b (%rax)", "x86-64-v2"),                     # cmpxchg16b
    # -- non-hazards that must stay unflagged --
    ("  4011a0:\taddsd  %xmm1,%xmm0", None),
    ("  4011b0:\tmovaps %xmm0,(%rax)", None),
    # tzcnt is 'rep bsf' on pre-BMI hardware: executes correctly, not a hazard
    ("  4011b8:\ttzcnt  %rcx,%rdx", None),
    # -- aarch64 (patterns untouched by the x86 factoring) --
    ("  4011c0:\tld1w   {z0.s},p0/z,[x0]", "armv8-a+sve"),
    ("  4011d0:\tptrue  p0.d", "armv8-a+sve"),
    ("  4011e0:\tsdot   v0.4s,v1.16b,v2.16b", "armv8.2-a"),
    ("  4011f0:\tldadd  w1,w2,[x0]", "armv8.1-a"),
    ("  401210a:\tfadd   d0,d1,d2", None),
]


# Lines that must NOT match anything.  Two kinds:
#
#   1. The false positives the first run of this scanner actually produced:
#      symbol names inside <> annotations read as instructions, which is how an
#      aarch64 libz.so came back "requiring x86-64-v2".  Real objdump shapes.
#   2. The near-misses the PREFIX FACTORING must keep rejecting.  Each is a
#      one-character neighbour of a real mnemonic that sits in the exact gap a
#      too-wide factoring would open, so the guarantee is a green test, not a
#      comment.  These are the whole reason the factoring was a plan: 'bls[imr]'
#      accepts 'blsm', a mnemonic no CPU emits and no corpus contains, so a
#      corpus test cannot see the widening -- only an explicit non-match can.
SELF_TEST_NEGATIVE = [
    # (1) symbol names in annotations are not instructions
    "  400430:\tbl\t400abc <crc32_z@plt>",
    "  400440:\tbl\t400b00 <__popcountdi2@plt>",
    "  400450:\tadrp\tx0, 411000 <ptest_data>",
    "  400460:\tb\t400c00 <sve_helper>",
    "  400470:\tcall   401050 <lzcnt_table>",
    "  400480:\tmov    %rax,%rbx  # ymm not used here",
    # (2) factoring near-misses that must stay non-matches
    "  401400:\tblsm   %eax,%ebx",              # bls(i|r|msk), never 'bls[imr]'
    "  401408:\tblsms  %eax,%ebx",              # 'msk' is all-or-nothing, not 'ms'
    "  401410:\tsharx  %eax,%ebx,%ecx",         # s(arx|h(lx|rx)) has no 'harx'
    "  401418:\tpdext  %eax,%ebx,%ecx",         # p(dep|ext), not 'p' + 'd?e' + ...
    "  401420:\tvfnadd %xmm0,%xmm1",            # vf(m|nm)(add|sub) needs the 'm'
    "  401428:\tvprangepd $0x0,%xmm0,%xmm1",    # V4 'vrangep' is not 'vp'-prefixed
    "  401430:\tpmovx  %xmm0,%xmm1",            # mov[sz]x needs the s or z
    # preserved pre-existing false negative: crc32\b declines the memory-operand
    # suffixed forms objdump emits (crc32b/crc32q), exactly as before factoring
    "  401438:\tcrc32b (%rax),%rbx",
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
