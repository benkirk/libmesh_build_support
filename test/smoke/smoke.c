/* Smoke test for the relocatable stack.
 *
 * Staged: this is the MPI-only stage.  PETSc and libMesh checks are compiled in
 * as those packages land (see the Makefile's feature defines), and the whole
 * thing is eventually replaced by libMesh's introduction_ex4.  The contract in
 * README.md does not change as it grows.
 *
 * The output contract, which test/run.sh asserts against:
 *
 *     smoke: rank <r>/<n>
 *     smoke: ranks=<n>              (rank 0 only, last line)
 *
 * Printing the size from every rank is the point.  The failure this is built to
 * catch is a binary that is not really MPI-linked, or is linked against a
 * DIFFERENT MPI than the launcher: 'mpiexec -n 4' then yields four independent
 * processes that each believe they are rank 0 of 1, and every one of them exits
 * 0.  Asserting the reported size -- from all ranks, not just one -- turns that
 * silent pass into a failure.  It is the check that carries the single-node MPI
 * requirement through distcheck.
 */
#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef SMOKE_HAVE_PETSC
#include <petscvec.h>
#endif

int main(int argc, char **argv)
{
    int rank = -1, size = -1, provided = 0;

    if (MPI_Init_thread(&argc, &argv, MPI_THREAD_SINGLE, &provided) != MPI_SUCCESS) {
        fprintf(stderr, "smoke: MPI_Init_thread failed\n");
        return 1;
    }
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    printf("smoke: rank %d/%d\n", rank, size);
    fflush(stdout);

    /* Prove the ranks can actually talk to each other, not merely that they
     * each initialised a communicator.  Sum of 0..size-1 is checked in closed
     * form, so a broken reduction cannot coincidentally agree. */
    {
        int mine = rank, total = -1, expect = size * (size - 1) / 2;
        MPI_Allreduce(&mine, &total, 1, MPI_INT, MPI_SUM, MPI_COMM_WORLD);
        if (total != expect) {
            fprintf(stderr, "smoke: allreduce gave %d, expected %d\n", total, expect);
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
    }

#ifdef SMOKE_HAVE_PETSC
    {
        Vec v;
        PetscInt n = 0;
        if (PetscInitialize(&argc, &argv, NULL, NULL)) {
            fprintf(stderr, "smoke: PetscInitialize failed\n");
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
        VecCreate(PETSC_COMM_WORLD, &v);
        VecSetSizes(v, PETSC_DECIDE, 100 * size);
        VecSetFromOptions(v);
        VecSet(v, 1.0);
        VecGetSize(v, &n);
        if (n != 100 * size) {
            fprintf(stderr, "smoke: petsc vec size %d, expected %d\n",
                    (int)n, 100 * size);
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
        if (rank == 0) printf("smoke: petsc vec global size %d\n", (int)n);
        VecDestroy(&v);
        PetscFinalize();
    }
#endif

    MPI_Barrier(MPI_COMM_WORLD);
    if (rank == 0) {
        printf("smoke: ranks=%d\n", size);
        fflush(stdout);
    }

    MPI_Finalize();
    return 0;
}
