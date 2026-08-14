# libMesh Build Support

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

The conda environment **is** the install prefix — there is no separate staging
tree and no copy step. Build-only packages (compilers, cmake, sysroot) are
pruned before packing; the compiler *runtime* stays, because
`libstdc++.so.6` and `libgcc_s.so.1` must resolve inside the tree.

## Status

Early. The driver, conda bootstrap and container loop work. The relocate,
prune, slim and validate stages are scaffolded stubs that exit non-zero — see
the sprint breakdown in the design doc, and
[`docs/HANDOFF.md`](docs/HANDOFF.md) for what is verified versus what is not.

## History

The previous generation of this repo built an **all-static** stack. That
approach is retired; see [`ARCHIVE.md`](ARCHIVE.md).
