#!/usr/bin/env bash
# relocate/patchelf.sh -- NOT YET IMPLEMENTED (sprint item S4/S5).
# See docs/RELOCATABLE-STACK-PLAN.md for the specified behaviour.
set -euo pipefail
echo "relocate/patchelf.sh: not implemented yet (see docs/RELOCATABLE-STACK-PLAN.md)" >&2
exit 1

# S4, specified:
#   - enumerate ELF by magic (\x7fELF); skip .a, scripts, symlinks (patch the
#     target once)
#   - per file: rel=$(realpath --relative-to=$(dirname f) $STACK/lib)
#     new rpath = $ORIGIN/$rel  (plus $ORIGIN for objects in lib/)
#   - patchelf --remove-rpath && patchelf --force-rpath --set-rpath ...
#   - RPATH not RUNPATH by default: DT_RPATH outranks a customer's polluted
#     LD_LIBRARY_PATH.  RPATH_MODE=runpath is the debugging escape hatch.
#   - do NOT --set-interpreter; we rely on host glibc meeting GLIBC_FLOOR
#   - idempotent and re-runnable
