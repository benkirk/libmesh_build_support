#!/usr/bin/env bash
# Template package recipe.  See docs/EXTENDING.md.
. "${TOPDIR}/lib/build_common.sh"

activate_toolchain
require curl tar make

download_src "${PKG_URL}"
cd "${BUILD_TMP}/${PKG_NAME}-${PKG_VERSION}"

# Install into the single merged prefix.  Always build shared.
./configure --prefix="${STACK}" --enable-shared --disable-static
make -j "${NPROC}"
make install

clean_build_tmp
log "done"
