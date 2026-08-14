#!/usr/bin/env bash
# Freeze the current solve into conda/lock/<platform>-<blas>-<mpi>.lock.
# Locks are what CI consumes, so a conda-forge migration cannot silently
# change an artifact underneath us.
set -euo pipefail
: "${CONDA_HOME:?}" "${STACK:?}"
TOPDIR="${TOPDIR:-$PWD}"
: "${TARGET_PLATFORM:=linux-64}" "${BLAS_PROVIDER:=openblas}" "${MPI_FAMILY:=mpich}"

[ -d "${STACK}/conda-meta" ] || { echo "no env at ${STACK}; run 'make conda' first" >&2; exit 1; }

mkdir -p "${TOPDIR}/conda/lock"
out="${TOPDIR}/conda/lock/${TARGET_PLATFORM}-${BLAS_PROVIDER}-${MPI_FAMILY}.lock"
"${CONDA_HOME}/bin/conda" list -p "${STACK}" --explicit > "${out}"
echo "wrote ${out}  ($(grep -c '^https' "${out}" || true) packages)"
