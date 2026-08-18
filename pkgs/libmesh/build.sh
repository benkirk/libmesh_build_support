#!/usr/bin/env bash
# libMesh.  Ported from:  git show v0-static-stack:libmesh/build.sh
#
# The option list is v0's, unchanged apart from the static/shared flip.  It is
# long, and every entry in it is a decision someone already made -- including
# the non-obvious ones, which are kept with their reasons:
#
#   --disable-dap        a netcdf option, not a libMesh one.  Stops netcdf
#                        linking libcurl and everything behind it.
#   --disable-strict-lgpl  enables the LGPL-licensed contrib packages.
#   --enable-tecio       Tecplot I/O from contrib.
#   --enable-petsc-required  fail configure if PETSc is not found, rather than
#                        quietly building a libMesh without it.
#   --with-boost=$STACK  Boost comes from the stack; the host is never consulted.
#                        Not v0's: added after a Rocky 8 host with boost-devel
#                        1.66 in /usr/include broke the build.  See the flag.
#   --with-vexcl=no      the other half of the same fix, for contrib/metaphysicl.
#
# Everything below --with-boost is the same argument continued, one optional
# package at a time.  Each of these has a default search that reaches /usr, and
# each records what it finds in the compile line libmesh-config hands customers:
#
#   --with-eigen-include=$STACK/include/eigen3
#                        conda's Eigen.  NOT $STACK/include -- that is where
#                        libMesh's own bundled copy installs itself, and finding
#                        that would be the A30 trap wearing a different hat.
#   --with-tecio-x11-include=$STACK/include
#                        the X11 headers contrib/tecplot/tecio needs.  Without
#                        them tecio.m4 disables Tecplot output SILENTLY, which
#                        is what it has been doing since v0.
#   --enable-glpk, --with-glpk-include, --with-glpk-lib
#                        v0 passed --disable-glpk.  The choice was never
#                        "on or off" but "off, or whatever the host had"; now it
#                        is on, from the stack.
#   --disable-nlopt      no conda-forge nlopt exists without numpy and a python
#                        extension module (conda/bootstrap.sh has the evidence),
#                        so it is explicitly OFF rather than left to probe /usr.
#   XDR                  version-dependent; see the block above configure.
#
# What is deliberately absent: --enable-trilinos.  v0 built Trilinos alongside
# libMesh, never into it.
. "${TOPDIR}/lib/build_common.sh"

activate_toolchain
list_build_env
require make
case "${PKG_SOURCE}" in
  # git mode needs no curl/tar, and the tarball needs no autotools: the release
  # archive is already bootstrapped, which is the whole difference between them.
  tarball) require curl tar ;;
  git)     require git autoconf automake libtool ;;
esac

fetch_src

src="${BUILD_TMP}/${PKG_NAME}-${PKG_VERSION}"
[ -d "${src}" ] || { echo "unexpected source layout under ${BUILD_TMP}" >&2; ls "${BUILD_TMP}" >&2; exit 1; }

# A checkout has no configure script -- 'make dist' is what generates one, and
# that is exactly what we skipped.  Tailed into the log because autoreconf over
# libMesh's contrib tree is long and only its ending is usually interesting.
if [ "${PKG_SOURCE}" = git ]; then
  log "bootstrapping (autoreconf); this takes a few minutes"
  ( cd "${src}" && ./bootstrap ) 2>&1 | tail -40
  [ -x "${src}/configure" ] \
    || { echo "./bootstrap produced no configure script" >&2; exit 1; }
fi

# Out-of-tree, as in v0.
bdir="${BUILD_TMP}/${PKG_NAME}-build"
mkdir -p "${bdir}"
cd "${bdir}" && log "building in $(pwd)"

# Diagnostics that ride the CI artifact next to the package log: configure's
# own config.log, the header the assertions below read, the libmesh-config it
# generated, and contrib/metaphysicl's config.log -- the one place the actual
# compiler error from a Boost probe is written, and until this existed the one
# log a failing configure did not leave behind.  Run from the EXIT trap as well
# as before the build tree is cleaned, so a configure that dies still reports.
save_libmesh_diagnostics () {
  local f
  for f in config.log:libmesh-config.log \
           include/libmesh_config.h:libmesh-config.h \
           contrib/bin/libmesh-config:libmesh-config.sh \
           contrib/metaphysicl/config.log:libmesh-metaphysicl-config.log; do
    [ -f "${bdir}/${f%%:*}" ] && cp -f "${bdir}/${f%%:*}" "${WORK}/logs/${f##*:}"
  done
  return 0
}
# Chained ahead of build_common.sh's manifest trap; the exit status is kept.
_libmesh_exit () { local rc=$?; save_libmesh_diagnostics; _record_source_install; exit "${rc}"; }
trap _libmesh_exit EXIT

# PETSc is installed with --prefix, so PETSC_ARCH is empty by construction.
# Saying so explicitly stops libMesh's configure from picking up a stale value
# and looking for lib/${PETSC_ARCH}/ that was never built.
export PETSC_DIR="${STACK}"
export PETSC_ARCH=""

# --with-boost=$STACK and --with-vexcl=no: point libMesh's configure INTO the
# stack instead of letting it wander the host.
#
# Without them, libMesh's m4/ax_boost_base.m4 walks $BOOST_ROOT /usr /usr/local
# /opt /opt/local for a Boost, and contrib/metaphysicl's optional VexCL probe
# (m4/common/vexcl.m4, via Sigoure boost.m4) walks /usr/include and friends
# too.  The conda compiler never sees the host's /usr/include on its own -- its
# default search path is the sysroot's -- so those explicit probes are the ONLY
# way a host Boost gets in.  On a Rocky 8 host with boost-devel 1.66 it did:
# metaphysicl found /usr/include, took -I/usr/include, could not compile
# boost/system/error_code.hpp with it, and died -- fatal, inside an OPTIONAL
# probe, because the 1.7 branch's metaphysicl predates the fix that made a
# broken Boost non-fatal there.  Had it survived, libMesh proper would have
# adopted the host Boost instead of its bundled subset: LIBMESH_HAVE_EXTERNAL_BOOST
# and -I/usr/include/ baked into the installed libmesh-config and .pc files, a
# host path in a stack whose premise is that the host does not matter.
#
# --with-boost=<dir> makes ax_boost_base look ONLY under <dir>/include and
# forwards to metaphysicl (AX_SUBDIRS_CONFIGURE passes every top-level arg),
# whose boost.m4 then looks only under <dir>/include and <dir> and ignores
# BOOST_ROOT.  $STACK now holds conda's libboost-headers, so both find it there
# as an in-stack EXTERNAL Boost -- which is the intended answer, and why the
# assertion below asks WHERE the Boost is rather than whether there is one.
# libMesh's bundled contrib/boost subset (present through 1.8.x, gone on devel)
# is what a stack without one falls back to.  --with-vexcl=no skips metaphysicl's
# whole VexCL block -- the Boost library chain that was fatal, and an OpenCL header
# probe of /usr/include with it.  VexCL is a metaphysicl test dependency libMesh
# never uses.
#
# Why not the obvious flags: --disable-boost on 1.7/1.8 disables the bundled
# subset too ("without either external or built-in"), changing the artifact;
# --with-boost=no is mishandled by libMesh's CONFIGURE_BOOST -- it skips the
# whole AX_BOOST_BASE body, so external_boost_found stays yes and you get a
# bogus HAVE_EXTERNAL_BOOST with no include path and no subset.  Both checked
# against m4/boost.m4 and m4/ax_boost_base.m4 at v1.7.8, v1.8.0 and devel.
#------------------------------------------------------------------------------
# Fail here if the env does not hold what the flags below are about to point at.
#
# A stale conda/lock is exactly how that happens, and it happens SILENTLY: a
# lock shadows the spec list in conda/bootstrap.sh, so adding a package there
# without refreshing the lock leaves the package absent and every --with- flag
# below pointing at nothing.  configure would then quietly fall back -- to the
# bundled Eigen, to no XDR, to no Tecplot -- and the first evidence would be a
# feature missing from an artifact nobody was looking at.  Two lines here beat
# reading a 4000-line config.log later.
for f in include/boost/version.hpp \
         include/eigen3/Eigen/Dense \
         include/tirpc/rpc/xdr.h \
         include/X11/Intrinsic.h \
         include/X11/X.h \
         include/glpk.h; do
  [ -e "${STACK}/${f}" ] || {
    echo "the env is missing ${f}, which this recipe configures against." >&2
    echo "  Refresh the lock: make conda IGNORE_LOCK=1 && make conda-lock" >&2
    exit 1; }
done

#------------------------------------------------------------------------------
# XDR: the same destination by two different roads, because libMesh changed how
# it asks.
#
# 1.8.x has --with-xdr-include / --with-xdr-libname.  Given them, configure tries
# ONLY that path ("to avoid accidentally bringing in any unwanted system RPC
# headers", says the m4) and records the result in libmesh_optional_INCLUDES and
# _LIBS -- exported, relocatable, exactly what we want.
#
# 1.7.x has neither flag.  Its whole XDR probe is: link-test <rpc/xdr.h> with
# the ambient CPPFLAGS and LIBS, and if that fails, retry with a HARD-CODED
# -I/usr/include/tirpc -ltirpc -- which, on a host that has libtirpc-devel, it
# then writes into libmesh_optional_INCLUDES.  A host path in the artifact.  So
# the ambient flags are the only lever there, and winning that FIRST test is
# what stops the /usr/include/tirpc fallback from ever running.
#
# They are a lever on this build only, though, NOT on what libMesh exports:
# 'libmesh-config --cppflags' emits per-METHOD flags (-DNDEBUG), not configure's
# CPPFLAGS, and 1.7.x records nothing about XDR in libmesh_optional_INCLUDES.
# Consumers are served by the include/rpc symlink above instead -- measured, and
# the reason it exists.
#
# Which road is taken is decided by asking the configure script what it accepts,
# not by parsing PKG_VERSION: PKG_SOURCE=git can be any ref at all, and the flag
# either exists in that source or it does not.
#------------------------------------------------------------------------------
# Put tirpc's headers where an -I${STACK}/include can see them.
#
# conda's libtirpc installs under include/tirpc/rpc/, mirroring the distro
# layout that deliberately keeps those headers away from glibc's own sunrpc
# ones.  Nothing in this stack has glibc sunrpc headers to collide with -- the
# 2.28 sysroot does not ship them, which is exactly why XDR was off here until
# now -- and libMesh's PUBLIC include/libmesh/xdr_cxx.h does
#
#     #include <rpc/rpc.h>
#
# under HAVE_XDR.  On 1.8.x the path reaches a consumer because
# --with-xdr-include is recorded in libmesh_optional_INCLUDES.  On 1.7.x there
# is no such flag and no way to add one: m4/libmesh_optional_packages.m4 sets
# libmesh_optional_INCLUDES="" at the top of the macro, so even a command-line
# assignment is wiped.  Measured on 1.7.9 without this link: a consumer
# compiling '#include <libmesh/xdr_cxx.h>' with exactly the flags
# 'libmesh-config --cppflags --cxxflags --include' emits dies on
# "rpc/rpc.h: No such file or directory".  Turning XDR on would have taken a
# header that compiles today and broken it.
#
# So the include path libMesh already exports is made sufficient.  Relative, so
# it survives relocation; created before configure, so the probe below sees it;
# and the manifest trap records it in etc/source-files.txt, which is what stops
# prune.sh from treating it as a conda-owned path.  The receipt is the contract
# compile after 'make install'.
# All three top-level entries, not just rpc/: rpc/types.h includes <netconfig.h>,
# which tirpc keeps beside rpc/ rather than inside it.  Linking only rpc/ got as
# far as rpc/rpc.h and died on netconfig.h -- found by the contract compile
# below, which is the whole reason it exists.  The result is the layout glibc's
# own sunrpc had in /usr/include: rpc/, rpcsvc/, netconfig.h.
for _e in rpc rpcsvc netconfig.h; do
  [ -e "${STACK}/include/${_e}" ] && continue
  [ -e "${STACK}/include/tirpc/${_e}" ] || continue
  ln -s "tirpc/${_e}" "${STACK}/include/${_e}"
  log "linked include/${_e} -> tirpc/${_e}"
done

xdr_inc="${STACK}/include/tirpc"
xdr_flags=()
xdr_libs=""
if grep -q -- '--with-xdr-include' "${src}/configure"; then
  xdr_flags=( --with-xdr-include="${xdr_inc}" --with-xdr-libname=tirpc )
  log "XDR: --with-xdr-include=${xdr_inc} (this libMesh takes the flag)"
else
  export CPPFLAGS="${CPPFLAGS} -I${xdr_inc}"
  xdr_libs=" -ltirpc"
  log "XDR: via CPPFLAGS and LIBS (this libMesh has no --with-xdr-include)"
fi

# ${arr[@]+"${arr[@]}"} rather than a bare "${arr[@]}": under 'set -u' an empty
# array expansion is an unbound-variable error in bash before 4.4, and
# almalinux:8 ships 4.4.19 -- close enough to the line to not stand on it.
"${src}"/configure \
    --prefix="${STACK}" \
    --enable-shared --disable-static \
    --disable-dependency-tracking \
    --with-cxx="$(command -v mpicxx)" \
    --with-cc="$(command -v mpicc)" \
    --with-f77="$(command -v mpif77)" \
    --with-fc="$(command -v mpif90)" \
    --disable-strict-lgpl \
    --with-thread-model=pthread \
    --enable-blocked-storage \
    --with-methods=opt \
    --enable-unique-id \
    --enable-tecio --with-tecio-x11-include="${STACK}/include" \
    --enable-glpk \
      --with-glpk-include="${STACK}/include" \
      --with-glpk-lib="${STACK}/lib" \
    --disable-nlopt \
    --enable-hdf5 --with-hdf5="${STACK}" \
    --enable-petsc-required \
    --with-boost="${STACK}" \
    --with-vexcl=no \
    --with-eigen-include="${STACK}/include/eigen3" \
    ${xdr_flags[@]+"${xdr_flags[@]}"} \
    PETSC_DIR="${STACK}" \
    LIBS="-lm -L${STACK}/lib -lz${xdr_libs}" \
    --disable-dap

#------------------------------------------------------------------------------
# Repair the netcdf_meta.h that contrib/exodus will actually compile against.
#
# libMesh sets, in configure:
#
#     NETCDF_INCLUDE="-I\$(top_srcdir)/contrib/netcdf/v4/include"
#
# top_srcdir ONLY.  The build tree's include/ -- where the sub-configure writes
# the netcdf_meta.h it just generated -- is never on the include path.  And the
# RELEASE TARBALL ships a netcdf_meta.h in that source directory saying
#
#     #define NC_HAS_NC4  0
#     #define NC_HAS_HDF5 0
#
# which disagrees with the same file in git, where both are 1.  'make dist'
# evidently regenerated it from netcdf_meta.h.in on a machine whose netcdf
# configured without HDF5.  So this bites tarball builds -- ours, and v0's --
# and not a git checkout.
#
# Either way exodus compiles believing netcdf has no HDF5, however netcdf was
# actually built.  ex_utils.c gates on '#if !NC_HAS_HDF5', and with
# --enable-hdf5 libMesh selects EX_NETCDF4|EX_NOCLASSIC for every ExodusII
# write with no runtime override -- so exodus refuses all of them:
#
#     EXODUS: ERROR: File format specified as netcdf-4, but the NetCDF
#     library being used was not configured to enable this format
#
# That is why introduction_ex4 solves correctly and then dies on output.
#
# Why copy rather than delete: netcdf.h defines NC_HAVE_META_H, so exodusII.h
# reaches its '#include "netcdf_meta.h"' unconditionally.  Removing the file
# either breaks the compile or lets some other copy on the include path decide,
# and '#if !NC_HAS_HDF5' reads an undefined macro as 0 either way.  Checked
# against the preprocessor: shipped 0/0 refuses, deleted refuses, 1/1 accepts.
#
# And why copy the GENERATED one rather than seding 1 into the shipped one:
# whatever the sub-configure decided about HDF5 is by definition what the netcdf
# being built supports, so this stays correct if the HDF5 knob changes, and is a
# no-op against a git checkout where the header is already right.
#
# This runs in BOTH source modes, deliberately.  Against a git checkout the copy
# is a no-op -- the checked-in header is already 1/1 -- and running it anyway
# keeps the two modes on one code path and turns the assertion below into a
# cross-check that git's header really is right.  Only the missing-file case is
# mode-dependent: a tarball build has no other source of truth and must stop,
# while a checkout does, so assert against that instead of failing.
# The directory name is discovered, not hard-coded.  1.7.x calls it
# contrib/netcdf/v4 (a real directory in the tarball, a symlink to
# netcdf-c-4.6.2 in git); 1.8.4 dropped the alias and ships
# contrib/netcdf/netcdf-c-4.6.2 alone, which stopped this block with the message
# below rather than silently skipping the repair -- the assertion working, one
# profile before anyone would have noticed the ExodusII writes failing.  Glob for
# whichever it is, in the build tree first because that is the copy configure
# just generated.
gen="$(cd "${bdir}" && ls contrib/netcdf/*/include/netcdf_meta.h 2>/dev/null | head -1)"
[ -n "${gen}" ] || gen="$(cd "${src}" && ls contrib/netcdf/*/include/netcdf_meta.h 2>/dev/null | head -1)"
[ -n "${gen}" ] || { echo "no netcdf_meta.h anywhere under contrib/netcdf; libMesh's contrib layout changed" >&2
                     ls -d "${src}"/contrib/netcdf/*/ >&2; exit 1; }
if [ -f "${gen}" ]; then
  grep -q '#define NC_HAS_HDF5[[:space:]]*1' "${gen}" \
    || { echo "generated netcdf_meta.h reports no HDF5 support:" >&2
         grep NC_HAS_HDF5 "${gen}" >&2; exit 1; }
  cp -f "${gen}" "${src}/${gen}"
  log "installed configure's netcdf_meta.h over the checked-in one"
elif [ "${PKG_SOURCE}" = git ]; then
  # In git, contrib/netcdf/v4 is a symlink to contrib/netcdf/netcdf-c-4.6.2 and
  # the header it points at is correct.  Assert that rather than repair it.
  grep -q '#define NC_HAS_HDF5[[:space:]]*1' "${src}/${gen}" \
    || { echo "git checkout's ${gen} reports no HDF5 support:" >&2
         grep NC_HAS_HDF5 "${src}/${gen}" >&2; exit 1; }
  log "no generated header; git checkout's own is already correct (A29)"
else
  echo "no generated ${gen}, and this is a tarball build, which has no other" >&2
  echo "source of truth for whether netcdf was configured with HDF5 (A29)." >&2
  exit 1
fi

#------------------------------------------------------------------------------
# Assert what configure DECIDED, on the generated files rather than on the flags
# above, and before a fifteen-minute compile.
#
# Every optional package in this recipe fails the same way when it fails: not
# with an error, but by quietly configuring itself off and building a libMesh
# that is missing a feature.  --enable-tecio is the standing proof -- it has been
# in this option list since v0, and HAVE_TECPLOT_API has never once been defined
# in a shipped artifact, because tecio.m4 disables itself when it cannot find
# X11 headers and says so in a line nobody reads.  A flag is a request; this is
# the receipt.
#
# The OFF list matters as much as the ON list.  Each of those has a default
# search that reaches into /usr, so "off" here means "off on purpose", and a
# name appearing in that column later is how we learn a build host was consulted.
LIBMESH_FEATURES_ON="HAVE_BOOST HAVE_EXTERNAL_BOOST HAVE_EIGEN HAVE_EIGEN_DENSE
  HAVE_EIGEN_SPARSE HAVE_XDR HAVE_HDF5 HAVE_HDF5_CXX HAVE_NETCDF HAVE_EXODUS_API
  HAVE_TECPLOT_API HAVE_GLPK HAVE_METAPHYSICL HAVE_PETSC HAVE_TRIANGLE"
LIBMESH_FEATURES_OFF="HAVE_NLOPT HAVE_VTK HAVE_TRILINOS HAVE_CURL HAVE_CAPNPROTO
  HAVE_SLEPC"

# assert_libmesh_features FILE LABEL -- read a libmesh_config.h, in the build
# tree or installed, and hold it to the two lists above.
#
# The two columns are not checked the same way, and cannot be: autoheader writes
# a disabled entry as '/* #undef HAVE_VTK */' -- unprefixed -- while an enabled
# one becomes '#define LIBMESH_HAVE_VTK 1'.  So the prefixed #define is the only
# reliable signal, and "off" is its absence.  The [[:space:]] guard keeps
# HAVE_EIGEN from being satisfied by HAVE_EIGEN_DENSE.
assert_libmesh_features () {
  local f="$1" label="$2" m bad=0
  [ -f "${f}" ] || { echo "no ${f} to check (${label})" >&2; exit 1; }
  for m in ${LIBMESH_FEATURES_ON}; do
    grep -q "^#define LIBMESH_${m}[[:space:]]" "${f}" || {
      echo "${label}: LIBMESH_${m} is NOT set, and this recipe asks for it." >&2
      bad=1; }
  done
  for m in ${LIBMESH_FEATURES_OFF}; do
    grep -q "^#define LIBMESH_${m}[[:space:]]" "${f}" && {
      echo "${label}: LIBMESH_${m} IS set; this recipe does not ask for it" >&2
      echo "  -- something was found that we did not point configure at." >&2
      bad=1; }
  done
  if [ "${bad}" != 0 ]; then
    echo "--- what ${f} records about optional packages:" >&2
    grep -E "^(#define LIBMESH_HAVE|/\* #undef HAVE)" "${f}" >&2
    exit 1
  fi
  log "${label}: every required feature on, every required-absent one off"
}

cfg_h="include/libmesh_config.h"
assert_libmesh_features "${cfg_h}" "configure's libmesh_config.h"

# Boost, specifically, because #28 asserted the opposite of what is now correct.
#
# Before conda's libboost-headers was in the env, ANY external Boost meant the
# host's had leaked past --with-boost (or a rebuild over a populated $STACK had
# found the previous pass's own bundled subset -- A30).  Now an external Boost is
# the intended outcome and its absence is the failure: it would mean the env lost
# libboost-headers and libMesh fell back to its bundled 1.61 subset, silently
# changing what the artifact contains.  HAVE_EXTERNAL_BOOST is in the ON list
# above for that reason.
#
# WHERE it came from is not recorded in the header, and does not need to be:
# --with-boost=<dir> makes ax_boost_base search <dir>/include and nothing else,
# so an external Boost found at all was found in the stack -- and the path check
# below reads the generated compile line to confirm nothing outside it appears.
if [ -d "${src}/contrib/boost" ]; then
  log "Boost: external, from the stack (this libMesh bundles a subset; unused)"
else
  log "Boost: external, from the stack (this libMesh bundles none at all)"
fi

# The generic form of the same question, for every optional package at once:
# nothing configure recorded may point outside the stack.  configure has just
# substituted libmesh_optional_INCLUDES/LIBS into contrib/bin/libmesh-config
# and the .pc files -- the very text 'make install' will ship.
cat contrib/bin/libmesh-config contrib/utils/libmesh*.pc \
  | assert_no_host_paths "configure's libmesh-config and libmesh*.pc"

make ${MAKE_J_L}
make install

# The same assertion on the ARTIFACT: what a consumer's compile line receives.
# libmesh-config and the .pc files carry libmesh_optional_INCLUDES; on 1.8.x
# timpi-config --cppflags carries the Boost include as well; metaphysicl's
# config header records its own hoisted Boost probe.
{ METHOD=opt "${STACK}/bin/libmesh-config" --include --ldflags --libs
  cat "${STACK}"/lib/pkgconfig/libmesh*.pc
  if [ -x "${STACK}/bin/timpi-config" ]; then
    METHOD=opt "${STACK}/bin/timpi-config" --cppflags
  fi
} | assert_no_host_paths "installed libmesh-config, libmesh*.pc, timpi-config"
# The same two questions of the INSTALLED header, and of contrib/metaphysicl.
#
# metaphysicl's own hoisted BOOST_REQUIRE runs even with --with-vexcl=no, and
# now that the stack holds a Boost it finds one -- so #28's assertion here
# ("must record no Boost at all") is no longer the right question.  The right
# one is the same one asked everywhere else: whatever it recorded, no path in it
# may point outside the tree.
assert_libmesh_features "${STACK}/include/libmesh/libmesh_config.h" \
                        "installed libmesh_config.h"
mp_h="${STACK}/include/metaphysicl/metaphysicl_config.h"
if [ -f "${mp_h}" ]; then
  assert_no_host_paths "installed metaphysicl_config.h" < "${mp_h}"
  grep -q -E '^#define (METAPHYSICL_)?HAVE_BOOST[[:space:]]' "${mp_h}" \
    && log "contrib/metaphysicl: Boost, from the stack" \
    || log "contrib/metaphysicl: no Boost recorded"
fi

#------------------------------------------------------------------------------
# The receipt for all of it: the flags libMesh hands a consumer must compile
# libMesh's own public headers.
#
# Every check above reads a file libMesh generated.  This one uses the artifact
# the way a customer does -- ask libmesh-config for the compile line, hand it to
# the compiler, include the headers that the features enabled above put in play
# (xdr_cxx.h pulls rpc/rpc.h, dense_vector.h pulls Eigen/Core) -- and it is the
# only check here that would have caught an exported include path that is complete
# for libMesh's own build and short by one -I for everybody else.
cat > "${BUILD_TMP}/contract.C" <<'EOF'
#include <libmesh/libmesh.h>
#include <libmesh/xdr_cxx.h>
#include <libmesh/dense_vector.h>
int main () { return 0; }
EOF
# shellcheck disable=SC2046  # word splitting is the point: these are flags
contract_flags="$(METHOD=opt "${STACK}/bin/libmesh-config" \
                    --cppflags --cxxflags --include)"
if PATH="${STACK}/bin:${PATH}" "${STACK}/bin/mpicxx" ${contract_flags} \
     -c "${BUILD_TMP}/contract.C" -o "${BUILD_TMP}/contract.o" \
     2>"${WORK}/logs/libmesh-contract.log"; then
  log "compile-line contract: libmesh-config's flags compile libMesh's headers"
else
  echo "the flags 'libmesh-config' emits cannot compile libMesh's own headers:" >&2
  head -20 "${WORK}/logs/libmesh-contract.log" >&2
  echo "  flags were: ${contract_flags}" >&2
  exit 1
fi

remove_libtool_archives

# v0's two "couple easy checks", kept non-fatal exactly as they were there:
# v0's build.sh ran without 'set -e', so neither could fail the build.  The
# enforcing gate is test/run.sh, which builds and runs introduction_ex4 against
# the INSTALLED tree -- a stronger claim than checking it in the build dir.
log "v0's in-build checks (advisory; test/run.sh is the gate)"
make ${MAKE_J_L} -C contrib check || log "warning: contrib check failed"
make ${MAKE_J_L} -C examples/introduction/introduction_ex4 check \
  || log "warning: introduction_ex4 check failed"

save_libmesh_diagnostics

# v0 trimmed the installed binaries: a static build put a dozen bloated
# example apps in bin/, and only meshtool was wanted.  Shared builds are far
# smaller, but this is what the stack has always shipped, so it is kept.
cd "${STACK}/bin" || exit 1
[ -f meshtool-opt ] && mv -f meshtool-opt meshtool
rm -f ./*-opt

clean_build_tmp
log "done"
