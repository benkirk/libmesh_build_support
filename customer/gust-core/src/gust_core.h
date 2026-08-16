/* gust/gust_core.h -- Gust Dynamics core layer, the customer's public API.
 *
 * This header is the demo's load-bearing idea.  It is the ONLY thing package B
 * (gust-app) sees: B includes this, links -lgustcore, and never mentions
 * libMesh, PETSc, HDF5 or MPI -- not in its includes, not on its link line.
 * The stack is A's dependency, not B's.
 *
 * So it is deliberately a C interface over a C++/FEM implementation:
 *
 *   - extern "C", so a plain C consumer can use it.  B is C, on purpose --
 *     if B had to be C++ to talk to A, the encapsulation would be leaking.
 *   - init/finalize instead of libMesh's RAII LibMeshInit, which is
 *     scope-bound and cannot cross a C boundary.
 *   - no libMesh types in any signature.  A struct of ints and a char buffer
 *     travel across an ABI boundary; libMesh::Mesh does not.
 *
 * The practical payoff shows up after relocation.  B's binary has a four-deep
 * transitive chain -- gust-hello -> libgustcore.so -> libmesh_opt.so ->
 * libpetsc.so -> libmpi.so -- and every link of it has to resolve through
 * $ORIGIN once the tarball is unpacked somewhere else.  B running at all is
 * that whole chain being proved.
 */
#ifndef GUST_CORE_H
#define GUST_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

#define GUST_CORE_VERSION "0.3.0"

/* Filled in by gust_core_probe().  Plain scalars and a fixed buffer: no
 * allocation crosses the boundary, so there is no matching free() to get
 * wrong, and no C++ type for a C caller to be unable to name. */
typedef struct
{
  int  ranks;        /* size of the solver communicator                     */
  int  rank;         /* this process's rank within it                       */
  int  elements;     /* active elements in the refined demo mesh            */
  int  dofs;         /* degrees of freedom in the demo system               */
  char backend[64];  /* the stack this was solved with, e.g. "libMesh 1.7.9"*/
} gust_probe_t;

/* The version of the library actually linked, which is not necessarily the
 * GUST_CORE_VERSION the caller was COMPILED against.  B prints both, so a
 * header/library skew shows up as a visible mismatch rather than as undefined
 * behaviour somewhere further along. */
const char *gust_core_version (void);

/* Bring up the stack: MPI, PETSc and libMesh, in that order, once.
 * Idempotent -- a second call is a no-op returning 0, so a consumer that does
 * not know whether a library already initialised the stack can just call it.
 * Takes argc/argv the way MPI_Init does, so libMesh sees --options.
 *
 * Pass NULL for BOTH to initialise with no command line.  That is not a
 * convenience: a Fortran main program has no argc/argv to hand over, so the
 * Fortran binding passes C_NULL_PTR for both and this is what makes the same
 * entry point usable from all three languages.
 *
 * Returns 0 on success, non-zero on failure. */
int gust_core_init (int *argc, char ***argv);

/* Rank and size of the solver communicator, or -1 before init. */
int gust_core_rank (void);
int gust_core_ranks (void);

/* Build a unit-square QUAD4 mesh, refine it uniformly `refinements` times,
 * attach a first-order system, and report what came out.  This is the smallest
 * thing that is still a real exercise of the stack: mesh generation, adaptive
 * refinement, DoF distribution and a parallel communicator, all of it running
 * through PETSc underneath.
 *
 * Cheap on purpose -- milliseconds at the default refinement -- because it runs
 * in the test harness, twice, on every base image in the verify matrix.
 *
 * Returns 0 on success and fills *out; non-zero on failure, leaving *out
 * zeroed.  libMesh throws on error and this is a C boundary, so exceptions are
 * caught here and turned into a return code. */
int gust_core_probe (int refinements, gust_probe_t *out);

/* Tear the stack down.  Safe to call without a matching init. */
void gust_core_finalize (void);

#ifdef __cplusplus
}
#endif

#endif /* GUST_CORE_H */
