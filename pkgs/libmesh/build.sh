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
mkdir -p "${BUILD_TMP}/${PKG_NAME}-build"
cd "${BUILD_TMP}/${PKG_NAME}-build" && log "building in $(pwd)"

# PETSc is installed with --prefix, so PETSC_ARCH is empty by construction.
# Saying so explicitly stops libMesh's configure from picking up a stale value
# and looking for lib/${PETSC_ARCH}/ that was never built.
export PETSC_DIR="${STACK}"
export PETSC_ARCH=""

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

make ${MAKE_J_L}
make install

remove_libtool_archives

# v0's two "couple easy checks", kept non-fatal exactly as they were there:
# v0's build.sh ran without 'set -e', so neither could fail the build.  The
# enforcing gate is test/run.sh, which builds and runs introduction_ex4 against
# the INSTALLED tree -- a stronger claim than checking it in the build dir.
log "v0's in-build checks (advisory; test/run.sh is the gate)"
make ${MAKE_J_L} -C contrib check || log "warning: contrib check failed"
make ${MAKE_J_L} -C examples/introduction/introduction_ex4 check \
  || log "warning: introduction_ex4 check failed"

[ -f config.log ] && cp config.log "${WORK}/logs/libmesh-config.log"

# v0 trimmed the installed binaries: a static build put a dozen bloated
# example apps in bin/, and only meshtool was wanted.  Shared builds are far
# smaller, but this is what the stack has always shipped, so it is kept.
cd "${STACK}/bin"
[ -f meshtool-opt ] && mv -f meshtool-opt meshtool
rm -f ./*-opt

clean_build_tmp
log "done"
