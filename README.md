# libMesh Build Support

[![checks](https://github.com/benkirk/libmesh_build_support/actions/workflows/checks.yml/badge.svg)](https://github.com/benkirk/libmesh_build_support/actions/workflows/checks.yml)
[![ci](https://github.com/benkirk/libmesh_build_support/actions/workflows/ci.yml/badge.svg)](https://github.com/benkirk/libmesh_build_support/actions/workflows/ci.yml)

Builds a **relocatable, shared-library stack** that can be tarred up, unpacked
anywhere on a customer's machine, and run — with no host dependencies beyond
core glibc.

The mechanism is `$ORIGIN`-relative RPATHs applied with `patchelf`. The point of
this repo is that it doesn't just *claim* relocatability: `make distcheck` tars
the tree, deletes the original, unpacks it at a different path depth, and runs
the tests again.

It is also a **template**. Drop your own package recipes into `site/` and they
join the same build graph; the relocate, prune and validate machinery then
covers your packages too.

Design and rationale: [`docs/RELOCATABLE-STACK-PLAN.md`](docs/RELOCATABLE-STACK-PLAN.md).

## Quick start

```sh
cp config.mk.example config.mk     # edit to taste
make conda                         # miniforge + the build env
make build                         # source packages, into the same prefix
make test                          # smoke example, in place
make relocate validate             # $ORIGIN rpaths, then the gate
make dist distcheck                # tar, unpack elsewhere, test again
```

`make help` lists every target. `make print-config` shows resolved settings.

## Developing on macOS

Don't build on the host — use the container loop:

```sh
cd docker
docker compose run --rm shell            # then: make conda, make build, ...
docker compose run --rm verify           # test the tarball on a pristine image
```

`build` and `verify` deliberately run on *different* images, and the tarball is
the only thing that crosses between them. On Apple Silicon `PLATFORM=linux/arm64`
is native and is a real target; `linux/amd64` runs under Rosetta and is required
for `BLAS_PROVIDER=mkl`.

## Pulling a published image

CI publishes two images per configuration — `builder` (the provisioned
toolchain) and `devel` (toolchain *plus* the built stack, the one to reach for).
To pull the image matching your checkout and drop into a shell:

```sh
make image-shell                        # devel, for the current make config
STAGE=builder make image-shell          # the toolchain-only image
docker/pull-shell.sh                    # same, straight from the compose loop
```

The tag is a *content hash* of the config and recipes, computed by the same
`inputs-sha.sh` that named the image when CI pushed it — so on the commit that
built an image this reproduces its reference exactly, and a tree CI never built
resolves to a tag that simply isn't there. Inside `devel`, drop a recipe into
`site/` and `make build` compiles only that addition; every tracked package is
already accounted for.

## How it fits together

| | |
|---|---|
| `Makefile`, `mk/` | the driver: knobs, package discovery, stage targets |
| `profiles/` | version sets (`default`, `stable`, `bleeding`) |
| `conda/` | miniforge bootstrap, env specs, locks, `prune.list` |
| `pkgs/` | source package recipes; `pkgs/_template/` to copy |
| `site/` | **your** recipes — gitignored, auto-discovered |
| `hooks/` | `pre-`/`post-` stage injection points |
| `relocate/` | patchelf, path fixup, prune, slim, and the validator |
| `test/` | smoke harness and the relocation proof |
| `docker/` | the local dev loop, reused by CI |
| `.github/workflows/` | the fast gate, and build-once-verify-everywhere |

The conda environment **is** the install prefix — there is no separate staging
tree and no copy step. Build-only packages (compilers, cmake, sysroot) are
pruned before packing; the compiler *runtime* stays, because
`libstdc++.so.6` and `libgcc_s.so.1` must resolve inside the tree.

## Status

The pipeline is green end to end on `linux-64` and `linux-aarch64`: `make all`
runs conda → relocate → validate → slim → dist → `distcheck`, and the tarball
it produces has been unpacked and run on distros from glibc 2.28 to 2.39. Every
pull request re-runs that, on both architectures, across five base images.

What it does *not* yet contain is the point of the exercise: the PETSc, libMesh
and Trilinos recipes are not written, so today's tarball is the conda
environment and a placeholder MPI smoke test. See the sprint breakdown in the
design doc, and [`docs/HANDOFF.md`](docs/HANDOFF.md) for what is verified
versus what is not.

## CI

| workflow | when | what |
|---|---|---|
| `checks.yml` | every push and PR | parses, lints, stage graph, ISA self-test, every base image builds — about two minutes |
| `ci.yml` | PRs and `main` | `make all` on both target platforms, then the tarball unpacked and run on all five base images |
| `extended.yml` | weekly | a fresh conda-forge solve instead of the lock, plus the knobs nobody runs: MKL, parallel HDF5, libMesh from git, a Debian-family builder |

The jobs drive `docker compose` against `docker/`, so they run the same images
and the same commands as the local dev loop — and the verify matrix expands
from `docker/bases.env`, so adding a distro there adds it to CI. Each build
publishes its tarball as a workflow artifact, which is the most convenient way
to get one onto real hardware.

## History

The previous generation of this repo built an **all-static** stack. That
approach is retired; see [`ARCHIVE.md`](ARCHIVE.md).
