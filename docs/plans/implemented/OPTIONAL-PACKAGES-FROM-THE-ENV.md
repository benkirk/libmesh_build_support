# Plan: libMesh's optional packages come from the env, not from the host

**Status: implemented.** The env additions are in `conda/bootstrap.sh` and
`conda/env/*.yml` (locks refreshed); the flags, the preflight, the feature
table and the compile-line contract are in `pkgs/libmesh/build.sh`; the
include-path check is in `test/run.sh`; `HOST_REPOS` runs through
`docker/Dockerfile.builder`, `docker/compose.yaml` and `stack.yml` to
`extended.yml`'s `dirty-host` job. Measured results are in **Evidence**.

Follow-on to [`HOST-BOOST-ISOLATION.md`](HOST-BOOST-ISOLATION.md), which closed
the Boost probe and listed the rest as out of scope. The second half of that
handoff — a second PETSc/libMesh/Trilinos pairing in CI — is still
[`SECOND-PROFILE.md`](SECOND-PROFILE.md).

## Context

#28 established that the conda compiler never sees the host's `/usr/include` on
its own: only autoconf macros that probe `/usr`, `/opt` and `$FOO_ROOT`
explicitly let the host in. It fixed the one probe that had crashed a build.
libMesh makes several more — `eigen.m4`, the XDR block, `tecio.m4`, `glpk.m4`,
`nlopt.m4` — and each writes what it finds into `libmesh_optional_INCLUDES`,
the text `libmesh-config --include` hands a customer.

Reading those m4 files answered a question nobody had asked: two of the
features were not leaking, they were **off**.

| | on `main` | why |
|---|---|---|
| `LIBMESH_HAVE_XDR` | undef | the glibc 2.28 sysroot has no usable `rpc/xdr.h`; glibc removed sunrpc in 2.32 |
| `LIBMESH_HAVE_TECPLOT_API` | undef | `tecio.m4` gates on `X11/Intrinsic.h` and disables the feature in one line when it is missing — `--enable-tecio` has been in the recipe since v0 |
| Boost | bundled 1.61 subset | a fraction of the library; `devel` has deleted it |
| Eigen | bundled copy | in `$STACK/include/Eigen`, and *not* exported: an internal Eigen goes to `libmesh_contrib_INCLUDES`, an external one to `libmesh_optional_INCLUDES` |
| `LIBMESH_HAVE_GLPK` | undef | `--disable-glpk`, inherited from v0 |

HDF5, NetCDF-4 and ExodusII were already right and are now asserted rather
than assumed.

## Design

1. **The env** gains `libboost-headers`, `eigen=3.4.*`, `libtirpc`,
   `xorg-libxt`, `xorg-xorgproto` and `glpk`. Eigen is pinned because
   conda-forge's newest is Eigen 5, which passes libMesh's `>= 3.1.2` test and
   is not a version either supported release has been built against.
   `xorg-xorgproto` is not redundant: `Xlib.h`'s first include is the protocol
   header `X11/X.h`, which conda-forge depends on only at build time.
2. **NOT nlopt.** Every conda-forge nlopt build ever published carries the
   Python bindings and depends on numpy and a `python_abi`; there is no
   `libnlopt`. That would put numpy in the artifact and a python extension
   module linking `libpython` into a tree whose python `prune.list` removes.
   `--disable-nlopt` closes the `/usr` probe instead, which was the point.
3. **Every probe pointed into `$STACK`** (`pkgs/libmesh/build.sh`):
   `--with-eigen-include=$STACK/include/eigen3` (not `$STACK/include`, where
   libMesh's own bundled copy lands — A30 with a different package),
   `--with-tecio-x11-include`, `--enable-glpk` with both paths, and XDR by one
   of two roads chosen by asking the configure script what it accepts rather
   than by parsing a version: `--with-xdr-include`/`--with-xdr-libname` where
   they exist (1.8+), the ambient `CPPFLAGS`/`LIBS` where they do not (1.7.x).
4. **`include/rpc -> tirpc/rpc`**, a relative symlink created before configure.
   libMesh's public `xdr_cxx.h` includes `<rpc/rpc.h>` under `HAVE_XDR`, and on
   1.7.x there is no way to export the tirpc include path at all —
   `libmesh_optional_INCLUDES` is cleared at the top of the macro, so even a
   command-line assignment is wiped, and `libmesh-config --cppflags` carries
   per-METHOD flags only. Without the link, turning XDR on breaks a header that
   compiles today.
5. **Assertions**, because every one of these fails silently: a required-on /
   required-off table over `libmesh_config.h` (configure's copy and the
   installed one); a preflight that the env holds what the flags point at (a
   stale lock is how it would not); and a **compile-line contract** — ask
   `libmesh-config` for the flags, hand them to the compiler, compile a TU
   including `libmesh.h`, `xdr_cxx.h` and `dense_matrix.h`.
6. **`test/run.sh`**: every `-I` `libmesh-config` emits must name a directory
   that exists inside the tree. `assert_no_host_paths` strips `$STACK` *and*
   `$WORK`, so an include into the build tree passes it; several libMesh
   contrib includes are written as `$(top_srcdir)/contrib/...`.
7. **The negative test grows** from `host-boost` to `dirty-host`: one distro
   dev package per probe, with `HOST_REPOS` to reach the ones in EPEL and
   PowerTools.

## Evidence

All local builds are `linux-aarch64`, native Docker on Apple Silicon, from a
fresh build root each (`-p <name>`), the branch mounted at `/src`. "Contract
files" = `include/libmesh/libmesh_config.h`,
`include/metaphysicl/metaphysicl_config.h`, `bin/libmesh-config`,
`lib/pkgconfig/libmesh-opt.pc`, `etc/libmesh/Make.common`, compared ignoring
`*_BUILD_HOST/USER/DATE/DEVSTATUS`.

**Clean build** (`almalinux:9` builder, fresh `$STACK`): `make all` green end to
end, `distcheck OK` including the unpack under a path containing a space. The
recipe's own lines:

```
=== libmesh: linked include/rpc -> tirpc/rpc
=== libmesh: linked include/netconfig.h -> tirpc/netconfig.h
=== libmesh: configure's libmesh_config.h: every required feature on, every required-absent one off
=== libmesh: Boost: external, from the stack (this libMesh bundles a subset; unused)
=== libmesh: no host paths in configure's libmesh-config and libmesh*.pc
=== libmesh: no host paths in installed libmesh-config, libmesh*.pc, timpi-config
=== libmesh: installed libmesh_config.h: every required feature on, every required-absent one off
=== libmesh: no host paths in installed metaphysicl_config.h
=== libmesh: compile-line contract: libmesh-config's flags compile libMesh's headers
```

`include/rpcsvc` is skipped by the `-e` guard: krb5 already ships one, and
nothing libMesh includes needs tirpc's.

**Against the pre-change artifact**, the contract files differ in exactly these
places and nowhere else:

| file | change |
|---|---|
| `libmesh_config.h` | `CONFIGURE_INFO` (the new flags); `HAVE_EXTERNAL_BOOST`, `HAVE_GLPK`, `HAVE_TECPLOT_API`, `HAVE_TECPLOT_API_112`, `HAVE_XDR` all `undef` → `1` |
| `metaphysicl_config.h` | `HAVE_BOOST` `undef` → `1` |
| `libmesh-config`, `libmesh-opt.pc` | `-I${prefix}/include/eigen3` and `-lglpk` added |
| `Make.common` | identical — it calls `libmesh-config --include` at run time |

No `-ltirpc` in `--libs` and no tirpc `-I` anywhere: the library arrives through
`libmesh_opt.so`'s `DT_NEEDED`, the headers through the symlink. Every path is
`${prefix}`-relative.

**Dirtied builder** (`almalinux:8` + `epel-release powertools` +
`boost-devel eigen3-devel libtirpc-devel libXt-devel glpk-devel cppunit-devel`,
built with `CPATH`, `CPPFLAGS`, `LIBRARY_PATH`, `BOOST_ROOT`, `EIGEN_INC`,
`EIGEN3_INCLUDE`, `GLPK_DIR`, `NLOPT_DIR` and `TIRPC_DIR` all pointed at the
host): `make all` green, and **all five contract files byte-identical to the
clean build's**. The environment scrub logged `CPATH`, `LIBRARY_PATH` and
`CPPFLAGS`; the `*_DIR`/`*_INC` variables are not scrubbed and did not need to
be — the explicit flags win. GLPK is the clean fingerprint: the artifact has
**5.0**, conda's, where el8's `glpk-devel` is 4.65.

**Size.** 110,662,547 → 129,341,577 bytes (+18.7 MB, +17%), 58 → 63 conda
packages (`libboost-headers` 1.91.0, `eigen` 3.4.0, `libtirpc` 1.3.7, `glpk`
5.0, `gmp` 6.3.0). Boost's header set is the bulk of it. `SLIM_PROFILE=runtime`
drops `include/` and so pays none of it. The X11 packages are pruned; one empty
`include/X11/` directory survives, since prune removes files rather than
directories.

## What this cost, and what found it

Four defects, none of which was in the plan, each caught by a different check:

1. **`xorg-libxt` is not enough.** `Xlib.h`'s first include is `X11/X.h`, which
   conda-forge ships in `xorg-xorgproto` and depends on only at build time. The
   env had `Intrinsic.h` and `Xlib.h` and could compile neither. *Caught by the
   required-on table*, one stage after the flag was added.
2. **Enabling XDR would have broken a public header.** `xdr_cxx.h` includes
   `<rpc/rpc.h>` under `HAVE_XDR`, which no consumer's include path reached.
   *Caught by the compile-line contract.*
3. **Then `rpc/types.h` needed `netconfig.h`**, which tirpc keeps beside `rpc/`
   rather than inside it. *Caught by the compile-line contract again*, on a
   clean build, after every other check had passed.
4. **`xorg-libx11` ships 14 `share/X11/locale/*/Compose` files** containing the
   build prefix. *Caught by `validate.sh`* — and the reason the X11 prune is
   required rather than tidy.

And one defect in a check rather than in the build: the first version of the
`-I` test split `libmesh-config`'s flag string on whitespace, so it failed the
one place built to catch exactly that — `distcheck`, which unpacks into
`.../a b/c` to keep A32 honest.
