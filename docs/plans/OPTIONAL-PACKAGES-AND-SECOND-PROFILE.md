# Plan: libMesh's optional packages from the env, and a second profile

**Status: not started.** Handoff from PR #28 (host Boost isolation), written
while that work was fresh; the facts below were measured or read there and are
the reason this is cut into two PRs and not one. Keep it short on purpose.

## Goal

libMesh's `--enable-<optional>` packages that today come from nowhere (Boost
bundled subset, Eigen bundled, XDR off, glpk/nlopt/cppunit off) should come
from the conda env, so the features are really on and the artifact still
carries no host path — and that should hold on two profiles, each its own
PETSc / libMesh / Trilinos pairing, not just `default`.

## What is already true (from #28)

- `--with-boost=$STACK` finds an in-stack Boost as an *external* one; the
  bundled subset is only the fallback. Putting Boost in the env changes the
  recipe's **assertions**, not the flag: "no `LIBMESH_HAVE_EXTERNAL_BOOST`"
  becomes "external only if under `$STACK`" (the path check already says that);
  the post-install `metaphysicl_config.h` `HAVE_BOOST` check must allow the
  in-stack case; record provenance (`bundled | stack | none`) in the manifest.
- `assert_no_host_paths` (`lib/build_common.sh`) and `test/run.sh`'s
  `check_libmesh_config_paths` are the gates for every package here.
- The `host-boost` job (`extended.yml`, `HOST_EXTRAS`) is the negative test.
  Once Boost/Eigen/tirpc are in the env, give it `boost-devel eigen3-devel
  libtirpc-devel` too: the stack's copies must win over the host's. At that
  point it is no longer about Boost — rename it.
- `PROFILE` exists (`profiles/*.mk`): `default` = PETSc 3.20.5 / libMesh 1.7.9
  / Trilinos 14-4-0; `bleeding` = 3.22.2 / 1.8.0 / 16-0-0, never built in CI.
- libMesh 1.8.0: `contrib/boost` still present; metaphysicl pin is the
  non-fatal one; `timpi-config --cppflags` carries the Boost include
  (`m4/boost.m4` exports `timpi_CPPFLAGS`), so the artifact check must keep
  covering `timpi-config`. `devel` has no `contrib/boost` at all — an in-stack
  Boost is what makes the git-source path consistent with the tarball one.

## PR 1 — optional packages from the env (default profile)

| libMesh option | conda-forge | do | notes |
|---|---|---|---|
| Boost | `libboost-headers` | env | header-only is all libMesh wants; not `libboost` (compiled) |
| Eigen | `eigen` | env | `--with-eigen-include=$STACK/include/eigen3` — **not** `$STACK/include`, where the bundled one would land; libMesh headers include Eigen, so the devel artifact must ship it |
| XDR | `libtirpc` | env | 1.7's m4 hard-codes `/usr/include/tirpc`: needs `-I$STACK/include/tirpc` on CPPFLAGS and `-ltirpc`; check whether 1.8's `xdr.m4` grew `--with-xdr-include` |
| glpk, nlopt | `glpk`, `nlopt` | env | cheap; check the `--with-*` arg names in `m4/glpk.m4`, `m4/nlopt.m4` |
| cppunit | `cppunit` | env (tests only) | enables `make check` as an extended job later |
| SLEPc | via PETSc `--download-slepc` | maybe | libMesh infers `SLEPC_DIR` from `PETSC_DIR` |
| VTK | `vtk-base` | not now | heavy, Qt-adjacent; only if someone needs the I/O |
| curl / DAP | — | off | `--disable-dap` is deliberate |
| TBB | — | off | thread model is pthread |

Then: prune/slim — `SLIM_PROFILE=runtime` drops `include/` anyway; `devel`
keeps the new headers, so measure the tarball growth (Boost's header set is the
bulk) and put the number in DESIGN.md. Refresh the locks (`make conda
IGNORE_LOCK=1`, `make conda-lock`). Verify: clean and dirtied builds, both
platforms, contract files compared as in
`implemented/HOST-BOOST-ISOLATION.md`.

## PR 2 — the second pairing in CI

- Decide the pairing by what libMesh's own 1.8 CI uses, not "newest"; bump
  `bleeding` (1.8.1?) or add `next`.
- Per-profile env pins where the sources demand them (`cmake<4` is a Trilinos
  14-4-0 constraint, Trilinos 16 wants newer; `python<3.13` is PETSc 3.20.5's),
  which likely puts the profile into the env-spec/lock name and into
  `.github/scripts/inputs-sha.sh`.
- CI cost is the real decision: 2 profiles × 2 platforms doubles `ci.yml`.
  Suggested: second profile on `linux-64` only in `ci.yml`, both platforms in
  `extended.yml`, until it has been green for a while.

## Do first, cheaply

1. The table above against the actual m4 in the two libMesh versions — that is
   the document people will argue about; get it right before touching the env.
2. What `devel` does with an in-stack Boost (`LIBMESH_SOURCE=git` on the
   env from PR 1), since the git-source job is where the design meets the
   future.
