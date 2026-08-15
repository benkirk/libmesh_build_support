#!/usr/bin/env python3
"""Render one table for a whole stack.yml fan-out, from per-job JSON sidecars.

The problem this solves is not presentation.  stack.yml's build and verify jobs
carry 'continue-on-error: ${{ inputs.experimental }}', and extended.yml sets
that on mkl, parallel HDF5 and the alternate builder distro.  A failure in any
of them is therefore reported as a GREEN workflow run, and the only way to find
out otherwise is to open each job in turn.  A weekly matrix nobody opens is a
weekly matrix nobody reads -- which extended.yml's own header already warns
about for a different reason.

So the section that matters here is the last one: experimental configurations
that failed are named explicitly, with the fact that the run stayed green said
out loud.  Everything above it is context for that.

Reads every *.json in the directory given as argv[1] and writes markdown to
stdout, for '>> $GITHUB_STEP_SUMMARY'.  Sidecars look like:

    {"kind": "build", "config": "linux-64 · openblas · mpich · hdf5no",
     "base": "almalinux:9", "outcome": "success", "experimental": false,
     "seconds": 3107, "tarball": "libmesh-stack-0.1.0-...tar.gz",
     "size": "112M", "packages": 59, "glibc_floor": "2.28",
     "isa": "x86-64-v2"}

    {"kind": "verify", "config": "linux-64 · openblas · mpich · hdf5no",
     "base": "almalinux:8", "outcome": "success", "experimental": false,
     "seconds": 96, "distro": "AlmaLinux 8.10", "glibc": "2.28"}

Written to be robust against missing keys: a job that died before it could fill
in the interesting fields still has to appear in the table, because that is
precisely the run someone is reading the summary for.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

OK, BAD, UNKNOWN = "✅", "❌", "·"


def hms(seconds) -> str:
    try:
        s = int(seconds)
    except (TypeError, ValueError):
        return "—"
    if s < 60:
        return f"{s}s"
    return f"{s // 60}m{s % 60:02d}s"


def mark(outcome: str) -> str:
    if outcome == "success":
        return OK
    if not outcome or outcome == "skipped":
        return UNKNOWN
    return BAD


def render(records: list[dict]) -> str:
    builds = sorted((r for r in records if r.get("kind") == "build"),
                    key=lambda r: (r.get("config", ""), r.get("base", "")))
    verifies = [r for r in records if r.get("kind") == "verify"]

    out: list[str] = []

    # ---------------------------------------------------------------- builds
    out.append("## Stack matrix\n")
    if builds:
        out.append("| Configuration | Built on | Result | Time | Tarball | Size "
                   "| Packages | glibc floor | ISA |")
        out.append("|---|---|:--:|--:|---|--:|--:|---|---|")
        for b in builds:
            out.append("| " + " | ".join([
                b.get("config", "?"),
                f"`{b.get('base', '?')}`",
                mark(b.get("outcome", "")),
                hms(b.get("seconds")),
                f"`{b['tarball']}`" if b.get("tarball") else "—",
                str(b.get("size") or "—"),
                str(b.get("packages") or "—"),
                str(b.get("glibc_floor") or "—"),
                f"`{b['isa']}`" if b.get("isa") else "—",
            ]) + " |")
    else:
        out.append("_No build results were collected._")
    out.append("")

    # --------------------------------------------------------------- verifies
    # One row per configuration, one column per base image.  This shape is the
    # point: "it runs on almalinux:9 but not on opensuse/leap:15" is the single
    # most useful thing the matrix can say, and it is invisible in a job list.
    if verifies:
        bases = sorted({v.get("base", "?") for v in verifies})
        configs = sorted({v.get("config", "?") for v in verifies})
        cell = {(v.get("config"), v.get("base")): v for v in verifies}

        out.append("### Verify — does that tarball run somewhere it was not built?\n")
        out.append("| Configuration | " + " | ".join(f"`{b}`" for b in bases) + " |")
        out.append("|---|" + "|".join(":--:" for _ in bases) + "|")
        for c in configs:
            row = [c]
            for b in bases:
                v = cell.get((c, b))
                row.append(f"{mark(v.get('outcome', ''))} {hms(v.get('seconds'))}"
                           if v else UNKNOWN)
            out.append("| " + " | ".join(row) + " |")
        out.append("")

        glibcs = sorted({f"`{v['base']}` glibc {v['glibc']}"
                         for v in verifies if v.get("glibc")})
        if glibcs:
            out.append("<details><summary>What each verify image actually was</summary>\n")
            for g in glibcs:
                out.append(f"- {g}")
            out.append("\n</details>\n")

    # ----------------------------------------------------- the whole point
    hidden = [r for r in records
              if r.get("experimental") and r.get("outcome") not in ("success", "skipped", None)]
    if hidden:
        out.append("### ⚠️ Experimental configurations that failed\n")
        out.append("These are marked `experimental: true`, so **this run is green "
                   "regardless of what follows.** That is the intended behaviour "
                   "— see the table in §S7 — but it is not a reason to leave them "
                   "unreported.\n")
        for r in sorted(hidden, key=lambda r: (r.get("config", ""), r.get("base", ""))):
            what = r.get("kind", "job")
            where = f" on `{r['base']}`" if r.get("base") else ""
            out.append(f"- **{r.get('config', '?')}** — {what}{where}: "
                       f"`{r.get('outcome')}`")
        out.append("")

    return "\n".join(out) + "\n"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: render_matrix_summary.py <dir>", file=sys.stderr)
        return 2
    src = Path(sys.argv[1])
    if not src.is_dir():
        # Not an error worth failing a build over: if no sidecars were collected
        # the summary should say so, not break the job that reports it.
        print("_No result sidecars were collected._")
        return 0

    records: list[dict] = []
    for path in sorted(src.glob("*.json")):
        try:
            records.append(json.loads(path.read_text()))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"warning: skipping {path.name}: {exc}", file=sys.stderr)

    sys.stdout.write(render(records))
    return 0


if __name__ == "__main__":
    sys.exit(main())
