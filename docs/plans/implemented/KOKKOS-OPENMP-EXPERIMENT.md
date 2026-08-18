# Handoff: does Kokkos' OpenMP backend cost this stack anything?

**Status: implemented.** The knob is `TRILINOS_OPENMP` in `mk/common.mk` and
`profiles/*.mk`, the lever is in `pkgs/trilinos/build.sh`, and `bleeding` is on.
The Trilinos exercise this asked for is `test/smoke/trilinos_smoke.C`.
Branch off `main` at `b6e8328`, which already carries the `bleeding` profile
(PETSc 3.23.7 / libMesh 1.8.4 / Trilinos 16-1-0) with `TRILINOS_KOKKOS=auto`.

libMesh-against-Trilinos (`--enable-trilinos`) is **deferred** and is not part
of this question.

## Settled — do not re-measure

Kokkos is already **on** in `bleeding` (that is what `auto` means), built and
verified on both platforms by `ci.yml`:

- +3 libraries (`libkokkoscore`, `libkokkoscontainers`, `libkokkossimd`),
  **63 conda packages either way** — Kokkos added no env dependency
- `validate` 0 failures on both platforms; every object within `armv8.1-a` /
  `x86-64-v2`; no `-march=native`, so the ISA wrappers never fired
- Kokkos' installed CMake configs carry no build-prefix strings (validate's
  text scan would have failed on them, as it did for X11's `Compose` files)

**The +9.8 MB figure is not Kokkos'.** It comes from `SECOND-PROFILE.md`'s
129.3 → 139.1 MB row, which is default (1.7.9 / 3.20.5 / 14-4-0) against
bleeding (1.8.4 / 3.23.7 / 16-1-0) — three version bumps bundled together.
Kokkos' own delta was never isolated, and the control for anything measured
here is **bleeding-as-shipped against bleeding+OpenMP, same pins**.

And the obvious first hypothesis is **already false**: the OpenMP runtime is in
the artifact today. `stack/lib/libgomp.so.1` and conda's `_openmp_mutex` ship,
and libMesh itself compiles with `-fopenmp` (it is in `libmesh-config
--cxxflags`). "Turning on OpenMP drags libgomp in" is answered — it is there.

## The flag this document used to name is a no-op

`-DKokkos_ENABLE_OPENMP=ON` does nothing in a Trilinos build. From
`packages/kokkos/cmake/kokkos_configure_trilinos.cmake`, guarded by
`if(CMAKE_PROJECT_NAME STREQUAL "Trilinos")`:

    if(NOT ${Trilinos_ENABLE_OpenMP} STREQUAL "")
      set(Kokkos_ENABLE_OPENMP ${Trilinos_ENABLE_OpenMP} CACHE BOOL "..." FORCE)
    else()
      set(Kokkos_ENABLE_OPENMP OFF CACHE BOOL "..." FORCE)
    endif()

`FORCE` overwrites the cache entry a `-D` on the command line created.
`cmake/kokkos_enable_devices.cmake:34-39` says it a second way: `OMP_DEFAULT`
is `ON` only when `Trilinos_ENABLE_Kokkos AND Trilinos_ENABLE_OpenMP`.

So the experiment as originally written configures, builds, validates and
`distcheck`s green **with the backend still off** — every one of the four
"no complications" conditions satisfied by a build that changed nothing. Same
shape as the `cmd > log; echo exit=$?` trap below: a green result that was
never the result.

**The lever is `-DTrilinos_ENABLE_OpenMP=ON`**, and it is project-wide TriBITS
scope — Teuchos, Sacado, Epetra and Pliris get it too. What this measures is
*Trilinos with OpenMP*, not *Kokkos with OpenMP*. There is no narrower switch.

## What that leaves of the three candidates

1. **Architecture flags — close to dead.** Every `-march=`/`-mcpu=` in
   `cmake/kokkos_arch.cmake` sits inside an `if(KOKKOS_ARCH_<x>)` block, and
   `-march=native -mtune=native` appears only under `if(KOKKOS_ARCH_NATIVE)`
   (lines 248-259), which is opt-in and off. No `Kokkos_ARCH_*` is passed, and
   enabling a host backend does not touch arch selection. Corroborated by the
   artifact: Kokkos is on today and scans 349/349 within `armv8.1-a`.
2. **A required `Kokkos_ARCH_*` choice — does not happen.** Kokkos names no
   architecture and does not demand one; `Kokkos_ENABLE_SERIAL` is forced on so
   a host space always exists.
3. **Exported text — dead for paths.** Kokkos installs its configs to
   `$STACK/lib/cmake/Kokkos` (`cmake/kokkos_install.cmake:26,28,47`), inside
   `relocate/fixup-text.sh`'s `find "${STACK}/lib" -name '*.cmake'` glob. What
   OpenMP adds is `-fopenmp` (a flag, not a path) and a `FIND_DEPENDENCY(OpenMP
   REQUIRED COMPONENTS CXX)` line written into `KokkosConfig.cmake` by
   `kokkos_export_cmake_tpl` (`cmake/kokkos_tpls.cmake:107`). Measured: the
   `.cmake` files grew by 7-47 bytes each.

Worth recording while here: the wrapper refuses only the literal tokens
`-march=native` / `-mcpu=native` (`wrappers/generate.sh:73-98`). Anything else
— Kokkos' `-mcpu=neoverse-n2`, say — passes and is silently capped by the
appended baseline. **The ISA scan, not the wrapper, is the detector**, and
`libkokkos*` is absent from validate's `DISPATCH` allowlist
(`relocate/validate.sh:289-290`), so an above-baseline Kokkos object is a hard
failure at `--stage final`. That is the behavior we want.

## The complications that are real

1. **A false green is the default outcome** unless the run asserts the backend
   is actually on. See the assertions below.
2. **A new requirement transfers to the consumer.** `KokkosConfig.cmake` gains
   `FIND_DEPENDENCY(OpenMP REQUIRED COMPONENTS CXX)` and `Kokkos_DEVICES`
   becomes `OPENMP;SERIAL`, so a downstream `find_package(Kokkos)` now fails
   unless the *consumer's* compiler does OpenMP.
   Nothing in this stack consumes Kokkos, so nothing here catches it; it lands
   on the deferred libMesh/Trilinos work.
3. **Nothing in the harness ever loads Kokkos.** `test/smoke/Makefile` links
   MPI, PETSc and libMesh only — `TRILINOS_DIR` is in the contract and unused.
   `Kokkos::initialize` is never called and no thread team is ever created in
   the artifact, so "no complications" is a build-and-inspect claim and never a
   runtime one. Say so rather than implying otherwise.
4. **`libgomp.so.1` is not in `MUST_BE_INTERNAL`** (`relocate/depsolve.py:49` —
   `libstdc++.so.6`, `libgcc_s.so.1`, `libgfortran.so.5` only). The host-leak
   failure mode that list exists for now applies to libgomp too, and nothing
   asserts it resolves in-tree. Worth fixing whether or not OpenMP ships:
   libMesh already compiles with `-fopenmp` and libgomp already ships.
5. **MKL is where two OpenMP runtimes would collide, and this run cannot see
   it.** The aarch64 lock pins `_openmp_mutex-4.5-20_gnu` + `libgomp`;
   `conda/env/linux-64-mkl.yml` asks for MKL, which conda-forge builds against
   `llvm-openmp`. Two runtimes in one process is the classic
   oversubscribe-or-crash. There is no MKL lock file and `extended.yml`'s `mkl`
   job is x86-only, so an aarch64/openblas run says nothing about it.
6. **`compose run verify` will not see the tarball.** `docker/compose.yaml:105`
   picks it with `ls -1 /dist/*.tar.gz | head -1`, which is not recursive: a
   tarball under `dist/kokkos-omp/` is invisible and the stale
   `dist/libmesh-stack-*.tar.gz` already in the tree gets picked instead.
   `make all`'s own `distcheck` is unaffected — it passes `TARBALL` explicitly.

## How to run it (~30 min, warm caches)

One temporary edit to `pkgs/trilinos/build.sh`, **not committed** — populate
the existing `auto)` arm so the single expansion point stays the only one and
the `off` path is untouched:

    auto) kokkos=( -DTrilinos_ENABLE_OpenMP=ON )
          log "Kokkos: no flag; Trilinos' own defaults decide (+ OpenMP, SCRATCH)" ;;

    # scratch override, not in the repo:
    #   volumes:
    #     conda-pkgs: {name: docker_conda-pkgs, external: true}
    #     src-cache:  {name: docker_src-cache,  external: true}
    cd docker
    nohup docker compose -f compose.yaml -f "$SP/caches.override.yaml" -p kokkos-omp \
      run --rm -T -e PROFILE=bleeding -e DIST_DIR=/src/dist/kokkos-omp \
      build make all > "$SP/kokkos-omp.log" 2>&1 &

## Assert the backend is on, before reading any other number

Cheapest disconfirmation first. If `KokkosCore_config.h` does not define it,
the run is void regardless of exit status and nothing downstream means
anything.

    grep -iE "Trilinos_ENABLE_OpenMP|Kokkos_ENABLE_OPENMP|OpenMP" .work/logs/trilinos.log
    grep KOKKOS_ENABLE_OPENMP stack/include/kokkos/KokkosCore_config.h  # must be a #define
    ldd stack/lib/libkokkoscore.so | grep libgomp                 # must resolve in-tree

## What "no complications" looks like

`make all` exit 0 and `distcheck OK`; `validate` 0 failures with every object
inside the baseline; package count still 63; nothing outside the tree in
`ldd stack/lib/libkokkoscore.so`; Trilinos' enabled top-level package set
unchanged. Compare size and `.so` count against **bleeding**, not default.
Then repeat on x86-64 in CI — Kokkos' arch tables differ per architecture, and
x86 must never be measured under Rosetta.

## Traps that cost wall-clock last time

- give every concurrent project its own `-e DIST_DIR=/src/dist/<name>`; they all
  default to `/src/dist` and silently overwrite each other's tarball
- use `nohup ... &`; a long build started as an agent background task is killed
  when the turn ends
- never edit `mk/`, `profiles/` or a `build.sh` while a build is starting — make
  parses them at startup, and a half-written file produces failures that do not
  reproduce
- `cmd > log; echo exit=$? >> log` makes the OUTER command exit 0. Grep the log
  for the recorded `exit=`; a PETSc failure was read as a success this way
- a pruned build root cannot be re-run (A20) — fresh volume per iteration, so
  batch recipe fixes before rebuilding

---

## Evidence — linux-aarch64, `b6e8328`, 2026-08-18

Two concurrent builds of `bleeding`, same commit, same warm caches, differing
only in `-DTrilinos_ENABLE_OpenMP=ON`. Both `make all` → `distcheck OK`,
recorded `exit=0`. The control was built from `git archive HEAD` in a separate
compose project, so it lacks the untracked `site/site-demo` package — **that,
and nothing else, is the whole file-list difference** (`stack/bin/site-demo`,
`stack/include/sitedemo.h`, `stack/lib/libsitedemo.so`, and two under
`stack/libexec/stack-tests/`), and it accounts for the +1 `.so` and the +3 ELF
objects. Corrected for it, **OpenMP added no file to the artifact.**

### The backend really is on

    #define KOKKOS_ENABLE_SERIAL
    #define KOKKOS_ENABLE_OPENMP          # stack/include/kokkos/KokkosCore_config.h
    NEEDED  libgomp.so.1                  # libkokkoscore.so.4.5.1
    SET(Kokkos_DEVICES OPENMP;SERIAL)     # lib/cmake/Kokkos/KokkosConfigCommon.cmake

The control's header carries `KOKKOS_ENABLE_SERIAL` alone. Trilinos' configure
prints `-- Skip adding flags for OpenMP because Kokkos flags does that`, which
is the TriBITS path that only runs when `Trilinos_ENABLE_OpenMP=ON`.

Note the install path: **`include/kokkos/KokkosCore_config.h`**, not
`include/`. The assertion above is worthless if pointed at the wrong path — it
reports "not found" for a build that is perfectly fine.

### Cost

| | control | +OpenMP |
|---|---|---|
| `make all` → `distcheck OK` | exit 0 | exit 0 |
| validate, `--stage final` | 0 failures | 0 failures |
| objects within `armv8.1-a` | 346/346 | 349/349 |
| above baseline | 0 (3 CPUID-dispatch, expected) | 0 (3 CPUID-dispatch, expected) |
| conda packages | 63 | 63 |
| enabled Trilinos packages | Kokkos Teuchos Sacado Epetra Pliris | unchanged |
| net size over common files | — | **−3,571 bytes** |

The size answer is the surprising one: **it is a wash.** `libkokkoscore`
+69,816 and `libepetra` +65,736 are paid for by `libteuchosparameterlist`
−73,984 and `libteuchoscomm` −65,536. Epetra and Teuchos moving at all is the
project-wide scope of `Trilinos_ENABLE_OpenMP` made visible — this is not a
Kokkos-only change, and the numbers say so.

`relocate/fixup-text.sh` needed nothing new: `no build-prefix strings in any
non-ELF file` at `--stage final`, and `distcheck` validated and ran
`introduction_ex4` 1D/2D/3D on 4 ranks from a path containing a space.

### What this does NOT answer

- **x86-64.** Not run. Kokkos' arch tables are per-architecture, and this is
  the platform where the ISA findings have come from. Do not measure it under
  Rosetta — dispatch `ci.yml` on a throwaway branch.
- **Anything at run time.** Nothing in the harness links Kokkos, so
  `Kokkos::initialize` was never called and no thread team was ever created.
  Green here means the artifact builds, relocates and resolves — not that the
  OpenMP backend works.
- **MKL.** x86-only, unlocked, and the one place two OpenMP runtimes could
  collide.
