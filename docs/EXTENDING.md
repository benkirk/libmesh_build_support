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
concurrently under `make -jN`.

`PKG_SOURCE := git` builds from a repository instead of a release archive, and
then two more variables are required:

```make
PKG_GIT_URL := https://github.com/example/mysolver.git
PKG_GIT_REF := v2.1.0           # any tag, branch or SHA
```

`pkgs/libmesh/` is the worked example — it exposes the choice as
`LIBMESH_SOURCE`, so `make LIBMESH_SOURCE=git build` switches it without editing
a tracked file.

**The stamp does not know which mode it was built in.** `mk/pkg.mk`'s rule
depends on dependency stamps and `build.sh`, not on the version, URL or source
mode, so `make LIBMESH_SOURCE=git build` over an existing tarball build is a
silent no-op. Delete the stamp (or `make clean`) when changing *what* is built
rather than how — the same caveat already applies to a version bump.

`PKG_STAGE` decides whether `make build` pulls the package in. `build`, the
default, puts it in the default graph. `optional` still gives it its own target
(`make mysolver`) and it still gets relocated, validated and packed if it has
been built — it just isn't built automatically. `make print-config` lists both
sets.

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
have.

`fetch_src` dispatches on `PKG_SOURCE`, so one call covers both modes and leaves
the sources at the same path either way. `fetch_git` caches a **bare mirror** in
`SRC_CACHE` and checks out the ref detached, with submodules — a mirror rather
than a shallow clone because `--depth 1` cannot check out an arbitrary SHA or
serve a different ref later from the same cache.

Where the tools come from is a split worth knowing, because it decides what your
recipe must `require`:

- **git is in the builder image**, alongside `curl` and `tar`. Fetching sources
  is the host's job.
- **autoconf, automake and libtool are in the conda env**, alongside `m4` and
  `cmake`, and are pruned from the artifact. Anything that compiles or generates
  belongs to the toolchain, where one pin behaves the same on every base image.

So a git-mode recipe requires them itself and runs its own bootstrap — the
framework fetches, it does not autoreconf for you:

```sh
case "${PKG_SOURCE}" in
  tarball) require curl tar ;;
  git)     require git autoconf automake libtool ;;
esac
fetch_src
[ "${PKG_SOURCE}" = git ] && ( cd "${src}" && ./bootstrap )
```

Two rules that matter:

1. **Install into `$STACK`.** One merged prefix is what makes every RPATH a
   simple `$ORIGIN/../lib`. Do not invent a sub-prefix.
2. **Build shared.** `--enable-shared --disable-static`, or the CMake
   equivalent. Link with an *absolute* rpath into `$STACK/lib`
   (`activate_toolchain` sets this for you); the `$ORIGIN` conversion happens
   later in `relocate/patchelf.sh`. Do not try to inject `$ORIGIN` at configure
   time — libtool mangles it, and a normalization pass exists precisely so you
   don't have to fight that.
3. **Do not set `-march` yourself.** `activate_toolchain` puts the ISA wrappers
   ahead of everything on `PATH`, and they append `-march=$ISA_BASELINE` after
   whatever your build system passes — because `-march` is last-wins and
   `CFLAGS` are injected first. Anything you set will simply lose. If your
   package needs a *higher* baseline, raise `ISA_BASELINE`; that is a decision
   about the whole artifact, not about one package. See `wrappers/README.md`.

Logs land in `$WORK/logs/<name>.log`; on failure the tail is printed.

## Worked example

`examples/site-package/` is a complete, working package — copy it and edit:

```sh
cp -r examples/site-package site/my-solver
make build
```

It is kept under `examples/` rather than `site/` so it can be tracked, and so it
is *exercised* rather than merely described: the full pipeline is run with it in
place, and it goes through `patchelf`, `validate` and `distcheck` like anything
else. It also shows two things the template does not: a package with **no
`PKG_URL`** (it generates its own sources), and one that declares `PKG_DEPS`.

## Getting your package tested

Install an executable into **`$STACK/libexec/stack-tests/`** and `test/run.sh`
will run it — serially and under `mpiexec`, in place and again from the
relocated tree inside `distcheck`. No edit to the harness is needed.

The assertion is deliberately weak: exit 0, and some output. The harness cannot
know what your program prints. What it does check is the part that matters here
— that the binary *loads*, with every library resolved, from wherever the tree
now lives.

Note the directory: `libexec/` itself is shared with conda packages (rdma-core
ships an executable there), so the extension point gets its own namespace rather
than scooping up whatever happens to be executable.

## Known limitation: whitespace in the install path

The **binaries** work from a path containing a space — `distcheck` unpacks into
one on every run and all objects resolve. The **make-based build integration**
does not: libMesh's example Makefiles and PETSc's `lib/petsc/conf/*` locate the
prefix from their own position, and GNU make's path functions are list
functions. With the tree at `.../a b/c`, `$(realpath …)` returns the right
string but `$(dir …)` and `$(abspath …)` split it on the space.

This is not something a makefile can work around — make cannot represent a
filename containing a space. `validate.sh` reports it rather than failing, and
`.pc` files and `libmesh-config` are unaffected. Install somewhere without
spaces if you intend to build against the stack with make.

## Hooks

`hooks/<stage>/*.sh` run in sorted order with the same environment. Stages:
`pre-conda`, `post-conda`, `pre-build`, `post-build`, `pre-test`, `post-test`,
`pre-relocate`, `post-relocate`, `pre-slim`, `post-slim`, `pre-dist`,
`post-dist`.

`pre-build` runs once, before the first package, not once per package.

Use these for site policy — extra validation, signing, publishing — rather than
editing tracked files.

## Instruction-set baseline

Your package is compiled through a wrapper layer that appends
`-march=$(ISA_BASELINE)` **last**, so it wins over anything your build system
sets. Defaults are `x86-64-v2` and `armv8-a`; override with `ISA_BASELINE_X86` /
`ISA_BASELINE_AARCH64` in `config.mk`.

This is not belt-and-braces. `-march` is last-wins on a gcc command line and
`CFLAGS` are injected first, so a build system that appends its own `-march`
silently beats any baseline set through the environment. The failure mode is a
`SIGILL` on the customer's older CPU, mid-run, in a library nobody suspected.

`-march=native` is rejected outright rather than quietly rewritten — if your
package wants it, that is worth knowing about.

Whatever the wrappers do, `relocate/isa-scan.py` disassembles every shipped
object and the validator fails on anything above the baseline. Libraries that
dispatch on CPUID at runtime (OpenBLAS, MKL, OpenSSL) are allowlisted, because
for them a high-ISA kernel is correct. If your package does its own runtime
dispatch, say so — it needs adding to that list.

## The shipped artifact has no compiler

`conda/prune.list` drops `gcc_impl` and the sysroot — about 530 MB, and most of
the reason the tarball is 60 MB rather than 600. So the tarball ships `mpicc`
and nothing behind it.

That is deliberate. The supported way to build against this stack is **inside
the template, before the prune**, which is exactly what `site/` is for. A
customer compiling against the shipped tarball uses their own compiler; `mpicc`
is still useful to them via `mpicc -show` and `MPICH_CC`.

## Things that will bite you

- **`dlopen`ed plugins are invisible to `ldd`.** If your package loads modules
  at runtime, add them to `stack/etc/entrypoints` or `SLIM_PROFILE=runtime` will
  prune them and the failure will only appear after relocation.
- **Absolute paths in generated text files** (`.pc`, `*Config.cmake`,
  `*-config` scripts) must be rewritten. `relocate/fixup-text.sh` handles the
  common cases; check yours with `grep -r "$BUILD_ROOT" "$STACK"`.
- **Libtool `.la` files** are removed wholesale — they are a relocation
  landmine. Don't depend on them.
