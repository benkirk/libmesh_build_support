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

Native arm64 is the fast path **and a real target** — `linux-aarch64` is a
shipping platform, not a convenience:

```sh
PLATFORM=linux/arm64 TARGET_PLATFORM=linux-aarch64 docker compose run --rm shell
```

For the primary x86 target, or anything involving MKL (which is x86-only):

```sh
PLATFORM=linux/amd64 TARGET_PLATFORM=linux-64 docker compose run --rm shell
```

> **Untested:** every verification below ran on **linux-64** in a Linux
> container. The arm64 path has not been exercised at all. Expect the first
> `make conda` on `linux-aarch64` to be where you find out whether the
> conda-forge package set lines up — that is the first thing worth doing.

## What is verified, and what is not

**Works, checked:**

- `make conda` end to end. gcc pinned to **14.4.0** (an unpinned solve picks
  16.1.0); mpich **5.0.1** exporting `libmpi.so.12`; **zero** MKL packages, so
  the env is **1.4 G** against the 1.9 G an unpinned solve produced;
  `mpicc`/`mpiexec`/`hydra_pmi_proxy` all present.
- An MPI hello built with the stack's `mpicc` runs 4 ranks under `env -i` and
  resolves everything inside the prefix except the core glibc allowlist, with
  `libstdc++.so.6` and `libgcc_s.so.1` already in-tree.
- Package discovery, dependency ordering, per-package targets, hooks,
  `make help`, `make print-config`.

**Stubs that exit non-zero** — each carries its specification in comments:
`relocate/patchelf.sh`, `fixup-text.sh`, `validate.sh`, `prune.sh`, `slim.sh`,
and `test/distcheck.sh`.

**Not written yet:** the real `pkgs/petsc`, `pkgs/libmesh`, `pkgs/trilinos`
recipes (S2), the shipped `stack/activate.sh` (S4), and the smoke example
itself, which is yours to provide.

## Gotchas already paid for

Do not re-discover these.

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

In rough order:

1. **S4 — `relocate/patchelf.sh` + `validate.sh`.** The one remaining spike, and
   the heart of the whole thing. Spec is in the stub comments and in the design
   doc. Worth doing before S2: it can be exercised against the conda env alone,
   with no source packages built, which is a much shorter feedback loop.
2. **S2 — the PETSc/libMesh/Trilinos recipes.** Port from the old `*/build.sh`,
   switching to shared and installing into `$STACK`. The old recipes are no
   longer in the tree — read them at `git show v0-static-stack:petsc/build.sh`
   and friends.
3. **The smoke example** into `test/smoke/` — must be parallel-capable on one
   node and assert rank-count-dependent output, so a silently serialized run
   fails rather than passes.
4. ~~**The archive step.**~~ Done: `v0-static-stack` is tagged at `8dad908` and
   pushed, and the autotools tree is out of the working tree.

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
