#!/usr/bin/env bash
# hello -- a customer shared library built against libMesh.
#
# Deliberately small and deliberately REAL.  It produces exactly the things a
# customer library produces and that the rest of the pipeline has to handle:
#
#   lib/libhello.so    a shared library that must get an $ORIGIN rpath
#   include/hello.h    a header the next package (goodbye) compiles against
#
# It compiles against libMesh through libMesh's own documented contract,
# libmesh-config, which is what a customer would use and what test/smoke builds
# introduction_ex4 with.  Sources are generated here rather than downloaded,
# which also demonstrates a package with no PKG_URL.
#
# The framework hands this script TOPDIR (the submodule root), STACK, WORK and
# the rest of PKG_ENV -- identical to a site/ package.  See docs/EXTENDING.md.
. "${TOPDIR}/lib/build_common.sh"

activate_toolchain
list_build_env
require mpicxx

lmc="${STACK}/bin/libmesh-config"
[ -x "${lmc}" ] || { echo "hello: ${lmc} not found -- is libMesh built?" >&2; exit 1; }

src="${BUILD_TMP}/src"
mkdir -p "${src}"
cd "${src}"

cat > hello.h <<'EOF'
#ifndef HELLO_H
#define HELLO_H
#ifdef __cplusplus
extern "C" {
#endif
/* Returns a static banner naming the libMesh this library was built against. */
const char *hello_banner(void);
#ifdef __cplusplus
}
#endif
#endif
EOF

# The library body includes a libMesh header, so building it proves libMesh's
# include contract resolves from the stack -- the thing a customer package
# actually depends on.  libmesh_config.h is the generated header every libMesh
# install ships, so this is robust across the version profiles.
cat > hello.C <<'EOF'
#include "hello.h"
#include "libmesh/libmesh_config.h"

const char *hello_banner(void)
{
    return "hello: built against the libMesh stack";
}
EOF

log "compiling libhello.so"
# The absolute -rpath is correct and intentional: relocate/patchelf.sh rewrites
# every rpath in the tree to $ORIGIN-relative afterwards, so do not write
# $ORIGIN here.  -rpath-link lets ld resolve libmesh_opt.so's own DT_NEEDED
# entries at link time (-L does not participate in that search); libmesh-config
# emits -L and -rpath but not -rpath-link, exactly as test/smoke documents.
# shellcheck disable=SC2046
mpicxx $(METHOD=opt "${lmc}" --cppflags --cxxflags --include) \
       -fPIC -c hello.C -o hello.o
# shellcheck disable=SC2046
mpicxx -shared -o libhello.so hello.o \
       -Wl,-rpath,"${STACK}/lib" -Wl,-rpath-link,"${STACK}/lib" \
       $(METHOD=opt "${lmc}" --libs)

log "installing into ${STACK}"
install -d "${STACK}/lib" "${STACK}/include"
install -m 0755 libhello.so "${STACK}/lib/"
install -m 0644 hello.h     "${STACK}/include/"

clean_build_tmp
log "done"
