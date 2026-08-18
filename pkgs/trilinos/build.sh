#!/usr/bin/env bash
# Trilinos.  Ported from:  git show v0-static-stack:trilinos/build.sh
#
# v0 enabled exactly two packages -- Sacado and Pliris -- and turned Kokkos off.
# That narrowness is the point of this recipe and is preserved: Trilinos is
# enormous, and what this stack has ever shipped is a small corner of it.  One
# part of that narrowness is now a per-profile CHOICE rather than a fixed
# answer: see TRILINOS_KOKKOS further down.
#
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

# CMake derives the archiver from the compiler's own name -- it looks for
# <toolchain-prefix>ar -- and the compiler here is 'mpif90', which carries no
# prefix to derive one from.  So it falls back to a bare 'ar' on PATH, and
# conda's binutils ships only x86_64-conda-linux-gnu-ar.  On a base image that
# carries no /usr/bin/ar the link line comes out as
#
#     CMAKE_AR-NOTFOUND qc libVerifyFortran.a ...
#
# in TriBITS' Fortran/C mangling probe, before Trilinos configures at all.
# Measured: almalinux 8 and 9 ship ar and ranlib, ubuntu and opensuse/leap ship
# neither.  Same lender, same silence, as PETSc's archiver and the ISA
# selftest's objdump -- this is the third consumer of the base image's binutils.
ar_bin="$(command -v "${AR:-ar}" 2>/dev/null || true)"
ranlib_bin="$(command -v "${RANLIB:-ranlib}" 2>/dev/null || true)"
[ -n "${ar_bin}" ] \
  || { echo "no archiver: neither \$AR nor a bare 'ar' is on PATH" >&2; exit 1; }
[ -n "${ranlib_bin}" ] \
  || { echo "no ranlib: neither \$RANLIB nor a bare 'ranlib' is on PATH" >&2; exit 1; }
log "archiver ${ar_bin}, ranlib ${ranlib_bin}"

# TPL_ENABLE_MPI=ON makes TriBITS locate mpicc/mpicxx/mpif90 on PATH, which
# activate_toolchain has already pointed at $STACK/bin.  v0 relied on the same
# thing; naming the compilers explicitly here would only duplicate it.

# TRILINOS_KOKKOS: 'off' (the default, and every profile but 'bleeding') passes
# v0's -DTrilinos_ENABLE_Kokkos=OFF; 'auto' passes NOTHING and lets Trilinos'
# own defaults decide.
#
# The flag is v0's answer to a question Trilinos 13 asked, carried forward
# without being re-asked.  profiles/README.md predicted it would not survive a
# version bump -- "Kokkos became a mandatory dependency of Sacado in later
# Trilinos" -- and that prediction is wrong: 16-1-0 configures and builds with
# it, because Sacado's Kokkos dependence is OPTIONAL ("Setting
# Sacado_ENABLE_Kokkos=OFF because Sacado has an optional library dependence on
# disabled package Kokkos"), and the enabled set comes out the same four
# packages as 14-4-0.  So this is a real choice, not a constraint, and a
# customer building 16.1.0 by hand passes no Kokkos flag at all -- which is what
# 'auto' reproduces.
kokkos=()
case "${TRILINOS_KOKKOS:-off}" in
  auto) log "Kokkos: no flag; Trilinos' own defaults decide" ;;
  off)  kokkos=( -DTrilinos_ENABLE_Kokkos=OFF )
        log "Kokkos: explicitly OFF (v0's answer)" ;;
  *) echo "TRILINOS_KOKKOS must be 'off' or 'auto', got: ${TRILINOS_KOKKOS}" >&2
     exit 1 ;;
esac

# TRILINOS_OPENMP: 'on' passes -DTrilinos_ENABLE_OpenMP=ON, 'off' (the default)
# passes nothing.
#
# -DKokkos_ENABLE_OPENMP=ON is NOT the flag, and reaching for it is the obvious
# mistake: packages/kokkos/cmake/kokkos_configure_trilinos.cmake re-sets that
# cache variable with FORCE from Trilinos_ENABLE_OpenMP, defaulting it to OFF,
# so a -D on the command line is silently overwritten and the build goes green
# with the backend still off.  Measured; see docs/plans/implemented/.
#
# The flag is project-wide rather than Kokkos-only -- Teuchos and Epetra are
# compiled differently too -- which is why it is its own knob.
openmp=()
case "${TRILINOS_OPENMP:-off}" in
  on)  openmp=( -DTrilinos_ENABLE_OpenMP=ON )
       log "OpenMP: ON (Trilinos-wide; drives Kokkos' OpenMP backend)" ;;
  off) log "OpenMP: no flag" ;;
  *) echo "TRILINOS_OPENMP must be 'on' or 'off', got: ${TRILINOS_OPENMP}" >&2
     exit 1 ;;
esac

cmake \
    -DCMAKE_INSTALL_PREFIX="${STACK}" \
    -DCMAKE_AR="${ar_bin}" \
    -DCMAKE_RANLIB="${ranlib_bin}" \
    -DTPL_ENABLE_MPI=ON \
    -DTrilinos_ENABLE_Sacado=ON \
    -DTrilinos_ENABLE_Pliris=ON \
    ${kokkos[@]+"${kokkos[@]}"} \
    ${openmp[@]+"${openmp[@]}"} \
    -DBUILD_SHARED_LIBS=ON \
    -DTPL_ENABLE_DLlib=ON \
    -DTPL_ENABLE_BLAS=ON -DTPL_BLAS_LIBRARIES="${blas}" \
    -DTPL_ENABLE_LAPACK=ON -DTPL_LAPACK_LIBRARIES="${lapack}" \
    "${src}"

make ${MAKE_J_L}
make install

clean_build_tmp
log "done"
