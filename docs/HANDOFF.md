# Handoff

Everything you need to pick this up on a Mac. Written after landing **S0**
(driver scaffold) and **S0b** (container dev loop).

- Design and rationale: [`RELOCATABLE-STACK-PLAN.md`](RELOCATABLE-STACK-PLAN.md)
- Extending it: [`EXTENDING.md`](EXTENDING.md)
- The retired static stack: [`../ARCHIVE.md`](../ARCHIVE.md)

## TL;DR

**`make all` is green end to end on native `linux-aarch64`.** The conda
environment **is** the redistributable prefix; it is relocated with
`$ORIGIN` rpaths, pruned to a **107 MB** tarball, and `distcheck` proves the
claim: tar, move the original out of its path, unpack at a different directory
depth, validate, and run there.

Verified across distros, which is the part that matters — built on
`almalinux:9`, then unpacked and run on `ubuntu:24.04` (glibc 2.39) **and on
`almalinux:8` (glibc 2.28, the declared floor)**, with the full solver stack
running `introduction_ex4` on both.

PETSc 3.20.5, Trilinos 14-4-0 and libMesh 1.7.9 are built from source into that
same prefix, and the smoke harness ends at libMesh's `introduction_ex4`.

## Get running on the Mac

### 1. Docker Desktop settings (do this first)

The defaults will not work.

| setting | why |
|---|---|
| **Disk image size ≥ 60 GB** | the env alone is ~1.4 GB, the conda package cache measured 2.3 GB, and PETSc/Trilinos build trees are large |
| **Memory ≥ 12 GB** | Trilinos linking is memory-hungry |
| **Enable Rosetta** (Settings → General) | only needed for `linux/amd64`; QEMU works but is far slower |

### 2. Clone and start

```sh
git clone https://github.com/benkirk/libmesh_build_support
cd libmesh_build_support

cd docker
docker compose run --rm shell        # drops you in /src with the toolchain image
```

Then inside the container:

```sh
make help          # every target
make print-config  # resolved knobs — check these before a long build
make conda         # ~6 min on x86; produces the env at /build/stack
```

`shell` plus incremental `make` is the realistic workflow. `make all` runs far
too long to sit in the foreground.

### 3. Which architecture

Both are verified. Native arm64 is the fast path **and a real target** —
`linux-aarch64` is a shipping platform, not a convenience:

```sh
docker compose run --rm shell bash -lc 'make all'       # native, ~15 min
```

For the primary x86 target, or anything involving MKL (x86-only), under Rosetta:

```sh
PLATFORM=linux/amd64 TARGET_PLATFORM=linux-64 \
  docker compose run --rm shell bash -lc 'make all'     # Rosetta, ~1 hour
```

Verifying the tarball on a different, poorer image:

```sh
VERIFY_IMAGE=almalinux:8  docker compose run --rm --build verify   # glibc 2.28
VERIFY_IMAGE=ubuntu:24.04 docker compose run --rm --build verify   # glibc 2.39
```

Timing notes, since they shape how you work: the ISA scan disassembles every
ELF and is the slowest single step (a few minutes native, much longer under
Rosetta). The conda package cache is a named volume, so re-solves cost no
network. `make all` is not re-runnable over its own output — `relocate` and
`slim` rewrite `$STACK` in place and `patchelf` is itself pruned — so iterate
with `rm -rf $BUILD_ROOT/stack $BUILD_ROOT/.work && make all`, or
`make distclean`.

## What is verified, and what is not

**Green end to end**, `make conda` through `make distcheck`, with PETSc,
Trilinos and libMesh built from source:

| | linux-aarch64 (native) | linux-64 (Rosetta) |
|---|---|---|
| shipped tarball | **107 MB** | — (conda-only: 60 MB) |
| ELF objects | 339 | 305 (conda-only) |
| source-installed files | 12787 | — |
| glibc floor measured | 2.27 (pin 2.28) | 2.25 (pin 2.28) |
| ISA baseline | `armv8.1-a`, **339/339 within** | `x86-64-v2`, 305/305 within |
| CPUID-dispatching objects | 3 | 7 |
| wall clock, clean build | ~12 min (12 cores) | ~4× that under Rosetta |

The x86-64 column predates the source builds; it has been verified only for the
conda-only stack, and re-running it is the first thing worth doing.

Cross-distro, with solvers: verified on **`almalinux:8` (glibc 2.28, the floor)**
and **`ubuntu:24.04` (glibc 2.39)** — `validate --runtime` clean, then
`introduction_ex4` in 1D/2D/3D, serial and on 4 ranks, from the prebuilt binary
in an image with no compiler, no python and no binutils.

**The ISA result is the one to note.** 339/339 within `armv8.1-a` includes
everything PETSc's six `--download-` TPLs built, each with its own build system.
Nothing compiled from source exceeded the baseline — which is what the compiler
wrapper layer exists to guarantee, and the only evidence that it does.

`distcheck` is the claim that matters: tar, move the original **out of its
path**, unpack at a different directory depth, validate, run 4 MPI ranks from
there. Verified cross-distro too — built on `almalinux:9`, then unpacked and run
on `ubuntu:24.04` (glibc 2.39) **and `almalinux:8` (glibc 2.28, the floor)**, in
a pristine image with no python, no binutils and no compiler.

`distcheck` now proves the whole claim with real solver code: the tarball is
unpacked at a different path depth and `introduction_ex4` runs there in 1D, 2D
and 3D, serial and on 4 ranks, writing ExodusII output — from a prebuilt binary,
in a tree with no compiler.

**Open PRs, stacked:** #4 (conda & packaging infrastructure) → `main`,
#5 (ISA baseline gate) → #4, and the source compiles → #5. Merge in that order;
GitHub retargets each automatically.

## Gotchas already paid for

Do not re-discover these.

- **The aarch64 floor is `armv8.1-a`, not `armv8-a`, and that is not a
  preference.** conda-forge's aarch64 toolchain emits LSE atomics *inline and
  unguarded* in `libstdc++`, `libgcc_s`, `libgfortran`, `libcurl`, `libfabric`,
  `libucs` and others — no `__aarch64_have_lse_atomics`, no outline-atomic
  helpers. Those are binaries we do not build. Excludes Cortex-A72/A53/A57.
- **`-march` is last-wins, `CFLAGS` are injected first.** So conda-forge's
  `-march=nocona` on x86-64 cannot override a build system that appends its own
  `-march`. That is why the compiler-wrapper layer appends the baseline *last*,
  and why `relocate/isa-scan.py` checks the artifact regardless.
- **Switching `TARGET_PLATFORM` against an existing build root** used to fail
  with a bare `Error 126`: the named volume kept a miniforge for the other
  architecture. `conda/bootstrap.sh` now detects and reinstalls.
- **`docker compose run` silently reuses the last-built image.** Pass `--build`
  when changing `BASE_IMAGE`/`VERIFY_IMAGE`, or you get a green run against the
  wrong distro. The verify service prints the distro and glibc it actually ran
  on — check that line.

- **Nothing is re-runnable over its own output — including a single package.**
  `make all` rewrites `$STACK` in place (A20), and a *source package* cannot be
  rebuilt over its own previous install either (A30): libMesh installs a bundled
  Boost subset into `$STACK/include`, and on a second pass `contrib/metaphysicl`
  finds `boost/version.hpp`, decides Boost is available, and dies on the
  `boost/chrono.hpp` that subset lacks. Incremental rebuilds are for diagnosis;
  the build that counts starts from a clean `$STACK`.
- **A checked-in lock silently shadows `conda/bootstrap.sh`'s spec list.** That
  is what a lock is for, and it cost two build cycles: editing the specs changes
  nothing, with no warning, and the package you added is simply not there. Use
  `make conda IGNORE_LOCK=1`, then `make conda-lock` to refreeze.
- **Build tools are pinned to the era of the sources they build**, not to the
  newest: `cmake<4` (CMake 4 hard-errors on Trilinos 14-4-0's
  `cmake_minimum_required(VERSION 2.6)`), `python<3.13` (PETSc 3.20.5's
  configure imports `xdrlib`, removed in 3.13), and `diffutils` (PETSc's
  configure needs `diff`). All three are on `prune.list`, so none is visible in
  the artifact — which is what makes the pins cheap.
- **v0's download URLs are not all alive.** PETSc's `ftp.mcs.anl.gov` was
  retired by ANL; snapshots are at `web.cels.anl.gov`. libMesh **1.7.6 has no
  release tarball at all** — only 1.7.8 and 1.7.9 in that series do — hence
  `LIBMESH_VERSION = 1.7.9`.
- **Never request the bare `libblas`/`liblapack` metapackages.** They drag in
  ~560 MB of MKL alongside the openblas actually selected. Use `libopenblas`
  plus `blas=*=openblas`.
- **Never request `mpich-mpicc`/`mpicxx`/`mpifort`.** Those split packages are
  stale and pin mpich back to **3.2.1 (2017)**. Modern mpich ships the wrappers,
  `mpiexec` and `hydra_pmi_proxy` in the main package.
- **Pin gcc.** Unpinned solves pick 16.1.0.
- **`mpicc` needs `$STACK/bin` on `PATH`** — it invokes
  `x86_64-conda-linux-gnu-cc` by name and fails confusingly without it. This is
  what the shipped `activate.sh` will handle.
- **`BUILD_ROOT` must never be a bind mount on macOS.** `compose.yaml` already
  puts it in a named volume; do not "helpfully" change that.
- **Modern mpich is fabric-heavy too.** A trivial MPI binary pulls `libucp`,
  `libucs`, `libfabric`, `librdmacm`, `libibverbs`, `libnl`. This is not an
  OpenMPI-only problem, and it is why pruning must stay at whole-package
  granularity — `dlopen`ed plugins are invisible to `ldd`.

## Where to pick up

**PR 3 — source compiles — is done.** The compiler wrapper layer, PETSc 3.20.5,
Trilinos 14-4-0 and libMesh 1.7.9 all build, and the smoke harness now ends at
`introduction_ex4` in 1D/2D/3D, serial and on N ranks, in place and again from
the relocated tree.

**Then:** PR 4 = `site/` extension hooks and docs; PR 5 = the CI matrix.

Two things from PR 3 worth carrying forward:

- **The ISA wrapper held against real code.** After PETSc, the only objects in
  `$STACK/lib` above `armv8.1-a` were conda's own prebuilts (`libgcc_s`,
  `libcrypto`, `libopenblas`). Nothing built from source exceeded the baseline,
  across six `--download-` TPLs with six different build systems. Kokkos never
  got the chance to prove the harder case — it stays off at 14-4-0 (A12).
- **The version pins inherited from v0 are claims about the past.** Two of three
  download URLs were dead, and three build tools had moved out from under the
  pinned sources. Expect the same when the pins are next bumped.

## Layout

```
Makefile  mk/          driver: knobs, discovery, stage targets
config.mk.example      copy to config.mk (gitignored)
profiles/              version sets: default, stable, bleeding
conda/                 bootstrap, env specs, locks, prune.list
wrappers/              build-time compiler wrappers: the ISA cap + its self-test
pkgs/                  source recipes: petsc, trilinos, libmesh; _template/ to copy
site/                  YOUR recipes — gitignored, auto-discovered
hooks/                 pre-/post- stage injection points
relocate/              patchelf, fixup, prune, slim, validate, isa-scan
test/                  smoke harness + relocation proof
docker/                the dev loop; CI reuses these files
```

Generated at runtime, none of it tracked:

```
$BUILD_ROOT/.conda/    miniforge — throwaway
$BUILD_ROOT/.work/     sources, build trees, stamps, logs
$BUILD_ROOT/stack/     the conda env AND the redistributable prefix
```

## Handing this to a fresh AI session

Point it at `docs/RELOCATABLE-STACK-PLAN.md` first — it carries the design plus
the reasoning behind the decisions, including why an earlier harvest-based
approach was dropped. Then this file for current state. The single most
important invariant to state up front: **the conda env is the install prefix,
there is no staging tree, and build-only packages are pruned rather than
runtime packages being copied out.**
