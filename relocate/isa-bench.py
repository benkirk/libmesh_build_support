#!/usr/bin/env python3
"""Measure where relocate/isa-scan.py spends its time.  Changes nothing.

The scan is 40% of the linux-64 build -- 20m36s of 51m47s measured -- and 2m53s
on linux-aarch64 for the same 341 objects, on native runners both times.  A 7x
asymmetry that large is a fact about the code, not about the hardware, and this
exists to find out which part.

The hypothesis it was written to test: isa-scan.py used a ThreadPoolExecutor.
subprocess.run(objdump) releases the GIL and parallelises properly, but
instructions() -- splitlines, then a match and a sub per line -- and the four to
six full-text regex searches after it are pure Python and hold the GIL, so that
half was serialised across the workers no matter how many there were.  Confirmed,
and the fix has landed: isa-scan.py uses processes.

The second half of that hypothesis was WRONG, and this is what measuring it was
for.  It guessed that x86-64 disassembly is far bulkier than aarch64 -- OpenBLAS
DYNAMIC_ARCH shipping kernels for every microarchitecture -- and that the volume
explained the 7x gap.  It does not.  The two architectures disassemble to almost
exactly the same thing:

                    aarch64   linux-64   ratio
  ELF objects          906       915      1.01x
  disassembly         4.0 GB    4.2 GB    1.05x
  objdump alone        45 s      60 s     1.33x
  python              127 s    1207 s     9.47x   <-- the entire asymmetry

Same object count, same bytes, comparable objdump time.  The gap is the REGEX
work alone: the x86 patterns cost 9.5x what the aarch64 ones do over the same
volume of text.  Four searches against three is not nine, so the difference is
in the patterns themselves -- X86_V3 alone is a sixteen-branch alternation, most
branches anchored with \b, and Python's re tries each alternative at every
position.

That makes the remaining headroom architecture-specific, and worth knowing
before anyone optimises further: after the switch to processes, objdump is 56%
of what is left on aarch64 and only 10% on linux-64.  Cheaper matching would
barely register on aarch64 and is nearly the whole cost on linux-64 -- which is
also the slower build.

It is a hypothesis.  This prints numbers instead of arguing:

  * objdump wall time on its own, over the same objects
  * total wall time with threads, and with processes, at several worker counts
  * total bytes of disassembly, which is the thing that differs between the
    architectures

and, because a faster gate that reports something different is not a faster
gate, it diffs the two result sets and says whether they are identical.

Deliberately a separate file.  isa-scan.py is a correctness gate whose
self-test carries six regression cases built from false positives it really
produced; this measures it, and nothing here can change what it reports.

It also carries the EQUIVALENCE gate for the scanner's x86 patterns, which is a
correctness question, not a timing one.  Those patterns were prefix-factored to
make matching cheap, and the only way a factoring goes wrong is by widening what
the gate accepts without changing any verdict a real corpus happens to exercise
(the classic case: 'bls[imr]' also accepting 'blsm', a mnemonic no CPU has).
Two modes hold the line, both comparing the live patterns against a frozen copy
of the pre-factoring originals kept in this file:

  * --verify-factoring  brute-forces every one-character mutation of every
                        relevant mnemonic in nine operand contexts and requires
                        identical verdicts and match spans.  No tree needed.
  * --compare-patterns  runs both pattern sets over every x86 object in a real
                        stack and requires byte-identical spans per file.

  relocate/isa-bench.py --root <stack> [--jobs 1,2,4] [--json out.json]
  relocate/isa-bench.py --root <stack> --compare-patterns
  relocate/isa-bench.py --verify-factoring

The timing and --compare-patterns modes require a tree that has not been slimmed
or pruned yet -- after 'make all' there is no objdump left and the objects are
stripped, so the only useful moment is between 'make build' and 'make all'.
--verify-factoring needs nothing but this file and the scanner.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import glob
import importlib.util
import json
import multiprocessing
import os
import re
import shutil
import subprocess
import sys
import time


def load_scanner():
    """Import isa-scan.py, whose hyphen makes it unimportable by name.

    Registered in sys.modules under the name the spec gives it so that
    ProcessPoolExecutor can pickle scan_one by reference: pickle stores
    module+qualname, and the forked child resolves it out of the inherited
    sys.modules.
    """
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "isa-scan.py")
    spec = importlib.util.spec_from_file_location("isa_scan", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["isa_scan"] = mod
    spec.loader.exec_module(mod)
    return mod


isa = load_scanner()


# --- pattern-set equivalence -------------------------------------------------
# The x86 level patterns exactly as they stood BEFORE prefix-factoring, frozen
# verbatim.  The scanner's live patterns (isa.X86_V*) were factored to make
# matching cheap; the whole risk of that change is a factoring that quietly
# widens what the gate accepts -- 'bls[imr]' silently swallowing the mnemonic
# 'blsm' is the example that made this a plan and not a patch.  Keeping the
# originals here turns "did the factoring change the accepted language?" from an
# invisible question into a diff:
#
#   --verify-factoring   brute-forces every one-character mutation of every
#                        relevant mnemonic in nine operand contexts and requires
#                        reference and live patterns to agree, match spans and
#                        all.  Needs no tree.
#   --compare-patterns   runs both pattern sets over every x86 ELF object in a
#                        real built stack and requires byte-identical finditer
#                        spans per file.
#
# aarch64 was deliberately untouched, so only x86 is carried here.  If a future
# edit to the scanner narrows or widens x86 matching, both modes go red.
REFERENCE_X86 = {
    "x86-64-v4": re.compile(
        r"%zmm|\{%k[0-7]\}|\bvpternlog|\bvpcompress|\bvpexpand|\bvpconflict|"
        r"\bvgatherpf|\bvscatter|\bvrangep|\bvreducep|\bvfpclass"),
    "x86-64-v3": re.compile(
        r"%ymm|\bvfmadd|\bvfmsub|\bvfnmadd|\bvfnmsub|\bvperm2i128|\bvpbroadcast|"
        r"\bbzhi\b|\bpdep\b|\bpext\b|\bmulx\b|\brorx\b|\bsarx\b|\bshlx\b|\bshrx\b|"
        r"\bandn\b|\bblsi\b|\bblsr\b|\bblsmsk\b|\blzcnt\b|\bmovbe\b"),
    "x86-64-v2": re.compile(
        r"\bpopcnt\b|\bpcmpgtq\b|\bpblend|\bptest\b|\bround[ps][sd]\b|"
        r"\bpmovzx|\bpmovsx|\bcrc32\b|\bcmpxchg16b\b"),
}
CURRENT_X86 = {
    "x86-64-v4": isa.X86_V4,
    "x86-64-v3": isa.X86_V3,
    "x86-64-v2": isa.X86_V2,
}


def _spans(rx, text):
    return [(m.start(), m.end()) for m in rx.finditer(text)]


def compare_one(args):
    """Diff reference vs live x86 patterns over one object, span by span.

    Returns (rel, diffs) where diffs is a list of (level, ref_count, cur_count)
    for every pattern whose finditer spans are not byte-identical -- empty means
    the two pattern sets saw exactly the same instructions in exactly the same
    places.  aarch64 objects short-circuit to no-diff: the factoring never
    touched their patterns.  Reads REFERENCE_X86/CURRENT_X86 from the inherited
    (forked) module globals rather than as arguments, so no compiled pattern has
    to survive pickling.
    """
    path, root, objdump, machine = args
    rel = os.path.relpath(path, root)
    if machine != isa.EM_X86_64:
        return rel, []
    out = subprocess.run([objdump, "-d", "--no-show-raw-insn", path],
                         capture_output=True, text=True, errors="replace")
    text = isa.instructions(out.stdout)
    diffs = []
    for level, ref in REFERENCE_X86.items():
        rs, cs = _spans(ref, text), _spans(CURRENT_X86[level], text)
        if rs != cs:
            diffs.append((level, len(rs), len(cs)))
    return rel, diffs


# Every token the x86 patterns care about, as bare mnemonics and as the fuller
# forms objdump emits (suffixes, operand markers).  --verify-factoring mutates
# each of these and checks the reference and live patterns still agree.
_FUZZ_TOKENS = [
    "%ymm0", "%zmm1", "{%k1}",
    "vpternlog", "vpternlogd", "vpternlogq", "vpcompress", "vpcompressd",
    "vpexpand", "vpexpandd", "vpconflict", "vpconflictd",
    "vgatherpf", "vgatherpf0dps", "vscatter", "vscatterdps",
    "vrangep", "vrangepd", "vrangeps", "vreducep", "vreducepd",
    "vfpclass", "vfpclasspd",
    "vfmadd", "vfmadd213sd", "vfmsub", "vfmsub231ps",
    "vfnmadd", "vfnmadd213sd", "vfnmsub", "vfnmsub231ps",
    "vperm2i128", "vpbroadcast", "vpbroadcastd",
    "bzhi", "pdep", "pext", "mulx", "rorx", "sarx", "shlx", "shrx",
    "andn", "blsi", "blsr", "blsmsk", "lzcnt", "movbe",
    "popcnt", "pcmpgtq", "pblend", "pblendw", "pblendvb", "ptest",
    "roundps", "roundpd", "roundss", "roundsd",
    "pmovzx", "pmovzxbw", "pmovsx", "pmovsxbd",
    "crc32", "crc32b", "crc32q", "cmpxchg16b",
]

# Nine operand contexts, chosen to exercise \b the way real objdump text does:
# bare, with operands, tab- and space-padded, glued to a word char on each side
# (which suppresses the boundary and must stay a non-match), and embedded.
_FUZZ_CONTEXTS = [
    "{}",
    "{} %eax,%ebx",
    "\t{}\t%xmm0,%xmm1",
    "  {}  ",
    "x{}",
    "{}x",
    "0x{}",
    "{},%rax",
    "foo {} bar",
]

_FUZZ_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789 %{}.,"


def _mutations(t):
    """t plus every single-character deletion, substitution, insertion and
    truncation -- the near-misses a too-wide factoring would start accepting."""
    yield t
    for i in range(len(t)):
        yield t[:i] + t[i + 1:]
        for c in _FUZZ_ALPHABET:
            yield t[:i] + c + t[i + 1:]
            yield t[:i] + c + t[i:]
    for c in _FUZZ_ALPHABET:
        yield t + c
    for i in range(1, len(t)):
        yield t[:i]


def verify_factoring():
    """Brute-force reference-vs-live equivalence for the x86 patterns.

    No tree, no objdump: pure pattern algebra.  For every mutation of every
    token in every context, require the reference and live patterns to return
    the same verdict AND the same finditer spans.  A single disagreement fails
    the run and prints the offending string, which is exactly the 'blsm' class
    of bug this change exists to not introduce.
    """
    total = verdict_diff = span_diff = 0
    seen = set()
    examples = []
    for tok in _FUZZ_TOKENS:
        for mut in _mutations(tok):
            for ctx in _FUZZ_CONTEXTS:
                s = ctx.format(mut)
                if s in seen:
                    continue
                seen.add(s)
                for level, ref in REFERENCE_X86.items():
                    cur = CURRENT_X86[level]
                    total += 1
                    if bool(ref.search(s)) != bool(cur.search(s)):
                        verdict_diff += 1
                        if len(examples) < 20:
                            examples.append((level, "verdict", repr(s)))
                    if _spans(ref, s) != _spans(cur, s):
                        span_diff += 1
                        if len(examples) < 20:
                            examples.append((level, "span", repr(s)))
    print(f"isa-bench --verify-factoring: {total} strings "
          f"({len(seen)} unique x 3 patterns)")
    print(f"  verdict disagreements: {verdict_diff}")
    print(f"  span disagreements:    {span_diff}")
    for level, kind, s in examples:
        print(f"  DIFF {level} {kind}: {s}")
    ok = verdict_diff == 0 and span_diff == 0
    print("  RESULT:", "identical" if ok else "PATTERNS DIFFER")
    return 0 if ok else 1


def objdump_only(args):
    """The subprocess half alone: disassemble and measure, parse nothing."""
    path, _root, objdump, _machine = args
    out = subprocess.run([objdump, "-d", "--no-show-raw-insn", path],
                         capture_output=True, text=True, errors="replace")
    return len(out.stdout)


def objdump_and_instructions(args):
    """objdump, plus instructions() -- but none of the pattern searches.

    The middle term.  Subtracting the three passes gives the split inside the
    Python half, which is the thing nobody has yet: instructions() does TWO
    regex operations per line, a match and a sub, over ~100 million lines, while
    the searches are four passes over the joined text.  Either could dominate,
    and they call for completely different fixes -- so measure before choosing,
    having already been wrong once about why x86 is slower.
    """
    path, _root, objdump, _machine = args
    out = subprocess.run([objdump, "-d", "--no-show-raw-insn", path],
                         capture_output=True, text=True, errors="replace")
    return len(isa.instructions(out.stdout))


def find_targets(root, objdump):
    targets = []
    for dirpath, _d, filenames in os.walk(root):
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            if os.path.islink(p) or fn.endswith((".a", ".la", ".py", ".pyc")):
                continue
            m = isa.elf_machine(p)
            if m in (isa.EM_X86_64, isa.EM_AARCH64):
                targets.append((p, root, objdump, m))
    return targets


def timed(fn):
    t0 = time.perf_counter()
    result = fn()
    return time.perf_counter() - t0, result


def run_pool(executor_cls, targets, jobs, fn, **kw):
    with executor_cls(max_workers=jobs, **kw) as pool:
        return list(pool.map(fn, targets))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=None,
                    help="required for every mode except --verify-factoring")
    ap.add_argument("--objdump", default=None)
    ap.add_argument("--jobs", default=None,
                    help="comma-separated worker counts (default: <ncpu> only; "
                         "pass e.g. 1,2,4 to see how it scales, at the cost of "
                         "a full scan per count per executor)")
    ap.add_argument("--json", dest="json_out", default=None)
    ap.add_argument("--compare-executors", action="store_true",
                    help="also run the thread pool and diff its results against "
                         "the process pool.  That question is settled -- x2.15 "
                         "and x2.13, identical results -- and re-asking it costs "
                         "a full serialised scan, 21 minutes on linux-64.")
    ap.add_argument("--compare-patterns", action="store_true",
                    help="run the scanner's live x86 patterns and the frozen "
                         "pre-factoring reference set over every ELF object and "
                         "require byte-identical match spans per file.  This is "
                         "the gate the factoring had to pass -- any difference "
                         "means the accepted language changed.")
    ap.add_argument("--verify-factoring", action="store_true",
                    help="prove reference-vs-live x86 pattern equivalence by "
                         "brute force over single-character mutations in nine "
                         "operand contexts.  Needs no tree; fast; run it first.")
    a = ap.parse_args(argv)

    # Pure pattern algebra: no root, no objdump, no disassembly.
    if a.verify_factoring:
        return verify_factoring()

    if not a.root:
        ap.error("--root is required unless --verify-factoring")
    root = os.path.abspath(a.root)
    objdump = a.objdump
    if not objdump:
        cand = sorted(glob.glob(os.path.join(root, "bin", "*-objdump")))
        objdump = cand[0] if cand else shutil.which("objdump")
    if not objdump:
        print("isa-bench: no objdump available -- run me before slim/prune",
              file=sys.stderr)
        return 1

    # Only the real worker count by default.  Each entry costs a FULL scan per
    # executor, and on linux-64 a full scan is ~20 minutes -- so the original
    # default of {1, ncpu} was four scans plus an objdump pass, around 87
    # minutes, which does not fit in any sane step budget.  The comparison that
    # decides anything is threads versus processes at the width the gate
    # actually runs at; jobs=1 is a scaling curve, available on request.
    ncpu = os.cpu_count() or 4
    counts = ([int(x) for x in a.jobs.split(",")] if a.jobs else [ncpu])

    targets = find_targets(root, objdump)
    if not targets:
        print(f"isa-bench: no ELF objects under {root}", file=sys.stderr)
        return 1

    # fork, explicitly: the scanner was loaded from a path rather than imported,
    # so a spawned child could not re-import it.  Linux-only, which is what CI
    # and the container are.
    try:
        ctx = multiprocessing.get_context("fork")
    except ValueError:
        ctx = None
    pool_kw = {"mp_context": ctx} if ctx is not None else {}
    procs = concurrent.futures.ProcessPoolExecutor

    # Per-file span diff of live vs reference x86 patterns.  One objdump pass,
    # no timing -- correctness only.  A faster gate that reports something
    # different is not a faster gate, and this is what proves it does not.
    if a.compare_patterns:
        n_x86 = sum(1 for t in targets if t[3] == isa.EM_X86_64)
        print(f"isa-bench --compare-patterns: {n_x86} x86 of {len(targets)} "
              f"objects (aarch64 patterns unchanged, skipped)")
        results = run_pool(procs, targets, ncpu, compare_one, **pool_kw)
        differing = [(rel, d) for rel, d in results if d]
        for rel, diffs in differing:
            for level, rn, cn in diffs:
                print(f"  DIFFER {rel}: {level} reference={rn} live={cn} spans")
        if a.json_out:
            with open(a.json_out, "w") as fh:
                json.dump({"root": root, "x86_objects": n_x86,
                           "differing_files": [r for r, _ in differing]},
                          fh, indent=1, sort_keys=True)
        if differing:
            print(f"  RESULT: {len(differing)} file(s) DIFFER -- factoring "
                  f"changed the accepted language")
            return 1
        print(f"  RESULT: all {n_x86} x86 objects identical, span for span")
        return 0

    report = {"root": root, "objdump": objdump, "cpus": ncpu,
              "objects": len(targets), "runs": {}}

    print(f"isa-bench: {len(targets)} ELF objects under {root}")
    print(f"           objdump {objdump}, {ncpu} cpus")

    # THREE passes over the same objects, all at full width and all with
    # processes, so the differences between them are the phases and nothing
    # else:
    #
    #   A  objdump                          the subprocess half
    #   B  objdump + instructions()         adds the per-line match and sub
    #   C  objdump + instructions + search  adds the four pattern searches
    #
    # B - A is instructions(); C - B is the searches.  Which of those dominates
    # decides what a fix even looks like -- a cheaper line filter and a cheaper
    # alternation are unrelated changes -- and the 9.5x gap between the
    # architectures is not explained by search count alone.
    t_a, sizes = timed(lambda: run_pool(procs, targets, ncpu, objdump_only, **pool_kw))
    total_bytes = sum(sizes)
    report["objdump_only_seconds"] = round(t_a, 2)
    report["disassembly_bytes"] = total_bytes
    print(f"\n  A objdump              {t_a:7.1f}s   "
          f"({total_bytes / 1e6:.0f} MB of disassembly)")

    t_b, kept = timed(lambda: run_pool(procs, targets, ncpu,
                                       objdump_and_instructions, **pool_kw))
    report["objdump_instructions_seconds"] = round(t_b, 2)
    report["instruction_text_bytes"] = sum(kept)
    print(f"  B + instructions()     {t_b:7.1f}s   "
          f"({sum(kept) / 1e6:.0f} MB kept as instruction text)")

    for jobs in counts:
        t_c, r_proc = timed(lambda: run_pool(procs, targets, jobs,
                                             isa.scan_one, **pool_kw))
        row = {"processes_seconds": round(t_c, 2)}
        line = f"  C + searches           {t_c:7.1f}s   (jobs={jobs})"

        if a.compare_executors:
            t_thread, r_thread = timed(lambda: run_pool(
                concurrent.futures.ThreadPoolExecutor, targets, jobs,
                isa.scan_one))
            row["threads_seconds"] = round(t_thread, 2)
            row["speedup"] = round(t_thread / t_c, 2) if t_c else None
            # A faster gate that reports something different is not a faster
            # gate.  Settled for the executor swap; kept because it is the shape
            # any future change to the scanner has to pass.
            same = dict(r_thread) == dict(r_proc)
            row["identical_results"] = same
            line += (f"   threads {t_thread:7.1f}s  x{t_thread / t_c:.2f}"
                     + ("  results identical" if same else "  RESULTS DIFFER"))

        report["runs"][str(jobs)] = row
        print(line)

    # The split this exists to produce.
    jobs = counts[-1]
    t_c = report["runs"][str(jobs)]["processes_seconds"]
    t_instr = t_b - t_a
    t_search = t_c - t_b
    report["instructions_seconds"] = round(t_instr, 2)
    report["searches_seconds"] = round(t_search, 2)
    report["python_seconds_estimate"] = round(t_c - t_a, 2)
    print(f"\n  where the python time goes, at jobs={jobs}:")
    for label, secs in (("objdump      (A)", t_a),
                        ("instructions (B-A)", t_instr),
                        ("searches     (C-B)", t_search)):
        pct = 100 * secs / t_c if t_c else 0
        print(f"    {label:20}{secs:8.1f}s  {pct:5.1f}%")

    if a.json_out:
        with open(a.json_out, "w") as fh:
            json.dump(report, fh, indent=1, sort_keys=True)
        print(f"  -> {a.json_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
