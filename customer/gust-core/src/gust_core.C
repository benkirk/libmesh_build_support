// gust_core.C -- the C++/libMesh side of the Gust Dynamics core layer.
//
// Everything libMesh-shaped is confined to this file.  gust_core.h exposes
// none of it, which is what lets package B be plain C and lets this library be
// the only object in the customer's tree that has to know how the stack is
// spelled.
//
// .C rather than .cpp because that is libMesh's own extension, and this file
// is compiled with flags that come straight out of libmesh-config.

#include "gust_core.h"

#include <libmesh/libmesh.h>
#include <libmesh/mesh.h>
#include <libmesh/mesh_generation.h>
#include <libmesh/mesh_refinement.h>
#include <libmesh/equation_systems.h>
#include <libmesh/linear_implicit_system.h>
#include <libmesh/enum_elem_type.h>
#include <libmesh/enum_order.h>

#include <cstdio>
#include <cstring>
#include <memory>

namespace
{
// libMesh's initialiser is RAII and scope-bound; the C API it is hiding behind
// is init/finalize.  A file-static unique_ptr is the bridge -- construction is
// gust_core_init, reset() is gust_core_finalize.
//
// Deliberately NOT a function-local static: those are destroyed at exit, in an
// order nothing here controls, and tearing MPI down during static destruction
// after main() has returned is a well-known way to get a clean run that ends in
// a mysterious non-zero exit status.
std::unique_ptr<libMesh::LibMeshInit> g_init;
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
  if (g_init)                      // idempotent, as documented
    return 0;

  // NULL/NULL means "no command line".  A Fortran main has no argc/argv to
  // pass, so its binding sends C_NULL_PTR for both -- and MPI_Init is
  // explicitly allowed to be handed a synthetic pair, so this costs nothing.
  // static, not automatic: libMesh keeps the pointer, so the storage has to
  // outlive this function.
  static char   fake_prog[] = "gust";
  static char  *fake_argv[] = { fake_prog, NULL };
  int    ac = (argc && argv) ? *argc : 1;
  char **av = (argc && argv) ? *argv : fake_argv;

  try
    {
      // This single line starts MPI and PETSc as well: libMesh owns the
      // bring-up of the whole stack underneath it, which is precisely the
      // detail package B is being kept from having to know.
      g_init.reset (new libMesh::LibMeshInit (ac, av));
    }
  catch (...)
    {
      g_init.reset ();
      return 1;
    }

  return 0;
}

int
gust_core_rank (void)
{
  return g_init ? static_cast<int> (g_init->comm ().rank ()) : -1;
}

int
gust_core_ranks (void)
{
  return g_init ? static_cast<int> (g_init->comm ().size ()) : -1;
}

int
gust_core_probe (int refinements, gust_probe_t *out)
{
  if (!out)
    return 1;

  std::memset (out, 0, sizeof (*out));

  if (!g_init)
    return 1;

  if (refinements < 0)
    refinements = 0;

  try
    {
      libMesh::Mesh mesh (g_init->comm ());

      // A 4x4 unit square, refined uniformly.  build_square prepares the mesh
      // for use, so there is no separate prepare_for_use() here.
      libMesh::MeshTools::Generation::build_square (mesh, 4, 4,
                                                    -1.0, 1.0,
                                                    -1.0, 1.0,
                                                    libMesh::QUAD4);

      if (refinements > 0)
        {
          libMesh::MeshRefinement refine (mesh);
          refine.uniformly_refine (static_cast<unsigned int> (refinements));
        }

      // Attach a system AFTER refining, so init() sees the final mesh and no
      // reinit() is needed.  A first-order Lagrange variable on QUAD4 gives
      // one DoF per node, which makes the reported count a number a reader can
      // check by hand: (4*2^r + 1)^2.
      libMesh::EquationSystems es (mesh);
      libMesh::LinearImplicitSystem & sys =
        es.add_system<libMesh::LinearImplicitSystem> ("GustDemo");
      sys.add_variable ("u", libMesh::FIRST);
      es.init ();

      out->ranks    = static_cast<int> (g_init->comm ().size ());
      out->rank     = static_cast<int> (g_init->comm ().rank ());
      out->elements = static_cast<int> (mesh.n_active_elem ());
      out->dofs     = static_cast<int> (sys.n_dofs ());

      std::snprintf (out->backend, sizeof (out->backend),
                     "libMesh %d.%d.%d",
                     LIBMESH_MAJOR_VERSION,
                     LIBMESH_MINOR_VERSION,
                     LIBMESH_MICRO_VERSION);
    }
  catch (...)
    {
      // The C boundary: an exception must not cross it.  Zero the struct so a
      // caller that ignores the return code cannot read a half-filled result.
      std::memset (out, 0, sizeof (*out));
      return 1;
    }

  return 0;
}

void
gust_core_finalize (void)
{
  g_init.reset ();
}

} // extern "C"
