#!/usr/bin/env bash
# Package B -- the customer's application, built entirely against package A.
#
# The interesting line in this file is the one that is NOT here: there is no
# reference to libMesh, PETSc, HDF5 or MPI anywhere in it.  B's compile and
# link flags come out of `pkg-config gust-core`, which A installed.
#
# Using pkg-config rather than hardcoded -I/-L paths is not decoration.  A's
# gust-core.pc contains an absolute prefix pointing at this build's $STACK, and
# relocate/fixup-text.sh has to rewrite it when the tree moves.  Consuming the
# .pc here means the demo would notice a .pc that was malformed, and a customer
# building against the SHIPPED tree gets a .pc that is correct for wherever
# they unpacked it.
. "${TOPDIR}/lib/build_common.sh"

PKG_DIR_ABS="$(cd "${TOPDIR}/${PKG_DIR}" && pwd)"
# shellcheck source=customer/common/gust_source.sh
. "${PKG_DIR_ABS}/../common/gust_source.sh"

activate_toolchain
list_build_env
require install pkg-config

#-------------------------------------------------------------------------------
# 1. Sources -- PKG_SOURCE is local (default), tarball or git, exactly as A.
gust_fetch_src

src="$(_gust_srcdir)"
cd "${src}" || exit 1

#-------------------------------------------------------------------------------
# 2. Ask package A how to build against it.
#
# activate_toolchain already put ${STACK}/lib/pkgconfig on PKG_CONFIG_PATH.
# The explicit --exists check is worth its two lines: without it, pkg-config
# prints nothing, the variables come back empty, and the failure surfaces much
# later as a confusing "gust/gust_core.h: No such file or directory" rather
# than as "package A did not install its .pc".
pkg-config --exists gust-core || {
  echo "pkg-config cannot find gust-core." >&2
  echo "  PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-<unset>}" >&2
  echo "  expected ${STACK}/lib/pkgconfig/gust-core.pc from package A" >&2
  exit 1
}

core_version="$(pkg-config --modversion gust-core)"
app_cflags="$(pkg-config --cflags gust-core)"
app_libs="$(pkg-config --libs gust-core)"

log "gust-core ${core_version} found via pkg-config"
log "  --cflags: ${app_cflags}"
log "  --libs:   ${app_libs}"

#-------------------------------------------------------------------------------
# 3. Compile -- the same program in three languages, against the same ABI.
#
# ORDINARY COMPILERS, NOT THE MPI WRAPPERS.  ${CC}/${CXX}/${FC} come from the
# conda toolchain via activate_toolchain, with the ISA wrappers ahead of them on
# PATH.  Package A is built with mpicxx because A genuinely is an MPI code;
# using mpicc here would undercut the entire claim, since B is supposed not to
# know that MPI is involved.  The binaries still load libmpi at run time --
# transitively, through libgustcore.so's own DT_NEEDED, which is exactly the
# point.
#
# -rpath-link is the one flag not coming from pkg-config, and it is not a
# cheat: link-time only, leaves nothing in the binary, and needed because ld
# has to resolve libgustcore.so's OWN DT_NEEDED entries (libmesh_opt, libpetsc,
# libmpi) to complete the link.  ld uses neither -L nor -rpath for that search.
# A .pc file cannot express it, and it says nothing about what B depends on --
# only about where ld may look while finalising A's chain.
appdef="-DGUST_APP_VERSION=\"${PKG_VERSION}\""
rpath_link="-Wl,-rpath-link,${STACK}/lib"

log "compiling gust-hello (C99)"
# shellcheck disable=SC2086
"${CC:-gcc}" -std=c99 -O2 -g -Wall ${app_cflags} "${appdef}" \
      -o gust-hello gust_hello.c \
      ${app_libs} "${rpath_link}"

# C++ with OpenMP.  This is the one front-end that changes what the ARTIFACT
# must contain rather than only what it consumes: -fopenmp puts a DT_NEEDED on
# libgomp, so libgomp has to survive conda/prune.list and resolve through
# $ORIGIN once the tarball is unpacked elsewhere.  It is not in prune.list and
# relocate/validate.sh already knows it as a CPUID-dispatching library, so it
# ships -- and this binary running from the relocated tree is the proof.
log "compiling gust-hello-omp (C++17 + OpenMP)"
# shellcheck disable=SC2086
"${CXX:-g++}" -std=c++17 -O2 -g -Wall -fopenmp ${app_cflags} "${appdef}" \
      -o gust-hello-omp gust_hello_omp.cpp \
      ${app_libs} "${rpath_link}"

# Fortran 2003, via the gust_core.mod that package A installed.  Note that the
# include flag is the SAME -I${includedir} pkg-config already emits for C and
# C++: gfortran searches -I for modules, so one .pc serves all three.
log "compiling gust-hello-f03 (Fortran 2003)"
# shellcheck disable=SC2086
"${FC:-gfortran}" -std=f2003 -O2 -g -Wall ${app_cflags} \
      -o gust-hello-f03 gust_hello_f03.f90 \
      ${app_libs} "${rpath_link}"

# The link lines above claim B needs exactly one library from the stack side.
# Put the evidence in the log rather than the claim -- DT_NEEDED is what the
# loader will actually go looking for -- and fail outright if a front-end
# reached around package A.
for b in gust-hello gust-hello-omp gust-hello-f03; do
  if command -v readelf >/dev/null 2>&1; then
    needed="$(readelf -d "${b}" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
    log "${b} DT_NEEDED: ${needed}"
    case "${needed}" in
      *libmesh*|*libpetsc*|*libmpi*)
        echo "${b} links the stack directly; package A is supposed to hide it" >&2
        exit 1 ;;
    esac
  fi
done

#-------------------------------------------------------------------------------
# 4. Install.  bin/ because these are real programs a user would run; and
#    libexec/stack-tests/ because that is where test/run.sh looks -- which is
#    what makes them travel in the tarball and get run again from the relocated
#    tree, rather than being built once and forgotten.
#
# All three go into stack-tests deliberately.  They exercise different runtime
# dependencies -- libgomp for the OpenMP build, libgfortran for the Fortran one
# -- and those are separate claims about what survived the prune, so they are
# worth separate binaries rather than one that does all three.
log "installing into ${STACK}"
install -d "${STACK}/bin" "${STACK}/libexec/stack-tests"
for b in gust-hello gust-hello-omp gust-hello-f03; do
  install -m 0755 "${b}" "${STACK}/bin/"
  install -m 0755 "${b}" "${STACK}/libexec/stack-tests/"
done

clean_build_tmp
log "done"
