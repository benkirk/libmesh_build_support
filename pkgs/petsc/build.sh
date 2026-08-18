#!/usr/bin/env bash
# PETSc.  Ported from the v0 static stack:  git show v0-static-stack:petsc/build.sh
#
# The option set is deliberately v0's, not a fresh opinion about what PETSc
# ought to enable.  Those flags are what this stack has shipped and what libMesh
# downstream expects; adding to them is a separate decision from making the
# stack relocatable.  Three things changed, each forced by the new design:
#
#   1. --with-shared-libraries=1.  The entire point of the rewrite.
#   2. BLAS/LAPACK come from conda instead of --download-fblaslapack.  v0 built
#      its own reference BLAS (or scavenged the host's /lib64 static one); we
#      have a tuned OpenBLAS in the prefix already, and shipping two BLAS
#      implementations in one tree is how you get subtly wrong answers.
#   3. configure.log is kept under $WORK/logs rather than copied into the
#      install prefix -- same repeatability, without putting a build artifact
#      in the tarball.
#
# Everything else -- the --download- TPL set, the unset prelude, the glob-cd,
# -g -O2 -- is carried across as-is.
. "${TOPDIR}/lib/build_common.sh"

activate_toolchain
list_build_env
# git: several of the --download- packages below are fetched from a repository
# rather than a tarball.  It comes from the builder image, not the conda env, so
# assert it here -- a missing git otherwise surfaces deep inside PETSc's
# configure as something much less obvious.
require curl tar make git

download_src "${PKG_URL}"

# The trailing glob is v0's and is load-bearing: asking for '3.13' downloads a
# tarball that unpacks to '3.13.6'.
cd "${BUILD_TMP}"/${PKG_NAME}-${PKG_VERSION}* && log "building in $(pwd)"

# v0's prelude.  PETSc's configure takes its compilers from --with-cc and
# friends and objects to being told twice; PETSC_DIR/PETSC_ARCH leaking in from
# the environment is a classic way to build against the wrong tree.
#
# LDFLAGS and CPPFLAGS are unset for the same reason, and they are OURS --
# activate_toolchain sets them a few lines above.  PETSc records the flags it
# was configured with and passes them to every --download- package; an
# -I/-L into the prefix confuses TPL detection into finding headers it was
# meant to build.  The rpath they carried is not lost: relocate/patchelf.sh
# rewrites every rpath in the tree afterwards regardless.
unset CC CXX FC F77 LDFLAGS CPPFLAGS PETSC_DIR PETSC_ARCH

case "${BLAS_PROVIDER}" in
  mkl)      blaslapack=( "--with-blaslapack-dir=${STACK}" ) ;;
  *)        blaslapack=( "--with-blaslapack-lib=${STACK}/lib/libopenblas.so" ) ;;
esac

# PETSc searches PATH for a bare 'ar' and explicitly IGNORES $AR -- it says so,
# in its own configure output -- then stops with
#
#     Could not find a suitable archiver.  Use --with-ar to specify an archiver.
#
# conda's binutils ships only triplet-prefixed names (x86_64-conda-linux-gnu-ar)
# and the builder image installs no binutils at all, deliberately.  So this
# worked only on base images that happen to carry their own: measured,
# almalinux 8 and 9 ship /usr/bin/ar and /usr/bin/ranlib, ubuntu and
# opensuse/leap ship neither.  The RHEL bases were quietly lending PETSc an
# archiver, exactly as they were quietly lending the ISA selftest an objdump.
#
# Naming the toolchain's own is what PETSc's error message asks for, and it is
# the same rule the compilers already follow: what the host happens to carry is
# not this build's business.
ar_bin="$(command -v "${AR:-ar}" 2>/dev/null || true)"
ranlib_bin="$(command -v "${RANLIB:-ranlib}" 2>/dev/null || true)"
[ -n "${ar_bin}" ] \
  || { echo "no archiver: neither \$AR nor a bare 'ar' is on PATH" >&2; exit 1; }
[ -n "${ranlib_bin}" ] \
  || { echo "no ranlib: neither \$RANLIB nor a bare 'ranlib' is on PATH" >&2; exit 1; }
log "archiver ${ar_bin}, ranlib ${ranlib_bin}"

# Note there is no --with-hdf5 here.  v0's PETSc had none either -- HDF5 enters
# the stack through libMesh, which is where the mesh I/O actually lives.
#
# The two additions to v0's "-g -O2" are compiler-compatibility flags, not
# choices about how PETSc is built.  Both restore behaviour that newer GCC
# changed out from under the pinned TPL sources:
#
#   -Wno-implicit-function-declaration  GCC 14 promoted implicit declarations
#     from a warning to an error.  ScaLAPACK's BLACS is pre-C99 and is full of
#     them (BI_imvcopy, BI_TransDist, ...), so --download-scalapack fails to
#     compile outright.  Measured, not anticipated.
#   -fallow-argument-mismatch  the gfortran >= 10 counterpart, for legacy
#     Fortran that passes mismatched types to MPI routines.
#
# --download-suitesparse-cmake-arguments=-DBUILD_TESTING=OFF: do not build
# SuiteSparse's demo programs, which this stack neither runs nor ships.
#
# Measured on PETSc 3.23.7 (aarch64), where they are what fails the build:
# SuiteSparse's own SUITESPARSE_DEMOS defaults OFF, but CHOLMOD/CMakeLists.txt
# gates them on 'SUITESPARSE_DEMOS OR BUILD_TESTING', and BUILD_TESTING is ON by
# default.  Linking cholmod_di_demo then dies --
#
#     ld: warning: libopenblas.so.0, needed by libcholmod.so.5.3.1, not found
#         (try using -rpath or -rpath-link)
#     make[3]: *** [CHOLMOD/.../cholmod_di_demo] Error 1
#     Error running make on  SUITESPARSE
#
# -- because a demo executable needs an -rpath-link to resolve a dependency of
# the library it links, and nothing supplies one.  The LIBRARIES this stack
# actually installs are unaffected; relocate/patchelf.sh gives every one of them
# an $ORIGIN rpath afterwards.  Turning the demos off is the narrower fix than
# putting $STACK/lib on LD_LIBRARY_PATH for the whole PETSc build, and it is
# also the honest one: nothing here wanted them built.
#
# The older SuiteSparse that PETSc 3.20.5 downloads does not build them, so this
# is a no-op on the default profile -- verified against the artifact, not
# assumed.
#
# These reach every --download- package, which is the point: PETSc passes its
# flags down to each TPL's own build system, and the TPLs are the old code.
python3 ./configure \
    --with-debugging=0 --with-shared-libraries=1 \
    --with-ssl=0 \
    --with-szlib=0 \
    --with-spooles=1 --download-spooles=yes \
    --with-ml=1 --download-ml=yes \
    --with-suitesparse=1 --download-suitesparse=yes \
    --download-suitesparse-cmake-arguments=-DBUILD_TESTING=OFF \
    --with-superlu=1 --download-superlu=yes \
    --with-scalapack=1 --download-scalapack=yes \
    "${blaslapack[@]}" --with-x=0 \
    --with-hypre=1 --download-hypre=yes \
    --prefix="${STACK}" \
    --with-cc="$(command -v mpicc)" \
    --with-cxx="$(command -v mpicxx)" \
    --with-fc="$(command -v mpif90)" \
    --with-ar="${ar_bin}" \
    --with-ranlib="${ranlib_bin}" \
    --CFLAGS="-g -O2 -Wno-implicit-function-declaration" \
    --CXXFLAGS="-g -O2" \
    --FFLAGS="-g -O2 -fallow-argument-mismatch"

make PETSC_DIR="$(pwd)" all install

# Kept for repeatability and for the next person debugging a TPL, as in v0 --
# but out of the prefix, since it is a record of the build, not part of it.
[ -f configure.log ] && cp configure.log "${WORK}/logs/petsc-configure.log"

clean_build_tmp
log "done"
