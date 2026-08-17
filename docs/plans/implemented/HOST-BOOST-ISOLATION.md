# Plan: libMesh must not see the host's Boost (or any host dev package)

**Status: implemented.** `--with-boost=$STACK --with-vexcl=no` and the
build-time assertions are in `pkgs/libmesh/build.sh`; `assert_no_host_paths`
and the environment scrub are in `lib/build_common.sh`; the artifact-side
check is `check_libmesh_config_paths` in `test/run.sh`; `HOST_EXTRAS` runs
through `docker/Dockerfile.builder`, `docker/compose.yaml` and `stack.yml` to
`extended.yml`'s `host-boost` job. Measured results are in **Evidence** at the
end. `docs/DESIGN.md` states the constraint.

Kept as the record of the design and why it was cut this way. **What follows
is the plan as written before the work**, in the future tense.

## Context

`make all` on a Rocky 8 workstation with `boost-devel-1.66.0` (RPM, headers in
`/usr/include`) died in libMesh 1.7.9's nested `contrib/metaphysicl` configure:

```
checking for Boost headers version >= 1.47.0... /usr/include
checking for Boost's header version... 1_66
...
checking boost/system/error_code.hpp usability... no
configure: WARNING: boost/system/error_code.hpp: present but cannot be compiled
configure: error: cannot find boost/system/error_code.hpp
configure: error: .../contrib/metaphysicl/configure failed for contrib/metaphysicl
```

The clean CI containers never see this: they have no Boost at all.

Root cause, traced in the libMesh sources (v1.7.8 as the proxy for 1.7.9, plus
v1.8.0 and `devel`, and the metaphysicl commits each pins):

1. `contrib/metaphysicl/m4/common/vexcl.m4` — an *optional* probe for a GPU
   library libMesh never uses — calls Sigoure `BOOST_REQUIRE`, which probes
   `/opt/local/include /usr/local/include /opt/include /usr/include`, found 1.66,
   took `-I/usr/include`, and then `BOOST_CHRONO → BOOST_SYSTEM → BOOST_FIND_HEADER`
   whose default action-if-not-found is `AC_MSG_ERROR`. A found-but-unusable
   Boost is fatal inside an optional probe. The 1.7 branch pins metaphysicl
   `8b68f71` (2021-09), which has this; v1.8.0 and `devel` pin a 2025 metaphysicl
   whose `vexcl.m4` passes `[no]` (ERROR_ON_UNUSABLE) — there the same host
   Boost is only noise.
2. libMesh's own `m4/boost.m4` + `m4/ax_boost_base.m4` (identical across the
   three) walk `$BOOST_ROOT $BOOST_DIR /usr /usr/local /opt /opt/local`. Had
   metaphysicl not died first, libMesh would have adopted the host Boost:
   `LIBMESH_HAVE_EXTERNAL_BOOST 1` and `-I/usr/include/` in
   `libmesh_optional_INCLUDES`, which is what the installed `libmesh-config
   --include`, every `lib/pkgconfig/libmesh-*.pc` and (via them) `Make.common`
   emit; on 1.8.x also `timpi-config --cppflags`. This exists in every version;
   only the crash is 1.7.x-specific.
3. `checking for Boost headers ... /usr/include` — a path, not `yes` — proves the
   first attempt with plain `CPPFLAGS=-I$STACK/include` failed: **the conda
   compiler does not search the host `/usr/include`**. Only autoconf macros that
   probe host paths explicitly, or host env like `BOOST_ROOT`/`CPATH`, can leak
   the host in. That is the lever.
4. The bundled Boost subset (`contrib/boost`) exists in 1.7.x and 1.8.0 and is
   used only when no external Boost is found; `devel` removed it (2024-12).
   `--disable-boost` on 1.7/1.8 disables the subset too and changes the clean
   artifact; `--with-boost=no` is mishandled by libMesh's `CONFIGURE_BOOST` (it
   skips the whole `AX_BOOST_BASE` body, so `external_boost_found` stays `yes`:
   bogus `HAVE_EXTERNAL_BOOST`, no include path, no subset). Neither is usable.

The control every gate must match is what a clean container already produces:
`libmesh_config.h` with `LIBMESH_HAVE_BOOST 1` and `HAVE_EXTERNAL_BOOST` undef,
`include/boost/version.hpp` (1_61) installed, `metaphysicl_config.h` with
`HAVE_BOOST` undef, and no `/usr` or `/opt` anywhere in `libmesh-config`,
`Make.common` or the `.pc` files.

Upstream follow-ups, not this PR: libMesh's `--with-boost=no` handling; the 1.7
branch's metaphysicl pin predates the optional-Boost fix.

## Design

1. **Recipe pins** (`pkgs/libmesh/build.sh`): `--with-boost="${STACK}"` and
   `--with-vexcl=no`. With `--with-boost=<dir>`, `ax_boost_base.m4` tries only
   `-I<dir>/include`; nothing is there on a first pass, so libMesh falls back to
   `contrib/boost` (or to no Boost on `devel`), and a conda `libboost-headers`
   would be found as an in-stack external. Both flags reach `contrib/metaphysicl`
   (`AX_SUBDIRS_CONFIGURE` forwards every top-level argument), whose
   `BOOST_REQUIRE` then searches only `$STACK/include` and `$STACK` and ignores
   `BOOST_ROOT` — needed even with `--with-vexcl=no`, because `BOOST_REQUIRE` is
   `AC_DEFUN_ONCE` and hoisted, and alone would still record `HAVE_BOOST` in
   the installed `metaphysicl_config.h`. `--with-vexcl=no` skips the whole VexCL
   block: the fatal Boost library chain and an OpenCL `/usr/include` probe with
   it. **Boost comes from the stack or the bundle; the host is never consulted.**
2. **Fail fast, then assert the artifact** (same file): after `configure`,
   `include/libmesh/libmesh_config.h` must not define `LIBMESH_HAVE_EXTERNAL_BOOST`
   and must define `LIBMESH_HAVE_BOOST 1` iff the source has `contrib/boost`; the
   generated `contrib/bin/libmesh-config` and `.pc` files must name no path
   outside the stack. After `make install`, the same on the installed
   `libmesh-config --include --ldflags --libs`, `lib/pkgconfig/libmesh*.pc`,
   `timpi-config --cppflags` and `metaphysicl_config.h`. The generic check is
   `assert_no_host_paths` in `lib/build_common.sh`: strip `$STACK` and `$WORK`
   (the compose loop's `BUILD_ROOT` is under `/opt`), then no `/usr/` or `/opt/`
   may remain. `libmesh_config.h`, the generated `libmesh-config` and
   metaphysicl's `config.log` are saved next to `config.log` for the CI
   diagnostics artifact.
3. **Artifact-side gate** (`test/run.sh`, both modes): the same check on the
   installed `libmesh-config` and `.pc` files, wherever the tree now lives;
   skipped when `SLIM_PROFILE=runtime` shipped neither.
4. **Negative test in CI**: `ARG HOST_EXTRAS=""` in `docker/Dockerfile.builder`
   (declared *after* `FROM`, or `RUN` never sees it and the test passes
   vacuously; installed and `rpm -q`/`dpkg -s`-verified separately from the
   honest "base image lacks" line), `HOST_EXTRAS` in `compose.yaml`, a
   `host_extras` input in `stack.yml` (into the artifact slug and CONFIG string,
   a "Host extras present" step as positive control, and
   `&& inputs.host_extras == ''` on both publish steps — a dirtied builder must
   never reach GHCR under a content-hash tag that does not know about it), and
   `extended.yml` job `host-boost`: `almalinux:8`, `linux-64`, `boost-devel`.
   `almalinux:8` had never been a *builder* base in CI; the local clean
   `almalinux:8` control build separates that from the Boost question.
5. **Environment hygiene** (`activate_toolchain`): drop inherited `CPATH`,
   `C_INCLUDE_PATH`, `CPLUS_INCLUDE_PATH`, `OBJC_INCLUDE_PATH`, `LIBRARY_PATH`,
   `LD_RUN_PATH`, `CPPFLAGS`, `CFLAGS`, `CXXFLAGS`, `FFLAGS`, `FCFLAGS`,
   `LDFLAGS`, `PKG_CONFIG_PATH`, logging each — `make` hands `build.sh` the
   invoking shell's environment, a `module load` sets exactly these, and this
   function used to *append* the inherited `CPPFLAGS`/`LDFLAGS`. `LD_LIBRARY_PATH`
   is left alone.
6. **Docs**: the DESIGN.md constraint bullet and the A30 amendment, a CI.md row
   and reproduction line, an EXTENDING.md pitfall, this file.

Out of scope, recorded for later: the rest of libMesh's host probes —
`eigen.m4` (`/usr/include/eigen3`, `EIGEN_INC`; the pin would be
`--with-eigen-include=$STACK/include/eigen3`, *not* `$STACK/include` where the
bundled Eigen lands), XDR (`-I/usr/include/tirpc -ltirpc`; `--disable-xdr` is a
no-op under the 2.28 sysroot but not under a 2.17 one), `vtk.m4`
(`VTK_DIR=/usr`), `trilinos.m4` (`/usr/include/trilinos`), `nlopt`/`capnproto`
(env and `$PATH` only), `cppunit` (tests only). The gates turn each into a loud
build failure; pinning is one `HOST_EXTRAS` package at a time in `host-boost`
(`eigen3-devel libtirpc-devel …`, some in CRB/EPEL on el8), each its own
measured commit. Also noted: `fresh-solve (linux-64)` and `customer-demo-stack`
compute the same artifact slug in one extended run.

## Verification (as planned)

Control = the `dist/` tarball from `main`. (1) Reproduce on `main`: `almalinux:8`
+ `boost-devel`, expect the reported error and keep metaphysicl's `config.log`.
(2) Fix, rebuild dirty from a fresh `$STACK` with `CPATH`, `BOOST_ROOT` and
`CPPFLAGS` set in the environment: green, assertions pass, scrub lines logged,
`libmesh_config.h`/`metaphysicl_config.h`/`libmesh-config` identical to the
control, verify on `almalinux:8`. (3) Clean `almalinux:9` and `almalinux:8`
controls after the change: identical. (4) The gate must *fail* a build-dir
`libmesh-config` with `-I/usr/include/` injected. (5) Fast gate. (6) PR, then
dispatch `extended.yml` with `only=host-boost`.

## Evidence

All local builds are `linux-aarch64`, native Docker on Apple Silicon, from a
fresh build root each (`-p <name>`), the branch mounted at `/src`. "Contract
files" = `include/libmesh/libmesh_config.h`, `include/metaphysicl/metaphysicl_config.h`,
`bin/libmesh-config`, `lib/pkgconfig/libmesh-opt.pc`, `etc/libmesh/Make.common`,
`include/boost/version.hpp`, compared ignoring `*_BUILD_HOST/USER/DEVSTATUS`.

**Before the fix, `almalinux:8` + `boost-devel-1.66.0-13.el8`:**

- aarch64 (local, `main`): `make conda build` **succeeds** — the crash does not
  happen here. libMesh: `checking for boostlib >= 1.57.0... yes / <<< Using
  external boost installation >>>`; metaphysicl finds `/usr/include` and its
  `boost/system/error_code.hpp` compiles. Installed: `LIBMESH_HAVE_EXTERNAL_BOOST 1`,
  `METAPHYSICL_HAVE_BOOST 1` (+ chrono/date_time/filesystem/system/thread),
  `libmesh-config --include` = `… -I$STACK//include -I/usr/include`. The new
  `test/run.sh` check run against this tree fails on three lines (`--include`
  and two `.pc` files) — the negative control for the gate.
- x86-64 (CI, `extended.yml` `only=host-boost` on a throwaway branch with the
  plumbing but not the fix, run 32068547208): the "Host extras present" step
  prints `#define BOOST_LIB_VERSION "1_66"`; `make build` dies 12 min in with
  the reported error verbatim (`boost/system/error_code.hpp: present but
  cannot be compiled … configure: error: cannot find boost/system/error_code.hpp
  … contrib/metaphysicl/configure failed`). The saved
  `libmesh-metaphysicl-config.log` has the compiler's reason:
  `In file included from /usr/include/stdlib.h:55 … /usr/include/bits/floatn.h:86:20:
  error: redeclaration of C++ built-in type '_Float128'` (and `_Float32`,
  `_Float64`, `_Float32x`, `_Float64x`). The `-I/usr/include` the Boost probe
  added put the host's glibc 2.28 headers ahead of the sysroot's, and el8's
  `bits/floatn.h` typedefs types GCC 14 treats as C++ built-ins; the aarch64
  header takes a different branch, which is why aarch64 silently contaminates
  where x86-64 crashes. Not a Boost incompatibility.

**After the fix:**

- `almalinux:8` + `boost-devel`, with `CPATH=/usr/include`, `BOOST_ROOT=/usr`,
  `CPPFLAGS=-I/usr/include`, `LIBRARY_PATH=/usr/lib64` in the environment:
  `make all` exit 0. `petsc.log`/`libmesh.log` open with three `scrubbed
  inherited …` lines (CPATH, LIBRARY_PATH, CPPFLAGS); libMesh `<<< Using
  libmesh-provided boost in ./contrib >>>`; metaphysicl `cannot find Boost
  headers version >= 1.47.0` (notice); `Boost: libMesh's bundled subset`, `no
  host paths in configure's libmesh-config and libmesh*.pc`, `no host paths in
  installed libmesh-config, libmesh*.pc, timpi-config`. Contract files identical
  to the pre-change `main` tarball except `LIBMESH_CONFIGURE_INFO` now lists the
  two flags. `verify` on a pristine `almalinux:8`: validate 0/0, smoke relocated
  OK with `libmesh-config: no host paths in the compile-line contract`.
- Clean `almalinux:8` and clean `almalinux:9` (default): `make all` exit 0;
  contract files identical to the dirtied build's. The change does not alter
  the clean artifact, and `almalinux:8` works as a builder.
- A30, measured: on the clean `almalinux:9` prefix after `make build`, delete
  the libmesh stamp and `make libmesh` again → `<<< Using external boost
  installation >>>` (its own installed subset), then the new assertion stops it
  before compiling: `configure found an EXTERNAL Boost … or this is a rebuild
  over a populated ${STACK} (A30) …`.
- Under Rosetta (x86-64 on the Mac) the pre-fix reproduction did not get as far
  as libMesh: PETSc's `--download-ml` compile took `Illegal instruction` in
  `cc1plus` — an emulation limit, not a finding about this change; the CI run
  above is the x86-64 measurement.
- `host-boost` on the branch itself (run 32070003135, x86-64, `almalinux:8` +
  `boost-devel`): build 37 min, verify on `almalinux:8` and `ubuntu:24.04`
  green — the same job that was red pre-fix. `ci.yml` on the branch: both
  platforms and all five verify images green.

Follow-on (Boost/Eigen/tirpc from the env, a second profile):
[`../OPTIONAL-PACKAGES-AND-SECOND-PROFILE.md`](../OPTIONAL-PACKAGES-AND-SECOND-PROFILE.md).
