# Smoke example

Drop the libMesh example here. The harness (`test/run.sh`) expects:

- a `Makefile` with `all` and `run` targets
- `LIBMESH_DIR`, `PETSC_DIR` and `MPIEXEC` supplied in the environment
- a binary named `smoke`

It must be **parallel-capable on a single node** and assert
rank-count-dependent output, so that a silently serialized run fails rather
than passes. That assertion is what carries the single-node MPI requirement
through `distcheck`.
