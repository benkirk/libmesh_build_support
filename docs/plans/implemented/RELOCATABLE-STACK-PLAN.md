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
installs only what a bare host genuinely needs (`curl`, `git`, `ca-certificates`,
`tar`, `gzip`, `bzip2`, `xz`, a shell — conda supplies the compilers), it is the
**executable statement of this project's minimal-host claim**. If it ever needs a dev
package added, that is a regression in the premise, not a fix to the image. The line
it draws is fetching versus building: transports live here, anything that compiles or
generates lives in the conda env.

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

### S7 — CI matrix
The shape is the one this section always described — **build once, validate the same
tarball everywhere** — because that is what the artifact's claim actually is. A build
job publishes a tarball; a fan-out of consume-and-test jobs unpacks that one tarball on
a pristine, poorer image and runs it. That is S0b's `build`/`verify` service split
scaled out, and it is implemented by *invoking* those services rather than by
reimplementing them: every job below shells out to `docker compose` against
`docker/compose.yaml`, so the builder image, the verify image, the volume layout and
the verify command are the ones a developer exercises locally. There is no second
description of the pipeline to keep in sync.

| workflow | trigger | cost | what it answers |
|---|---|---|---|
| `checks.yml` | every push and PR | ~2 min | does it parse, does the stage graph still order itself, do the ISA regexes still match what they claim, does each base image still build |
| `ci.yml` | PRs and `main`, excluding doc-only changes | ~30 min ×2 | the default configuration — openblas, mpich, serial HDF5 — on `linux-64` **and** `linux-aarch64`, verified on all five base images |
| `stack.yml` | called, never triggered directly | — | the build-and-verify implementation, parameterised |
| `extended.yml` | weekly, and on demand | hours | the axes below |

Four decisions worth recording:

**`docker/bases.env` is read, not transcribed.** `docker/bases.sh --json` emits the
image list and the verify matrix expands from it, so adding a distro to the local loop
adds it to CI in the same commit. A list copied into a workflow file is a list that
drifts the first time someone updates one copy. (`checks.yml`'s image-build matrix is
the one place the list is duplicated — GitHub will not let a job compute its own
matrix — so that job asserts its copy matches `bases.env` rather than trusting it to.)

**Both target platforms build natively.** `linux-aarch64` gets an `ubuntu-24.04-arm`
runner, not QEMU: it is a shipping target, and it is where the interesting findings
have come from — the `armv8.1-a` floor was measured there. Under emulation the ISA
scan alone, which disassembles every ELF object, would dominate the run.

**The fast gate is separate from the expensive one, and runs on everything.** Most
mistakes in this repo — a script that does not parse, a stage graph that stops
ordering itself, an ISA regex that matches a symbol name — are catchable in two
minutes without building anything. A1 was exactly that class of break, and
`make -n all` under `-j8` is what catches it. Spending 30 minutes of matrix to
discover a syntax error trains people to ignore CI.

**`ci.yml` builds from the checked-in lock; `extended.yml` solves from the spec.**
A lock is reproducible precisely because it never re-solves, so it can never tell us
that `conda/env/*.yml` has stopped resolving to something that works. `CONDA_USE_LOCK=no`
forces the solve path, and `refresh_lock` publishes the lock that solve produced.

#### The second axis, and what is deliberately not in it

| axis | state |
|---|---|
| `BLAS_PROVIDER=mkl` | weekly, **experimental**. `linux-64` only — `bootstrap.sh` rejects it on aarch64 at config time. The number to watch is the tarball size: the accidental MKL pull §S1 warns about was ~560 MB, and this asks for it deliberately. |
| `HDF5_PARALLEL=yes` | weekly, **experimental**. A supported knob nobody has run; the `mpi_*` variant pulls MPI into the closure of everything touching HDF5 (A3). |
| builder distro | weekly, **experimental**. Builds `linux-64` on `ubuntu:24.04` instead of `almalinux:9`. The builder's own glibc *should* be irrelevant — conda supplies the toolchain, the sysroot pins the floor — and A14 is the precedent for not assuming it. |
| `MPI_FAMILY=openmpi` | **not wired.** It needs a `conda/env/*-openmpi.yml`, an `MPI_VERSION` that means something for OpenMPI (`5.0.1` is MPICH's), `prune.list` entries for OpenMPI's plugin packages, and a transport pinned in the smoke harness so it does not probe and warn in a container. A matrix entry added before those exist buys a permanently red job, which is worse than an absent one. |
| `GLIBC_FLOOR=2.17` | **not wired.** Verifying it needs a glibc-2.17 image to run the tarball on, and there isn't a maintained one: `centos:7` is EOL with dead mirrors. Building *against* a 2.17 sysroot is testable without one, but a floor nothing verifies is a claim, and this repo's whole premise is not making those. |

Neither exclusion is a technical obstacle — both are a missing prerequisite, named,
so that adding the axis means satisfying it rather than rediscovering it.

#### What the first run measured

Worth keeping, because it decides where the next optimisation goes and it is not
where anyone would guess. On a 4-vCPU runner, conda-only:

| | linux-64 | linux-aarch64 |
|---|---|---|
| build job, end to end | 21 min | 4.5 min |
| of which `isa-scan` | **18 min** (873 objects) | — |
| env | solved fresh, 86 pkgs pre-slim | from the lock, 58 pkgs |
| verify jobs | ~60 s each | ~35 s each |

**The ISA scan is 85% of the x86 build**, and that is before the source builds add
their objects. It disassembles every ELF with `objdump`, which is inherently serial
per object and parallel only across them, so it scales with `--jobs` and the runner
has four. Two things follow: the gap between the platforms above is mostly package
count and lock-vs-solve (A33), not architecture; and if build time becomes a problem,
the scan is the thing to attack — not the matrix width, where the temptation will be.

#### What CI cannot tell us

Worth stating so a green matrix is not read as more than it is. The runners are
4-vCPU single machines, so `SMOKE_RANKS=4` on one node is the ceiling — multi-node MPI
was already out of scope (§Locked decisions), and CI does not change that. Nothing
here runs on old hardware; `relocate/isa-scan.py` is the stand-in for the customer's
2015 Xeon and it is a static check, not a run. And CI verifies distros, not CPUs:
five base images on two architectures says nothing about the ISA floor that the ISA
gate does not already say by itself.

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

### Observed while landing the source compiles

**A22 — the wrapper has to cover bare `cc`, and that is a correctness matter.**
The wrapper layer was specified as covering conda's compilers. conda installs
only *triplet-named* ones (`aarch64-conda-linux-gnu-gcc`), and the builder image
has its own system `gcc`. So a build system falling back to plain `cc` or `gcc`
— and plenty do — would have compiled against the **host** toolchain: host
libstdc++, host glibc headers, no baseline. It would have linked, and it would
have run on the build machine. `generate.sh` therefore emits bare aliases too,
pointing at the conda compilers; our `cc` being first on `PATH` is what keeps
that fallback inside the stack.

Also settled while building it: `mpicc` is **not** wrapped (it invokes the
already-wrapped triplet compiler, so wrapping both double-injects), but whether
`mpicc` resolves that compiler through `PATH` or by absolute path is mpich's
choice, so `env.sh` sets `MPICH_CC`/`OMPI_CC` as a second route and the
self-test compiles *through* `mpicc` rather than assuming either.

**A23 — build tools must be pinned to the era of the sources, not to the
newest.** Three failures, all of the same shape, all before a single line of
our own code compiled:

- **CMake 4** removed compatibility with `cmake_minimum_required(VERSION <3.5)`
  and hard-errors on it. Trilinos 14-4-0 still declares 2.6, 2.6.4, 2.7, 2.8.4,
  2.8.8, 3.0 and 3.1 across its sub-projects, so CMake 4 cannot configure it at
  all. Pinned `cmake<4`.
- **Python 3.13** removed `xdrlib` from the standard library. PETSc 3.20.5's
  configure imports it and died with `No module named 'xdrlib'`. Pinned
  `python<3.13`.
- **`diffutils`** was simply absent: PETSc's configure stops with *"Could not
  locate diff executable"*. It belongs in the conda env rather than in
  `Dockerfile.builder`, because the conda env *is* the toolchain — `make`,
  `cmake` and `pkg-config` already come from there, and the builder image is
  deliberately as poor as a customer's host.

None of these is visible in the artifact: all three are on `prune.list` and are
gone before packing. That is what makes them cheap — pinning a build tool is not
a statement about what the stack supports.

**A24 — a checked-in lock silently shadows the spec list.** This cost two build
cycles. `conda/bootstrap.sh` prefers `conda/lock/*.lock` when one exists, which
is exactly what a lock is for; the consequence is that editing the `specs` array
changes *nothing*, with no warning, and the package you added is simply not
there. Now `IGNORE_LOCK=1` forces a fresh solve, and the lock path prints a line
saying it is ignoring the spec list.

**A25 — the v0 pins are not all obtainable.** Two of the three download URLs
carried over from v0 are dead, which is worth stating plainly: version pins
inherited from a retired build system are claims about the past, not guarantees
about the present.

- **PETSc**'s `ftp.mcs.anl.gov` host has been retired by ANL and 404s for every
  version. Release snapshots moved to `web.cels.anl.gov`.
- **libMesh 1.7.6 cannot be downloaded.** The tag exists, but libMesh publishes
  dist tarballs for only a subset of tags, and in the whole 1.7 series only
  1.7.8 and 1.7.9 have release assets. `LIBMESH_VERSION` moves to **1.7.9** —
  the nearest obtainable release in the same series, forced by availability
  rather than chosen. Building 1.7.6 would mean an unbootstrapped tag archive
  plus autoconf/automake/libtool in the env, which is a larger deviation, not a
  smaller one.

**A26 — GCC 14 broke the pinned TPL sources, not our code.** `--download-scalapack`
fails outright: GCC 14 promoted implicit function declarations from a warning to
an error, and ScaLAPACK's BLACS is pre-C99 and full of them (`BI_imvcopy`,
`BI_TransDist`, …). PETSc's `--CFLAGS` gains `-Wno-implicit-function-declaration`
and `--FFLAGS` gains the gfortran-10+ counterpart `-fallow-argument-mismatch`.
These reach every `--download-` package, which is the point: PETSc passes its
flags down to each TPL's own build system, and the TPLs are the old code. Both
restore behaviour a newer compiler changed; neither is a choice about how PETSc
is built.

**A29 — a libMesh built from the RELEASE TARBALL with `--enable-hdf5` can never
write an ExodusII file.** Two things combine:

1. `configure` sets `NETCDF_INCLUDE="-I$(top_srcdir)/contrib/netcdf/v4/include"`
   — **`top_srcdir` only**. The build tree's `include/`, where the netcdf
   sub-configure writes the `netcdf_meta.h` it just generated, is never on the
   include path.
2. **The dist tarball ships a `netcdf_meta.h` that disagrees with the one in
   git.** Git has `NC_HAS_NC4 1` / `NC_HAS_HDF5 1`; the 1.7.9 tarball ships the
   same file saying `0` / `0`. `make dist` evidently regenerated it from
   `netcdf_meta.h.in` on a machine whose netcdf configured without HDF5, and
   shipped that instead.

**This is a tarball defect, not a libMesh source defect** — checked against
`v1.7.9` in git, where `contrib/netcdf/v4` is a symlink to
`contrib/netcdf/netcdf-c-4.6.2`. A git checkout has the correct header, so (1)
is harmless there and exodus works. It bites anyone building from the published
release, which is what this stack does and what v0 did.

So `contrib/exodus` always compiles believing netcdf has no HDF5, however netcdf
was actually built — and ours is built with it (`libnetcdf.settings` reports
*"NetCDF-4 API: yes"*; the installed `netcdf_meta.h` says `NC_HAS_HDF5 1`; a
direct `nc_create(..., NC_NETCDF4)` succeeds).

The consequence is not subtle. `ex_utils.c` gates on `#if !NC_HAS_HDF5`, and
`ExodusII_IO_Helper::create` selects `EX_NETCDF4|EX_NOCLASSIC` unconditionally
under `--enable-hdf5` — there is no runtime override. Exodus then refuses every
one: *"File format specified as netcdf-4, but the NetCDF library being used was
not configured to enable this format"*. `introduction_ex4` solves correctly and
dies on output.

**Deleting the stale header is not the simpler fix, and cannot be.** That was
tried first and measured not to work; the reason first written down here — "the
include path has nowhere correct to fall through to" — was an inference, and the
real one is better. `netcdf.h` defines `NC_HAVE_META_H`, so `exodusII.h` reaches
its `#include "netcdf_meta.h"` unconditionally. Removing the file therefore
either breaks the compile outright or lets some other copy on the include path
decide, and `#if !NC_HAS_HDF5` treats an undefined macro as 0 either way.
Checked against the preprocessor directly, with the shipped header, with it
deleted, and with git's values:

| `netcdf_meta.h` | verdict |
|---|---|
| tarball, `0`/`0` | exodus refuses netcdf-4 |
| deleted | exodus refuses netcdf-4 |
| git's `1`/`1` | exodus accepts |

The remaining choice is *where the right answer comes from*, and only two exist:
hardcode `1` before configure, or read what the sub-configure decided. The
recipe copies the sub-configure's *generated*
`netcdf_meta.h` over the shipped one after configuring, and refuses to build if
that file is missing or itself reports no HDF5. Using configure's own answer
rather than hardcoded values means it stays right if the HDF5 knob changes —
and makes the fix a no-op rather than a hazard should the recipe ever be pointed
at a git checkout, where the header is already correct.

Worth reporting upstream: the tarball's `netcdf_meta.h` is strictly worse than
the one in the repository it was cut from.

This is worth stating plainly: v0 had the same configuration and the same
defect, and never knew, because its example checks ran without `|| exit 1`.
Carrying those checks across *and looking at what they said* is what surfaced
it. It is also the argument for the smoke test ending at `introduction_ex4`
rather than at something that only proves the libraries link.

**A34 — a `grep -l` behind `xargs` truncated its own work list, silently and
non-deterministically. CI found it; repeated local runs did not.** The first CI
run of the full pipeline failed identically on both platforms with five files
still naming the build prefix:

```
lib/libnetcdf.settings
lib/petsc/conf/modules/petsc/3.20.5
lib/petsc/conf/configure-hash
lib/petsc/conf/uninstall.py
lib/petsc/conf/reconfigure-arch-linux-c-opt.py
```

`fixup-text.sh` reported **13** provenance files fixed in CI against **18**
locally — and 18 − 13 is exactly those five. The provenance list is built by a
process substitution whose first generator was a pipeline:

```sh
find "${STACK}/include" … -print0 | xargs -0 -r grep -l "${STACK}"
```

The tree holds **4828** matching headers, so `xargs` runs `grep` in several
batches. A batch matching nothing makes that `grep` exit 1, which makes **`xargs`
exit 123**. The script runs under `set -euo pipefail`, the subshell inherits it,
and a non-zero pipeline there kills the subshell — so the three *remaining*
generators never ran. Measured:

```
pipeline exit=0 123 0        # find, xargs, (subshell)
with pipefail, exit=123
```

Whether it trips depends on where the batch boundary happens to fall, which is
precisely why local runs escaped it. The same hazard was latent in the make
generator, which has both a `grep -v` (exits 1 if it filters everything out) and
a trailing `ls` of files that need not exist.

Fixed by using a single `grep -rl` instead of `find | xargs grep -l` — no
batching, so no 123 to begin with — and `|| true` on every generator in both
lists. `fixup-text.sh` now also re-scans the families it claims to have fixed and
fails naming the file, rather than letting the omission surface as a `validate`
failure two stages and twenty minutes later.

Two things worth keeping from this. **A list-building failure is invisible by
construction**: nothing errors, you simply get less work done, and the eventual
symptom points at the files rather than at the generator. And it is the argument
for the CI matrix paying for itself on its first green-ish run — this had
survived four clean local `make all` cycles.

**A32 — the relocatable make fragments cannot handle a space in the install
path, and nothing can make them.** `distcheck` now unpacks under `.../a b/c`,
and the first run found this. GNU make's path functions are *list* functions:
with the tree under a path containing a space, `$(realpath …)` returns the
correct string while `$(dir …)` and `$(abspath …)` split it and return nonsense.
Measured directly:

```
realpath=[/tmp/sp test/a b/c/Makefile]
__p=[/tmp /tmp/sp test/a b/c/test /tmp/sp test/a b/c/b]
```

No makefile can work around that — make cannot represent a filename containing a
space. So the **binaries are fine** (all 342 objects resolve from such a path
and everything runs), `.pc` files and `libmesh-config` are fine, and only the
make-based build integration is affected. `validate.sh` reports it as a warning
naming the cause rather than failing a gate over something unfixable.

Worth stating the trade honestly: the *original* hardcoded `LIBMESH_DIR` would
have handled a space fine, being a literal. Making it relocatable (A31) is what
introduced the constraint. That is the right way round — relocation is the
point — but it is a trade, and it is now documented rather than found later by
someone with a space in their install path.

**A33 — the extension point had never been extended.** S6's mechanisms all
existed; its *verification* step — "add a throwaway package in `site/` and
confirm it builds, gets patchelf'd, and survives `distcheck`" — did not.
`examples/site-package/` is now a real package, tracked (it cannot live in
`site/`, which is gitignored), and a clean `make all` with it copied into
`site/` proves the claim end to end.

It also produced a finding: the harness first ran *everything* executable under
`libexec/`, and immediately tried to execute rdma-core's
`truescale-serdes.cmds`. `libexec/` is shared with conda, so the extension point
gets its own namespace, `libexec/stack-tests/`. No directory in this prefix
belongs to us alone.

**A31 — source packages bring build-integration metadata, and it bakes the
prefix in formats the text fixup did not cover.** A conda-only tree had none of
these. The three source packages install **115** text files naming the build
root — measured, and all 115 source-installed, zero conda-owned, so nothing in
the conda handling regressed. They fall into three groups:

- **105 resolvable configuration files** — 83 GNU make fragments (libMesh's
  example Makefiles, `Make.common`, PETSc's `lib/petsc/conf/*`) and 18 CMake
  package configs (Trilinos, Sacado, Teuchos, superlu, scalapack). These are how
  a customer builds against the stack, so they get the same treatment §S4 already
  applies to `.pc` files and shell wrappers: the idiom the consuming tool already
  has — `$(dir $(realpath $(lastword $(MAKEFILE_LIST))))` for make,
  `${CMAKE_CURRENT_LIST_DIR}` for cmake.
- **1 shell script** — `contrib/bin/libtool`; the wrapper pass simply was not
  looking in `contrib/bin`.
- **~11 provenance strings** with no relative form at all — `PETSC_MPICC_SHOW`,
  `LIBMESH_CONFIGURE_INFO`, `libnetcdf.settings`, PETSc's configure hash. A C
  `#define` cannot be made self-locating, so these are neutralised rather than
  rewritten, which is the call already made for `H5pubconf.h`. A stale absolute
  path invites a consumer to resolve it and silently get nothing; a visible
  placeholder says what happened.

**Two things this cost, both worth remembering.**

The injected variable is numbered per file. These fragments include one another,
and `LIBMESH_DIR ?= $(...)` is *recursively* expanded — a shared variable name
would let the last fragment parsed decide what every earlier one meant.

And `$(realpath ...)` is load-bearing. libMesh installs `Make.common` at
`etc/libmesh/Make.common` **and symlinks it as `<prefix>/Make.common`**, which is
the path the examples actually include. Without `realpath`,
`$(dir $(lastword $(MAKEFILE_LIST)))` yields the *symlink's* directory, so a
depth computed for `etc/libmesh/` climbed two levels too far and every
`LIBMESH_DIR` resolved to `/opt`. **The residue scan was perfectly happy** — the
build prefix was gone. That is the whole lesson of this project in one bug, so
`validate.sh` now asks `make` what `LIBMESH_DIR` actually evaluates to and
compares it to the tree it is standing in.

**A30 — a source package cannot be rebuilt over its own previous install.**
A20 recorded that the *pipeline* is not re-runnable over its output. The same is
true one level down, for a reason worth naming separately: a package that
installs headers into the shared prefix changes the answers `configure` gets the
next time round.

libMesh installs its bundled Boost subset to `$STACK/include/boost`. On a second
`make build` into the same prefix, `contrib/metaphysicl`'s configure finds
`boost/version.hpp` (1_61), concludes Boost is available, and then dies on
`cannot find boost/chrono.hpp` — which that subset does not contain. A clean
prefix has no Boost at all, so metaphysicl correctly skips it.

Nothing is wrong with the recipe; the prefix is simply not re-entrant, because
`activate_toolchain` puts `-I$STACK/include` on the compile line and that is
exactly what makes HDF5 and PETSc findable. Iterating on a single source package
therefore means removing that package's installed files first, or starting from
a fresh prefix. The practical rule: **incremental rebuilds are for diagnosis;
the only build that counts is one from a clean `$STACK`.**

**A28 — "sealed after `make conda`" was a rule with nothing enforcing it, and
it destroyed a completed build.** F9 named this hazard during review and it was
left as a convention. It is not one: `conda create -p $STACK` does not ask
whether the prefix already holds anything, and `conda.stamp` depends on
`conda/bootstrap.sh` — so *editing bootstrap.sh* marks the conda stage out of
date, and the next `make build` recreates the env before rebuilding. A finished
PETSc install (8510 files, twenty-five minutes) was lost this way while adding
one package to the spec list. The stamp dependency is correct; the action was
not.

`bootstrap.sh` now leaves an existing env alone. When `etc/source-files.txt`
shows source builds have installed into it, it says so and stops; re-creating
is `CONDA_RECREATE=1` or `make distclean`. This is also why the manifest from
A10 is worth having twice over: it is what lets the seal know the prefix is not
merely populated but *unreproducible without a rebuild*.

**A27 — libtool `.la` files have to be removed by the recipe.** `validate.sh`
rejects them because they record the absolute prefix and absolute paths to
dependencies, so a relocated tree carries them pointing at a directory that no
longer exists. Every autotools package installs them by default, so
`remove_libtool_archives` lives in `lib/build_common.sh` and libMesh calls it
after `make install`. Nothing links against them — the `.so` and the `.pc` carry
what a consumer needs.

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

### Observed while landing CI

**A36 — a lint gate finds things, which is the point, and two of them were real.**
`checks.yml` runs `shellcheck --severity=warning` over every tracked script, and it
was not green on arrival. `relocate/validate.sh`'s `soft()` helper passed `"$@ …"` —
mixing an array expansion with a string, so with more than one argument the
`[advisory: pre-slim]` suffix attaches to the last argument rather than to the
message (SC2145). Every current call site passes a single string, so it has never
misbehaved; it was a trap laid for the next caller. The second real one arrived with
the source builds: `fixup-text.sh` feeds `find … | xargs grep -l` over
`$STACK/include`, which breaks on any header whose path contains whitespace
(SC2038) — `-print0`/`-0` now. Two were not defects: `fixup-text.sh` matched four
shebang patterns where one suffices (`'#!'*sh` already covers `'#! '*bash`), which
read as covering cases it did not, and `wrappers/selftest.sh` and
`lib/build_common.sh` each needed a directive where the code was already deliberate.
The severity threshold is `warning` on purpose — the style tier is mostly advice
about idioms this repo has chosen, and a gate that fires on things you intend to
keep is a gate you learn to ignore.

**A37 — `linux-64` has no checked-in lock, so its reproducibility is a claim about
conda-forge rather than about this repository.** `conda/lock/` contains exactly one
file, for `linux-aarch64`, because that is the platform the pipeline was developed on.
`bootstrap.sh` falls back to solving from the spec when no lock exists — which is the
right behaviour, and it means `ci.yml`'s x86 build re-solves on every run and will
change underneath us at some point without anything saying so.

The first CI run made the gap concrete and larger than "reproducibility": the two
platforms did not build the same package set. `linux-aarch64` created its env from
the lock and validated **58 packages**; `linux-64` solved fresh and reached the
pre-slim gate with **86**. Whatever else that is, it is not the same artifact with a
different `-march`. `extended.yml`'s `refresh_lock` publishes the lock a fresh solve
produced, for both platforms, so closing this is a matter of downloading that
artifact and committing it — from a solve someone has watched `make all` succeed
against, rather than lifted off a runner unverified.

It also produced a small lesson about reporting. The build job's summary line
originally printed the *input* — "env from the checked-in lock" — on the very run
that had solved from scratch, because no `linux-64` lock exists for it to have used.
It now tests for the lock file and reports what actually happened. A status line
that reports the request rather than the outcome is worse than no status line.

**A38 — `opensuse/leap:15` has no `gzip`, and that is the verify matrix earning its
keep.** The first CI run was green on eight of ten verify jobs and red on
`opensuse/leap:15` — on *both* architectures, identically:

```
=== verify on openSUSE Leap 15.6, glibc 2.38
unpacking libmesh-stack-0.1.0-linux-64-openblas-glibc2.28.tar.gz …
tar (child): gzip: Cannot exec: No such file or directory
```

`Dockerfile.verify` installed `tar` and nothing else, on the reasoning that
unpacking a tarball is all that image has to do. But GNU `tar` does not decompress:
`-z` execs `gzip`, and every other base image in `bases.env` happens to ship it. The
artifact was never implicated — it was never unpacked.

Both Dockerfiles now name `gzip`, because both need it: the builder untars `.tar.gz`
sources for PETSc, Trilinos and libMesh and *writes* a `.tar.gz` in `make dist`, so
`BASE_IMAGE=opensuse/leap:15` would have failed on the first source download for the
same reason. That is the more useful form of the finding: the package list in these
files is the honest answer to "what does a machine need to build, unpack and run
this?", and it was one entry short. A single-distro check could not have found it,
and `fail-fast: false` is what kept "which distro?" legible rather than cancelling
the run at the first red job.

**A39 — `strip` takes SIGBUS on at least one object, and the failure is swallowed.**
Visible in the first CI run's `linux-64` log, mid-`slim`:

```
relocate/slim.sh: line 135: 85226 Bus error (core dumped)
  "${STRIP}" --strip-unneeded "$f" 2> /dev/null
```

The loop continues, 532 objects strip successfully, and nothing downstream notices —
so the build is green and one object is silently unstripped. This is the same family
as A16, where `patchelf` died on the three files it had itself mapped, and the fix
there was to patch a copy and `rename(2)` it in. Not fixed here: which object, and
whether it is the same hardlink-from-the-package-cache mechanism, wants
investigating rather than guessing, and the honest interim position is that the
build tolerates a crashing `strip` without saying so. `slim.sh` should at minimum
count and report them.

---

## A21 — instruction-set portability (added after the review)

A concern the original plan does not address at all: the stack is built on
whatever CPU the build host happens to have, and ships to customers whose
hardware may be considerably older. A library compiled with `-march=native` on
an AVX-512 builder dies with `SIGILL` on a 2015 Xeon — at an arbitrary point
mid-run, in a library nobody suspected, on a machine we never see. Nothing else
in the pipeline notices: the tree relocates correctly, resolves correctly, and
runs perfectly on the machine that built it.

### What is actually true today, measured

| | conda-forge injects | gcc default when nothing is injected |
|---|---|---|
| `linux-64` | `-march=nocona -mtune=haswell` (SSE3, 2004) | `-march=x86-64` (SSE2) |
| `linux-aarch64` | **nothing** | `-march=armv8-a` (baseline) |

So the *baseline* is conservative on both platforms already, and
`lib/build_common.sh`'s `activate_toolchain` inherits it by sourcing the
activation scripts. The exposure is narrower than it first looks — but it is
real, for one specific reason:

**`-march` is last-wins on a gcc command line, and `CFLAGS` are injected
first.** conda-forge's `-march=nocona` therefore cannot override a build system
that appends its own `-march`. Kokkos autodetecting the host architecture is the
canonical offender, and it arrives with Trilinos.

### Decision: a wrapper for what we compile, a gate for everything

Both, because neither is sufficient alone.

**`ISA_BASELINE_X86 ?= x86-64-v2`, `ISA_BASELINE_AARCH64 ?= armv8-a`.** v2 is
SSE4.2 + popcnt, Nehalem/2009 and later — the level RHEL 9 itself requires, so
it cannot exclude a host running a current distro, while being meaningfully
faster than SSE2/SSE3 for numerics. On aarch64 the declared floor is **`armv8.1-a`, not the `armv8-a` baseline** —
and that is a measured correction rather than a preference. The gate's first run
on a real artifact found 13 objects above `armv8-a`: `libstdc++`, `libgcc_s`,
`libgfortran`, `libatomic`, `libcurl`, `libfabric`, `libucs`, `libuv`, `libffi`,
`libitm` and friends, all carrying ARMv8.1 LSE atomics. Verified they are **not**
runtime-guarded — there is no `__aarch64_have_lse_atomics`, no
`__aarch64_ldadd*` outline helpers, and `libstdc++` has zero undefined
references to them, so conda-forge's aarch64 toolchain is emitting LSE inline
with `-moutline-atomics` off. Those are binaries we do not build and cannot
change; what was left was to declare the floor accurately. ARMv8.1 is 2016+ and
covers every server part (Graviton 2+, Neoverse, Ampere); it excludes
Cortex-A72/A53/A57, i.e. Raspberry Pi 4 class hardware. SVE remains a hazard and
is not baseline.

This is the gate paying for itself before it had a wrapper to check: the number
was previously invisible, and we would have shipped it believing otherwise.

**x86-64, scanned under Rosetta:** all 305 objects within `x86-64-v2`, with 7
carrying CPUID dispatch. Clean — but only after the scanner learned two things
from being disbelieved. `tzcnt` is not a hazard: it encodes as `F3 0F BC`, which
a pre-BMI CPU decodes as `rep bsf` and executes correctly, differing only for a
zero operand where `__builtin_ctz` is undefined anyway — which is exactly why
gcc emits it at `-march=nocona`. `lzcnt` stays flagged, because it decodes as
`rep bsr`, does not fault, and returns a *different answer*: silently wrong
rather than undefined.

**A build-time compiler wrapper layer** (S2, next PR), in the spirit of
[NCAR's `ncarcompilers`](https://github.com/NCAR/ncarcompilers), which
establishes the precedent of intercepting compiler invocations to inject flags
transparently regardless of build-system complexity. Adapted rather than
vendored: ncarcompilers carries assumptions about NCAR's module environment that
do not apply here, and our need is narrower — append `-march=$(ISA_BASELINE)`
*last* so it wins, and hard-error on `-march=native` rather than silently
correcting it. Wrappers live outside the shipped tree and go on `PATH` only
during source builds, so the artifact is unchanged.

**An ISA verification gate on the artifact** (`relocate/isa-scan.py`), because
the wrapper is blind to the ~58 conda-forge packages that arrive prebuilt —
which is *100% of the current 60 MB tarball*. Every ELF is disassembled and
scanned for instructions above the baseline. Disassembly rather than
`.note.gnu.property`, because that note carries an x86 ISA level only when built
with `-march=x86-64-vN` specifically and misses `-march=haswell` entirely.

Three details that matter:

- **Runtime dispatch is DETECTED, not listed.** The first x86-64 scan flagged
  seven objects, and the interesting part was *which*: not just OpenBLAS, but
  `libgfortran` (multiversioned matmul), `libmpi` and `libmpi_abi` (MPICH's
  yaksa pack/unpack kernels), `libstdc++`, `libgcc_s`, `libitm`. A hand-kept
  list of library names would have had to grow to cover all of those and would
  still be wrong for the next package added. But every x86 dispatch scheme —
  ifunc, GCC's `__builtin_cpu_supports`, hand-rolled feature tests — bottoms out
  in the `CPUID` instruction, and those libraries carry 13–17 of them each. So
  an object containing `CPUID` is reported as dispatching rather than as a
  hazard. It is a heuristic and is treated as one: such objects get their own
  bucket rather than a silent pass, so a library with `CPUID` for an unrelated
  reason *and* genuinely unguarded AVX-512 still surfaces.
- **The scan runs during `relocate`**, while `objdump` is still in the tree —
  `binutils` is on `prune.list`. The report is filtered by which files still
  exist, so one scan serves both validate stages. Same constraint that forces
  slim before prune (A17).
- **The patterns are self-tested** (`isa-scan.py --self-test`). Without that,
  "0 objects above baseline" on x86-64 would be indistinguishable from "the
  regexes never matched anything" — and the x86 patterns cannot be exercised on
  an aarch64 development machine. The aarch64 patterns are additionally checked
  against real compiler output.
