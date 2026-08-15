#!/usr/bin/env bash
# Trilinos.  Ported from:  git show v0-static-stack:trilinos/build.sh
#
# v0 enabled exactly two packages -- Sacado and Pliris -- and turned Kokkos off.
# That narrowness is the point of this recipe and is preserved: Trilinos is
# enormous, and what this stack has ever shipped is a small corner of it.
# Three changes, each forced by the new design:
#
#   1. -DBUILD_SHARED_LIBS=ON.
#   2. -DTPL_ENABLE_DLlib=ON.  v0 turned dlopen off because it was linking
#      everything statically; a shared build needs it back.
#   3. BLAS/LAPACK point at conda's OpenBLAS.  v0 pointed them at PETSc's
#      from-source libfblas.a, which is also why v0's Trilinos had to be built
#      after PETSc.  It no longer does -- see pkg.mk.
. "${TOPDIR}/lib/build_common.sh"

activate_toolchain
list_build_env
require curl tar make cmake

download_src "${PKG_URL}"

# The tarball unpacks to Trilinos-trilinos-release-<version>, not to
# <name>-<version> like everything else.
src="${BUILD_TMP}/Trilinos-trilinos-release-${PKG_VERSION}"
[ -d "${src}" ] || { echo "unexpected source layout under ${BUILD_TMP}" >&2; ls "${BUILD_TMP}" >&2; exit 1; }

mkdir -p "${BUILD_TMP}/build"
cd "${BUILD_TMP}/build" && log "building in $(pwd)"

case "${BLAS_PROVIDER}" in
  mkl) blas="${STACK}/lib/libmkl_rt.so"    ; lapack="${blas}" ;;
  *)   blas="${STACK}/lib/libopenblas.so"  ; lapack="${blas}" ;;
esac

# TPL_ENABLE_MPI=ON makes TriBITS locate mpicc/mpicxx/mpif90 on PATH, which
# activate_toolchain has already pointed at $STACK/bin.  v0 relied on the same
# thing; naming the compilers explicitly here would only duplicate it.
cmake \
    -DCMAKE_INSTALL_PREFIX="${STACK}" \
    -DTPL_ENABLE_MPI=ON \
    -DTrilinos_ENABLE_Sacado=ON \
    -DTrilinos_ENABLE_Pliris=ON \
    -DTrilinos_ENABLE_Kokkos=OFF \
    -DBUILD_SHARED_LIBS=ON \
    -DTPL_ENABLE_DLlib=ON \
    -DTPL_ENABLE_BLAS=ON -DTPL_BLAS_LIBRARIES="${blas}" \
    -DTPL_ENABLE_LAPACK=ON -DTPL_LAPACK_LIBRARIES="${lapack}" \
    "${src}"

make ${MAKE_J_L}
make install

clean_build_tmp
log "done"
