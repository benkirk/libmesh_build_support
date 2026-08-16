/* gust_selftest.c -- package A's own test binary, installed into
 * $STACK/libexec/stack-tests/ so test/run.sh runs it serially and under
 * mpiexec, in place and again from the unpacked tarball.  (docs/EXTENDING.md,
 * "Getting your package tested" -- no edit to the harness is needed.)
 *
 * It is C, not C++, and that is the assertion: if this compiles and links,
 * gust_core.h really is consumable from C, and libgustcore.so really does
 * carry its C++ runtime dependencies itself.  A C++ test would have proved
 * neither, because the C++ driver would have dragged libstdc++ in on its own.
 *
 * Constraints this binary lives under, both from the harness:
 *   - no arguments.  run_site_bins invokes it bare.
 *   - no files written.  It runs in whatever directory the harness happens to
 *     be in, which in the relocated case is inside a temporary unpack tree.
 */
#include <gust/gust_core.h>

#include <stdio.h>
#include <string.h>

#define REFINEMENTS 3

int
main (int argc, char **argv)
{
  gust_probe_t p;
  int rank, ranks, expect_dofs, side;

  if (gust_core_init (&argc, &argv) != 0)
    {
      fprintf (stderr, "gust-core: stack init failed\n");
      return 1;
    }

  rank  = gust_core_rank ();
  ranks = gust_core_ranks ();

  /* Every rank reports, and the harness's assertion is over the whole set.
   * The failure this catches is the one that otherwise passes silently: a
   * binary linked against a different MPI than the launcher yields N processes
   * that each believe they are rank 0 of 1, and all of them exit 0. */
  printf ("gust-core: rank %d/%d\n", rank, ranks);
  fflush (stdout);

  if (gust_core_probe (REFINEMENTS, &p) != 0)
    {
      fprintf (stderr, "gust-core: probe failed on rank %d\n", rank);
      return 1;
    }

  /* A 4x4 square refined r times is 4*2^r elements per side, first-order
   * Lagrange on QUAD4 puts one DoF per node, so the counts are predictable and
   * worth checking rather than merely printing.  A solve that runs but
   * distributes DoFs wrongly is exactly the kind of thing that survives a test
   * asserting only "exit 0". */
  side = 4 << REFINEMENTS;
  expect_dofs = (side + 1) * (side + 1);

  if (p.elements != side * side || p.dofs != expect_dofs)
    {
      fprintf (stderr,
               "gust-core: mesh mismatch -- elements %d (want %d), dofs %d (want %d)\n",
               p.elements, side * side, p.dofs, expect_dofs);
      return 1;
    }

  if (strcmp (gust_core_version (), GUST_CORE_VERSION) != 0)
    {
      fprintf (stderr, "gust-core: header %s vs library %s\n",
               GUST_CORE_VERSION, gust_core_version ());
      return 1;
    }

  if (rank == 0)
    {
      printf ("gust-core: ranks=%d elements=%d dofs=%d backend=%s version=%s\n",
              ranks, p.elements, p.dofs, p.backend, gust_core_version ());
      fflush (stdout);
    }

  gust_core_finalize ();
  return 0;
}
