#!/usr/bin/env python3
"""Measure where relocate/isa-scan.py spends its time.  Changes nothing.

The scan is 40% of the linux-64 build -- 20m36s of 51m47s measured -- and 2m53s
on linux-aarch64 for the same 341 objects, on native runners both times.  A 7x
asymmetry that large is a fact about the code, not about the hardware, and this
exists to find out which part.

The hypothesis it was written to test: isa-scan.py uses a ThreadPoolExecutor.
subprocess.run(objdump) releases the GIL and parallelises properly, but
instructions() -- splitlines, then a match and a sub per line -- and the four to
six full-text regex searches after it are pure Python and hold the GIL, so that
half is serialised across the workers no matter how many there are.  x86-64
disassembly is far bulkier than aarch64 (OpenBLAS DYNAMIC_ARCH alone ships
kernels for every microarchitecture), so the serialised half is much larger
there.  If that is right, a ProcessPoolExecutor is close to a one-line fix.

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


def objdump_only(args):
    """The subprocess half alone: disassemble and measure, parse nothing."""
    path, _root, objdump, _machine = args
    out = subprocess.run([objdump, "-d", "--no-show-raw-insn", path],
                         capture_output=True, text=True, errors="replace")
    return len(out.stdout)


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

    # The subprocess half on its own, at full width.  Everything above this in
    # a full scan is Python.
    secs, sizes = timed(lambda: run_pool(
        concurrent.futures.ThreadPoolExecutor, targets, ncpu, objdump_only))
    total_bytes = sum(sizes)
    report["objdump_only_seconds"] = round(secs, 2)
    report["disassembly_bytes"] = total_bytes
    print(f"\n  objdump alone      {secs:7.1f}s   "
          f"({total_bytes / 1e6:.0f} MB of disassembly)")

    # fork, explicitly: the scanner was loaded from a path rather than imported,
    # so a spawned child could not re-import it.  Linux-only, which is what CI
    # and the container are.
    try:
        ctx = multiprocessing.get_context("fork")
    except ValueError:
        ctx = None

    baseline = None
    for jobs in counts:
        t_thread, r_thread = timed(lambda: run_pool(
            concurrent.futures.ThreadPoolExecutor, targets, jobs, isa.scan_one))
        row = {"threads_seconds": round(t_thread, 2)}
        line = f"  jobs={jobs:<3} threads {t_thread:7.1f}s"

        if ctx is not None:
            t_proc, r_proc = timed(lambda: run_pool(
                concurrent.futures.ProcessPoolExecutor, targets, jobs,
                isa.scan_one, mp_context=ctx))
            row["processes_seconds"] = round(t_proc, 2)
            row["speedup"] = round(t_thread / t_proc, 2) if t_proc else None
            line += f"   processes {t_proc:7.1f}s   x{t_thread / t_proc:.2f}"

            # A faster gate that reports something different is not a faster
            # gate.  This is the check that would have to pass before anyone
            # changes isa-scan.py itself.
            same = dict(r_thread) == dict(r_proc)
            row["identical_results"] = same
            line += "   results identical" if same else "   RESULTS DIFFER"

        if baseline is None:
            baseline = dict(r_thread)
        elif dict(r_thread) != baseline:
            row["identical_results"] = False
            line += "   (differs from jobs=%d)" % counts[0]

        report["runs"][str(jobs)] = row
        print(line)

    # The split the whole exercise is about.
    best = report["runs"][str(counts[-1])]["threads_seconds"]
    python_share = best - report["objdump_only_seconds"]
    report["python_seconds_estimate"] = round(python_share, 2)
    pct = 100 * python_share / best if best else 0
    print(f"\n  python share       {python_share:7.1f}s of {best:.1f}s "
          f"({pct:.0f}%) at jobs={counts[-1]}")

    if a.json_out:
        with open(a.json_out, "w") as fh:
            json.dump(report, fh, indent=1, sort_keys=True)
        print(f"  -> {a.json_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
