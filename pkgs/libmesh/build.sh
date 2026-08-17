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
#   --with-boost=$STACK  Boost comes from the stack or from libMesh's bundled
#                        subset; the host is never consulted.  Not v0's: added
#                        after a Rocky 8 host with boost-devel 1.66 in
#                        /usr/include broke the build.  See the flag itself.
#   --with-vexcl=no      the other half of the same fix, for contrib/metaphysicl.
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
# BOOST_ROOT.  $STACK holds no Boost on a first pass, so libMesh falls back to
# contrib/boost (1.7.x, 1.8.x) and configures without Boost on a devel checkout
# that no longer bundles one; a conda libboost-headers in the env would be found
# there as an in-stack external.  --with-vexcl=no skips metaphysicl's whole
# VexCL block -- the Boost library chain that was fatal, and an OpenCL header
# probe of /usr/include with it.  VexCL is a metaphysicl test dependency libMesh
# never uses.
#
# Why not the obvious flags: --disable-boost on 1.7/1.8 disables the bundled
# subset too ("without either external or built-in"), changing the artifact;
# --with-boost=no is mishandled by libMesh's CONFIGURE_BOOST -- it skips the
# whole AX_BOOST_BASE body, so external_boost_found stays yes and you get a
# bogus HAVE_EXTERNAL_BOOST with no include path and no subset.  Both checked
# against m4/boost.m4 and m4/ax_boost_base.m4 at v1.7.8, v1.8.0 and devel.
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
    --enable-tecio \
    --disable-glpk \
    --enable-hdf5 --with-hdf5="${STACK}" \
    --enable-petsc-required \
    --with-boost="${STACK}" \
    --with-vexcl=no \
    PETSC_DIR="${STACK}" \
    LIBS="-lm -L${STACK}/lib -lz" \
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
gen="contrib/netcdf/v4/include/netcdf_meta.h"
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
  echo "no generated ${gen}; libMesh's contrib layout changed" >&2; exit 1
fi

#------------------------------------------------------------------------------
# Assert what configure decided about Boost -- before a 15-minute compile, and
# on the generated files rather than on the flags above.  configure has already
# written include/libmesh_config.h (the LIBMESH_-prefixed header 'make' will
# install as include/libmesh/libmesh_config.h) and contrib/bin/libmesh-config
# into the build tree.
#
# Two things can put an external Boost here: a host Boost that got past the
# flags (a new libMesh whose m4 searches somewhere else), or a rebuild over a
# populated $STACK, where the subset a previous pass installed to
# $STACK/include/boost is found through -I$STACK/include and misclassified as
# external (A30: the build that counts starts from a clean $STACK).  Either
# way, stop here rather than ship it.
cfg_h="include/libmesh_config.h"
[ -f "${cfg_h}" ] || { echo "configure produced no ${cfg_h}" >&2; exit 1; }
if grep -q '#define LIBMESH_HAVE_EXTERNAL_BOOST' "${cfg_h}"; then
  echo "configure found an EXTERNAL Boost.  Either the host's leaked past" >&2
  echo "--with-boost=\${STACK}, or this is a rebuild over a populated \${STACK}" >&2
  echo "(A30) and the previous pass's bundled subset was taken for external." >&2
  grep -n -i 'boost' "${cfg_h}" >&2; exit 1
fi
if [ -d "${src}/contrib/boost" ]; then
  grep -q '#define LIBMESH_HAVE_BOOST 1' "${cfg_h}" \
    || { echo "libMesh ships contrib/boost but configure did not select it:" >&2
         grep -n -i 'boost' "${cfg_h}" >&2; exit 1; }
  log "Boost: libMesh's bundled subset (contrib/boost), no external"
else
  grep -q '#define LIBMESH_HAVE_BOOST 1' "${cfg_h}" \
    && { echo "no contrib/boost in this libMesh, yet configure found a Boost:" >&2
         grep -n -i 'boost' "${cfg_h}" >&2; exit 1; }
  log "Boost: none (this libMesh has no bundled subset and the stack ships none)"
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
mp_h="${STACK}/include/metaphysicl/metaphysicl_config.h"
if [ -f "${mp_h}" ] && grep -q -E '#define (METAPHYSICL_)?HAVE_BOOST[[:space:]]' "${mp_h}"; then
  echo "contrib/metaphysicl recorded a Boost (its BOOST_REQUIRE runs even with" >&2
  echo "--with-vexcl=no); --with-boost=\${STACK} should have kept it in the stack:" >&2
  grep -n 'HAVE_BOOST' "${mp_h}" >&2; exit 1
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
