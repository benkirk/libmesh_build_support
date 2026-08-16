/* gust_hello_omp.cpp -- package B, the C++/OpenMP front-end.
 *
 * Same claim as gust_hello.c, in a second language and with a second axis of
 * parallelism: MPI ranks come from package A, threads come from OpenMP, and
 * this file names neither MPI nor libMesh.  Its only stack-facing include is
 * <gust/gust_core.h>, which is extern "C" and therefore just as usable from
 * C++ as from C.
 *
 * WHY OPENMP IS WORTH DEMONSTRATING HERE
 *
 * It is the one thing in this demo that changes the shipped artifact rather
 * than just consuming it: an OpenMP binary carries a DT_NEEDED on libgomp, so
 * libgomp has to survive conda/prune.list and resolve through $ORIGIN in the
 * relocated tree like everything else.  Running this from the unpacked tarball
 * is what proves it does.
 *
 * THE RULE THIS FILE FOLLOWS: no MPI call, and no libMesh call, from inside a
 * parallel region.  libMesh's LibMeshInit does not promise MPI_THREAD_MULTIPLE,
 * and this program never asks for it -- the threaded section below is pure
 * arithmetic on local data.  Hybrid codes that ignore this work on the
 * developer's machine and deadlock on the customer's.
 */
#include <gust/gust_core.h>

/* Compile-time proof that -fopenmp actually reached the compiler.  Without
 * this the omp pragmas would be silently ignored, omp_get_num_threads() would
 * report 1, and the program would pass while testing nothing at all -- the
 * exact failure mode a demo is supposed to rule out. */
#ifndef _OPENMP
#  error "gust-hello-omp must be compiled with -fopenmp"
#endif

#include <omp.h>

#include <algorithm>
#include <cstdio>

namespace
{
constexpr int REFINEMENTS = 2;

/* 4 MPI ranks x N threads on a 4-vCPU CI runner is 4N runnable threads on 4
 * cores, and the harness runs every stack-tests binary under mpiexec.  Capping
 * here rather than trusting OMP_NUM_THREADS is deliberate: test/run.sh sets no
 * environment for these binaries, and this branch may not edit it. */
constexpr int MAX_THREADS = 2;
}

int
main (int argc, char **argv)
{
  gust_probe_t p;

  if (gust_core_init (&argc, &argv) != 0)
    {
      std::fprintf (stderr, "gust-hello-omp: could not bring up the stack\n");
      return 1;
    }

  const int rank  = gust_core_rank ();
  const int ranks = gust_core_ranks ();

  std::printf ("gust-hello-omp: rank %d/%d\n", rank, ranks);
  std::fflush (stdout);

  if (gust_core_probe (REFINEMENTS, &p) != 0)
    {
      std::fprintf (stderr, "gust-hello-omp: probe failed on rank %d\n", rank);
      return 1;
    }

  omp_set_num_threads (std::min (omp_get_max_threads (), MAX_THREADS));

  /* A reduction over integers, so the answer does not depend on how the
   * iterations were distributed or in what order the partial sums were
   * combined.  A floating-point reduction would be a bad test here: it would
   * differ run to run with the thread count, and the only way to assert on it
   * would be a tolerance, which would also accept a genuinely wrong answer. */
  long long acc = 0;
  int threads_used = 0;

#pragma omp parallel reduction(+ : acc)
  {
#pragma omp single
    threads_used = omp_get_num_threads ();

#pragma omp for
    for (int i = 0; i < p.dofs; ++i)
      acc += i;
  }

  const long long expect =
    static_cast<long long> (p.dofs) * (p.dofs - 1) / 2;

  if (acc != expect)
    {
      std::fprintf (stderr,
                    "gust-hello-omp: reduction gave %lld, expected %lld "
                    "(threads=%d)\n",
                    acc, expect, threads_used);
      return 1;
    }

  if (threads_used < 1)
    {
      std::fprintf (stderr, "gust-hello-omp: no threads reported\n");
      return 1;
    }

  if (rank == 0)
    {
      std::printf ("gust-hello-omp: hello from Gust App " GUST_APP_VERSION
                   " (C++/OpenMP)\n");
      std::printf ("gust-hello-omp: gust-core %s, %s\n",
                   gust_core_version (), p.backend);
      std::printf ("gust-hello-omp: %d rank(s) x %d thread(s), %d dofs, "
                   "reduction=%lld ok\n",
                   ranks, threads_used, p.dofs, acc);
      std::fflush (stdout);
    }

  gust_core_finalize ();
  return 0;
}
