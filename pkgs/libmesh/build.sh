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
require curl tar make

download_src "${PKG_URL}"

src="${BUILD_TMP}/${PKG_NAME}-${PKG_VERSION}"
[ -d "${src}" ] || { echo "unexpected source layout under ${BUILD_TMP}" >&2; ls "${BUILD_TMP}" >&2; exit 1; }

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
# the netcdf_meta.h it just generated -- is never on the include path.  The
# tarball also ships a checked-in netcdf_meta.h in that source directory saying
#
#     #define NC_HAS_NC4  0
#     #define NC_HAS_HDF5 0
#
# so exodus always compiles believing netcdf has no HDF5, however netcdf was
# actually built.  ex_utils.c gates on '#if !NC_HAS_HDF5', and with
# --enable-hdf5 libMesh selects EX_NETCDF4|EX_NOCLASSIC for every ExodusII
# write with no runtime override -- so exodus refuses all of them:
#
#     EXODUS: ERROR: File format specified as netcdf-4, but the NetCDF
#     library being used was not configured to enable this format
#
# That is why introduction_ex4 solves correctly and then dies on output.
#
# Copy configure's own answer over the stale one rather than hardcoding values:
# whatever the sub-configure decided about HDF5 is by definition what the netcdf
# being built supports.  Deleting the stale file instead does NOT work -- the
# include path has nowhere else correct to fall through to.
gen="contrib/netcdf/v4/include/netcdf_meta.h"
[ -f "${gen}" ] || { echo "no generated ${gen}; libMesh's contrib layout changed" >&2; exit 1; }
grep -q '#define NC_HAS_HDF5[[:space:]]*1' "${gen}" \
  || { echo "generated netcdf_meta.h reports no HDF5 support:" >&2
       grep NC_HAS_HDF5 "${gen}" >&2; exit 1; }
cp -f "${gen}" "${src}/${gen}"
log "installed configure's netcdf_meta.h over the stale checked-in one"

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
