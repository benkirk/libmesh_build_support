# Consuming the stack as a submodule

A worked, tracked example of the **submodule consumer** layout: your repository
is the top level, this project is vendored as a git submodule, and you maintain
nothing but your own package recipes plus a one-screen `Makefile`.

It is the mirror image of [`site/`](../../docs/EXTENDING.md): same discovery
mechanism (`SITE_DIRS`), same `pkg.mk` + `build.sh` contract, same relocate →
validate → pack pipeline — but your packages live in **your** repo, not inside
a checkout of this one. Nothing of ours is copied into your tree; you track two
files per package and a wrapper Makefile, and pull our machinery as a submodule
you can bump like any other dependency.

## Layout

```
your-repo/
├── Makefile                 # the wrapper (copy examples/consumer/Makefile)
├── build_support/           # THIS repo, as a git submodule
└── packages/
    ├── hello/               # a shared library built on libMesh
    │   ├── pkg.mk
    │   └── build.sh
    └── goodbye/             # an app on your OWN hello (goodbye -> hello -> libMesh)
        ├── pkg.mk
        └── build.sh
```

Two files per package, in `packages/<name>/`. That's the whole prescription.

## Quick start

```sh
# 1. Start your repo and add ours as a submodule.
git init your-repo && cd your-repo
git submodule add https://github.com/benkirk/libmesh_build_support build_support

# 2. Drop in the wrapper Makefile and your packages.
cp build_support/examples/consumer/Makefile .
cp -r build_support/examples/consumer/packages .   # or write your own

# 3. Build the whole stack -- ours plus yours -- and pack it.
make PROFILE=stable all
```

`make help` forwards to the submodule and lists every target
(`conda`, `build`, `test`, `relocate`, `validate`, `dist`, `distcheck`, `all`, …).
`make print-config` shows the resolved settings, including your packages under
`PACKAGES`.

## What the wrapper does

The wrapper (`Makefile` here) forwards every goal to a single sub-make in the
submodule and sets three things:

| Override | Why |
|---|---|
| `SITE_DIRS=$(CURDIR)/packages` | Point the submodule's existing extension point at *your* packages. |
| `BUILD_ROOT=$(CURDIR)/_root`   | Build artifacts land in your tree, not inside the submodule checkout. |
| `DIST_DIR=$(CURDIR)/dist`      | The tarball / installer land in your tree too. |

Everything else — `PROFILE`, `V`, `BLAS_PROVIDER`, any `VAR=value` — you pass on
the command line and it propagates to the submodule automatically. Override
`BUILD_SUPPORT`, `PKGS_DIR`, `BUILD_ROOT` or `DIST_DIR` if your layout differs.

## Writing a package

Your `pkg.mk` and `build.sh` follow the exact contract in
[`docs/EXTENDING.md`](../../docs/EXTENDING.md#pkgmk-contract) — there is no
consumer-specific dialect. In particular:

- **`build.sh` sources `"${TOPDIR}/lib/build_common.sh"`.** `TOPDIR` is the
  submodule root, supplied by the framework, so this resolves correctly even
  though your recipe lives outside the submodule.
- **Install into the single merged `$STACK` prefix, build shared, don't set
  `-march`.** The three rules that make the artifact relocatable apply to your
  packages exactly as to ours.
- **Install a test binary into `$STACK/libexec/stack-tests/`** and `test/run.sh`
  runs it automatically, in place and again from the relocated tree — which is
  how `goodbye` here proves a two-deep customer chain survives relocation.

## Keeping the submodule current

```sh
git -C build_support fetch && git -C build_support checkout <tag-or-main>
git add build_support && git commit -m "Bump build_support"
```

Pin it to a release tag for reproducibility; bump it deliberately, like any
dependency.
