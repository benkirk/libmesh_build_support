#!/usr/bin/env bash
# A worked site package: a shared library plus a program that uses it, linked
# against MPI and PETSc from the stack.
#
# It is deliberately small and deliberately REAL.  Small, so it costs seconds
# rather than minutes.  Real, in that it produces exactly the things a customer
# package produces and that the rest of the pipeline has to handle correctly:
#
#   lib/libsitedemo.so             a shared library that must get an $ORIGIN rpath
#   bin/site-demo                  a program that must resolve libraries in-tree
#   libexec/stack-tests/site-demo  the same program where test/run.sh will find
#                                  it, so this package is exercised by distcheck
#                                  rather than merely built (docs/EXTENDING.md)
#
# Sources are generated here rather than downloaded, which also demonstrates a
# package with no PKG_URL.
. "${TOPDIR}/lib/build_common.sh"

activate_toolchain
list_build_env
require make

src="${BUILD_TMP}/src"
mkdir -p "${src}"
cd "${src}"

cat > sitedemo.h <<'EOF'
#ifndef SITEDEMO_H
#define SITEDEMO_H
/* Returns the size of MPI_COMM_WORLD, or -1 if MPI is not initialised. */
int sitedemo_ranks(void);
/* Returns the global size of a PETSc vector of n entries per rank. */
int sitedemo_vec_size(int per_rank);
#endif
EOF

cat > sitedemo.c <<'EOF'
#include "sitedemo.h"
#include <mpi.h>
#include <petscvec.h>

int sitedemo_ranks(void)
{
    int inited = 0, size = -1;
    MPI_Initialized(&inited);
    if (!inited) return -1;
    MPI_Comm_size(MPI_COMM_WORLD, &size);
    return size;
}

int sitedemo_vec_size(int per_rank)
{
    Vec v;
    PetscInt n = 0;
    int size = sitedemo_ranks();
    if (size < 0) return -1;
    VecCreate(PETSC_COMM_WORLD, &v);
    VecSetSizes(v, PETSC_DECIDE, (PetscInt)(per_rank * size));
    VecSetFromOptions(v);
    VecSet(v, 1.0);
    VecGetSize(v, &n);
    VecDestroy(&v);
    return (int)n;
}
EOF

cat > main.c <<'EOF'
#include "sitedemo.h"
#include <petscsys.h>
#include <mpi.h>
#include <stdio.h>

/* The output contract test/run.sh asserts against, kept deliberately close to
 * test/smoke's: every rank reports, so a binary that is not really MPI-linked
 * cannot pass by each process believing it is rank 0 of 1. */
int main(int argc, char **argv)
{
    int rank = -1, size = -1, n = -1;
    MPI_Init(&argc, &argv);
    PetscInitialize(&argc, &argv, NULL, NULL);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    size = sitedemo_ranks();
    n = sitedemo_vec_size(10);
    printf("site-demo: rank %d/%d\n", rank, size);
    fflush(stdout);
    MPI_Barrier(MPI_COMM_WORLD);
    if (rank == 0) {
        if (n != 10 * size) {
            fprintf(stderr, "site-demo: vec size %d, expected %d\n", n, 10 * size);
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
        printf("site-demo: ranks=%d vec=%d\n", size, n);
        fflush(stdout);
    }
    PetscFinalize();
    MPI_Finalize();
    return 0;
}
EOF

log "compiling"
# -rpath-link is needed to resolve libpetsc.so's OWN DT_NEEDED entries at link
# time; ld does not use -L or -rpath for that search.  The absolute -rpath is
# correct and intentional -- relocate/patchelf.sh converts every rpath in the
# tree to $ORIGIN-relative afterwards, so do not try to write $ORIGIN here.
#
# ${LDFLAGS} would already carry all three here -- -L and -rpath from
# activate_toolchain, -rpath-link from the conda activate.d it sources.  They
# are spelled out on purpose: this file is the worked example of a compile
# line, and the same line has to work for a customer building against the
# unpacked TARBALL, where there is no activate.d to source and neither
# libmesh-config nor the .pc files emit -rpath-link.
mpicc -O2 -g -fPIC -I"${STACK}/include" -c sitedemo.c -o sitedemo.o
mpicc -shared -o libsitedemo.so sitedemo.o \
      -L"${STACK}/lib" -Wl,-rpath,"${STACK}/lib" -Wl,-rpath-link,"${STACK}/lib" -lpetsc
mpicc -O2 -g -I"${STACK}/include" -o site-demo main.c \
      -L. -lsitedemo \
      -L"${STACK}/lib" -Wl,-rpath,"${STACK}/lib" -Wl,-rpath-link,"${STACK}/lib" -lpetsc

log "installing into ${STACK}"
install -d "${STACK}/lib" "${STACK}/bin" "${STACK}/include" "${STACK}/libexec/stack-tests"
install -m 0755 libsitedemo.so "${STACK}/lib/"
install -m 0644 sitedemo.h     "${STACK}/include/"
install -m 0755 site-demo      "${STACK}/bin/"
# Also into libexec/stack-tests, which is where test/run.sh looks.  That is what
# makes this package travel in the tarball and get run again from the relocated
# tree, rather than merely being built once and forgotten.
install -m 0755 site-demo      "${STACK}/libexec/stack-tests/"

clean_build_tmp
log "done"
