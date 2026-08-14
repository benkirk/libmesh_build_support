# Sprint Plan: Relocatable Shared-Library Stack (v1)

> **Status: in progress.** This is the agreed design for the next generation of
> `libmesh_build_support`, and it remains the source of truth. S0 and S0b are
> done — the `v0-static-stack` tag is pushed, the autotools tree is gone, and the
> driver and container loop are in place. Everything from `relocate` onward is
> still a stub. A review of this plan is recorded in **Amendments** at the end;
> read it before implementing any section, since several specifics here have been
> corrected there.
>
> Two departures from the sprint order below, both deliberate:
> **S4 lands before S2** — the relocate/validate machinery can be proven against
> the conda env alone in a six-minute loop, instead of last and on a multi-hour
> one. And the smoke test arrives **staged** (MPI-only → PETSc → libMesh →
> `introduction_ex4`) so the pipeline is exercisable from the start.

## Context

`libmesh_build_support` today is an autotools-driven meta-build that produces an
**all-static** stack (gcc → zlib → hdf5 → mpich → petsc → libmesh → trilinos) so a
libMesh dev environment can be stood up on a minimal host. The static premise is
visible everywhere: `--enable-static --disable-shared` in `gcc/build.sh`,
`hdf5/build.sh`, `libmesh/build.sh`, `mpich/build.sh`; `--static` in `zlib/build.sh`;
`--with-shared-libraries=0` in `petsc/build.sh`; `-DBUILD_SHARED_LIBS=OFF` in
`trilinos/build.sh`; and PETSc/Trilinos scavenging host `/lib64/libblas.a`.

That premise no longer holds. Fully-static builds of this stack are increasingly
impractical — glibc's static NSS, `--download-*` packages that ignore static
requests (see the `3.17*` special case in `petsc/build.sh:47` where ML had to be
disabled), and upstreams that simply don't test static any more.

The replacement premise: **ship shared libraries in a directory tree that works at
any install path, on any reasonably modern Linux host, with essentially no host
dependencies beyond core glibc.** The mechanism is `$ORIGIN`-relative RPATHs applied
by `patchelf`, and — critically — the workflow *validates* that claim end-to-end by
tarring the tree, deleting the original, unpacking it somewhere else, and testing
again.

Second goal, equally important: this becomes a **template**. Customers layer their
own packages on top of libMesh in the same build graph, and the relocate/slim/validate
machinery then runs over the whole tree, theirs included.

The current static workflow will be tagged and archived (S0); the new workflow then
replaces the top level.

## Locked decisions

| Decision | Choice |
|---|---|
| Repo | Same repo, new generation. Tag `v0-static-stack`, replace top-level layout. |
| Toolchain | conda-forge `gcc/gxx/gfortran_linux-*` + pinned `sysroot_linux-*`. **`GCC_VERSION` is a knob**, default 14 — conda-forge carries 7 through 16; an unpinned solve picks 16.1.0, which is not what we want. |
| Prefix | Single merged `stack/{bin,lib,include}` → every RPATH is `$ORIGIN/../lib`. |
| Driver | Plain GNU Makefile + bash. No autoconf. No absolute paths baked into env scripts. |
| From conda | build tools, MPI, BLAS/LAPACK, HDF5, zlib. |
| MPI family | `MPI_FAMILY ∈ {mpich, openmpi}`, orthogonal to `MPI_PROVIDER ∈ {conda, source}`. MPICH is the default and the better-behaved one to relocate; OpenMPI is supported but costs real extra work (see below). |
| BLAS/LAPACK | A build parameter on **every** platform, not just aarch64. `openblas` yields a fully OSS-licensed artifact; `mkl` yields an x86-only optimized one. Both built from the same tree; the provider is encoded in the tarball name. |
| MPI scope | **Requirement:** the bundled MPI runs N ranks on a single node. Multi-node via a customer's own ABI-compatible MPI is a **deferred follow-on**, not sprint scope — we only avoid choices that would foreclose it. |
| From source | PETSc, libMesh, Trilinos, customer packages. Source MPI stays as an opt-in override. |
| glibc floor | A knob. Default `sysroot=2.28`; `2.17` supported. |
| conda env | **The env is the prefix.** `conda create -p $(BUILD_ROOT)/stack`; source packages install into that same prefix. Build-only packages (compilers, cmake, ninja, sysroot) are *pruned* before packing — compiler **runtime** stays. No harvest/copy step. |
| Validator gate | Only core glibc may resolve outside the tree. `libstdc++.so.6` / `libgcc_s.so.1` **must** resolve inside it. |
| Platforms | `linux-64` and `linux-aarch64`. (macOS explicitly out of scope.) |
| Consumer mode | Template for extension — customers build packages against the stack, so compile capability is retained through the build and is a slim-profile choice at the end. |

## Target layout

### Repo, after the change

```
Makefile                  top-level driver: conda build test relocate validate slim dist distcheck
config.mk.example         knobs (copy to config.mk); see below
mk/common.mk              paths, stamps, verbosity, -jN, ELF helpers
mk/pkg.mk                 generic per-package rule  (successor to rules/Make.pkg_deps)
mk/stages.mk              stage targets and their ordering
profiles/{default,stable,bleeding}.mk        (successor to utils/versions/*.sh)
conda/bootstrap.sh        non-interactive miniforge install into the build root
conda/env/*.yml           env specs per platform x BLAS provider
conda/lock/*.lock         explicit locks (regenerated by `make conda-lock`)
pkgs/petsc/{pkg.mk,build.sh}
pkgs/libmesh/{pkg.mk,build.sh}
pkgs/trilinos/{pkg.mk,build.sh}
pkgs/mpich/{pkg.mk,build.sh}        opt-in source MPI
pkgs/_template/{pkg.mk,build.sh}    ← the extension point (successor to utils/build_template.sh)
site/                     gitignored; customer package dirs, auto-discovered
hooks/{pre,post}-<stage>/ run-parts style injection points
conda/prune.list          conda packages dropped from the redistributable
relocate/depsolve.py  patchelf.sh  fixup-text.sh  prune.sh  slim.sh  validate.sh
stack/activate.sh.in      template for the shipped activation script
test/smoke/               owner-provided libMesh example lands here
test/run.sh               harness, MODE = inplace | relocated
docker/Dockerfile.builder  Dockerfile.verify  compose.yaml  bases.env
docs/EXTENDING.md
ARCHIVE.md  README.md  .dockerignore
```

`docker/Dockerfile.builder` is worth calling out as more than convenience: because it
installs only what a bare host genuinely needs (`curl`, `ca-certificates`, `tar`,
`bzip2`, a shell — conda supplies the compilers), it is the **executable statement of
this project's minimal-host claim**. If it ever needs a dev package added, that is a
regression in the premise, not a fix to the image.

### Generated build root (step 0's "new, empty directory")

```
$(BUILD_ROOT)/
  .conda/         miniforge installer + base — throwaway, never shipped
  .work/          sources, tmp builds, logs, stamps
  stack/          ← a conda env AND the redistributable prefix; this is what gets tarred
     bin/ lib/ include/ share/ libexec/
     conda-meta/           package manifests + embedded-prefix inventory (see below)
     etc/stack-manifest.json
     activate.sh
```

`stack/` is created by `conda create -p $(BUILD_ROOT)/stack`, and the source-built
packages install into that same prefix with `--prefix=$(BUILD_ROOT)/stack`. There is
no second prefix and no copy step between them.

### `config.mk` knobs

```make
BUILD_ROOT      ?= $(CURDIR)/_root     # step 0's new, empty directory
PROFILE         ?= default             # profiles/*.mk — package version set
TARGET_PLATFORM ?= linux-64            # linux-64 | linux-aarch64
GLIBC_FLOOR     ?= 2.28                # sysroot_linux-* pin; 2.17 supported
GCC_VERSION     ?= 14                  # conda-forge gcc_linux-*; 7..16 available, 14.4.0 current
BLAS_PROVIDER   ?= openblas            # openblas (OSS) | mkl (x86-64 only)
MPI_FAMILY      ?= mpich               # mpich | openmpi
MPI_PROVIDER    ?= conda               # conda | source
MPI_VERSION     ?= 5.0.1               # mpich 5.0.1 | openmpi 5.0.10
HDF5_PARALLEL   ?= no                  # no -> nompi_* | yes -> mpi_<family>_*  (see A3)
RPATH_MODE      ?= rpath               # rpath | runpath
SLIM_PROFILE    ?= devel               # devel | runtime
SHIP_PYTHON     ?= no                  # keep conda's python in the redistributable?
SMOKE_RANKS     ?= 4
SITE_DIRS       ?= site
```

## Key design decision: the conda env *is* the prefix

An earlier revision of this plan had a **harvest** step: build against a conda env in
`.toolchain/`, then copy the runtime content we needed into a separate `stack/` prefix
and discard the env. That step is gone. It was the riskiest part of the design and it
bought almost nothing. The reasoning is worth recording, because it is the single
biggest structural decision here.

**Harvest defeated its own size argument.** A dependency closure cannot see
`dlopen`ed libraries — MKL's dispatch (`libmkl_def`, `libmkl_avx2`, `libmkl_avx512`,
`libmkl_vml_*`) loaded from `libmkl_core`, OpenBLAS threading layers, MPICH's
Hydra/PMI helpers, libfabric/UCX providers, hwloc plugins. The only safe mitigation is
to copy whole conda packages. But "copy the whole package to be safe" *is* shipping
the package. Once dlopen forces whole-package granularity, harvest ships substantially
the same payload as a pruned env — via several hundred lines of code that can silently
omit something.

**Harvest's layout argument was also circular.** The merged `bin/lib/include` prefix
that makes every RPATH a simple `$ORIGIN/../lib` is precisely what a conda env prefix
already is. Harvest was rebuilding, by hand, a layout conda hands over for free.

**The risk profile inverts, and that is the real prize.** Harvest asks *"did I copy
everything I need?"* — unbounded, and its failures surface on the customer's machine.
Pruning asks *"did I delete something I need?"* — bounded, and `distcheck` already
catches it, because the relocated smoke test runs after the prune.

**Conda hands us a better fixup inventory than we could build.** Each
`conda-meta/<pkg>.json` records not only the package's exact file list but, per file,
whether the build prefix is embedded and whether as text or as padded binary. That is
a precise, machine-readable list of every file needing path rewriting. The earlier
plan's `grep -r $(BUILD_ROOT)` sweep was a safety net designed *because* harvest gave
no such inventory; it now demotes to a cheap final assertion rather than the primary
mechanism.

The cost of this choice, stated plainly: we inherit conda's full dependency closure,
including packages nobody asked for (openssl, libcurl, ncurses and friends). That is
more surface for the validator and more licenses to account for — though `conda-meta`
carries per-package license metadata, making that audit easier than it would be for a
hand-assembled set, not harder.

What survives from the old design: selection and pruning are still driven by conda
package file manifests, never by guesswork; and `relocate/depsolve.py` still exists,
but it now only drives the aggressive slim profile instead of being load-bearing for
correctness.

### Measured, not estimated

A real conda-forge solve on `linux-64` (conda 26.3.2, 2026-08), env spec as in S1:

| | uncompressed |
|---|---|
| Full env as solved | **1.9 GB** (1828 MB by package accounting) |
| Build-only packages (compilers, sysroot, binutils, cmake, ninja) | 861 MB |
| After dropping build-only | 967 MB |
| …minus the accidental MKL pull (below) | ~407 MB |
| …minus the python stack (python, pip, icu, tk, sqlite, ncurses, readline) | **~215 MB** |
| MKL variant: `mkl` package alone | 683 MB |

So a correctly-pruned openblas redistributable lands around **200–250 MB** — which is
what a harvest of the same runtime packages would have produced, because it is the
same set of packages. The gigabytes are compilers, and both approaches drop them.
**Confirms the decision: near-identical shipped size, materially lower risk.**

Two findings from the measurement that are now design constraints, not observations:

1. **Asking for the `libblas`/`liblapack` metapackages dragged in MKL** — 560 MB of it,
   alongside the openblas that was actually selected. Request `libopenblas` and pin the
   BLAS variant (`blas=*=openblas`) explicitly; never take the bare metapackages. This
   is exactly the class of drift the checked-in lock files exist to prevent, and it is
   only visible by measuring.
2. **The `mpich-mpicc`/`mpicxx`/`mpifort` split packages are stale and constrained the
   solve back to mpich 3.2.1 (2017).** Modern `mpich` builds ship the wrappers
   themselves. Request `mpich` alone and pin a current version.

Both are one-line fixes in the env spec, and both would have been invisible until a
customer hit them.

## MPI: what is in scope, and what we merely avoid foreclosing

**In scope, and a hard requirement:** the bundled MPICH launches N ranks on one node,
in place and after relocation. The concrete work is small but real — MPICH's Hydra
launcher finds `hydra_pmi_proxy` via a path compiled in at configure time, so it needs
the same treatment as the `mpicc` wrappers, and `activate.sh` putting `stack/bin` on
`PATH` covers the rest for local launch. The libMesh smoke example therefore runs
under `mpiexec -n N` at every test point, including inside `distcheck`.

**Deferred:** letting a customer substitute their own ABI-compatible MPI. Not sprint
scope. What keeps the door open costs nothing now and needs no extra design:

- conda-forge's mpich exports the MPICH ABI SONAME `libmpi.so.12`, shared with Intel
  MPI and MVAPICH. **Verified against mpich 5.0.1**: despite the major version bump it
  still ships `libmpi.so.12.6.1` with `SONAME libmpi.so.12`. Installing it as an
  ordinary shared library under that SONAME — rather than renaming, wrapping, or
  partially inlining it — is simply the default behaviour, and is the whole of
  "don't break it by design."
- **MPICH 5.0 additionally ships `libmpi_abi.so.1` plus `mpicc_abi`/`mpicxx_abi`
  wrappers** — the standardized MPI-5 ABI, which OpenMPI is also implementing. That is
  a genuine cross-implementation interface rather than MPICH's older informal
  compatibility initiative. If it lands broadly it makes the deferred substitution
  work materially easier than assumed here, so the follow-on should re-evaluate
  against `libmpi_abi` rather than starting from the `libmpi.so.12` assumption.
- With DT_RPATH (see S4) resolution is by SONAME *within the tree*, so the eventual
  substitution mechanism is "replace `stack/lib/libmpi.so.12`", which works fine.
  `LD_LIBRARY_PATH`-based override does not work under RPATH — that is an accepted
  consequence, and revisiting it belongs to the deferred follow-on, not here.

Nothing in the sprint should be slowed down to accommodate the deferred case.

### OpenMPI as an alternative family

Supported via `MPI_FAMILY=openmpi`, but it is **not** a drop-in swap, and the default
stays MPICH. The old repo already carried both recipes (`mpich/build.sh`,
`openmpi/build.sh`) with a "last non-disabled wins" rule in `configure.ac`; the new
`MPI_FAMILY` knob replaces that with an explicit choice. What actually differs:

- **Relocation has a sanctioned mechanism, and we must use it.** OpenMPI reads
  `OPAL_PREFIX` to override its compiled-in prefix; OpenMPI 5.x additionally needs
  `PRTE_PREFIX` and `PMIX_PREFIX` for PRRTE and PMIx. `activate.sh` must set these
  from `${BASH_SOURCE[0]}`. This is the one place the shipped env script does more than
  set `PATH` — and unlike `LD_LIBRARY_PATH`, these are the vendor's intended interface,
  not a workaround for a failed RPATH. Wrapper data in
  `share/openmpi/*-wrapper-data.txt` also carries baked paths for `fixup-text.sh`.
- **More dlopen surface — but the gap is narrower than it first appears.** OpenMPI's
  MCA components live in `lib/openmpi/mca_*.so` and are all dlopened, and conda's
  `openmpi 5.0.10` pulls `ucx`, `ucc`, `libfabric`/`libfabric1`, `libpmix`, `libnl`,
  `libevent`, `libhwloc`. It would be wrong to file this as an OpenMPI-only problem:
  conda's `mpich 5.0.1` on ch4/ucx drags in much the same fabric stack (ucx, libnl,
  the `ibv_*`/`rdma_*` tooling, hwloc, and icu/libxml2 behind hwloc's XML support).
  Either family lands a fabric stack whose plugins are invisible to a dependency
  closure — which is precisely why whole-package prune granularity is non-negotiable
  regardless of `MPI_FAMILY`. OpenMPI is still the larger artifact, but not by the
  margin the MCA layout alone suggests.
- **Different ABI.** OpenMPI is `libmpi.so.40` and is *not* MPICH-ABI compatible, so
  the deferred external-MPI substitution is family-scoped: an OpenMPI-built tree can
  only ever accept another OpenMPI.
- **Single-node launch quirks.** `mpirun` under OpenMPI commonly needs
  `--allow-run-as-root` in containers and may emit fabric warnings when no high-speed
  interconnect exists. For our single-node requirement the `self`/`sm` BTLs suffice;
  the smoke harness should pin the transport explicitly rather than let OpenMPI probe
  and warn. This mostly shows up in the S7 CI images.

Practical consequence: land MPICH end-to-end first, add OpenMPI as a second matrix
axis once `distcheck` is green. Treat it as a variant to validate, not a parallel
design.

## Sprint breakdown

Each increment is independently verifiable. **(spike)** marks work with genuine
unknowns — timebox these first.

### S0 — Archive and scaffold
- `git tag -a v0-static-stack` at current `main` (8dad908) with an annotation
  explaining what it is and why it was retired.
- `ARCHIVE.md`: one screen — what the static stack was, why it was retired, how to
  get it back (`git checkout v0-static-stack`), and that it is unmaintained.
- Remove from the working tree: `configure.ac`, `autogen.sh`, `Makefile.am`,
  `*/Makefile.am`, `build_config.sh.in`, `m4/`, `build-aux/`, `rules/`,
  `utils/use_stack.sh.in`, `utils/build_autotools.sh`, `utils/torture.sh`.
- Carry forward, adapted rather than rewritten: the `download_src` /
  `clean_build_tmp_dirs` / `list_build_env` helpers from `build_config.sh.in` become
  `mk/../relocate`-adjacent `lib/build_common.sh`; the version-profile idea from
  `utils/versions/*.sh` becomes `profiles/*.mk`; the per-package `build.sh` idiom and
  the "write a `config_env.sh` on success" pattern survive, minus the absolute paths.
- Rewrite `README.md` for the new premise.
- Land `Makefile`, `mk/*.mk`, `config.mk.example` with all stage targets stubbed and
  the package-discovery glob working.
- **Verify:** `make -n all` prints a sensible ordered plan; `make help` lists targets.

**Done.** The tag exists and is pushed; the autotools tree is gone; the stage
graph now encodes the seven-step order and `make -n all` prints it once, in
order, holding under `-j8`. See the amendments section for what the review of
this plan turned up.

### S0b — Local container dev loop (Docker Compose)
Lands immediately after the scaffold, because it is the environment everything else is
developed in. Primary driver: developing on an Apple Silicon Mac, where the build must
not run on the host. S7's CI consumes these same files rather than reinventing them.

**It is a local model of the CI topology, not a separate thing.** S7's shape is "build
once, validate the same tarball everywhere" — so compose gets two services on
*different* images, and the tarball is the only thing that crosses between them:

```
docker/Dockerfile.builder   ARG BASE_IMAGE — the minimal host set, nothing more
docker/Dockerfile.verify    ARG BASE_IMAGE — deliberately empty; no compiler, no dev pkgs
docker/compose.yaml
docker/bases.env            the image matrix, shared with S7
.dockerignore               must exclude $(BUILD_ROOT) — it reaches ~2 GB
```

Services: `build` (runs `make all`), `shell` (interactive iteration), and `verify`,
which mounts only `dist/` read-only into a pristine image and untars, validates, and
runs the smoke test. `verify` running on a *different, emptier* image than `build` is
the point — it is `distcheck`'s guarantee made structural rather than assumed.

**The volume layout is the part that matters, and it maps onto the plan's existing
split.** Docker Desktop bind mounts on macOS are slow for many-small-file workloads,
and a conda env plus a PETSc build is exactly that workload:

| path | mount | why |
|---|---|---|
| repo → `/src` | bind mount | small, edited from the host, wants to be live |
| `$(BUILD_ROOT)` → `/build` | **named volume** | ~2 GB and hundreds of thousands of files; a bind mount here is the difference between minutes and hours |
| `CONDA_PKGS_DIRS` → `/cache/conda-pkgs` | named volume | the measured 2.3 GB cache; survives `compose down` so re-solves are instant |
| source tarballs → `/cache/src` | named volume | avoids re-downloading PETSc/Trilinos on every iteration |
| `dist/` | bind mount | few large files; you want the tarball visible from macOS |

The two cache volumes are the main quality-of-life win: after the first run, iterating
on `relocate/` or `test/` costs no network at all.

**Architecture.** Both `linux/arm64` and `linux/amd64` are worth having, via a
`PLATFORM` variable:
- **arm64 is native and first-class** — the plan already targets `linux-aarch64`, so
  this is not emulation-for-convenience, it is the real second target being developed
  on real hardware. Fast.
- **amd64 runs under Rosetta** (enable Docker Desktop's Rosetta option; QEMU otherwise
  and it is much slower). Needed for the primary target and unavoidable for
  `BLAS_PROVIDER=mkl`, which is x86-only.

**Practical notes:** raise Docker Desktop's memory and disk allocation — the default
disk is not enough for a ~2 GB env plus PETSc/Trilinos build trees plus the package
cache, and Trilinos linking is memory-hungry. Expect the full `make all` to run long
enough that `shell` plus incremental `make` is the real workflow, not `compose up`.

- **Verify:** `BASE_IMAGE=almalinux:9 docker compose run --rm build make conda`
  succeeds on both platforms; `compose down && compose up` re-solves from cache with
  no network; `verify` on a different base image than `build` passes `distcheck`.

### S1 — Conda bootstrap
No longer a spike — the harvest step that made it one is gone.
- `conda/bootstrap.sh`: fetch `Miniforge3-Linux-$(uname -m).sh`, install with
  `-b -f -p $(BUILD_ROOT)/.conda`. Isolate hermetically —
  `CONDARC=$(BUILD_ROOT)/.conda/condarc`, `CONDA_PKGS_DIRS` inside the root,
  `channel_priority: strict`. Never read or write `~/.condarc`.
- `conda create -p $(BUILD_ROOT)/stack` — **the env is the redistributable prefix.**
  The miniforge base in `.conda/` is only the tool that creates it and is discarded.
- `conda/env/<platform>-<blas>.yml` → explicit `conda/lock/*.lock` checked in;
  `make conda-lock` regenerates. Locks are what CI consumes, so a conda-forge
  migration cannot silently change an artifact.
- Env contents: `gcc_linux-64=$(GCC_VERSION) gxx_linux-64=$(GCC_VERSION)
  gfortran_linux-64=$(GCC_VERSION) sysroot_linux-64=$(GLIBC_FLOOR)
  cmake ninja make pkg-config patchelf python
  $(MPI_FAMILY)=$(MPI_VERSION) libopenblas blas=*=openblas hdf5 zlib`
  (`_linux-aarch64` variants on ARM). Pin every version explicitly — the unpinned
  solve selected gcc 16.1.0. conda-forge carries gcc 7 through 16; **14.4.0** is the
  current 14.x and the intended default.
  Note the two measured traps above: **no bare `libblas`/`liblapack`** (drags in MKL)
  and **no `mpich-mpi*` split packages** — those are stale and pin mpich back to
  3.2.1 when current mpich is **5.0.1** (full conda-forge line: 3.2.1 → 3.3.x → 3.4.x
  → 4.0–4.3.2 → 5.0.0 → 5.0.1). Verified that mpich 5.0.1's main package ships
  `mpicc`/`mpicxx`/`mpifort`/`mpiexec`/`hydra_pmi_proxy` directly, so the split
  packages buy nothing. OpenMPI's current release is **5.0.10** (conda-forge has no
  5.0.9).
  `BLAS_PROVIDER` is a first-class parameter on every platform: `openblas` → the
  OSS-licensed artifact and the default; `mkl` → the optimized x86-only artifact,
  selected via `blas=*=mkl`. aarch64 rejects `mkl` at config time.
- Keep `CONDA_PKGS_DIRS` under `.conda/` — the package cache measured 2.3 GB and must
  never land inside `stack/`.
- `lib/activate_build_env.sh`: source the env's `etc/conda/activate.d/*.sh`
  deterministically and export `CC/CXX/FC/CONDA_BUILD_SYSROOT/CFLAGS/LDFLAGS`.
- `conda/prune.list`: the packages dropped before packing — `gcc_*`/`gxx_*`/
  `gfortran_*` and their `*_impl_*` counterparts, `binutils*`, `ld_impl_*`,
  `sysroot_*`, `kernel-headers_*`, `*-devel_linux-*`, `cmake`, `ninja`,
  `pkg-config`, and (when `SHIP_PYTHON=no`) the python stack. **Explicitly retained:**
  `libgcc`/`libgcc-ng`, `libstdcxx`/`libstdcxx-ng`, `libgfortran*` — the compiler
  *runtime*, without which validator rule 3 fails by construction. This list is the
  one place where "what ships" is decided, and it is reviewable in a diff.
- **Verify:** the env creates; `mpiexec -n 4` runs a hello-MPI built by
  `$(STACK)/bin/mpicc`; `du -sh $(STACK)` recorded before and after a dry-run prune so
  the size trade is measured rather than assumed.
- **Risks:** conda's own RPATHs are a mix of absolute and `$ORIGIN` (normalized in S4);
  Hydra's compiled-in proxy path.

### S2 — Source builds, shared, into the merged prefix
All three recipes keep their existing shape (`source` a common prelude,
`download_src`, configure, `make install`, emit an env fragment) but install into
`$(STACK)` and link shared. Build with **absolute** `-Wl,-rpath,$(STACK)/lib`; the
`$ORIGIN` conversion is S4's job. Fighting libtool's `$ORIGIN` mangling at configure
time is not worth it when a later normalization pass exists.
- **PETSc** (`pkgs/petsc/build.sh`, from `petsc/build.sh`): `--with-shared-libraries=1`,
  `--with-mpi-dir=$(STACK)`, `--with-blaslapack-dir=$(STACK)` (or MKL equivalents),
  `--with-hdf5-dir=$(STACK)`, `--with-zlib`. Drop the `/lib64/libblas.a` scavenging
  and `--download-fblaslapack` entirely. Retain `--download-` for hypre, superlu,
  suitesparse, scalapack, spooles, ml — these become shared under
  `--with-shared-libraries=1`, which also lets the `3.17*` ML workaround go away.
  Traps: absolute paths land in `lib/petsc/conf/petscvariables`, `petscconf.h`, and
  `lib/pkgconfig/PETSc.pc`; `make check` needs `PETSC_DIR`.
- **libMesh** (from `libmesh/build.sh`): `--enable-shared --disable-static`. Keep the
  existing `--disable-dap`, `--enable-hdf5`, `--enable-petsc-required`, methods, and
  `--enable-tecio` choices. Traps: `bin/libmesh-config` and `Make.common` bake paths;
  the `rm -f ./*-opt` cleanup at `libmesh/build.sh:54` was a static-bloat workaround
  and should be reconsidered now that examples are small.
- **Trilinos** (from `trilinos/build.sh`): `-DBUILD_SHARED_LIBS=ON`,
  `-DCMAKE_INSTALL_RPATH='$ORIGIN/../lib'`, `-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON`,
  BLAS/LAPACK from `$(STACK)`. Traps: `TrilinosConfig.cmake` / `*Targets.cmake` embed
  absolute paths in `INTERFACE_LINK_LIBRARIES`.
- Dependencies become stamp prerequisites in `pkg.mk`, so — unlike today's
  `.NOTPARALLEL:` in `Makefile.am` — independent packages can build concurrently.
- **Verify:** every package installs; `ldd` on `$(STACK)/lib/libmesh_opt.so` resolves
  entirely within `$(STACK)` plus core glibc.

### S3 — Smoke-test harness
- `test/run.sh MODE` with `MODE ∈ {inplace, relocated}`; `test/smoke/` holds the
  owner-provided libMesh example behind a fixed contract (a `Makefile` with `all` and
  `run` targets, given `LIBMESH_DIR`/`PETSC_DIR`/`MPIEXEC`).
- The example must be **parallel-capable on one node** — run it serially and at
  `-n $(SMOKE_RANKS)` (default 4), asserting rank-count-dependent output so a silently
  serialized run fails. This is the test that carries the single-node MPI requirement.
- `inplace`: compile via `libmesh-config`, run serial, then under `mpiexec -n N`.
- `relocated`: **run the prebuilt binary first**, serial and `-n N` (the guarantee that
  matters), then recompile if the slim profile kept headers.
- Until the example arrives, ship a trivial placeholder (MPI + PETSc `VecCreate` +
  a libMesh mesh construction) so the pipeline is exercisable.

### S4 — patchelf, text fixup, validator **(spike)**
- `relocate/patchelf.sh`: enumerate ELF by magic (`\x7fELF`), skipping `.a`, scripts,
  and symlinks (patch the target once). For each file compute
  `$ORIGIN/$(realpath --relative-to=$(dirname $f) $(STACK)/lib)`, plus `$ORIGIN` for
  objects in `lib/` and any extra dirs PETSc creates. Then
  `patchelf --remove-rpath && patchelf --force-rpath --set-rpath '<computed>'`.
  Idempotent and re-runnable.
  - **RPATH, not RUNPATH** (`--force-rpath`). RUNPATH is overridable by a customer's
    `LD_LIBRARY_PATH`; DT_RPATH takes precedence over it. For a redistributable that
    must survive an arbitrary host environment, RPATH is the right default. Expose
    `RPATH_MODE=runpath` as a build knob for debugging — and as the natural hook for
    the deferred external-MPI work, which need not be resolved now.
  - **Do not** `--set-interpreter`. The whole premise is that host glibc satisfies the
    declared floor; rewriting the interpreter would contradict that and break on
    hosts with different loader paths.
  - Use patchelf ≥ 0.18 (from conda); older versions corrupt binaries when growing
    program headers. The validator is the backstop.
- `relocate/fixup-text.sh`: rewrite remaining absolute paths in `.pc`, `*.cmake`,
  `petscvariables`, `petscconf.h`, `libmesh-config`, `Make.common`, `*-config`, MPI
  wrappers. Success criterion is mechanical: `grep -rIl "$(BUILD_ROOT)" $(STACK)`
  returns nothing.
- `relocate/depsolve.py`: the shared dependency resolver — parses `DT_NEEDED`,
  `DT_RPATH`/`DT_RUNPATH`, expands `$ORIGIN`, resolves against the tree. Used by both
  `prune.sh`'s runtime profile and `validate.sh` so the two agree by construction.
- `relocate/validate.sh` — the gate. For every ELF in `$(STACK)`, with a scrubbed
  environment (`env -i`):
  1. no unresolved (`not found`) dependencies;
  2. anything resolving outside `$(STACK)` must be in the core allowlist
     (`libc libm libdl libpthread librt libutil libresolv ld-linux linux-vdso`);
  3. `libstdc++.so.6` and `libgcc_s.so.1` **must** resolve inside `$(STACK)`;
  4. required symbol versions (`objdump -T`) must not exceed the declared
     `GLIBC_FLOOR`; `GLIBCXX_`/`CXXABI_` must not exceed what the shipped
     `libstdc++.so.6` provides;
  5. no absolute build-root strings in text files; no `.la` files; no dangling symlinks.
  Emits a human-readable report, a non-zero exit, and `stack/etc/stack-manifest.json`
  (packages, versions, BLAS/MPI provider, glibc floor, git sha, build date).
- `stack/activate.sh` derives its own root from `${BASH_SOURCE[0]}` — the concrete fix
  for what `utils/use_stack.sh.in` got wrong via `@abs_top_builddir@`. Sets `PATH`,
  `PETSC_DIR`, `LIBMESH_DIR`, `TRILINOS_DIR`, `MPI_ROOT`, and — when
  `MPI_FAMILY=openmpi` — `OPAL_PREFIX`/`PRTE_PREFIX`/`PMIX_PREFIX`. It deliberately
  does **not** set `LD_LIBRARY_PATH`: if that were needed, RPATH has failed and the
  validator should have caught it.
- **Verify:** `make relocate validate` is green, and `test/run.sh inplace` still
  passes afterward (step 5 of the requested workflow).

### S5 — Prune, slim, pack, and the relocation proof
- `relocate/prune.sh` runs first and does the heavy lifting: remove the packages in
  `conda/prune.list` **by their `conda-meta` file lists**, never by path globbing, so
  removal is exactly as precise as installation was. This is where the measured
  861 MB of compilers and build tools goes. Whole-package granularity is what keeps
  `dlopen`ed plugins safe. It reports bytes removed per package, so the diff between
  two builds is legible.
- `relocate/slim.sh` then does file-level trimming, with two profiles:
  - `devel` (default): drop `.la`, `share/doc`, `share/man`, conda metadata,
    `__pycache__`, build logs, test binaries; `strip --strip-unneeded` libraries.
    **Keep** headers, `.pc`, cmake configs, compiler wrappers — customers extend this
    tree.
  - `runtime`: additionally drop `include/`, `lib/pkgconfig`, `lib/cmake`, `*-config`,
    and any ELF outside the transitive closure of `stack/etc/entrypoints`.
    `mpiexec`, `hydra_pmi_proxy`, and the dlopen-only libraries from S1's package
    manifests must be seeded into `entrypoints` explicitly — a closure walk will not
    find them, and losing them breaks parallel launch only after relocation.
  Prune and slim both run **before** the final validate, and the relocated test must
  pass after them — that ordering is what makes aggressive trimming safe to attempt,
  and it is the whole reason pruning is a better-behaved risk than harvesting was.
- `make dist`: reproducible tar —
  `tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@$SOURCE_DATE_EPOCH`
  → `dist/<name>-<version>-<platform>-<blas>-glibc<floor>.tar.gz`, so the OSS
  (`openblas`) and optimized (`mkl`) artifacts are unambiguous side by side.
- `make distcheck` — the actual proof, and the headline feature: tar → `rm -rf` the
  original tree → untar at a **different path depth** (e.g. `.../relocated/a/b/c/`) →
  `validate.sh` → `test/run.sh relocated`. Different depth is deliberate: it is what
  catches a hard-coded `../..` assumption that a same-depth move would hide.

### S6 — Extension hooks and docs
- `site/` auto-discovery (`SITE_DIRS ?= site`, `include $(wildcard $(SITE_DIRS)/*/pkg.mk)`)
  so customers add packages without touching tracked files.
- `pkg.mk` contract: `PKG_NAME`, `PKG_VERSION`, `PKG_DEPS`, `PKG_URL`, `PKG_STAGE`.
- `build.sh` contract: receives `STACK` (which is both the conda env and the install
  prefix — there is no second one), `WORK`, `NPROC`, `PKG_*`;
  gets `download_src` / `log` / `require` helpers — the direct descendant of today's
  `build_config.sh.in` helper block.
- `hooks/{pre,post}-{conda,build,test,relocate,slim,dist}/` run in sorted order.
- `docs/EXTENDING.md` plus a worked example under `pkgs/_template/`.
- **Verify:** add a throwaway package in `site/` and confirm it builds, gets
  patchelf'd, and survives `distcheck`.

### S7 — CI matrix (follow-on, deliberately loose)
A GitHub Actions matrix over minimal base images — a couple of AlmaLinux variants,
openSUSE Leap, and two Ubuntu LTS — running the same `make all distcheck` in a
container with no dev packages installed. **Reuses S0b's `docker/` directory
directly**: same `Dockerfile.builder`/`Dockerfile.verify`, same `bases.env` matrix
list, so a green local `compose run verify` means something about CI rather than being
a parallel implementation that drifts. The point is not to build the stack on each
distro; it is to **build once and validate the same tarball everywhere**, so the split
is a build job publishing an artifact plus a fan-out of consume-and-test jobs — which
is exactly S0b's `build`/`verify` service split, scaled out. A
second axis over `GLIBC_FLOOR ∈ {2.17, 2.28}`, `BLAS_PROVIDER ∈ {openblas, mkl}`, and
`MPI_FAMILY ∈ {mpich, openmpi}` — the last of which is where OpenMPI's container
launch quirks will surface, so it wants real images rather than a local check.
Shape this against the owner's other repo before writing it.

## Verification

End-to-end, on a clean host:

```
cp config.mk.example config.mk      # set BUILD_ROOT, PROFILE, GLIBC_FLOOR, BLAS_PROVIDER
make conda                          # step 1: miniforge + create the env AS stack/
make build                          # step 2: PETSc, libMesh, Trilinos, site/* — shared
make test                           # step 3: smoke example, in place
make relocate                       # step 4: patchelf, text fixup
make validate                       # the gate
make test                           # step 5: in place, again, post-relocation
make slim                           # step 6: prune conda build-only pkgs, then trim files
make dist distcheck                 # step 7: tar, rm -rf, untar elsewhere, validate, test
```

`make all` chains the lot. The single most important signal is `distcheck` exiting
zero from a **different install path than the one the stack was built at**.

Spot checks worth doing by hand at least once:
- `readelf -d $(STACK)/lib/libmesh_opt.so | grep -E 'RPATH|RUNPATH'` shows `$ORIGIN`.
- `env -i $(STACK)/bin/<smoke-binary>` runs with no environment at all.
- `mpiexec -n 4 <smoke-binary>` reports 4 distinct ranks from the **relocated** tree.
- `$(STACK)/lib/libmpi.so.12` exists under exactly that SONAME (keeps the deferred
  external-MPI door open at zero cost).
- `grep -rI "$(BUILD_ROOT)" $(STACK)` is empty.
- `$(STACK)/lib/libstdc++.so.6` and `libgcc_s.so.1` still present after prune — the
  single most likely prune mistake.
- Untar into a path with a space in it, and into a read-only directory.

## Open risks

1. **Prune correctness.** Now the mirror image of the old harvest risk, and much
   better behaved: the question is "did I delete something needed?", which `distcheck`
   answers because the relocated smoke test runs after the prune. The specific hazard
   is deleting a compiler package and taking its *runtime* with it — `conda/prune.list`
   must drop `gcc_impl_*` while keeping `libgcc`/`libstdcxx`/`libgfortran*`.
   `dlopen`ed plugins (MKL dispatch, OpenBLAS threading, Hydra/PMI, hwloc) remain
   invisible to `ldd`, so the `runtime` slim profile must never prune below
   whole-package granularity.
2. **conda-forge's runtime split** — `libgcc-ng`/`libstdcxx-ng` versus what the
   compiler package itself provides. Getting the *wrong* `libstdc++.so.6` into
   `stack/lib` produces a tree that works on the build host and fails elsewhere.
   Validator rule 4 is the specific defence.
3. **MPI process management, single node.** Scoped down but not free: a relocated
   `mpiexec` must still find `hydra_pmi_proxy`, whose path Hydra compiles in. Covered
   by the wrapper/path fixup in S1 and proven by running the smoke example under
   `mpiexec -n N` inside `distcheck`. Multi-node is explicitly deferred.
4. **C++ ABI at the seam.** Customer packages built in `site/` use our conda toolchain
   and are fine. Customer code compiled *later* with their own older `g++`, linking
   our libraries, can hit `GLIBCXX_` mismatches. `GCC_VERSION` is the lever here — a
   lower pin narrows the gap to what customers are likely to have, at the cost of
   newer language features. Defaulting to 14 rather than the solver's 16 is partly
   this consideration. Document the supported path (build inside the template)
   explicitly.
5. **BLAS provider as a product axis.** Licensing is settled (MKL redistribution is
   acceptable to the owner), so the remaining risk is mechanical: `openblas` and `mkl`
   must be genuinely interchangeable at the `config.mk` level, produce distinctly
   named artifacts, and both pass the same validator. The MKL variant carries the
   dlopen-dispatch hazard from risk 1; the openblas variant is the
   OSS-licensed artifact and stays the default.
6. **PETSc `--download-*` under shared.** Several of these have historically been
   shaky about honouring shared builds — the `3.17*`/ML case already in the tree is
   the precedent. Expect per-version special-casing to survive into the new recipe.
7. **OpenMPI is a heavier variant, not a swap.** `OPAL_PREFIX`/`PRTE_PREFIX`/
   `PMIX_PREFIX` handling in `activate.sh`, wrapper-data text fixup, a much larger
   dlopen surface (MCA components plus the ucx/ucc/libfabric/pmix stack), a different
   ABI, and container launch quirks. Sequence it after MPICH is green end to end.

---

## Amendments (review, 2026-08)

This plan was reviewed against the repo as scaffolded, against the v0 tree it
supersedes, and — where it makes factual claims about conda-forge — against
conda-forge itself. The design held; these are corrections. Each is fixed in the
commit that closes it, and this section records the correction so the plan above
does not have to be read alongside a separate errata list.

### Fixed in S0

**A1 — `make all` skipped the gate.** `all` resolved to `dist`, and `dist`
depended only on `relocate.stamp`, so the default workflow ran conda → build →
relocate → dist and skipped `test`, `validate` and `slim` entirely. `validate`
depended on the validate.sh *file* rather than on `relocate.stamp`, and `slim`
had no stamp at all. The seven-step order in §Verification was documented but
not encoded. Now a real dependency graph, with one stamp per gate *position*
(`test-built`, `validate-relocated`, `test-relocated`, `validate-slimmed`) and
phony `test`/`validate` entry points that always re-run.

**A2 — contract gaps.** `PKG_STAGE` was in the §S6 `pkg.mk` contract but
unimplemented; it now selects `build` (default) vs `optional`. `MAKE_J_L` and
`TARGET_PLATFORM` were missing from `PKG_ENV`. `list_build_env` had no
successor. Four of the twelve hook stages had no directory. `make shell` was
`.PHONY` with no rule.

### Closed in the conda & packaging infrastructure PR

**A3 — the `hdf5` variant is decided by accident, and §S2 quietly widened its
scope.** `hdf5` ships `nompi_*`, `mpi_mpich_*`, `mpi_openmpi_*` and
`mpi_mvapich_*` variants, and the conda-forge feedstock does
`{% set build = build + 100 %}` under the comment *"prioritize nompi via build
number"*. So a bare `hdf5` spec resolves to the **serial** build by build-number
luck rather than by our intent, and a future migration could flip it without
notice.

Which way it should resolve is a separate question, and the v0 tree answers it:
`hdf5/build.sh` passed `--disable-parallel` deliberately, installed into
`$(HDF5_VERSION)-$(COMPILER_ID)` rather than `-$(MPI_ID)`, and sat before MPI in
`SUBDIRS` depending only on gcc and zlib. Its only consumer was **libMesh**
(`--enable-hdf5 --with-hdf5=$HDF5_ROOT`); PETSc had no `--with-hdf5` at all and
Trilinos had none either. §S2's `--with-hdf5-dir=$(STACK)` for PETSc is
therefore *new scope*, not a property being preserved.

**Decision: serial by default, parallel as a knob.** `HDF5_PARALLEL ?= no`
selects `nompi_*`; `yes` selects `mpi_${MPI_FAMILY}_*`. Pinned explicitly either
way, so the choice is ours rather than the solver's. Serial is the default
because it matches v0, and because the `mpi_*` variant makes `libhdf5` link
`libmpi` — which drags MPI into the closure of anything that touches HDF5, and
closure size is the whole game here.

Checked, so the knob is safe to flip: **both** variants ship `libhdf5_cpp`,
`libhdf5_hl`, `libhdf5_hl_cpp` and the Fortran bindings — the feedstock tests
that unconditionally — so either matches v0's `--enable-hl --enable-cxx
--enable-fortran`. And PETSc does **not** require parallel HDF5:
`config/packages/hdf5.py` preprocesses `H5pubconf.h` for `H5_HAVE_PARALLEL` and
merely *defines* `PETSC_HDF5_HAVE_PARALLEL` when present, so serial configures
cleanly and only collective I/O is given up.

The version pin is not optional either: hdf5 2.1.0 and 2.2.0 are now on
conda-forge and post-date the pinned PETSc and libMesh. Pin `hdf5=1.14.*` —
well ahead of v0's 1.10.6, and short of a major-version API change that
NetCDF4/Exodus have not been tested against here.

**A4 — the shipped glibc floor is not the one we pin. Measured.** `GLIBC_FLOOR`
pins `sysroot_*`, which constrains only *our* compilations; every prebuilt
conda-forge binary carries conda-forge's own baseline, so the effective floor is
the max of the two.

Measured on `linux-aarch64`, `GLIBC_FLOOR=2.28`, across all **837** ELF objects
in the solved env: the maximum required symbol version is **`GLIBC_2.34`**, not
2.28. So the claim was real — but the blast radius is tiny. Exactly **two**
files exceed 2.28:

```
lib/libsystemd.so.0.44.0    GLIBC_2.34
lib/libudev.so.1.7.14       GLIBC_2.34
```

Everything else — all 835 — sits at 2.28 or below. And nothing in the tree
`DT_NEEDED`s either of them, nor names them for `dlopen`; `libibverbs` links
only `libnl`. They arrive purely as declared conda dependencies of `rdma-core`,
which mpich's ch4 fabric stack pulls in. **They are now on `conda/prune.list`**,
which takes the artifact's effective floor back to 2.28 — the difference between
running on `almalinux:8` and `opensuse/leap:15` or not, i.e. two of the five
images in `docker/bases.env`. (v0 reached the same place the hard way, with
mpich's `--with-hwloc-prefix=embedded --disable-libudev`.)

Validator rule 4 must still **measure** rather than assume: compute the max
required `GLIBC_x.y` over the final, pruned tree, fail if it exceeds
`GLIBC_FLOOR`, and record the measured value in `stack-manifest.json` and in the
tarball name. The point stands even though this instance was cheap to fix — the
number has to be observed, not pinned.

§Locked decisions' "`2.17` supported" remains downgraded to aspirational: the
floor is a property of the *solve*, and only measurement tells you what you got.

**A5 — `grep -rI "$(BUILD_ROOT)"` cannot catch the failure that matters.** `-I`
means *ignore binary files*, so a build-root path baked into an ELF — precisely
what breaks relocation — is invisible to it. Used as §S4's success criterion and
again in §Verification's spot checks. Must scan binaries, with a narrow and
justified allowlist.

**A6 — conda's padded-binary prefix rewriting has a hard ceiling. Measured, and
milder than first assumed.** `conda-meta` marks each embedded-prefix file `text`
or `binary`; a padded binary slot can only ever be rewritten within the space
the placeholder reserved, NUL-padded. The plan leans on that inventory as its
primary fixup mechanism without saying so.

Measured on the solved env: the placeholder is **255 bytes**, uniformly, and
only **287 of 22,636** installed files carry a binary-embedded prefix at all.
Our build prefix is 35 bytes, so there is ~220 bytes of headroom.

So the constraint is *not* "can only shorten relative to the build path", as
first written here — it is a flat **255-byte ceiling on the installed prefix**,
which is generous and, more importantly, checkable. Concretely:
`relocate/fixup-text.sh` must write into the NUL-padded field rather than assume
it can only shrink, and `validate.sh` must reject an install path over 255
bytes. The 287-file inventory is small enough to enumerate and assert on
directly.

**A7 — the validator needs tools the tarball will not have.** `validate.sh`
needs `readelf`/`objdump` (binutils is on `prune.list`) and `depsolve.py` needs
python (pruned when `SHIP_PYTHON=no`), while `Dockerfile.verify` installs only
`tar`. So full validation cannot run where §S0b implies it does — and the
compose `verify` service currently runs neither `validate.sh` nor
`test/distcheck.sh`. Split into `--full` (builder image, against the untarred
tree — this is `distcheck`'s job) and `--runtime` (loader-only, what the
pristine verify image can actually run).

**A8 — `test/run.sh` ignores `MODE`.** It always compiles first, which
contradicts §S3's "run the prebuilt binary first" — the guarantee that matters —
and is impossible in the verify image, which has no compiler. It also does not
export the `LIBMESH_DIR`/`PETSC_DIR`/`MPIEXEC` its own contract declares, and
writes build output into `test/smoke/`, which compose mounts read-only.

**A9 — no placeholder smoke test.** §S3 calls for one so the pipeline is
exercisable; without it `make test` cannot run at all, and nothing downstream of
it can be proven. Staged: MPI-only first, then PETSc, then libMesh, culminating
in `introduction_ex4`.

**A10 — `prune.sh` can delete source-installed files.** It removes conda
packages by their `conda-meta` file lists, so a source package that overwrote a
conda-owned file loses it when that package is pruned. Relatedly, once source
packages live in `$STACK`, further `conda` operations on that prefix are unsafe.
Needs a stated "sealed after `make conda`" rule and a validator check for
conda/source file-ownership collisions.

### Found while implementing, and now part of the design

**A15 — `patchelf >= 0.18` is not installable from conda-forge.** §S4 says to use
0.18+ "from conda", because older versions corrupt binaries when they have to
grow the program headers. conda-forge marked **every** 0.18.0 build `broken` on
the main label, across `linux-64`, `linux-aarch64` and `linux-ppc64le`, and
0.19.1 never left the `patchelf_dev` label. The newest installable patchelf is
**0.17.2** — precisely the version the plan warns about.

Rather than pin something unavailable, `relocate/patchelf.sh` **measures**: it
snapshots SONAME, `DT_NEEDED`, the interpreter, ELF type and machine for every
object before and after the rewrite, and fails if any of them moved. patchelf is
only ever asked to change `DT_RPATH`, so any other difference is damage — from
this bug, a future one, or a truncated write. That is strictly stronger than the
version pin would have been, and it is the pattern to prefer generally: an
assertion about the artifact beats an assertion about the tool.

**A16 — patchelf cannot rewrite files it has itself mapped.** In-place patching
died with SIGSEGV/SIGBUS on exactly three files: `bin/patchelf`,
`lib/libstdc++.so.6` and `lib/libgcc_s.so.1`. patchelf is a C++ program that
loads the latter two *from the tree it is patching*, and its own executable
lives there too; rewriting an `mmap`'d file earns a bus error. Those three are
also the ones that cannot be skipped, since validator rule 3 requires the C++
runtime to resolve in-tree.

Fixed by patching a copy and `rename(2)`-ing it into place. That also closes a
latent second bug: when the package cache shares a filesystem with the env,
conda **hardlinks** files into the env, so in-place editing would rewrite the
cache too and poison every future env built from it. `rename` breaks the link
instead of following it, and is atomic, so a crash mid-patch cannot leave a
half-written binary either.

**A17 — slim must run before prune.** The plan has prune first. `strip` is
provided only by `binutils_impl_*`, which is on `prune.list`, and the miniforge
base has no strip either — so pruning first silently turns stripping into a
no-op, exactly when it matters most, on the large unstripped source-built
libraries. Trim and strip first, then prune.

**A18 — the artifact ships `mpicc` but no compiler, and that is correct.**
`prune.list` drops `gcc_impl` and the sysroot (~530 MB of the diet), so the
shipped tarball has the MPI wrappers and nothing behind them. The relocated
rebuild step surfaced this by failing. It is the intended shape rather than a
defect: §Locked decisions' "consumer mode" means the supported path is building
**inside the template, before the prune**, where the whole toolchain is present.
A customer compiling against the shipped tarball uses their own compiler, and
`mpicc` is still useful to them — `mpicc -show` yields the flags and MPICH
honours `MPICH_CC`. `test/run.sh` now detects the absence and skips with that
reason. Worth stating explicitly in `docs/EXTENDING.md`.

**A19 — grepping an ELF for the build prefix produces false positives.** patchelf
rewrites `DT_RPATH` but leaves the *old* rpath string behind in `.dynstr` as an
unreferenced orphan. 31 objects therefore still contain the build prefix in
their bytes while their live rpaths are perfectly relocatable. So A5's
"scan binaries too" is right about *why* (a prefix baked into an ELF is real and
`grep -rI` hides it) but wrong about *what to conclude*: for an ELF, the dynamic
table governs and the bytes do not. The validator now asserts directly that
every rpath is `$ORIGIN`-relative — the single most important property in the
system, and one the plan never actually listed as a check — and applies the byte
scan only to non-ELF files.

**A20 — the pipeline is destructive and not re-runnable.** `relocate` and `slim`
rewrite `$STACK` in place, so re-running them over their own output fails
confusingly (`patchelf` has itself been pruned by then). Recovery is
`make distclean && make all`. `relocate/patchelf.sh` now says so rather than
leaving "patchelf not found" to be decoded.

### Open — to be closed in the source-compiles PR

**A11 — Trilinos' PETSc dependency is spurious.** In the v0 tree it existed only
to scavenge `${PETSC_DIR}/lib/libfblas.a`. With BLAS from conda, `PKG_DEPS` for
trilinos is empty — which is what actually unlocks the concurrency §S2 promises:
petsc and trilinos build in parallel, then libmesh.

**A12 — `-DTrilinos_ENABLE_Kokkos=OFF` may not survive the pinned version.**
Kokkos became a mandatory dependency of Sacado in later Trilinos. The pins stay
at 14-4-0 for now, so this is the first thing to test when the Trilinos recipe
lands; the fallback is to bump Trilinos alone. `-DTPL_ENABLE_DLlib=OFF` was a
static-era flag and must flip to `ON`.

### Observed while landing the conda stage

**A13 — `GCC_VERSION` does not control the shipped C++ runtime.** The solved env
on `linux-aarch64` with `GCC_VERSION=14` contains:

```
gcc_linux-aarch64      14.4.0      <- the compiler, as pinned
libgcc / libgcc-ng     16.1.0      <- the runtime that ships
libstdcxx / libstdcxx-ng 16.1.0
```

This is conda-forge behaving as designed — libstdc++ is backward compatible, so
the channel ships the newest runtime and lets it serve code built by any older
gcc. It is not a bug, and it is not the failure §Open risks #2 warns about (that
is about getting an *older* runtime than the compiler needs, which cannot happen
here).

But it does invalidate a claim in §Open risks #4. "`GCC_VERSION` is the lever
here — a lower pin narrows the gap to what customers are likely to have" is only
true of the *code we emit*, not of the `libstdc++.so.6` we ship. Pinning
`GCC_VERSION=14` still ships a gcc-16 runtime providing `GLIBCXX_3.4.35`+.

For our own tree this is harmless and arguably desirable — validator rule 3
wants the C++ runtime resolving in-tree, and a newer one satisfies strictly more.
It matters only for the customer-compiles-later seam, where the honest statement
is: the supported path is building inside the template, and the shipped
`libstdc++.so.6` is conda-forge's current, not a function of `GCC_VERSION`.
`validate.sh` should record both versions in `stack-manifest.json` so the pair is
visible rather than assumed.

**A14 — `Dockerfile.builder` could not build on `almalinux:9`.** It named a
fixed package list including `curl`; almalinux:9 ships `curl-minimal`, and
`dnf install curl` is a package *conflict*, not a no-op:

```
package curl-minimal-7.76.1-40.el9.aarch64 from @System conflicts with
curl provided by curl-7.76.1-40.el9.aarch64 from baseos
```

Fixed by probing for each *command* and installing only what is genuinely
missing. That is also the more honest form of the minimal-host claim this file
is supposed to embody: the build log now prints exactly what each base image
lacked, which is the number worth knowing, and `--allowerasing` — which would
have "fixed" it by installing *more* than needed — is not used.
