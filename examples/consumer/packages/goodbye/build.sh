#!/usr/bin/env bash
# goodbye -- a customer application that links the customer's OWN libhello.so
# (from the sibling 'hello' package) AND initialises libMesh for real.
#
# It installs its binary into $STACK/libexec/stack-tests/, which is the one
# thing that makes a package TRAVEL: test/run.sh runs every executable there,
# serially and under mpiexec, in place and again from the relocated tree inside
# distcheck (docs/EXTENDING.md).  So this package is not merely built once and
# forgotten -- it is the proof that a two-deep customer chain (goodbye -> hello
# -> libMesh) still resolves every library after the tarball is unpacked
# somewhere else.
. "${TOPDIR}/lib/build_common.sh"

activate_toolchain
list_build_env
require mpicxx

lmc="${STACK}/bin/libmesh-config"
[ -x "${lmc}" ] || { echo "goodbye: ${lmc} not found -- is libMesh built?" >&2; exit 1; }
[ -e "${STACK}/include/hello.h" ] \
  || { echo "goodbye: hello.h not found -- did the hello package install?" >&2; exit 1; }

src="${BUILD_TMP}/src"
mkdir -p "${src}"
cd "${src}"

# Uses hello's C banner AND a real libMesh runtime object (LibMeshInit), so the
# binary genuinely NEEDs both libhello.so and libmesh_opt.so at load time.  The
# output is deliberately simple: test/run.sh only asserts a stack-tests binary
# exits 0 and prints something, because it cannot know what a customer program
# says.
cat > goodbye.C <<'EOF'
#include "hello.h"
#include "libmesh/libmesh.h"
#include <iostream>

int main(int argc, char **argv)
{
    libMesh::LibMeshInit init(argc, argv);
    const libMesh::Parallel::Communicator & comm = init.comm();
    std::cout << hello_banner() << "\n";
    std::cout << "goodbye: rank " << comm.rank() << "/" << comm.size() << "\n";
    std::cout.flush();
    return 0;
}
EOF

log "compiling goodbye"
# -I$STACK/include finds hello.h; -L$STACK/lib -lhello links the customer's own
# library; libmesh-config supplies libMesh.  -rpath-link as everywhere else --
# ld resolves the DT_NEEDED closure of libmesh_opt.so and libhello.so through it.
# shellcheck disable=SC2046
mpicxx $(METHOD=opt "${lmc}" --cppflags --cxxflags --include) \
       -I"${STACK}/include" \
       -o goodbye goodbye.C \
       -L"${STACK}/lib" -lhello \
       -Wl,-rpath,"${STACK}/lib" -Wl,-rpath-link,"${STACK}/lib" \
       $(METHOD=opt "${lmc}" --libs)

log "installing into ${STACK}"
install -d "${STACK}/bin" "${STACK}/libexec/stack-tests"
install -m 0755 goodbye "${STACK}/bin/"
# Also into libexec/stack-tests, where test/run.sh looks -- this is what makes
# goodbye travel in the tarball and get run again from the relocated tree.
install -m 0755 goodbye "${STACK}/libexec/stack-tests/"

clean_build_tmp
log "done"
