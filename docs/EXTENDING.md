# Adding your own packages

Anything in `site/*/` is discovered automatically and joins the build graph.
`site/` is gitignored, so you can layer proprietary recipes on top of this repo
without forking it or carrying a patch. How the pipeline treats what you install
is in [`DESIGN.md`](DESIGN.md).

```sh
cp -r pkgs/_template site/mysolver
$EDITOR site/mysolver/pkg.mk site/mysolver/build.sh
make build
```

## Worked example

`examples/site-package/` is a complete, working package — copy it and edit:

```sh
cp -r examples/site-package site/my-solver
make build
```

It lives under `examples/` rather than `site/` so it can be tracked and
*exercised*: the full pipeline is run with it in place, through `patchelf`,
`validate` and `distcheck` like anything else. It also shows two things the
template does not: a package with **no `PKG_URL`** (it generates its own
sources), and one that declares `PKG_DEPS`.

## Getting your package tested

Install an executable into **`$STACK/libexec/stack-tests/`** and `test/run.sh`
will run it — serially and under `mpiexec`, in place and again from the
relocated tree inside `distcheck`. No edit to the harness is needed.

The assertion is deliberately weak — exit 0, and some output — because the
harness cannot know what your program prints. What it does check is the part
that matters: the binary *loads*, every library resolved, from wherever the tree
now lives. The directory is its own namespace because `libexec/` is shared with
conda packages.

## `pkg.mk` contract

```make
PKG_NAME    := mysolver
PKG_VERSION := 2.1.0
PKG_URL     := https://example.com/mysolver-2.1.0.tar.gz
PKG_DEPS    := libmesh          # other package names; conda env is implicit
PKG_STAGE   := build            # build (default) | optional
PKG_SOURCE  := tarball          # tarball (default) | git

$(eval $(call declare_pkg))
```

`declare_pkg` snapshots these into namespaced variables, so every recipe can use
the same plain `PKG_*` names without clobbering its neighbours. Assign with
`:=`, never `?=` — the snapshot clears each name afterwards, leaving it
*defined-but-empty*, so a `?=` in any package included after the first silently
does nothing.

`PKG_DEPS` becomes a stamp prerequisite, so independent packages build
concurrently under `make -jN`. `PKG_STAGE := optional` still gives the package
its own target (`make mysolver`) and it is still relocated, validated and packed
if built — it just isn't built by `make build`. `make print-config` lists both
sets.

`PKG_SOURCE := git` builds from a repository instead of a release archive and
then needs `PKG_GIT_URL` and `PKG_GIT_REF` (any tag, branch or SHA).
`pkgs/libmesh/` is the worked example — it exposes the choice as
`LIBMESH_SOURCE`, so `make LIBMESH_SOURCE=git build` switches it without editing
a tracked file. **The stamp does not know which mode it was built in**: the rule
depends on dependency stamps and `build.sh`, not on the version, URL or source
mode, so switching modes (or bumping a version) over an existing build is a
silent no-op. Delete the stamp, or `make clean`, when changing *what* is built.

## `build.sh` contract

Receives `STACK`, `WORK`, `SRC_CACHE`, `CONDA_HOME`, `NPROC`, `MAKE_J_L`,
`TARGET_PLATFORM`, `BLAS_PROVIDER`, `MPI_FAMILY`, `RPATH_MODE`, `ISA_BASELINE`,
`USE_WRAPPERS`, `TOPDIR`, and its own `PKG_NAME` / `PKG_VERSION` / `PKG_URL` /
`PKG_DIR` / `PKG_SOURCE` / `PKG_GIT_URL` / `PKG_GIT_REF`.

Prefer `make $MAKE_J_L` over a bare `make -j$NPROC`: it carries a `-l` load cap,
which is what keeps a shared build host usable.

Sourcing `lib/build_common.sh` gives you `activate_toolchain`, `list_build_env`,
`download_src`, `fetch_git`, `fetch_src`, `log`, `require`, `clean_build_tmp`,
and a `BUILD_TMP` scratch directory. Call `list_build_env` right after
`activate_toolchain` — when a build fails three hours in, the log is all you
have. `fetch_src` dispatches on `PKG_SOURCE` and leaves the sources at the same
path either way; `fetch_git` keeps a bare mirror in `SRC_CACHE`.

Where the tools come from decides what your recipe must `require`: **git is in
the builder image** with `curl` and `tar` — fetching is the host's job;
**autoconf, automake and libtool are in the conda env** and pruned from the
artifact — generators belong to the toolchain, where one pin behaves the same on
every base image. A git-mode recipe runs its own bootstrap; the framework
fetches, it does not autoreconf for you:

```sh
case "${PKG_SOURCE}" in
  tarball) require curl tar ;;
  git)     require git autoconf automake libtool ;;
esac
fetch_src
[ "${PKG_SOURCE}" = git ] && ( cd "${src}" && ./bootstrap )
```

Three rules that matter:

1. **Install into `$STACK`.** One merged prefix is what makes every RPATH a
   simple `$ORIGIN/../lib`. Do not invent a sub-prefix.
2. **Build shared.** `--enable-shared --disable-static`, or the CMake
   equivalent. Link with an *absolute* rpath into `$STACK/lib`
   (`activate_toolchain` sets this); `relocate/patchelf.sh` converts it to
   `$ORIGIN` later. Do not inject `$ORIGIN` at configure time — libtool mangles
   it, and the normalization pass exists so you don't have to fight that.
3. **Do not set `-march` yourself.** `activate_toolchain` puts the ISA wrappers
   ahead of everything on `PATH`, and they append `-march=$ISA_BASELINE` after
   whatever your build system passes. Anything you set will simply lose; if your
   package needs a *higher* baseline, raise `ISA_BASELINE_*` — a decision about
   the whole artifact, not one package. See `wrappers/README.md`.

Logs land in `$WORK/logs/<name>.log`; on failure the tail is printed.

## Hooks

`hooks/<stage>/*.sh` run in sorted order with the same environment. Stages:
`pre-conda`, `post-conda`, `pre-build`, `post-build`, `pre-test`, `post-test`,
`pre-relocate`, `post-relocate`, `pre-slim`, `post-slim`, `pre-dist`,
`post-dist`. `pre-build` runs once, before the first package, not once per
package. Use these for site policy — extra validation, signing, publishing —
rather than editing tracked files.

## Instruction-set baseline

Your package is compiled through a wrapper layer that appends
`-march=$(ISA_BASELINE)` **last**, so it wins over anything your build system
sets. Defaults are `x86-64-v2` and `armv8.1-a` (`ISA_BASELINE_X86` /
`ISA_BASELINE_AARCH64` in `config.mk`); `-march=native` is rejected outright.
Whatever the wrappers do, `relocate/isa-scan.py` disassembles every shipped
object and the validator fails on anything above the baseline; libraries that
dispatch on CPUID at runtime (OpenBLAS, MKL, OpenSSL) get their own bucket. If
your package does its own runtime dispatch, say so. Why none of this is
belt-and-braces: `DESIGN.md`, the ISA section.

## The shipped artifact has no compiler

`conda/prune.list` drops `gcc_impl` and the sysroot — about 530 MB — so the
tarball ships `mpicc` and nothing behind it. That is deliberate: the supported
way to build against this stack is **inside the template, before the prune**,
which is what `site/` is for. A customer compiling against the shipped tarball
uses their own compiler; `mpicc -show` and `MPICH_CC` still serve them.

## Things that will bite you

- **`dlopen`ed plugins are invisible to `ldd`.** If your package loads modules
  at runtime, add them to `stack/etc/entrypoints` or `SLIM_PROFILE=runtime` will
  prune them and the failure will only appear after relocation.
- **Absolute paths in generated text files** (`.pc`, `*Config.cmake`,
  `*-config` scripts) must be rewritten. `relocate/fixup-text.sh` handles the
  common cases; check yours with `grep -r "$BUILD_ROOT" "$STACK"`.
- **Libtool `.la` files** are removed wholesale — they are a relocation
  landmine. Don't depend on them.
- **Make fragments cannot survive a space in the install path** — GNU make's
  path functions are list functions. Binaries and `.pc` files are fine; make
  integration you install inherits the limitation (`DESIGN.md`, A32).
- **A source package cannot be rebuilt over its own previous install** — the
  headers it installed change what `configure` finds next time (A30). The build
  that counts starts from a clean `$STACK`.
