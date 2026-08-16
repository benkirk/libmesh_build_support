/* gust_hello.c -- package B.  The "hello world" end of the demo.
 *
 * Read the include list, because it is the entire point of this file:
 *
 *     #include <gust/gust_core.h>      <- package A
 *     #include <stdio.h>               <- libc
 *
 * There is no <mpi.h>, no <petscsys.h>, no libmesh header.  This program runs a
 * parallel FEM problem on a stack of MPI, PETSc, HDF5, netCDF and libMesh, and
 * it does not name a single one of them -- not here, and not on its link line,
 * which is `pkg-config --libs gust-core` and nothing else.
 *
 * That is what a second-order dependency looks like when the first-order one
 * has done its job, and it is the strongest statement this demo makes about
 * the stack: A absorbed the stack so B did not have to.
 *
 * Two constraints, both from test/run.sh, which runs this binary out of
 * libexec/stack-tests/: no command-line arguments, and no files written.
 */
#include <gust/gust_core.h>

#include <stdio.h>

#define REFINEMENTS 2

int
main (int argc, char **argv)
{
  gust_probe_t p;
  int rank, ranks;

  /* One call brings up MPI, PETSc and libMesh.  B does not know that, and does
   * not have to -- which is why B never had to be rebuilt when A moved from
   * PETSc-only to libMesh underneath it. */
  if (gust_core_init (&argc, &argv) != 0)
    {
      fprintf (stderr, "gust-hello: could not bring up the stack\n");
      return 1;
    }

  rank  = gust_core_rank ();
  ranks = gust_core_ranks ();

  /* Every rank speaks, so N processes that each think they are rank 0 of 1 --
   * the signature of a binary linked against a different MPI than the launcher
   * -- cannot pass by exiting 0 quietly. */
  printf ("gust-hello: rank %d/%d\n", rank, ranks);
  fflush (stdout);

  if (gust_core_probe (REFINEMENTS, &p) != 0)
    {
      fprintf (stderr, "gust-hello: probe failed on rank %d\n", rank);
      return 1;
    }

  if (rank == 0)
    {
      printf ("gust-hello: hello from Gust App " GUST_APP_VERSION "\n");
      /* Both versions, because they are not the same fact.  The literal is
       * what this binary was COMPILED against; the call is what it LINKED
       * against at run time -- and after the tarball is unpacked somewhere
       * else, that second one is resolved by the dynamic loader from a
       * relative rpath.  Printing only one of them would hide a skew. */
      printf ("gust-hello: gust-core %s (compiled against %s), %s\n",
              gust_core_version (), GUST_CORE_VERSION, p.backend);
      printf ("gust-hello: solved on %d rank(s): %d elements, %d dofs\n",
              ranks, p.elements, p.dofs);
      fflush (stdout);
    }

  gust_core_finalize ();
  return 0;
}
