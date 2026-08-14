#!/usr/bin/env bash
# relocate/prune.sh -- NOT YET IMPLEMENTED (sprint item S4/S5).
# See docs/RELOCATABLE-STACK-PLAN.md for the specified behaviour.
set -euo pipefail
echo "relocate/prune.sh: not implemented yet (see docs/RELOCATABLE-STACK-PLAN.md)" >&2
exit 1

# S5, specified: remove the packages named in conda/prune.list BY THEIR
# conda-meta file lists, never by path globbing -- removal must be exactly as
# precise as installation was.  Whole-package granularity is what keeps
# dlopen'd plugins (MKL dispatch, OpenBLAS threading, Hydra/PMI, hwloc) safe.
# Honours SHIP_PYTHON for the '#@python-only' section of the list.
# Reports bytes removed per package so two builds can be diffed.
