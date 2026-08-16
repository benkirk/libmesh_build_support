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

  relocate/isa-bench.py --root <stack> [--jobs 1,2,4] [--json out.json]
                        [--compare-patterns <other-isa-scan.py>]

Requires a tree that has not been slimmed or pruned yet -- after 'make all'
there is no objdump left and the objects are stripped, so the only useful
moment is between 'make build' and 'make all'.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import glob
import importlib.util
import json
import multiprocessing
import os
import shutil
import subprocess
import sys
import time


def load_scanner(path=None, name="isa_scan"):
    """Import isa-scan.py, whose hyphen makes it unimportable by name.

    Registered in sys.modules under the given name so that
    ProcessPoolExecutor can pickle scan_one by reference: pickle stores
    module+qualname, and the forked child resolves it out of the inherited
    sys.modules.  --compare-patterns loads a SECOND scanner file the same
    way, under a distinct name, so both copies coexist and both pickle.
    """
    if path is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "isa-scan.py")
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


isa = load_scanner()


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
    ap.add_argument("--root", required=True)
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
    ap.add_argument("--compare-patterns", metavar="SCANNER_PY",
                    help="a second isa-scan.py (e.g. 'git show main:relocate/"
                         "isa-scan.py > /tmp/old.py') to run over the same tree "
                         "and diff per-file against this one.  ANY difference is "
                         "a failure: a faster gate that reports something "
                         "different is not a faster gate.  Exits non-zero on "
                         "difference.")
    a = ap.parse_args(argv)

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

    report = {"root": root, "objdump": objdump, "cpus": ncpu,
              "objects": len(targets), "runs": {}}

    print(f"isa-bench: {len(targets)} ELF objects under {root}")
    print(f"           objdump {objdump}, {ncpu} cpus")

    # fork, explicitly: the scanner was loaded from a path rather than imported,
    # so a spawned child could not re-import it.  Linux-only, which is what CI
    # and the container are.
    try:
        ctx = multiprocessing.get_context("fork")
    except ValueError:
        ctx = None
    pool_kw = {"mp_context": ctx} if ctx is not None else {}
    procs = concurrent.futures.ProcessPoolExecutor

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

    # Two PATTERN SETS over the same tree, per-file.  This is the gate any
    # change to the patterns has to pass: the executor comparison above asks
    # "same results, different plumbing", this asks "same results, different
    # regexes" -- and per-file, not as a boolean, because the per-file
    # 'features' dicts are exactly what validate.sh consumes.
    rc = 0
    if a.compare_patterns:
        alt = load_scanner(os.path.abspath(a.compare_patterns),
                           name="isa_scan_alt")
        jobs = counts[-1]
        t_alt, r_alt = timed(lambda: run_pool(procs, targets, jobs,
                                              alt.scan_one, **pool_kw))
        this, other = dict(r_proc), dict(r_alt)
        differing = sorted(rel for rel in this.keys() | other.keys()
                           if this.get(rel) != other.get(rel))
        t_this = report["runs"][str(jobs)]["processes_seconds"]
        report["compare_patterns"] = {
            "alt_scanner": os.path.abspath(a.compare_patterns),
            "alt_seconds": round(t_alt, 2),
            "this_seconds": t_this,
            "differing_files": differing,
        }
        print(f"\n  patterns: this {t_this:7.1f}s   {a.compare_patterns} "
              f"{t_alt:7.1f}s   x{t_alt / t_this:.2f}" if t_this else "")
        if differing:
            rc = 1
            print(f"  RESULTS DIFFER on {len(differing)} file(s) -- "
                  f"the pattern change is WRONG, speed is irrelevant:")
            for rel in differing[:20]:
                print(f"    {rel}\n      this: {this.get(rel)}\n"
                      f"      alt : {other.get(rel)}")
            if len(differing) > 20:
                print(f"    ... and {len(differing) - 20} more")
        else:
            print(f"  per-file results identical across all "
                  f"{len(this)} objects")

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
    return rc


if __name__ == "__main__":
    sys.exit(main())
