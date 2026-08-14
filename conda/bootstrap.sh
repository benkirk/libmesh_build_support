#!/usr/bin/env bash
# Install miniforge into $CONDA_HOME, then create the build env AT $STACK.
#
# The env IS the redistributable prefix -- there is no separate install prefix
# and no harvest/copy step.  See docs/RELOCATABLE-STACK-PLAN.md.
set -euo pipefail

: "${CONDA_HOME:?}" "${STACK:?}" "${TARGET_PLATFORM:?}"
: "${GLIBC_FLOOR:?}" "${GCC_VERSION:?}" "${BLAS_PROVIDER:?}"
: "${MPI_FAMILY:?}" "${MPI_VERSION:?}" "${MPI_PROVIDER:?}"
TOPDIR="${TOPDIR:-$PWD}"

case "${TARGET_PLATFORM}" in
  linux-64)      arch=x86_64  ; ctag=linux-64      ;;
  linux-aarch64) arch=aarch64 ; ctag=linux-aarch64 ;;
  *) echo "unsupported TARGET_PLATFORM: ${TARGET_PLATFORM}" >&2; exit 1 ;;
esac

# MKL is x86-only.  Fail at config time rather than deep in a solve.
if [ "${BLAS_PROVIDER}" = mkl ] && [ "${ctag}" != linux-64 ]; then
  echo "BLAS_PROVIDER=mkl is x86-64 only; use openblas on ${ctag}" >&2
  exit 1
fi

#-------------------------------------------------------------------------------
# miniforge, hermetically.  Never reads or writes ~/.condarc.
export CONDARC="${CONDA_HOME}/condarc"
export CONDA_PKGS_DIRS="${CONDA_PKGS_DIRS:-${CONDA_HOME}/pkgs}"

if [ ! -x "${CONDA_HOME}/bin/conda" ]; then
  echo "installing miniforge into ${CONDA_HOME}"
  mkdir -p "$(dirname "${CONDA_HOME}")"
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  url="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-${arch}.sh"
  curl -fsSL -o "${tmp}/miniforge.sh" "${url}"
  bash "${tmp}/miniforge.sh" -b -f -p "${CONDA_HOME}"
fi

mkdir -p "${CONDA_HOME}"
cat > "${CONDARC}" <<'RC'
channels:
  - conda-forge
channel_priority: strict
auto_activate_base: false
RC

CONDA="${CONDA_HOME}/bin/conda"
"${CONDA}" --version

#-------------------------------------------------------------------------------
# Create the env at $STACK.  Prefer a checked-in explicit lock; fall back to
# solving from the yml so a fresh platform is not blocked on a lock existing.
lock="${TOPDIR}/conda/lock/${ctag}-${BLAS_PROVIDER}-${MPI_FAMILY}.lock"

if [ -s "${lock}" ]; then
  echo "creating ${STACK} from lock ${lock##*/}"
  "${CONDA}" create -y -p "${STACK}" --file "${lock}"
else
  echo "no lock for ${ctag}-${BLAS_PROVIDER}-${MPI_FAMILY}; solving from spec"
  echo "  (run 'make conda-lock' to freeze this solve)"

  # Two measured traps, both encoded here deliberately:
  #  - never ask for the bare libblas/liblapack metapackages: they drag in
  #    ~560 MB of MKL alongside the openblas actually selected.
  #  - never ask for the mpich-mpicc/mpicxx/mpifort split packages: they are
  #    stale and pin mpich back to 3.2.1 (2017).  Modern mpich ships the
  #    wrappers, mpiexec and hydra_pmi_proxy in the main package.
  specs=(
    "gcc_${ctag}=${GCC_VERSION}"
    "gxx_${ctag}=${GCC_VERSION}"
    "gfortran_${ctag}=${GCC_VERSION}"
    "sysroot_${ctag}=${GLIBC_FLOOR}"
    cmake ninja make pkg-config patchelf python
  )
  case "${BLAS_PROVIDER}" in
    openblas) specs+=( libopenblas "blas=*=openblas" ) ;;
    mkl)      specs+=( mkl mkl-devel "blas=*=mkl" ) ;;
    *) echo "unknown BLAS_PROVIDER: ${BLAS_PROVIDER}" >&2; exit 1 ;;
  esac
  if [ "${MPI_PROVIDER}" = conda ]; then
    specs+=( "${MPI_FAMILY}=${MPI_VERSION}" )
  fi
  specs+=( hdf5 zlib )

  "${CONDA}" create -y -p "${STACK}" "${specs[@]}"
fi

#-------------------------------------------------------------------------------
# Record what we actually got, for the manifest and for debugging.
mkdir -p "${STACK}/etc"
"${CONDA}" list -p "${STACK}" --explicit > "${STACK}/etc/conda-explicit.txt"

echo "conda env ready at ${STACK}"
