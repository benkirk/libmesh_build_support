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

$(eval $(call declare_pkg))
```

`declare_pkg` snapshots these into namespaced variables, so every recipe can use
the same plain `PKG_*` names without clobbering its neighbours.

`PKG_DEPS` becomes a stamp prerequisite, so independent packages build
concurrently under `make -jN`.

`PKG_STAGE` decides whether `make build` pulls the package in. `build`, the
default, puts it in the default graph. `optional` still gives it its own target
(`make mysolver`) and it still gets relocated, validated and packed if it has
been built — it just isn't built automatically. `make print-config` lists both
sets.

## `build.sh` contract

Receives `STACK`, `WORK`, `SRC_CACHE`, `CONDA_HOME`, `NPROC`, `MAKE_J_L`,
`TARGET_PLATFORM`, `BLAS_PROVIDER`, `MPI_FAMILY`, `RPATH_MODE`, `ISA_BASELINE`,
`USE_WRAPPERS`, `TOPDIR`, and its own `PKG_NAME` / `PKG_VERSION` / `PKG_URL` /
`PKG_DIR`.

Prefer `make $MAKE_J_L` over a bare `make -j$NPROC`: it carries a `-l` load cap,
which is what keeps a shared build host usable.

Sourcing `lib/build_common.sh` gives you `activate_toolchain`, `list_build_env`,
`download_src`, `log`, `require`, `clean_build_tmp`, and a `BUILD_TMP` scratch
directory. Call `list_build_env` right after `activate_toolchain` — when a build
fails three hours in, the log is all you have.

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
