#!/usr/bin/env bash
# Freeze the current solve into
# conda/lock/<platform>-<blas>-<mpi>-<hdf5ser|hdf5par>.lock.
# Locks are what CI consumes, so a conda-forge migration cannot silently
# change an artifact underneath us.  Every knob that changes the solve has to
# be in the filename, or a lock for one configuration would satisfy another.
set -euo pipefail
: "${CONDA_HOME:?}" "${STACK:?}"
TOPDIR="${TOPDIR:-$PWD}"
: "${TARGET_PLATFORM:=linux-64}" "${BLAS_PROVIDER:=openblas}" "${MPI_FAMILY:=mpich}"
: "${HDF5_PARALLEL:=no}"

[ -d "${STACK}/conda-meta" ] || { echo "no env at ${STACK}; run 'make conda' first" >&2; exit 1; }

case "${HDF5_PARALLEL}" in yes) h5tag=hdf5par ;; *) h5tag=hdf5ser ;; esac

mkdir -p "${TOPDIR}/conda/lock"
out="${TOPDIR}/conda/lock/${TARGET_PLATFORM}-${BLAS_PROVIDER}-${MPI_FAMILY}-${h5tag}.lock"
"${CONDA_HOME}/bin/conda" list -p "${STACK}" --explicit > "${out}"
echo "wrote ${out}  ($(grep -c '^https' "${out}" || true) packages)"
