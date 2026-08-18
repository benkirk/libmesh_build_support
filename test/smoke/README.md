# Smoke example

`trilinos_smoke.C` joins them, and is the only thing in this repo that loads the
Trilinos libraries at all: Epetra, Teuchos and — when the profile ships it —
Kokkos. It asserts values it computes independently (a `parallel_reduce` sum, a
`ParameterList` round-trip, a global `Norm1`), and it asserts that the Kokkos
host backend the runtime reports matches what the headers were compiled with —
the check that catches a build where the OpenMP backend was requested and
silently forced off. `test/run.sh` pins `OMP_NUM_THREADS` (`SMOKE_OMP_THREADS`,
default 2) so its threads do not multiply against the MPI ranks.

Two binaries, one Makefile: `smoke.c`, the MPI rank check whose contract is
below, and libMesh's own `introduction_ex4`, built with `libmesh-config` and
installed beside it, which `test/run.sh` runs in 1D/2D/3D, serial and on N
ranks. `smoke.c` stays because its assertion is the one that catches a binary
that is not really MPI-linked.

## Contract

`test/run.sh` expects:

- a `Makefile` with `all` and `run` targets
- `STACK`, `WORK`, `LIBMESH_DIR`, `PETSC_DIR`, `TRILINOS_DIR` and `MPIEXEC`
  supplied in the environment
- `make all` to leave the binary at **`$STACK/libexec/smoke`**
- object files written under `$WORK`, never beside the source

The last two are not incidental:

- **The binary installs into the stack** so that it travels inside the tarball.
  That is what makes `relocated` mode meaningful — after unpacking somewhere
  else there is a genuinely prebuilt executable to run. A binary rebuilt against
  the relocated tree would prove something weaker, and cannot be built at all in
  the verify image, which ships no compiler.
- **Nothing is written beside the source** because `docker/compose.yaml` mounts
  this directory read-only into the verify service.

## Output contract

```
smoke: rank <r>/<n>        one line per rank
smoke: ranks=<n>           rank 0 only, last
```

It must be **parallel-capable on a single node** and report the communicator
size *from every rank*, so a silently serialized run fails rather than passes.

That is stricter than it looks, and deliberately so. The failure it exists to
catch is a binary that is not really MPI-linked, or is linked against a
different MPI than the launcher: `mpiexec -n 4` then produces four independent
processes that each believe they are rank 0 of 1, and every one of them exits 0.
Checking only a rank-0 summary would pass. `test/run.sh` therefore requires
every rank id `0..n-1` to appear and every rank to have agreed on `n`.

This assertion is what carries the single-node MPI requirement through
`distcheck`.
