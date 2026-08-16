// gust_core_stub.C -- a contract mock of package A, for the ABI check only.
//
// NOT A FALLBACK, and never installed into $STACK.  customer/test/abi-check.sh
// builds this into a throwaway prefix so that package B's three front-ends can
// be compiled, linked and RUN in a few seconds on a machine with no stack on
// it -- which is the only way the C / C++ / Fortran bindings get exercised on
// every push rather than once per 40-minute build.
//
// It implements exactly the contract gust_core.h documents, including the
// arithmetic: a 4x4 square refined r times has 4*2^r elements per side, and
// first-order Lagrange on QUAD4 puts one DoF per node.  That matters, because
// the front-ends assert those numbers themselves -- so if this file and
// gust_core.C ever disagreed about the contract, the front-ends would catch it
// rather than being quietly rewritten to match whichever one ran last.
//
// C++ rather than C on purpose: the real libgustcore.so is C++, so building
// the mock the same way keeps the thing under test -- extern "C" over a C++
// translation unit, and the libstdc++ DT_NEEDED that comes with it -- the same
// as in the real article.
//
// What it deliberately does NOT mock: MPI.  It always reports 1 rank.  Whether
// the bindings behave correctly across ranks is a question only the real stack
// can answer, and test/run.sh asks it under mpiexec.

#include "gust_core.h"

#include <cstdio>
#include <cstring>

namespace
{
bool g_inited = false;
}

extern "C" {

const char *
gust_core_version (void)
{
  return GUST_CORE_VERSION;
}

int
gust_core_init (int *argc, char ***argv)
{
  (void) argc;
  (void) argv;         // NULL for both is legal -- that is the Fortran path
  g_inited = true;
  return 0;
}

int
gust_core_rank (void)
{
  return g_inited ? 0 : -1;
}

int
gust_core_ranks (void)
{
  return g_inited ? 1 : -1;
}

int
gust_core_probe (int refinements, gust_probe_t *out)
{
  if (!out)
    return 1;

  std::memset (out, 0, sizeof (*out));

  if (!g_inited)
    return 1;

  if (refinements < 0)
    refinements = 0;

  const int side = 4 << refinements;

  out->ranks    = 1;
  out->rank     = 0;
  out->elements = side * side;
  out->dofs     = (side + 1) * (side + 1);

  std::snprintf (out->backend, sizeof (out->backend), "stub (no libMesh)");

  return 0;
}

void
gust_core_finalize (void)
{
  g_inited = false;
}

} // extern "C"
