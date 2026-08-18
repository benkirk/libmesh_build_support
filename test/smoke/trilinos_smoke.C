// Trilinos smoke test -- the Trilinos half of the artifact, which until now
// nothing exercised.
//
// The stack ships libepetra, libteuchos*, libsacado, libpliris and (when the
// profile enables it) libkokkoscore/containers/simd.  distcheck proved those
// libraries RESOLVE from a relocated tree; nothing proved they RUN.  Those are
// different claims, and only the second one is what a customer gets.
//
// Every check here asserts a value it can compute independently, so a library
// that loads and then misbehaves fails rather than passes quietly.  The output
// contract is smoke.c's, for the same reason: reporting the communicator size
// from every rank is what catches a binary that is not really MPI-linked.
//
// Kokkos is optional at compile time -- the 'default' profile ships Trilinos
// with -DTrilinos_ENABLE_Kokkos=OFF -- so the Kokkos block is guarded and the
// Makefile defines SMOKE_HAVE_KOKKOS only when the libraries are present.
#include <mpi.h>

#include <cstdio>
#include <cstdlib>
#include <string>

#include <Teuchos_ParameterList.hpp>
#include <Epetra_MpiComm.h>
#include <Epetra_Map.h>
#include <Epetra_Vector.h>

#ifdef SMOKE_HAVE_KOKKOS
#include <Kokkos_Core.hpp>
#endif

namespace
{
int failures = 0;

void check(bool ok, const char * what)
{
  if (!ok)
    {
      std::fprintf(stderr, "trilinos: FAILED: %s\n", what);
      ++failures;
    }
}
} // namespace

int main(int argc, char ** argv)
{
  MPI_Init(&argc, &argv);

  int rank = 0, size = 1;
  MPI_Comm_rank(MPI_COMM_WORLD, &rank);
  MPI_Comm_size(MPI_COMM_WORLD, &size);

  // Every rank reports, so a run that silently serialized fails the harness.
  //
  // fflush immediately, and barrier before anything else prints.  Both are
  // load-bearing and smoke.c does the same: stdout to a pipe is BLOCK-buffered,
  // so without the flush a partial buffer is written at an arbitrary point and
  // two ranks interleave mid-line --
  //
  //     trilinos: kokkos not compiled in (...)trilinos: rank 1/4
  //
  // which is not a line any 'grep -x' will match.  A flushed line shorter than
  // PIPE_BUF is written atomically, and the barrier keeps the per-rank lines
  // ahead of the rank-0 detail below.  Measured: this raced green on two
  // platforms and failed on the third.
  std::printf("trilinos: rank %d/%d\n", rank, size);
  std::fflush(stdout);
  MPI_Barrier(MPI_COMM_WORLD);

#ifdef SMOKE_HAVE_KOKKOS
  Kokkos::initialize(argc, argv);
  {
    // The assertion that matters, and the one that would have caught a build
    // where the OpenMP backend was requested and silently forced off: what the
    // headers were COMPILED with must be what the runtime actually reports.
    // A green build whose backend quietly fell back to Serial is exactly the
    // failure this exists to make loud.
    const std::string host = Kokkos::DefaultHostExecutionSpace::name();
#ifdef KOKKOS_ENABLE_OPENMP
    check(host == "OpenMP",
          "compiled with KOKKOS_ENABLE_OPENMP but the host space is not OpenMP");
#else
    check(host != "OpenMP",
          "reports the OpenMP host space without KOKKOS_ENABLE_OPENMP");
#endif

    const int conc = Kokkos::DefaultHostExecutionSpace().concurrency();
    check(conc >= 1, "host execution space reports no concurrency");

    // A real parallel_reduce with an independently known answer.  Loading the
    // library proves nothing about whether its dispatch works.
    // int index, long accumulator: the sum overflows 32 bits, and letting the
    // range and the reducer be different types is the ordinary Kokkos idiom.
    const int n = 100000;
    long sum = 0;
    Kokkos::parallel_reduce(
        "trilinos_smoke_sum", n,
        KOKKOS_LAMBDA(const int i, long & acc) { acc += i; }, sum);
    check(sum == static_cast<long>(n) * (n - 1) / 2,
          "Kokkos parallel_reduce produced the wrong sum");

    if (rank == 0)
      {
        std::printf("trilinos: kokkos backend=%s concurrency=%d\n",
                    host.c_str(), conc);
        std::fflush(stdout);
      }
  }
  Kokkos::finalize();
#else
  // Say so out loud.  This binary is genuinely weaker in a profile that ships
  // Trilinos without Kokkos, and a check that is quietly absent is the failure
  // mode this project keeps warning about -- a gate you cannot see is not a
  // gate.  A profile that loses Kokkos unexpectedly should be visible in the
  // log rather than inferred from the absence of a line.
  if (rank == 0)
    {
      std::printf("trilinos: kokkos not compiled in (profile ships Trilinos without it)\n");
      std::fflush(stdout);
    }
#endif

  // Teuchos: a ParameterList round-trip, including the sublist path, which is
  // where the template instantiations actually live.
  {
    Teuchos::ParameterList pl("smoke");
    pl.set("iterations", 42);
    pl.set("tolerance", 1.0e-8);
    pl.sublist("nested").set("label", std::string("ok"));

    check(pl.get<int>("iterations") == 42, "Teuchos ParameterList lost an int");
    check(pl.get<double>("tolerance") == 1.0e-8, "Teuchos ParameterList lost a double");
    check(pl.sublist("nested").get<std::string>("label") == "ok",
          "Teuchos ParameterList lost a sublist entry");

    if (rank == 0)
      { std::printf("trilinos: teuchos ok\n"); std::fflush(stdout); }
  }

  // Epetra: a distributed vector over the real communicator, with a norm whose
  // value depends on every rank having contributed.  A broken decomposition
  // gives the wrong answer rather than the right one on one rank.
  {
    Epetra_MpiComm comm(MPI_COMM_WORLD);
    const int n_global = 120;
    Epetra_Map map(n_global, 0, comm);
    Epetra_Vector v(map);

    check(map.NumGlobalElements() == n_global, "Epetra_Map lost elements");
    check(v.PutScalar(2.0) == 0, "Epetra_Vector::PutScalar failed");

    double norm1 = -1.0;
    check(v.Norm1(&norm1) == 0, "Epetra_Vector::Norm1 failed");
    check(norm1 == 2.0 * n_global, "Epetra_Vector::Norm1 is not the global sum");

    if (rank == 0)
      { std::printf("trilinos: epetra norm1=%g\n", norm1); std::fflush(stdout); }
  }

  // Rank 0, last -- same contract as smoke.c, barrier included.
  MPI_Barrier(MPI_COMM_WORLD);
  if (rank == 0)
    {
      std::printf("trilinos: ranks=%d\n", size);
      std::fflush(stdout);
    }

  int total = 0;
  MPI_Allreduce(&failures, &total, 1, MPI_INT, MPI_SUM, MPI_COMM_WORLD);
  MPI_Finalize();
  return total == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
