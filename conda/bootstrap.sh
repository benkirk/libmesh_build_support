#!/usr/bin/env bash
# Install miniforge into $CONDA_HOME, then create the build env AT $STACK.
#
# The env IS the redistributable prefix -- there is no separate install prefix
# and no harvest/copy step.  See docs/RELOCATABLE-STACK-PLAN.md.
set -euo pipefail

: "${CONDA_HOME:?}" "${STACK:?}" "${TARGET_PLATFORM:?}"
: "${GLIBC_FLOOR:?}" "${GCC_VERSION:?}" "${BLAS_PROVIDER:?}"
: "${MPI_FAMILY:?}" "${MPI_VERSION:?}" "${MPI_PROVIDER:?}"
: "${HDF5_VERSION:?}" "${HDF5_PARALLEL:?}"
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
# HDF5_PARALLEL changes the solve, so it has to be part of the lock identity --
# otherwise a serial lock would silently satisfy a parallel request.
case "${HDF5_PARALLEL}" in yes) h5tag=hdf5par ;; *) h5tag=hdf5ser ;; esac
lock="${TOPDIR}/conda/lock/${ctag}-${BLAS_PROVIDER}-${MPI_FAMILY}-${h5tag}.lock"

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
    cmake ninja make pkg-config python
    #  - patchelf is deliberately NOT pinned >= 0.18, despite that being the
    #    version that fixes program-header-growth corruption: conda-forge
    #    marked every 0.18.0 build 'broken' on main across all Linux subdirs,
    #    and 0.19.1 never left the 'patchelf_dev' label.  0.17.2 is the newest
    #    installable one.  relocate/patchelf.sh compensates by verifying that
    #    nothing but the RPATH changed, which is a stronger check than the
    #    version pin would have been.  See amendment A15.
    patchelf
  )
  case "${BLAS_PROVIDER}" in
    openblas) specs+=( libopenblas "blas=*=openblas" ) ;;
    mkl)      specs+=( mkl mkl-devel "blas=*=mkl" ) ;;
    *) echo "unknown BLAS_PROVIDER: ${BLAS_PROVIDER}" >&2; exit 1 ;;
  esac
  if [ "${MPI_PROVIDER}" = conda ]; then
    specs+=( "${MPI_FAMILY}=${MPI_VERSION}" )
  fi

  #  - never take a bare 'hdf5': the feedstock adds +100 to the nompi build
  #    number ("prioritize nompi via build number"), so an unqualified request
  #    resolves to serial by accident rather than by intent, and a migration
  #    could flip it silently.  Pin the variant explicitly either way.
  #    Serial is the default: it is what v0 shipped (--disable-parallel), and
  #    the mpi_* variant makes libhdf5 link libmpi, pulling MPI into the
  #    closure of everything that touches HDF5.
  case "${HDF5_PARALLEL}" in
    no)  specs+=( "hdf5=${HDF5_VERSION}.*=nompi_*" ) ;;
    yes) specs+=( "hdf5=${HDF5_VERSION}.*=mpi_${MPI_FAMILY}_*" ) ;;
    *) echo "HDF5_PARALLEL must be yes or no, got: ${HDF5_PARALLEL}" >&2; exit 1 ;;
  esac

  # git: several PETSc --download-* packages fetch from git rather than a
  # tarball.  Pruned before packing like the rest of the build tools.
  specs+=( zlib git )

  "${CONDA}" create -y -p "${STACK}" "${specs[@]}"
fi

#-------------------------------------------------------------------------------
# Record what we actually got, for the manifest and for debugging.
mkdir -p "${STACK}/etc"
"${CONDA}" list -p "${STACK}" --explicit > "${STACK}/etc/conda-explicit.txt"

echo "conda env ready at ${STACK}"
