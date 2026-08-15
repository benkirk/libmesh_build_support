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

# The build root can outlive a change of TARGET_PLATFORM -- in the container it
# is a named volume that persists across runs, so switching between linux-64 and
# linux-aarch64 leaves a miniforge for the wrong architecture in place.  The
# symptom is 'Error 126' from make, which says nothing useful.  Detect it and
# rebuild instead: .conda is a throwaway toolchain root, so this costs a
# download, not any real work.
if [ -x "${CONDA_HOME}/bin/conda" ] && \
   [ "$(cat "${CONDA_HOME}/.arch" 2>/dev/null)" != "${arch}" ]; then
  echo "miniforge in ${CONDA_HOME} is for $(cat "${CONDA_HOME}/.arch" 2>/dev/null || echo 'an unknown arch'), need ${arch}"
  echo "removing and reinstalling (it is a throwaway toolchain root)"
  rm -rf "${CONDA_HOME}"
fi

if [ ! -x "${CONDA_HOME}/bin/conda" ]; then
  echo "installing miniforge into ${CONDA_HOME}"
  mkdir -p "$(dirname "${CONDA_HOME}")"
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  url="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-${arch}.sh"
  curl -fsSL -o "${tmp}/miniforge.sh" "${url}"
  bash "${tmp}/miniforge.sh" -b -f -p "${CONDA_HOME}"
  echo "${arch}" > "${CONDA_HOME}/.arch"
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

#-------------------------------------------------------------------------------
# The prefix is SEALED once source builds have installed into it.
#
# 'conda create -p $STACK' does not ask whether the prefix already holds
# anything -- it recreates it, and everything a source build put there is gone.
# This is not hypothetical and it is not obscure: conda.stamp depends on THIS
# FILE, so simply editing bootstrap.sh marks the conda stage out of date, and
# the next 'make build' silently destroys the tree before rebuilding it.  That
# is how a completed PETSc install -- 8510 files, twenty-five minutes -- was
# lost while adding one package to the spec list.
#
# So: an existing env is left alone.  Re-provisioning is a deliberate act, and
# when there are source installs to lose it has to be spelled out.
if [ -d "${STACK}/conda-meta" ]; then
  if [ "${CONDA_RECREATE:-0}" = 1 ]; then
    echo "CONDA_RECREATE=1: removing the existing env at ${STACK}"
    rm -rf "${STACK}"
  elif [ -s "${STACK}/etc/source-files.txt" ]; then
    echo "env at ${STACK} is SEALED: $(wc -l < "${STACK}/etc/source-files.txt") path(s)"
    echo "  were installed there by source builds.  Recreating it would destroy them."
    echo "  Nothing to do.  To start over: 'make distclean', or CONDA_RECREATE=1."
    exit 0
  else
    echo "env already exists at ${STACK}; leaving it alone"
    echo "  (CONDA_RECREATE=1 to rebuild it from scratch)"
    exit 0
  fi
fi

# A lock, once checked in, SHADOWS the spec list below -- which is the whole
# point of a lock, and also a trap worth naming.  Editing the specs while a lock
# exists changes nothing, silently: the env is still built from the frozen list,
# and the package you added is simply absent.  (Measured, twice, adding
# diffutils.)  IGNORE_LOCK=1 forces a fresh solve; 'make conda-lock' then
# refreezes it.
if [ -s "${lock}" ] && [ "${IGNORE_LOCK:-0}" != 1 ]; then
  echo "creating ${STACK} from lock ${lock##*/}"
  echo "  (spec changes in conda/bootstrap.sh are IGNORED while this lock exists;"
  echo "   use 'make conda IGNORE_LOCK=1' then 'make conda-lock' to change it)"
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
    #  - cmake and python are pinned to the era of the sources we build, not to
    #    the newest available.  Both are BUILD tools: conda/prune.list drops
    #    them before packing, so neither pin is visible in the artifact, and
    #    neither is a statement about what the stack supports.
    #
    #    cmake < 4: CMake 4.0 removed compatibility with
    #    'cmake_minimum_required(VERSION <3.5)' and hard-errors on it.  Trilinos
    #    14-4-0 still declares 2.6, 2.6.4, 2.7, 2.8.4, 2.8.8, 3.0 and 3.1 across
    #    its sub-projects (measured, not assumed), so CMake 4 cannot configure
    #    it at all.
    #
    #    python < 3.13: PETSc 3.20.5's configure imports 'xdrlib', which was
    #    removed from the standard library in Python 3.13.  Unpinned, the solve
    #    took 3.14 and PETSc died with "No module named 'xdrlib'" before it
    #    reached a compiler.
    #  - diffutils: PETSc's configure fails with "Could not locate diff
    #    executable".  It goes here rather than into docker/Dockerfile.builder
    #    because the conda env is the toolchain -- make, cmake and pkg-config
    #    already come from here, and the builder image is deliberately kept as
    #    poor as a customer's host.
    #  - m4: libMesh's bundled netcdf configure stops with "Cannot find m4
    #    utility".  Same category as diffutils -- a build tool the conda env
    #    owns, not a host prerequisite.
    "cmake<4" "python<3.13" ninja make pkg-config diffutils m4
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
