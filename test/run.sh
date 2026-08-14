#!/usr/bin/env bash
# test/run.sh MODE   (MODE = inplace | relocated)
#
# Builds and runs the smoke example against a stack.  In 'relocated' mode
# $STACK points at an unpacked tarball somewhere else on disk, and the
# prebuilt binary is exercised FIRST -- that is the guarantee that matters.
set -euo pipefail

MODE="${1:-inplace}"
: "${STACK:?}"
SMOKE_RANKS="${SMOKE_RANKS:-4}"
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/smoke" && pwd)"

[ -f "${SMOKE_DIR}/Makefile" ] || {
  echo "test/smoke/ has no Makefile yet -- awaiting the libMesh example." >&2
  echo "Contract: 'make all' builds, 'make run' runs, given LIBMESH_DIR," >&2
  echo "PETSC_DIR and MPIEXEC in the environment." >&2
  exit 1
}

. "${STACK}/activate.sh"

echo "=== smoke: ${MODE} (ranks=${SMOKE_RANKS}) ==="
make -C "${SMOKE_DIR}" all
make -C "${SMOKE_DIR}" run
"${STACK}/bin/mpiexec" -n "${SMOKE_RANKS}" "${SMOKE_DIR}/smoke"
