# Plan: a second PETSc / libMesh / Trilinos pairing, built in CI

**Status: not started.** What remains of the handoff from #28 after the
optional-package half landed —
[`implemented/OPTIONAL-PACKAGES-FROM-THE-ENV.md`](implemented/OPTIONAL-PACKAGES-FROM-THE-ENV.md).

## Goal

`PROFILE` selects `profiles/<name>.mk`, and only `default` has ever been built.
`bleeding` is a declaration, not a claim. Bump it to a current pairing and put
it in `ci.yml` on both platforms, so "the stack builds against a newer PETSc"
is something CI knows rather than something we assume.

## The pairing

PETSc **3.23.7**, libMesh **1.8.4**, Trilinos **16-1-0**. All three fetch from
the URLs `pkgs/*/pkg.mk` already construct (`libmesh-1.8.4.tar.gz` is a
published release asset; 3.25.4 and 16-2-2 exist but the point is a pairing
someone runs, not the newest of everything).

Measured on `linux-aarch64` while the optional-package work was in flight, so
the two known risks are already retired:

- **PETSc 3.23.7 builds**, with one addition to the recipe's v0 option set.
  3.23 downloads a SuiteSparse whose CHOLMOD builds demo programs under
  `BUILD_TESTING` (its own `SUITESPARSE_DEMOS` defaults OFF, but the CMake gate
  is `SUITESPARSE_DEMOS OR BUILD_TESTING`), and linking `cholmod_di_demo` fails
  for want of an `-rpath-link` to `libopenblas.so.0`. `pkgs/petsc/build.sh`
  passes `--download-suitesparse-cmake-arguments=-DBUILD_TESTING=OFF`: the
  libraries the stack installs were never affected, and nothing here wanted the
  demos built. A no-op for the older SuiteSparse 3.20.5 downloads.

  Recorded because the first reading of this measurement was wrong: the run was
  called green when only the shell wrapper around it had exited 0. Both attempts
  had failed identically.
- **Trilinos 16-1-0 builds** with the recipe unchanged, including
  `-DTrilinos_ENABLE_Kokkos=OFF`. `profiles/README.md` carries a v0-era
  prediction that this flag "is not expected to survive a version bump"; it
  did. Sacado's Kokkos dependence is *optional* (`-- Setting
  Sacado_ENABLE_Kokkos=OFF because Sacado has an optional library dependence on
  disabled package Kokkos`), and the final package set is the same four:
  Teuchos, Sacado, Epetra, Pliris. `libdpliris.so.16.1.0` installs.

What is **not** yet measured: libMesh 1.8.4 against that PETSc, and the whole
pairing end to end. 1.8.4 does have `--with-xdr-include`/`--with-xdr-libname`
(they arrived in 1.8.0), so the XDR road the recipe picks by probing
`configure` changes under it — that branch has never run.

### Kokkos is now a choice, not a constraint

Since 16-1-0 builds either way, the question is which configuration to ship. A
customer is reportedly building Trilinos 16.1.0 with no Kokkos flag at all,
which means Kokkos defaults **on** for them. Make it a knob rather than a
hard-coded line in the recipe:

- `mk/common.mk`: `TRILINOS_KOKKOS ?= off` — `off` passes
  `-DTrilinos_ENABLE_Kokkos=OFF`, `auto` passes nothing and lets Trilinos
  decide.
- `profiles/default.mk` keeps `off` (14-4-0's artifact must not move);
  `profiles/bleeding.mk` sets `auto`.
- Measure what `auto` costs: build time, installed library set, package count,
  tarball size. Two things to watch, both findings either way — Kokkos' CMake
  adds architecture flags and the ISA wrappers **error** on `-march=native`;
  and Trilinos' installed set widens in a prefix whose Trilinos side has no
  compile-line gate of its own.

## Plumbing

`PROFILE` is a make knob and nothing else: absent from `docker/compose.yaml`'s
`environment:`, from `stack.yml`'s inputs, from the artifact slug and CONFIG
string, and from `.github/scripts/inputs-sha.sh` — which hashes the *contents*
of `profiles/` but not which one was selected. The `devel` image tag is
`<platform>-<blas>-<mpi>-<SHA_BUILD>`, so two profiles would publish over each
other.

- `docker/compose.yaml`: `PROFILE: ${PROFILE:-default}`.
- `stack.yml`: a `profile` input, into the build job's `env:` and into the
  Names step — appended to the artifact slug only when non-default, as
  `LIBMESH_SOURCE` and `HOST_EXTRAS` already are, so today's names do not move.
  The CONFIG string should always name it.
- `inputs-sha.sh`: fold `profile=` into `sha_build` **only** — the toolchain
  image is profile-independent, so `SHA_CONDA` must not change — and suffix the
  `devel` tag when non-default. `docker/pull-shell.sh` and `image-shell` in
  `mk/stages.mk` pass it too, or the local ref stops matching the published one.
- `relocate/validate.sh`: record `profile` and the source-package versions in
  `etc/stack-manifest.json` (through `PKG_ENV` in `mk/common.mk`). The manifest
  currently describes the conda side only, so a tarball cannot say which
  pairing it is.
- `ci.yml`: matrix over `profile × target_platform`. Give the `bleeding` legs
  `verify_bases: 'almalinux:8 ubuntu:24.04'` and `experimental: true` until
  they have been green for a few weeks, both stated as temporary, with the
  promotion criterion.

**No per-profile conda env is expected.** `cmake<4` resolves to 3.31, above
Trilinos 16's `>= 3.23` floor (and it configured 16-1-0 in the measurement
above), and `python<3.13` is harmless to PETSc 3.23.7 (which built under it).
Both are build tools `prune.list` drops. If that turns out to be wrong, the
profile has to enter the env-spec and lock names and `inputs-sha.sh`'s conda
half — a much larger change, worth its own discussion.

## Do first, cheaply

1. `PROFILE=bleeding make all` on aarch64, locally. That answers the libMesh
   1.8.4 questions — the 1.8 XDR branch, whether `contrib/boost` is still
   preferred over conda's, whether the netcdf_meta.h repair (A29) is still
   needed — for the price of one 40-minute run, before any CI time is spent.
2. Then the plumbing, then `ci.yml`.

## Deliberately not here

Renaming the profiles (`stable` → `legacy`, `default` → `stable`, `bleeding` →
`default`, leaving room for a future `devel`). It is the right end state once
the new pairing is proven, and it changes what every per-PR job defends, so it
is its own PR: a `git mv` plus a sweep of `README.md`, `docs/DESIGN.md`,
`docs/CI.md`, `config.mk.example` and `profiles/README.md`.
