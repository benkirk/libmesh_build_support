# Adding your own packages

Anything in `site/*/` is discovered automatically and joins the build graph.
`site/` is gitignored, so you can layer proprietary recipes on top of this repo
without forking it or carrying a patch.

```sh
cp -r pkgs/_template site/mysolver
$EDITOR site/mysolver/pkg.mk site/mysolver/build.sh
make build
```

## `pkg.mk` contract

```make
PKG_NAME    := mysolver
PKG_VERSION := 2.1.0
PKG_URL     := https://example.com/mysolver-2.1.0.tar.gz
PKG_DEPS    := libmesh          # other package names; conda env is implicit

$(eval $(call declare_pkg))
```

`declare_pkg` snapshots these into namespaced variables, so every recipe can use
the same plain `PKG_*` names without clobbering its neighbours.

`PKG_DEPS` becomes a stamp prerequisite, so independent packages build
concurrently under `make -jN`.

## `build.sh` contract

Receives `STACK`, `WORK`, `SRC_CACHE`, `CONDA_HOME`, `NPROC`, `BLAS_PROVIDER`,
`MPI_FAMILY`, `RPATH_MODE`, `TOPDIR`, and its own `PKG_NAME` / `PKG_VERSION` /
`PKG_URL` / `PKG_DIR`.

Sourcing `lib/build_common.sh` gives you `activate_toolchain`, `download_src`,
`log`, `require`, `clean_build_tmp`, and a `BUILD_TMP` scratch directory.

Two rules that matter:

1. **Install into `$STACK`.** One merged prefix is what makes every RPATH a
   simple `$ORIGIN/../lib`. Do not invent a sub-prefix.
2. **Build shared.** `--enable-shared --disable-static`, or the CMake
   equivalent. Link with an *absolute* rpath into `$STACK/lib`
   (`activate_toolchain` sets this for you); the `$ORIGIN` conversion happens
   later in `relocate/patchelf.sh`. Do not try to inject `$ORIGIN` at configure
   time — libtool mangles it, and a normalization pass exists precisely so you
   don't have to fight that.

Logs land in `$WORK/logs/<name>.log`; on failure the tail is printed.

## Hooks

`hooks/<stage>/*.sh` run in sorted order with the same environment. Stages:
`pre-conda`, `post-conda`, `post-build`, `pre-relocate`, `post-relocate`,
`pre-slim`, `post-slim`, `post-dist`.

Use these for site policy — extra validation, signing, publishing — rather than
editing tracked files.

## Things that will bite you

- **`dlopen`ed plugins are invisible to `ldd`.** If your package loads modules
  at runtime, add them to `stack/etc/entrypoints` or `SLIM_PROFILE=runtime` will
  prune them and the failure will only appear after relocation.
- **Absolute paths in generated text files** (`.pc`, `*Config.cmake`,
  `*-config` scripts) must be rewritten. `relocate/fixup-text.sh` handles the
  common cases; check yours with `grep -r "$BUILD_ROOT" "$STACK"`.
- **Libtool `.la` files** are removed wholesale — they are a relocation
  landmine. Don't depend on them.
