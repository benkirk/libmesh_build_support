# Plan: git-source installs for libMesh (alongside the release-tarball path)

**Status: implemented.** `PKG_SOURCE`, `PKG_GIT_URL` and `PKG_GIT_REF` are in
`mk/common.mk`'s `declare_pkg` and `mk/pkg.mk`'s `PKG_RULE`; `fetch_git` and
`fetch_src` are in `lib/build_common.sh`; libMesh builds from git with
`make LIBMESH_SOURCE=git`, measured green from `make conda` through
`make distcheck`. See `docs/DESIGN.md` for the numbers.

Kept as the record of the design and why it was cut this way. **What follows is
the plan as written before the work**, in the future tense, with line numbers
from the tree as it then was — read it as rationale, not as a description of
the current code.

## Context

libMesh is built today only from a GitHub **release tarball**
(`pkgs/libmesh/pkg.mk` sets `PKG_URL`, fetched by `download_src` in
`lib/build_common.sh`). That path carries real gymnastics. The largest is the
`netcdf_meta.h` repair in `pkgs/libmesh/build.sh:59-104`, which exists *only
because the release tarball ships a stale header* (`NC_HAS_HDF5 0`) that makes
ExodusII refuse every HDF5 write — the recipe's own comment (`:73-76`, `:94-97`)
records that this "bites tarball builds ... and not a git checkout." The tarball
also constrains version choice: profiles are pinned to versions that publish dist
assets, and `profiles/default.mk:12-15` notes that a git-tag build "would mean an
unbootstrapped tag archive plus autoconf/automake/libtool in the env, which is a
bigger change." libMesh publishes release assets for only a subset of tags, so an
unobtainable tarball is currently a hard blocker on a version.

We want to **keep the tarball path as the default** and **add an opt-in
git-source path** — generalised at the framework level so PETSc, Trilinos and
`site/` recipes can use it too, wired concretely for libMesh. Building from a git
checkout means: clone at a ref, initialise submodules (libMesh's contrib —
`contrib/metaphysicl`, `contrib/timpi`, `m4/autoconf-submodule` — are git
submodules, vendored in the tarball), and run `./bootstrap` (autoreconf), which
needs autoconf/automake/libtool.

### Provisioning decision

git and the autotools are provisioned in **different** places, on purpose:

- **git → the builder image.** git is a standard, heavyweight *source fetcher*,
  the same category as `curl` and `tar`, which the builder image already
  provides. It has no place in the conda toolchain, and moving it out keeps the
  env focused on what actually compiles the stack.
- **autotools → the conda env.** `./bootstrap` is sensitive to
  autoconf/automake/libtool versions; a conda-forge pin gives one reproducible
  version across every base-image distro. `m4` is already a conda build tool and
  `autoconf` requires it, so the whole autotools family belongs together there.

This is the split that keeps each side coherent: git leaves the conda env and the
artifact-prune story entirely; the version-sensitive autotools stay
distro-independent.

## Approach

### 1. A per-package source-mode switch (default `tarball`)

Thread a new `PKG_SOURCE = tarball | git` selector through the package framework,
defaulting to `tarball` so every existing recipe is byte-for-byte unchanged.

- `mk/common.mk` — in `declare_pkg` (lines 105-117), snapshot three new namespaced
  vars and clear them, mirroring the existing `PKG_STAGE` default idiom:
  `PKG_SOURCE_$(PKG_NAME) := $(or $(PKG_SOURCE),tarball)`,
  `PKG_GIT_URL_$(PKG_NAME) := $(PKG_GIT_URL)`,
  `PKG_GIT_REF_$(PKG_NAME) := $(PKG_GIT_REF)`.
- `mk/pkg.mk` — in `PKG_RULE`'s env block (after the `PKG_URL='…'` line), export
  `PKG_SOURCE`, `PKG_GIT_URL`, `PKG_GIT_REF`. These are *per-package* values, so
  they belong here, not in `PKG_ENV` (which carries only global knobs).

### 2. `fetch_git` + `fetch_src` in `lib/build_common.sh`

Add helpers after `download_src` (after line 92), mirroring its
cache-then-populate-`BUILD_TMP` shape and populating the **same** predictable
source dir `${BUILD_TMP}/${PKG_NAME}-${PKG_VERSION}`, so a recipe resolves `src`
identically in both modes.

- `fetch_git URL REF`: cache a **bare mirror** in `SRC_CACHE`
  (`$(basename URL .git).git`) with an atomic `.part` rename like `download_src`;
  `git remote update --prune` on reuse, non-fatal (an existing mirror plus offline
  is a valid state); then clone the mirror into `BUILD_TMP`,
  `git checkout --detach "${REF}"` (one code path for tag, branch, or raw SHA),
  and `git submodule update --init --recursive`. Use a mirror rather than a
  shallow `--depth 1` clone — shallow cannot check out an arbitrary SHA or serve a
  later ref.
- `fetch_src`: dispatch on `PKG_SOURCE` (default `tarball`) to `download_src` or
  `fetch_git`, for future recipes that need nothing more than a fetch. libMesh
  branches explicitly instead, because git mode also runs `./bootstrap` and needs
  a different `require` set.
- Update the "Provided by mk/pkg.mk" header comment (lines 6-8) to list the three
  new env vars.

### 3. libMesh recipe

- `pkgs/libmesh/pkg.mk` — after the `PKG_URL` line, add
  `PKG_SOURCE ?= $(LIBMESH_SOURCE)`, `PKG_GIT_URL ?= $(LIBMESH_GIT_URL)`,
  `PKG_GIT_REF ?= $(LIBMESH_GIT_REF)`.
- `profiles/{default,stable,bleeding}.mk` — add tarball-preserving defaults:
  `LIBMESH_SOURCE ?= tarball`,
  `LIBMESH_GIT_URL ?= https://github.com/libMesh/libmesh.git`,
  `LIBMESH_GIT_REF ?= v$(LIBMESH_VERSION)`. The default ref builds the same
  version as the tarball unless overridden — a natural cross-check (libMesh tags
  are `vX.Y.Z`).
- `pkgs/libmesh/build.sh` — resolve `src` once, then branch:
  - tarball: `require curl tar`; `download_src "${PKG_URL}"`.
  - git: `require git autoconf automake libtool`; `fetch_git "${PKG_GIT_URL}"
    "${PKG_GIT_REF}"`; then `( cd "${src}" && ./bootstrap )`.
  - The configure/make/install block (lines 38-57, 106-130) stays **identical**
    across modes.
  - Wrap the `netcdf_meta.h` repair (lines 59-104) so it runs for `tarball` and is
    skipped with a log line for `git`. This honours the recipe's own comment and
    avoids the `[ -f "${gen}" ] || exit 1` guard (line 99) failing a git build.

### 4. Provisioning — the split

**git → builder image:**

- `docker/Dockerfile.builder` — add `have git || need+=(git)` to the
  `have()/need+=()` probe (near lines 27-33), alongside curl/tar. The existing
  `$PM` switch already covers dnf/zypper/apt.
- `conda/bootstrap.sh` — remove `git` from the specs (line 186; keep `zlib`).
- `conda/prune.list` — remove the now-dead `git`, `libgit2` and `perl` entries
  (lines 36, 42, 47) with their comments; once git leaves the solve, `perl` (its
  only consumer, per the comment) and `libgit2` no longer appear.
- `conda/env/*.yml` — drop the `- git` line (26) from all three reference specs.
- PETSc's `--download-*` git fetches still resolve: git stays on the build PATH,
  now from the image instead of conda.

**autotools → conda:**

- `conda/bootstrap.sh` — add `autoconf automake libtool` to the build-tools spec
  line (152), next to `m4`.
- `conda/prune.list` — add `autoconf`, `automake`, `libtool` under
  `# --- build tools ---`, so they are dropped from the artifact like cmake/m4.
- `conda/env/*.yml` — add the three for consistency (non-authoritative, but should
  match the solve).

**Lock regeneration (mandatory).** The committed
`conda/lock/linux-aarch64-openblas-mpich-hdf5ser.lock` currently pins
`git-2.55.0` and `perl` and lacks the autotools, and a checked-in lock *shadows*
the spec list (`conda/bootstrap.sh:103-113`). Regenerate it so git/perl leave and
autoconf/automake/libtool arrive: `make conda IGNORE_LOCK=1 && make conda-lock`,
run on aarch64 (native in CI). linux-64 has no committed lock — it solves fresh,
so no action is needed there.

### 5. Builder compression support: xz and bz2

For forward flexibility with source tarballs published as `.tar.bz2` or `.tar.xz`
(future TPLs; some upstreams do not ship `.tar.gz`), the **builder image** must
carry the matching decompressors. `download_src` already uses `tar -xf`, which
auto-detects the format and shells out to the decompressor — so this is purely an
image-provisioning gap, no recipe change.

- `bzip2` is **already** installed by `docker/Dockerfile.builder` (line 30, added
  for the miniforge installer), so `.tar.bz2` is already covered.
- `xz` is **missing**. Add it to the same probe. Note the package name differs by
  package manager, unlike bzip2: `xz` on dnf and zypper, but `xz-utils` on apt.
  Follow the pattern the probe already uses for the procps naming split (`$PS`) —
  set an `XZ` variable per `$PM` and append it: `have xz || need+=("$XZ")`.

The **verify** image (`docker/Dockerfile.verify`) is deliberately left unchanged:
it only unpacks *our* artifact, which is `.tar.gz` (`mk/common.mk:62`), so it
needs `tar` + `gzip` and nothing more. Revisit only if the dist compression
changes.

### 6. Docs + CI

- `docs/EXTENDING.md` — extend the `pkg.mk` contract (document `PKG_SOURCE`,
  `PKG_GIT_URL`, `PKG_GIT_REF`; default `tarball`, the git vars required only when
  `PKG_SOURCE := git`) and the `build.sh` contract (recipe now also receives those
  three; `lib/build_common.sh` provides `fetch_git`/`fetch_src`; git mode requires
  the recipe to `require git autoconf automake libtool` and run its own bootstrap;
  git comes from the builder image, autotools from conda).
- `profiles/default.mk:12-15` — update the "bigger change" comment: this path now
  exists (`make LIBMESH_SOURCE=git LIBMESH_GIT_REF=v1.7.6`), so an unobtainable
  release tarball is no longer a hard blocker on a version.
- `lib/build_common.sh` header (lines 6-8) — list the three new env vars and the
  two new helpers.
- `relocate/validate.sh:61` — minor comment tidy: git/perl are no longer in the
  tree to be pruned (cosmetic; no logic change).
- CI (`.github/workflows/`): add a weekly `libmesh-git` job to `extended.yml` (the
  right home for a declared-but-unproven config), exercising the git path end to
  end including the ExodusII smoke test. linux-64 first (conda solves fresh, no
  lock refresh needed); add aarch64 once the regenerated lock is committed.
  Threading it needs a small `libmesh_source` input (default `tarball`) in
  `stack.yml`, plumbed as `-e LIBMESH_SOURCE=` into the `make all` step, mirroring
  how `HDF5_PARALLEL`/`IGNORE_LOCK` are passed. Keep the job `experimental: true`.

## Verification (end to end)

1. **Tarball path unchanged (regression guard):** `make conda build test` — the
   default `PKG_SOURCE=tarball` still runs the netcdf repair and passes
   `introduction_ex4`.
2. **Provision + refresh lock (once, on aarch64 in CI):**
   `make conda IGNORE_LOCK=1 && make conda-lock`; confirm the new lock drops
   git/perl and adds autoconf/automake/libtool.
3. **Build from git:** `make LIBMESH_SOURCE=git build` (optionally
   `LIBMESH_GIT_REF=v1.7.9` to match the tarball, or a branch/SHA). The log should
   show the mirror clone, the submodule fetch, `bootstrapping (autoreconf)`, and
   the skipped tarball repair.
4. **ExodusII/HDF5 gate:** `make LIBMESH_SOURCE=git test` runs `test/run.sh
   inplace`, which builds and runs `introduction_ex4` and asserts non-empty
   ExodusII output — exactly the path the netcdf patch existed for, proving the git
   build's upstream header is correct without the repair.
5. **Relocate + ship:** `make LIBMESH_SOURCE=git relocate validate dist distcheck`
   — validate rejects `.la` files and embedded build paths; distcheck unpacks the
   tarball elsewhere and reruns the prebuilt ex4; confirm autoconf/automake/libtool
   and git are absent from the packed tree.
6. **Compression:** confirm the builder image has both `bzip2` and `xz` (e.g. a
   `.tar.xz` source unpacks via `download_src`), across the dnf/zypper/apt bases.

## Risks / edge cases

- **Submodule network fetch** — the one genuinely new external dependency versus
  the tarball. The top-level mirror caches the superproject but not submodule
  objects, so a re-run still reaches the network for contrib submodules.
- **Lock shadowing (aarch64)** — highest-probability operational failure: without
  the regen, the aarch64 git build dies at `./bootstrap` (no `autoreconf`) and
  still carries git/perl.
- **`./bootstrap` version sensitivity** — a too-new automake/libtool can trip on
  libMesh's `configure.ac`; the conda pin gives one controllable version. The
  recipe already copies `config.log` (line 120); consider capturing bootstrap
  output too.
- **Bare-host (non-docker) builds** now need git on the host (as they already need
  curl/tar) — a deliberate consequence of treating git as a fetcher.
- **`xz` package naming** — `xz-utils` on apt vs `xz` on dnf/zypper; a single
  `need+=(xz)` would fail on Debian-family bases.
- **`v$(LIBMESH_VERSION)` default ref** — if a version's tag is named differently,
  the checkout fails clearly; override `LIBMESH_GIT_REF`.
