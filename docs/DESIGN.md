# Design

How the stack is built and why it is shaped this way; `mk/stages.mk` is the
authority for the pipeline, this is the reasoning. The invariant, up front:
**the conda env is the install prefix, there is no staging tree, and build-only
packages are pruned rather than runtime packages being copied out.**

`A<n>` cites the amendments in
[`plans/implemented/RELOCATABLE-STACK-PLAN.md`](plans/implemented/RELOCATABLE-STACK-PLAN.md)
(A1–A39; A35 was never issued; A21 is its own section at the end). Each records
a claim that turned out to be false and the measurement that disproved it. The
evidence stays there; this file states the constraint and points.

## The core decision: the conda env *is* the prefix

An earlier revision of the sprint plan had a **harvest** step: build against a conda env in
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

Conda also hands over, in `conda-meta/<pkg>.json`, a per-file record of where
the build prefix is embedded and how — the fixup inventory a harvest never had.
The cost is inheriting conda's full closure, packages nobody asked for included.
The sizing that confirmed the choice is the plan's "Measured, not estimated"
table: near-identical shipped size, materially lower risk.

## The pipeline

```
conda -> wrappers -> build -> test -> relocate -> validate -> test
                          -> slim -> validate -> dist -> distcheck
```

Every stage is a stamp, so `make -n all` prints the plan in order; the verifying
stages appear twice because they answer a different question each time. What
follows is what each one guarantees.

- **conda** — miniforge, then the env created *as* `$STACK`: from the checked-in
  lock when one exists for the platform/BLAS/MPI, else a fresh solve
  (`conda/lock/README.md`). Once source builds land in it the env is sealed and
  `bootstrap.sh` refuses to recreate it (A28).
- **wrappers** — the ISA-capping compiler shims, generated into `$WORK`,
  self-tested against object files, never shipped (`wrappers/README.md`).
- **build** — `pkgs/*` and `site/*`, discovered by directory, ordered by
  `PKG_DEPS`, all into the same `$STACK`, shared, with an absolute RPATH that
  `relocate` rewrites.
- **test** — the smoke harness in place: `introduction_ex4` in 1D/2D/3D, serial
  and on `SMOKE_RANKS`, plus anything in `libexec/stack-tests/`.
- **relocate** — every ELF gets a per-file `$ORIGIN/<relative path to lib>`
  RPATH; text files (`.pc`, cmake configs, `petscvariables`, `libmesh-config`,
  the make fragments) are rewritten to find the prefix from their own position,
  and the rewrite re-scans what it claims to have fixed (A34). The ISA scan runs
  here, while `objdump` still exists (A17). `activate.sh` is installed here.
- **validate** — the gate, under a scrubbed environment: nothing unresolved;
  nothing outside the tree but core glibc; `libstdc++.so.6` and `libgcc_s.so.1`
  resolve *inside*; `GLIBC_*` symbol versions within the floor, measured rather
  than asserted (A4); no build-root strings, `.la` files or dangling symlinks;
  every object within the ISA baseline. Post-relocate, residue in packages about
  to be pruned is reported; on the final tree it is fatal.
- **test** again, from the relocated tree, before anything is deleted.
- **slim** — file-level trimming (`.la`, docs, man, conda metadata, `strip`),
  *then* prune: `conda/prune.list` packages removed by their `conda-meta` file
  lists, never by glob. Slim first because `strip` is itself on the list (A17).
  `SLIM_PROFILE=devel` keeps headers, `.pc` and cmake configs — customers extend
  this tree.
- **validate** again — this is the artifact.
- **dist** — a reproducible tar, `<name>-<version>-<platform>-<blas>-glibc<floor>.tar.gz`,
  one top-level `stack/`.
- **distcheck** — the actual proof, and the headline feature: tar → move the
  original tree out of its path → untar at a **different path depth**
  (e.g. `.../relocated/a/b/c/`) →
  `validate.sh` → `test/run.sh relocated`. Different depth is deliberate: it is what
  catches a hard-coded `../..` assumption that a same-depth move would hide.
  It unpacks under a path containing a **space** and runs the tree
  **read-only** as well.

## RPATH not RUNPATH, `$ORIGIN`, and whole-package pruning

- **RPATH, not RUNPATH** (`--force-rpath`). RUNPATH is overridable by a customer's
  `LD_LIBRARY_PATH`; DT_RPATH takes precedence over it. For a redistributable that
  must survive an arbitrary host environment, RPATH is the right default. Expose
  `RPATH_MODE=runpath` as a build knob for debugging — and as the natural hook for
  the deferred external-MPI work, which need not be resolved now.
- **Do not** `--set-interpreter`. The whole premise is that host glibc satisfies the
  declared floor; rewriting the interpreter would contradict that and break on
  hosts with different loader paths.

Pruning is by whole conda package, by manifest, for the reason given above: a
dependency closure cannot see `dlopen`ed libraries, and that list — MKL
dispatch, OpenBLAS threading, Hydra/PMI, libfabric/UCX, hwloc plugins — is
what file-level pruning would lose, silently, until a customer ran in parallel.
`SLIM_PROFILE=runtime` removes headers, `.pc`/cmake files, `*-config` scripts
and the UCX GPU plugins by name — it walks no closure either.

## The ISA baseline and the compiler wrappers

Built on one CPU, shipped to older ones — and nothing else in the pipeline
notices a `-march=native` slip, because the tree runs perfectly on the machine
that built it (A21).

### Decision: a wrapper for what we compile, a gate for everything

Both, because neither is sufficient alone.

The wrappers stand between the build system and the compiler and *append*
`-march=$ISA_BASELINE` — a cap, not a floor — because `-march` is last-wins and
`CFLAGS` go first, so appending is the only position that wins. Bare `cc`/`gcc`
are wrapped too; `mpicc` is not (it invokes the already-wrapped compiler);
`-march=native` is refused. Defaults are
`x86-64-v2` and `armv8.1-a` (`mk/common.mk`); the aarch64 one is a measured
correction — first constraint below. `relocate/isa-scan.py` then disassembles
every shipped object regardless of who built it, self-tests its own patterns so
"0 above baseline" cannot mean "the regexes never matched", and puts objects
carrying `CPUID` dispatch (OpenBLAS, `libgfortran` matmul, MPICH's yaksa) in
their own bucket rather than passing them silently. Mechanism and self-test:
`wrappers/README.md`. Do not set `-march` in a recipe.

## Constraints found by measurement

Do not re-discover these. Each was paid for once.

- **The aarch64 floor is `armv8.1-a`, not `armv8-a`, and that is not a
  preference.** conda-forge's aarch64 toolchain emits LSE atomics *inline and
  unguarded* in `libstdc++`, `libgcc_s`, `libgfortran`, `libcurl`, `libfabric`,
  `libucs` and others — no `__aarch64_have_lse_atomics`, no outline-atomic
  helpers. Those are binaries we do not build. Excludes Cortex-A72/A53/A57 (A21).
- **`-march` is last-wins, `CFLAGS` are injected first.** So conda-forge's
  `-march=nocona` on x86-64 cannot override a build system that appends its own
  `-march`. That is why the compiler-wrapper layer appends the baseline *last*,
  and why `relocate/isa-scan.py` checks the artifact regardless (A21).
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
  somewhere without spaces if you build against the stack with make (A32).
- **Nothing is re-runnable over its own output — including a single package.**
  `make all` rewrites `$STACK` in place (A20), and a *source package* cannot be
  rebuilt over its own previous install either (A30): libMesh installs a bundled
  Boost subset into `$STACK/include`, and on a second pass its configure finds
  that subset through `-I$STACK/include` and takes it for an external Boost —
  `pkgs/libmesh/build.sh` now stops there with a message naming A30, where it
  used to die later inside `contrib/metaphysicl`. Incremental rebuilds are for
  diagnosis; the build that counts starts from a clean `$STACK`.
- **A dev package on the build host can steer libMesh's configure.** Rocky 8
  with `boost-devel` 1.66: `contrib/metaphysicl`'s optional VexCL probe found
  it in `/usr/include`, added `-I/usr/include`, and died — fatal inside an
  optional check. Reproduced in CI on `almalinux:8` x86-64: that `-I` puts the
  host's glibc headers ahead of the sysroot's, and el8's `bits/floatn.h`
  typedefs `_Float128`, which GCC 14 rejects in C++. Not a Boost problem. On
  aarch64 the header does not clash and the outcome is worse: libMesh adopts
  the host Boost and ships `LIBMESH_HAVE_EXTERNAL_BOOST 1` and `-I/usr/include`
  in `libmesh-config --include` (measured). The conda compiler never sees the
  host `/usr/include` by itself; only autoconf macros that probe `/usr`, `/opt`
  and `$BOOST_ROOT` explicitly let it in (Boost; also Eigen, XDR/tirpc, X11,
  GLPK, NLopt, VTK, curl in libMesh's m4). So: `--with-boost=$STACK
  --with-vexcl=no`, assertions on what configure recorded and on the installed
  `libmesh-config`/`.pc` files (`pkgs/libmesh/build.sh`, `test/run.sh`), an
  environment scrub in `activate_toolchain`, and `extended.yml`'s weekly
  `dirty-host` job on a deliberately dirtied `almalinux:8`. Numbers:
  [`plans/implemented/HOST-BOOST-ISOLATION.md`](plans/implemented/HOST-BOOST-ISOLATION.md).
- **Pointing a probe at `$STACK` is only half an answer; the stack has to hold
  the package.** Every optional package libMesh looks for now comes from the
  conda env — Boost (`libboost-headers`), Eigen (`eigen`, in `include/eigen3`,
  *not* `include/`, where libMesh's own bundled copy lands), XDR (`libtirpc`),
  the X11 headers `contrib/tecplot/tecio` needs (`xorg-libxt` **and**
  `xorg-xorgproto`, since `Xlib.h`'s first include is the protocol header
  `X11/X.h`), and GLPK. Two of those features had never been on at all: the
  glibc 2.28 sysroot has no usable `rpc/xdr.h`, and `--enable-tecio` has been in
  the recipe since v0 while `HAVE_TECPLOT_API` was never once defined in a
  shipped artifact, because `tecio.m4` disables itself in one line when the X11
  headers are missing. NLopt is the exception and is explicitly `--disable`d:
  every conda-forge build of it carries the Python bindings and depends on
  numpy. A flag is a request, not a receipt — `pkgs/libmesh/build.sh` holds
  `libmesh_config.h` to a required-on / required-off table, before the compile
  and again on the installed header.
- **A feature being on is not the same as a consumer being able to use it.**
  libMesh's public `xdr_cxx.h` includes `<rpc/rpc.h>` under `HAVE_XDR`, and
  conda's libtirpc keeps its headers under `include/tirpc/`. libMesh 1.8 exports
  that path (`--with-xdr-include` lands in `libmesh_optional_INCLUDES`); 1.7
  cannot be made to at all — the variable is cleared at the top of the macro and
  `libmesh-config --cppflags` carries per-METHOD flags only. So the recipe links
  `include/{rpc,rpcsvc,netconfig.h}` to their `tirpc/` counterparts, the layout
  glibc's own sunrpc had, and then *proves* it: after `make install` it asks
  `libmesh-config` for the compile line and compiles a TU including `libmesh.h`,
  `xdr_cxx.h` and `dense_vector.h` with exactly those flags. That check found
  both the missing `rpc/` path and, once linked, the `netconfig.h` behind it —
  neither of which any check on a generated file could see.
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
  nothing (`bootstrap.sh` now prints a note saying so), and the package you added
  is simply not there. Use `make conda IGNORE_LOCK=1` — plus `CONDA_RECREATE=1`
  over an existing env — then `make conda-lock` to refreeze (A24, A28).
- **Build tools are pinned to the era of the sources they build**, not to the
  newest: `cmake<4` (CMake 4 hard-errors on Trilinos 14-4-0's
  `cmake_minimum_required(VERSION 2.6)`), `python<3.13` (PETSc 3.20.5's
  configure imports `xdrlib`, removed in 3.13), and `diffutils` (PETSc's
  configure needs `diff`). All three are on `prune.list`, so none is visible in
  the artifact — which is what makes the pins cheap (A23).
- **v0's download URLs are not all alive.** PETSc's `ftp.mcs.anl.gov` was
  retired by ANL; snapshots are at `web.cels.anl.gov`. libMesh **1.7.6 has no
  release tarball at all** — only 1.7.8 and 1.7.9 in that series do — hence
  `LIBMESH_VERSION = 1.7.9` (A25).
- **Never request the bare `libblas`/`liblapack` metapackages.** They drag in
  ~560 MB of MKL alongside the openblas actually selected. Use `libopenblas`
  plus `blas=*=openblas`.
- **Never request `mpich-mpicc`/`mpicxx`/`mpifort`.** Those split packages are
  stale and pin mpich back to **3.2.1 (2017)**. Modern mpich ships the wrappers,
  `mpiexec` and `hydra_pmi_proxy` in the main package.
- **Pin gcc.** Unpinned solves pick 16.1.0. The pin governs the compiler only;
  the shipped `libstdc++` is conda-forge's newest regardless (A13).
- **`mpicc` needs `$STACK/bin` on `PATH`** — it invokes
  `x86_64-conda-linux-gnu-cc` by name and fails confusingly without it. The
  shipped `activate.sh` does this.
- **`BUILD_ROOT` must never be a bind mount on macOS.** `compose.yaml` already
  puts it in a named volume; do not "helpfully" change that.
- **Modern mpich is fabric-heavy too.** A trivial MPI binary pulls `libucp`,
  `libucs`, `libfabric`, `librdmacm`, `libibverbs`, `libnl`. This is not an
  OpenMPI-only problem, and it is why pruning must stay at whole-package
  granularity — `dlopen`ed plugins are invisible to `ldd`.
- **The prefix is sealed after `make conda`.** `conda create -p` does not ask
  whether the prefix already holds anything, and editing `bootstrap.sh` marks
  the conda stage out of date — so `bootstrap.sh` now refuses to recreate an env
  that source builds have installed into (A28; `CONDA_RECREATE=1` overrides).

## What is verified, and how

Measured on `main` at `a61f0d6` (2026-08-16), from that commit's `ci` run; later
runs supersede this table without anyone editing it. Cells from an earlier
measurement say so.

| | linux-64 | linux-aarch64 |
|---|---|---|
| tarball | 111 MB | 106 MB |
| packages after prune | 58 | 58 |
| ELF objects in the shipped tree | 335 | 333 |
| glibc floor | requested 2.28, measured 2.27 | requested 2.28, measured 2.27 |
| ISA baseline | `x86-64-v2`, 335/335 within | `armv8.1-a`, 333/333 within |
| CPUID-dispatching objects | 7 | 3 |
| wall clock, `make all` on a 4-vCPU runner | 2173 s | 1826 s |

Verified on `almalinux:8` (glibc 2.28, the floor), `almalinux:9` (2.34),
`ubuntu:22.04` (2.35), `opensuse/leap:15` (2.38) and `ubuntu:24.04` (2.39), both
architectures, every `ci` run — `validate --runtime` clean, then
`introduction_ex4` in 1D/2D/3D, serial and on 4 ranks, from the prebuilt binary
with the loader alone — the runtime validate and the smoke run need no compiler,
python or binutils, and none of the images ships a compiler.

The single most important signal is `distcheck` exiting
zero from a **different install path than the one the stack was built at**.

**The ISA result is the one to note**, and it now holds on both architectures:
339/339 within `armv8.1-a` and 341/341 within `x86-64-v2`. That includes
everything PETSc's six `--download-` TPLs built, each with its own build system
and its own opinions about `-march`. Nothing compiled from source exceeded the
baseline — which is what the compiler wrapper layer exists to guarantee, and the
only evidence that it does. *(Counts as measured 2026-08-15; the table above is current.)*

**libMesh also builds from git**, not only from the release tarball
(`make LIBMESH_SOURCE=git`). Measured on `linux-aarch64`, clean stack, `make
conda` through `make distcheck` green: the mirror clone plus recursive
submodules is 50 s cold and 229 MB cached, `./bootstrap` is 33 s against
autoconf 2.72 / automake 1.17 / libtool 2.5.4, and the resulting artifact is
**the same size and the same 336 objects** as the tarball build (measured
2026-08-15; the table above is current). That last part
is the point — the two modes are a cross-check on each other, because the
default ref is `v$(LIBMESH_VERSION)`.

It also settles A29 — the 1.7.9 release tarball ships a `netcdf_meta.h` that
disagrees with git, so an unpatched tarball build cannot write ExodusII — from
the inside. `contrib/netcdf/v4` really is a symlink to
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
