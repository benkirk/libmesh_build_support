# Handoff

Everything you need to pick this up on a Mac. Written after landing **S0**
(driver scaffold) and **S0b** (container dev loop).

- Design and rationale: [`RELOCATABLE-STACK-PLAN.md`](RELOCATABLE-STACK-PLAN.md)
- Extending it: [`EXTENDING.md`](EXTENDING.md)
- The retired static stack: [`../ARCHIVE.md`](../ARCHIVE.md)

## TL;DR

**`make all` is green end to end on native `linux-aarch64`.** The conda
environment **is** the redistributable prefix; it is relocated with
`$ORIGIN` rpaths, pruned from 1.6 G to a **60 MB** tarball, and `distcheck`
proves the claim: tar, move the original out of its path, unpack at a different
directory depth, validate, run 4 MPI ranks from there.

Verified across distros, which is the part that matters — built on
`almalinux:9`, then unpacked and run on `ubuntu:24.04` (glibc 2.39) **and on
`almalinux:8` (glibc 2.28, the declared floor)**.

Still to come: the PETSc / libMesh / Trilinos recipes, and the real smoke
example.

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

**Green end to end on BOTH platforms**, `make conda` through `make distcheck`:

| | linux-aarch64 (native) | linux-64 (Rosetta) |
|---|---|---|
| env as solved | 1.6 G | 1.6 G |
| shipped tarball | **60 MB** | — |
| ELF objects | 302 | 305 |
| glibc floor measured | 2.25 (pin 2.28) | 2.25 (pin 2.28) |
| ISA baseline | `armv8.1-a`, 302/302 within | `x86-64-v2`, 305/305 within |
| CPUID-dispatching objects | 3 | 7 |

`distcheck` is the claim that matters: tar, move the original **out of its
path**, unpack at a different directory depth, validate, run 4 MPI ranks from
there. Verified cross-distro too — built on `almalinux:9`, then unpacked and run
on `ubuntu:24.04` (glibc 2.39) **and `almalinux:8` (glibc 2.28, the floor)**, in
a pristine image with no python, no binutils and no compiler.

**Not written yet:** the real `pkgs/petsc`, `pkgs/libmesh`, `pkgs/trilinos`
recipes; the compiler-wrapper layer (spec below); and the real smoke example,
which is yours to provide. `test/smoke/smoke.c` is the staged placeholder — MPI
today, with the PETSc `VecCreate` already written behind a feature define.

**Open PRs, stacked:** #4 (conda & packaging infrastructure) → `main`, and
#5 (ISA baseline gate) → #4. Merge #4 first; GitHub retargets #5 automatically.

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

**PR 3 — source compiles.** Three commit groups, in this order:

1. **The compiler wrapper layer**, before any package uses it. Build-time only:
   wrappers live outside the shipped tree and go on `PATH` ahead of
   `$STACK/bin` during source builds. They append `-march=$(ISA_BASELINE)`
   **last** — that is the entire point, since `-march` is last-wins on a gcc
   command line and `CFLAGS` are injected first, so nothing set through the
   environment can beat a build system that appends its own. They must also
   hard-error on `-march=native` rather than silently correcting it.

   Precedent is [NCAR/ncarcompilers](https://github.com/NCAR/ncarcompilers);
   adapt rather than vendor — it assumes NCAR's module environment.

   Traps to expect: avoid recursion (exec the real compiler by absolute path,
   or keep the wrapper dir off `PATH` at that moment); stay silent on stdout,
   because configure runs thousands of compile tests and parses their output;
   pass `-v`/`--version`/`-print-*` through untouched, since PETSc introspects
   the compiler; and do **not** wrap `mpicc` as well as `cc` — mpicc already
   calls the wrapped `cc`, so wrapping both double-injects.

2. **PETSc**, then **Trilinos** (no longer depends on PETSc — that dependency
   existed only to scavenge `libfblas.a`, so the two build concurrently), then
   **libMesh**. Port from `git show v0-static-stack:petsc/build.sh` and friends.

3. **The smoke example** grows: PETSc `VecCreate`, then libMesh, culminating in
   `introduction_ex4`.

The ISA gate is what will tell you whether the wrapper's last-wins injection
actually won — particularly against Kokkos, which autodetects the host
architecture and arrives with Trilinos.

**Then:** PR 4 = `site/` extension hooks and docs; PR 5 = the CI matrix.

## Layout

```
Makefile  mk/          driver: knobs, discovery, stage targets
config.mk.example      copy to config.mk (gitignored)
profiles/              version sets: default, stable, bleeding
conda/                 bootstrap, env specs, locks, prune.list
pkgs/                  source recipes; _template/ to copy
site/                  YOUR recipes — gitignored, auto-discovered
hooks/                 pre-/post- stage injection points
relocate/              patchelf, fixup, prune, slim, validate  (stubs)
test/                  smoke harness + relocation proof        (stubs)
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
