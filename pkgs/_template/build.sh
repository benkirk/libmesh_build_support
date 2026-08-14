#!/usr/bin/env bash
# Template package recipe.  See docs/EXTENDING.md.
. "${TOPDIR}/lib/build_common.sh"

activate_toolchain
list_build_env          # dumps CC/CXX/FC and the env into $WORK/logs/<pkg>.log
require curl tar make

download_src "${PKG_URL}"
cd "${BUILD_TMP}/${PKG_NAME}-${PKG_VERSION}"

# Install into the single merged prefix.  Always build shared.
./configure --prefix="${STACK}" --enable-shared --disable-static
make ${MAKE_J_L}
make install

clean_build_tmp
log "done"
