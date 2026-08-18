# libMesh Build Support

[![checks](https://github.com/benkirk/libmesh_build_support/actions/workflows/checks.yml/badge.svg)](https://github.com/benkirk/libmesh_build_support/actions/workflows/checks.yml)
[![ci](https://github.com/benkirk/libmesh_build_support/actions/workflows/ci.yml/badge.svg)](https://github.com/benkirk/libmesh_build_support/actions/workflows/ci.yml)

Builds a **relocatable, shared-library stack** — PETSc, Trilinos, libMesh and
their MPI/BLAS/HDF5 closure — that can be tarred up, unpacked anywhere on a
customer's machine, and run, with no host dependency beyond core glibc. The
mechanism is `$ORIGIN`-relative RPATHs; the point is that the repo does not
*claim* relocatability, it proves it: `make distcheck` tars the tree, moves
the original out of its path, unpacks at a different depth and runs the tests
again.

It is also a **template**: drop your own recipes into `site/` and the same
build, relocate, prune and validate machinery covers them.

## Using the artifact

The tarball is `libmesh-stack-<version>-<platform>-<blas>-glibc<floor>.tar.gz`,
with one top-level `stack/`. Every `ci` run on `main` publishes it as a
workflow artifact for 14 days; or build it yourself (next section).

```sh
tar xzf libmesh-stack-0.1.0-linux-64-openblas-glibc2.28.tar.gz
. stack/activate.sh                # PATH, PKG_CONFIG_PATH, CMAKE_PREFIX_PATH,
                                   # PETSC_DIR, LIBMESH_DIR, TRILINOS_DIR, HDF5_ROOT
libmesh-config --cxx --cppflags --libs     # or: pkg-config --libs libmesh PETSc
mpiexec -n 4 stack/libexec/introduction_ex4 -d 2 -n 15
```

`activate.sh` finds its own root and never sets `LD_LIBRARY_PATH` — every
object carries its RPATH. `stack/etc/stack-manifest.json` records what is
inside and what it was measured at. Three things to know:

- **No compiler ships.** `mpicc` is there, and `mpicc -show` tells you the flags;
  build with your own compiler (`MPICH_CC=…`), or build inside the template
  before the prune — that is what `site/` is for.
- **The host's glibc must be at least the floor in the name** — the `GLIBC_FLOOR`
  pin, 2.28 by default; `validate` measures what the tree really needs and fails
  if that exceeds the pin.
- **Install somewhere without spaces** if you build against the stack with
  make. The binaries and `.pc` files work from any path — `distcheck` unpacks
  under one with a space — but GNU make's path functions split on it, so
  libMesh's example Makefiles and PETSc's `conf/*` do not.

## Building the stack

Don't build on the host — use the container loop, which is what CI runs too:

```sh
cd docker
docker compose run --rm shell      # /src on the toolchain image; inside it:
  make print-config                #   check the knobs before a long build
  make conda build                 #   miniforge + env, then the source packages
  make all                         #   ... test, relocate, validate, slim, dist, distcheck
VERIFY_IMAGE=almalinux:8 docker compose run --rm --build verify   # back on the host
```

`make help` lists every target. The compose loop defaults to `linux/arm64` and
`TARGET_PLATFORM=linux-aarch64`; for the x86 column set
`PLATFORM=linux/amd64 TARGET_PLATFORM=linux-64` in the environment (Rosetta on
Apple Silicon; required for `BLAS_PROVIDER=mkl`). On a 4-vCPU CI runner
`make all` is ~36 min (`linux-64`) / ~30 min (`linux-aarch64`). Give
Docker Desktop ≥ 60 GB disk and ≥ 12 GB memory. Nothing is re-runnable over its
own output — iterate with `make distclean`. `make image-shell` pulls the image
CI built for your checkout instead of building one.

## What you get

`linux-aarch64` measured on this branch (2026-08-17); `linux-64` still from
`main` at `a61f0d6` and refreshed by the next `ci` run, which is the live source
and supersedes this table.

| | linux-64 | linux-aarch64 |
|---|---|---|
| from source | PETSc 3.20.5, Trilinos 14-4-0, libMesh 1.7.9 | same |
| from conda-forge | mpich 5.0.1, OpenBLAS, HDF5 1.14 (serial); Boost 1.91, Eigen 3.4, libtirpc, GLPK 5.0 for libMesh; libstdc++ 16.1 runtime, compiled with gcc 14 | same |
| libMesh options on | PETSc, HDF5, NetCDF-4, ExodusII, Boost, Eigen, XDR, Tecplot (TecIO), GLPK, MetaPhysicL, Triangle | same |
| tarball | 111 MB, 58 packages | 123 MB, 63 packages |
| ELF objects | 335, all within `x86-64-v2` | 341, all within `armv8.1-a` |
| glibc floor | 2.28 requested, 2.27 measured | same |
| runs on | `almalinux:8` (glibc 2.28) through `ubuntu:24.04` (2.39), five images | same |

## The knobs worth knowing

Set in `config.mk` (copy `config.mk.example`) or on the command line.

| knob | default | |
|---|---|---|
| `TARGET_PLATFORM` | `linux-64` | or `linux-aarch64` |
| `BLAS_PROVIDER` | `openblas` | `mkl` is x86-64 only |
| `MPI_FAMILY` | `mpich` | `openmpi` is not supported yet — prerequisites in `docs/CI.md` |
| `GLIBC_FLOOR` | `2.28` | the conda sysroot pin; the tarball name carries it |
| `ISA_BASELINE_X86` / `_AARCH64` | `x86-64-v2` / `armv8.1-a` | a cap the compiler wrappers enforce and the ISA scan gates |
| `PROFILE` | `default` | version set, `profiles/` |
| `SHIP_PYTHON` | `no` | keep the python stack in the artifact |
| `LIBMESH_SOURCE` | `tarball` | `git` clones and bootstraps `LIBMESH_GIT_REF` |

Everything else: `make print-config`.

## Where to go next

- [`docs/DESIGN.md`](docs/DESIGN.md) — how it works and why: the conda env *is*
  the prefix, the pipeline, RPATH, the ISA baseline, and every constraint that
  was found by measurement.
- [`docs/EXTENDING.md`](docs/EXTENDING.md) — adding your own packages to `site/`.
- [`docs/CI.md`](docs/CI.md) — the workflows, the matrix, and how to read a run.
- [`ARCHIVE.md`](ARCHIVE.md) — the retired all-static generation.
- `docs/plans/` holds work not yet done; `docs/plans/implemented/` holds finished
  plans and the sprint history, kept for their reasoning, not as current docs.

## License

This repository — the recipes, scripts and documentation — is [MIT](LICENSE).
The tarball it builds carries the licenses of what is inside it: libMesh
(LGPL), PETSc, Trilinos, OpenBLAS and HDF5 (BSD), MPICH, and the conda-forge
closure; `stack/etc/stack-manifest.json` records each package's license. Shared
linking is what keeps the LGPL obligation to relinking, which the tree satisfies
by construction. `BLAS_PROVIDER=mkl` adds Intel's own license terms.
