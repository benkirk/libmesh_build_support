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

| | linux-aarch64 | linux-64 |
|---|---|---|
| shipped tarball | **107 MB** | — |
| ELF objects | 339 | 341 |
| source-installed files | 12787 | — |
| glibc floor measured | 2.27 (pin 2.28) | 2.27 (pin 2.28) |
| ISA baseline | `armv8.1-a`, **339/339 within** | `x86-64-v2`, **341/341 within** |
| CPUID-dispatching objects | 3 | 7 |
| wall clock, clean build | ~12 min (12 cores) | ~20 min on a CI runner |

**Both columns are now the full source stack**, aarch64 measured locally and
x86-64 measured by the CI matrix — the first thing to run this pipeline on
x86-64 with PETSc, Trilinos and libMesh in it. No Rosetta run is needed to
close that gap.

Cross-distro, with solvers: verified on **`almalinux:8` (glibc 2.28, the floor)**
and **`ubuntu:24.04` (glibc 2.39)** — `validate --runtime` clean, then
`introduction_ex4` in 1D/2D/3D, serial and on 4 ranks, from the prebuilt binary
in an image with no compiler, no python and no binutils.

**libMesh also builds from git**, not only from the release tarball
(`make LIBMESH_SOURCE=git`). Measured on `linux-aarch64`, clean stack, `make
conda` through `make distcheck` green: the mirror clone plus recursive
submodules is 50 s cold and 229 MB cached, `./bootstrap` is 33 s against
autoconf 2.72 / automake 1.17 / libtool 2.5.4, and the resulting artifact is
**the same size and the same 336 objects** as the tarball build. That last part
is the point — the two modes are a cross-check on each other, because the
default ref is `v$(LIBMESH_VERSION)`.

It also settles A29 from the inside. `contrib/netcdf/v4` really is a symlink to
`contrib/netcdf/netcdf-c-4.6.2` in git, its `netcdf_meta.h` really does say
`NC_HAS_NC4 1` / `NC_HAS_HDF5 1`, and `introduction_ex4` writes ExodusII output
on a git build — which A29 asserted from the outside and nothing could test
until there was a git build to test it with.

Provisioning is split on purpose: **git is in the builder image** (a fetcher,
like curl and tar) and **the autotools are in the conda env** (generators, and
version-sensitive, so one pin serves every base image). `git-core` rather than
`git` on the RHEL and SUSE families — `git` there is a metapackage pulling perl
and openssh-clients, 76 packages against git-core's 6.4 MB, and git-core does
everything this project asks of it.

**The ISA result is the one to note**, and it now holds on both architectures:
339/339 within `armv8.1-a` and 341/341 within `x86-64-v2`. That includes
everything PETSc's six `--download-` TPLs built, each with its own build system
and its own opinions about `-march`. Nothing compiled from source exceeded the
baseline — which is what the compiler wrapper layer exists to guarantee, and the
only evidence that it does.

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
#5 (ISA baseline gate) → #4, #7 (source compiles) → #5, and #6 (the CI
workflows) → #7. Merge in that order; GitHub retargets each one automatically
as the one below it lands.

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

- **A space in the install path breaks the make fragments, and cannot be fixed.**
  GNU make's path functions are list functions, so `$(dir …)`/`$(abspath …)`
  split on the space. Binaries, `.pc` files and `libmesh-config` are unaffected;
  libMesh's example Makefiles and PETSc's `lib/petsc/conf/*` are not. Install
  somewhere without spaces if you build against the stack with make.
- **Nothing is re-runnable over its own output — including a single package.**
  `make all` rewrites `$STACK` in place (A20), and a *source package* cannot be
  rebuilt over its own previous install either (A30): libMesh installs a bundled
  Boost subset into `$STACK/include`, and on a second pass `contrib/metaphysicl`
  finds `boost/version.hpp`, decides Boost is available, and dies on the
  `boost/chrono.hpp` that subset lacks. Incremental rebuilds are for diagnosis;
  the build that counts starts from a clean `$STACK`.
- **Changing a package's source mode does not invalidate its stamp.**
  `mk/pkg.mk`'s rule depends on dependency stamps and `build.sh` — not on the
  version, the URL, the source mode or the git ref. So
  `make LIBMESH_SOURCE=git build` over a tree already built from the tarball is
  a silent no-op, and every downstream check then passes on the *old* build.
  Delete the stamp when changing what is built rather than how. The same has
  always been true of a version bump; it only became a trap worth naming when
  there were two ways to build the same version.
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

**S6 is done too** — `examples/site-package/` is a real, tracked package proven
by a clean `make all` with it copied into `site/`, and anything installed into
`$STACK/libexec/stack-tests/` is exercised by `distcheck` automatically.
`distcheck` also now unpacks under a path containing a **space** and runs the
tree **read-only**.

**CI is in place** (§S7), so the source recipes land into a matrix that is
watching. Three things to know about it before you push:

- `ci.yml` runs `make all` on **both** target platforms for every PR, then
  unpacks that tarball on five base images. A PETSc or Trilinos recipe that
  builds on your Mac and not on a runner is a red job rather than a discovery
  six weeks later — and it is what re-runs the `linux-64` column that the
  source builds have not yet been verified against.
- **Runners have 4 cores.** The job timeout is 180 min, which is generous
  against a clean source build (~12 min on 12 cores), but the number that will
  bite first is the ISA scan: it was **18 of the 21 minutes** of the first
  x86 conda-only build, and the source builds only add objects to it. If build
  time becomes a problem, that is where to look — not at the matrix width.
- The compiler wrapper is exactly what the ISA gate is watching for, and the
  gate runs inside `make all`. If the wrapper's last-wins injection loses to
  Kokkos, CI says so on both architectures before it reaches a customer.

Gaps CI cannot close for you, all recorded as amendments: `linux-64` has no
checked-in conda lock, so the two platforms are not even building the same
package set (A37 — `extended.yml` publishes a lock weekly; it needs committing
from a solve someone has watched succeed); `strip` takes SIGBUS on at least one
object and `slim.sh` swallows it (A39); and neither `MPI_FAMILY=openmpi` nor
`GLIBC_FLOOR=2.17` is wired into the matrix, because each is missing a
prerequisite named in §S7 rather than merely unwritten.

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
docker/                the dev loop; CI runs these same files
.github/workflows/     fast gate, build-once-verify-everywhere, weekly extras
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
