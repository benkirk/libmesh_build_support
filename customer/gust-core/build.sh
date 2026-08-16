#!/usr/bin/env bash
# Package A -- the customer's layer on top of the base stack.
#
# Produces four things, and each one is there to be exercised by a later stage
# rather than merely built:
#
#   include/gust/gust_core.h        the public API.  Package B's only input.
#   lib/libgustcore.so              C++/libMesh behind a C ABI.  Must acquire an
#                                   $ORIGIN rpath and keep resolving libmesh_opt,
#                                   libpetsc and libmpi after relocation.
#   lib/pkgconfig/gust-core.pc      how B finds A.  Contains an absolute prefix
#                                   at build time, so relocate/fixup-text.sh has
#                                   to rewrite it -- and B is what proves it did.
#   libexec/stack-tests/gust-core-selftest
#                                   picked up automatically by test/run.sh, in
#                                   place and again from the unpacked tarball.
#
# It also does the thing a customer actually does first: take an example out of
# the installed libMesh, build it against the installation, and run it.
. "${TOPDIR}/lib/build_common.sh"

# PKG_DIR arrives relative to TOPDIR with a trailing slash; resolve it once,
# up front, because the rest of this script cd's around.
PKG_DIR_ABS="$(cd "${TOPDIR}/${PKG_DIR}" && pwd)"
# shellcheck source=customer/common/gust_source.sh
. "${PKG_DIR_ABS}/../common/gust_source.sh"

activate_toolchain
list_build_env
require make install

#-------------------------------------------------------------------------------
# 1. Sources -- PKG_SOURCE is local (default), tarball or git.  All three land
#    in the same place, so nothing below this line knows which one ran.
gust_fetch_src

src="$(_gust_srcdir)"
cd "${src}" || exit 1

#-------------------------------------------------------------------------------
# 2. Compile the library against the INSTALLED libMesh.
#
# libmesh-config is libMesh's own documented contract for building against an
# installation, and it is what a customer would reach for -- so the demo uses
# it rather than reconstructing the flags by hand.  METHOD=opt matches what the
# stack installs.
LIBMESH_CONFIG="${STACK}/bin/libmesh-config"
[ -x "${LIBMESH_CONFIG}" ] || {
  echo "no ${LIBMESH_CONFIG} -- gust-core requires libmesh (PKG_DEPS)" >&2
  exit 1
}

export METHOD=opt
lm_cxxflags="$("${LIBMESH_CONFIG}" --cppflags --cxxflags --include)"
lm_libs="$("${LIBMESH_CONFIG}" --libs)"
log "libmesh-config --cxxflags: ${lm_cxxflags}"
log "libmesh-config --libs:     ${lm_libs}"

# The absolute -rpath is correct and intentional; relocate/patchelf.sh rewrites
# every rpath in the tree to $ORIGIN-relative afterwards, so do not write
# $ORIGIN here.  -rpath-link is a SEPARATE search path and is not redundant
# with it: linking against libmesh_opt.so makes ld resolve that library's own
# DT_NEEDED entries (libnetcdf, libpetsc, ...), and ld uses neither -L nor
# -rpath for that search.  It is link-time only and leaves nothing in the
# binary, so it cannot affect relocation.  Same reasoning as test/smoke/Makefile.
stack_ld=("-L${STACK}/lib" "-Wl,-rpath,${STACK}/lib" "-Wl,-rpath-link,${STACK}/lib")

log "compiling libgustcore.so"
# Unquoted on purpose: libmesh-config emits a flag LIST that has to word-split.
# shellcheck disable=SC2086
mpicxx -O2 -g -fPIC ${lm_cxxflags} -I. -c gust_core.C -o gust_core.o

# -soname so the DT_NEEDED consumers record is the library's name rather than
# whatever path happened to be on the link line.
# shellcheck disable=SC2086
mpicxx -shared -Wl,-soname,libgustcore.so -o libgustcore.so gust_core.o \
       "${stack_ld[@]}" ${lm_libs}

#-------------------------------------------------------------------------------
# 3. Install, INCLUDING the .pc file -- before building anything that consumes
#    it, so what gets tested is the installed layout rather than the build tree.
log "installing into ${STACK}"
install -d "${STACK}/include/gust" \
           "${STACK}/lib/pkgconfig" \
           "${STACK}/libexec/stack-tests" \
           "${STACK}/libexec/gust"

install -m 0644 gust_core.h  "${STACK}/include/gust/gust_core.h"
install -m 0755 libgustcore.so "${STACK}/lib/libgustcore.so"

# The Fortran 2003 face of the same ABI.  Interface-only, so this produces a
# .mod to install and an object file to throw away -- see the header comment in
# gust_core_mod.f90 for why the module deliberately contains no procedure.
#
# -J writes the .mod straight into the install tree.  It goes in include/
# rather than include/gust/ because gfortran searches -I for modules, and the
# -I${includedir} that gust-core.pc already emits is then enough for a Fortran
# consumer too: one .pc serves all three languages.
log "compiling the Fortran 2003 interface module"
"${FC:-gfortran}" -O2 -g -J"${STACK}/include" -c gust_core_mod.f90 -o gust_core_mod.o
[ -f "${STACK}/include/gust_core.mod" ] || {
  echo "no gust_core.mod produced by ${FC:-gfortran}" >&2
  exit 1
}

# The module SOURCE as well, because a .mod is gfortran-version specific and
# the shipped artifact has no compiler in it.  A customer building against the
# unpacked tarball with their own gfortran needs this file, not the .mod.
install -d "${STACK}/share/gust"
install -m 0644 gust_core_mod.f90 "${STACK}/share/gust/"

# Generated rather than shipped verbatim, because prefix= must be this build's
# $STACK.  That absolute path is the point: relocate/fixup-text.sh rewrites it
# when the tree moves, and package B linking successfully is the check that the
# rewrite produced something usable.
#
# -Wl,-rpath in Libs: is deliberate.  A consumer of this .pc is building a
# binary that has to find libgustcore.so at run time, and after relocation that
# rpath is $ORIGIN-relative like every other one in the tree.
cat > "${STACK}/lib/pkgconfig/gust-core.pc" <<EOF
prefix=${STACK}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: gust-core
Description: Gust Dynamics core layer -- FEM services over libMesh/PETSc/MPI
Version: ${PKG_VERSION}
Libs: -L\${libdir} -Wl,-rpath,\${libdir} -lgustcore
Cflags: -I\${includedir}
EOF
log "wrote ${STACK}/lib/pkgconfig/gust-core.pc"

#-------------------------------------------------------------------------------
# 4. The self-test, compiled with a C compiler against the INSTALLED header.
#
# Being C is the assertion -- see the comment in gust_selftest.c.  It links
# -lgustcore and nothing else from the stack: no -lmesh, no -lpetsc, no -lmpi.
# If that link succeeds, libgustcore.so really does carry its own dependencies.
log "compiling gust-core-selftest (C, against the installed header)"
mpicc -O2 -g -I"${STACK}/include" -o gust-core-selftest gust_selftest.c \
      "${stack_ld[@]}" -lgustcore

install -m 0755 gust-core-selftest "${STACK}/libexec/stack-tests/"

#-------------------------------------------------------------------------------
# 5. The customer's first real question: can I build one of the shipped libMesh
#    examples against this installation, and does it run?
#
# libMesh installs example SOURCES but no binaries, so this compiles ex4 the
# same way test/smoke/Makefile does and puts the result in libexec/gust/.
#
# NOT in libexec/stack-tests/: test/run.sh invokes everything there with no
# arguments and in an arbitrary working directory, and ex4 takes options and
# writes mesh files.  The harness already runs ex4 properly, with -d/-n and in
# a scratch directory, via its own run_ex4.
ex4_dir=""
for d in "${STACK}/examples/introduction/ex4" \
         "${STACK}/examples/introduction/introduction_ex4"; do
  [ -d "${d}" ] && { ex4_dir="${d}"; break; }
done

if [ -z "${ex4_dir}" ]; then
  echo "no installed libMesh introduction example found; looked in:" >&2
  echo "  ${STACK}/examples/introduction/{ex4,introduction_ex4}" >&2
  exit 1
fi

log "building libMesh's ${ex4_dir##*/} against the installed stack"
ex4_src=()
while IFS= read -r f; do ex4_src+=("${f}"); done \
  < <(find "${ex4_dir}" -maxdepth 1 -name '*.C' -type f | sort)
[ "${#ex4_src[@]}" -gt 0 ] || { echo "no *.C sources in ${ex4_dir}" >&2; exit 1; }

# shellcheck disable=SC2086
mpicxx -O2 -g ${lm_cxxflags} -o gust-ex4 "${ex4_src[@]}" \
       -Wl,-rpath-link,"${STACK}/lib" ${lm_libs}

# Run it, from a scratch directory, because it writes mesh output.  Small on
# purpose: this is a "does the customer's build of it work" check, not a
# convergence study.  test/run.sh's run_ex4 is the enforcing gate -- it asserts
# the ExodusII files are actually non-empty, which is the failure this stack has
# actually seen.
rundir="$(mktemp -d "${WORK}/gust-ex4.XXXXXX")"
log "running gust-ex4 -d 2 -n 8 in ${rundir}"
( cd "${rundir}" && "${src}/gust-ex4" -d 2 -n 8 ) > "${rundir}/ex4.out" 2>&1 || {
  echo "--- gust-ex4 failed; tail of its output ---" >&2
  tail -25 "${rundir}/ex4.out" >&2
  exit 1
}
log "gust-ex4 ok: $(wc -l < "${rundir}/ex4.out") lines of output, wrote $(find "${rundir}" -name '*.e' | wc -l) ExodusII file(s)"
rm -rf "${rundir}"

install -m 0755 gust-ex4 "${STACK}/libexec/gust/"

clean_build_tmp
log "done"
