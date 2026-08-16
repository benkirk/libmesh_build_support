# The customer demo

A worked example of the shape most customers actually arrive with: **not one
package, but a small stack of their own** — an in-house library built on the
provided solvers, and applications built on that library.

`examples/site-package/` already shows a single package depending on the base
stack. This shows the next problem, which is the one that generates the
questions: **the customer's second package depends on their first.**

```
   conda env ──► petsc ──► libmesh ──►  gust-core  ──►  gust-app
   ╰────────── this repo's stack ──────╯  ╰──── the customer's ────╯
                                            package A     package B
```

Everything here is fictional. "Gust Dynamics" is a placeholder; the point is
the wiring, which is not.

## Quick start

The packages live in `customer/` rather than `site/` so they can be tracked in
git, and are picked up through the existing `SITE_DIRS` knob:

```sh
make SITE_DIRS=customer conda build test
make SITE_DIRS=customer relocate validate dist distcheck
```

In the container loop, `compose run` overrides the service command:

```sh
cd docker
docker compose run --rm build make SITE_DIRS=customer all
```

To keep your own `site/` recipes in the graph as well, pass both:
`make SITE_DIRS='site customer' build`.

**This branch is `customer/` and nothing else.** Not a modified `Makefile`, not
an edited `.gitignore`, not even a workflow of its own — the CI that gates it
lives on `main` (see [The branch contract](#the-branch-contract)). With no
`SITE_DIRS` set the build is byte-for-byte the one on `main`.

## What each package is for

### Package A — `gust-core`, depends on `libmesh`

The layer that knows how the stack is spelled, so nothing above it has to.

| installs | why it is interesting |
|---|---|
| `include/gust/gust_core.h` | a **C** API over a C++/libMesh implementation — the ABI all of B is built on |
| `include/gust_core.mod` | the same ABI as a **Fortran 2003** module; interface-only, so it adds no runtime dependency |
| `share/gust/gust_core_mod.f90` | the module *source*, because a `.mod` is gfortran-version specific and the artifact ships no compiler |
| `lib/libgustcore.so` | must acquire an `$ORIGIN` rpath and keep resolving libMesh, PETSc and MPI after relocation |
| `lib/pkgconfig/gust-core.pc` | written with an absolute `prefix=`, so `relocate/fixup-text.sh` has to rewrite it |
| `libexec/stack-tests/gust-core-selftest` | run by `test/run.sh` in place *and* from the unpacked tarball |
| `libexec/gust/gust-ex4` | libMesh's `introduction_ex4`, compiled against the **installed** stack |

One `.pc` serves all three languages: gfortran searches `-I` for modules, so
the `-I${includedir}` it already emits is what a Fortran consumer needs too.

That last one is the first thing a customer does with a delivered tarball, so
the demo does it too: take an example out of the installation, build it with
`libmesh-config` — libMesh's own documented contract for building against an
install — run it, and keep the binary. It is *not* installed into
`stack-tests/`, because the harness invokes everything there with no arguments
in an arbitrary directory, and `ex4` takes options and writes mesh files.
`test/run.sh` already runs `ex4` properly, with its own `run_ex4`.

### Package B — `gust-app`, depends on `gust-core`

The "hello world" end — the same program, written three times, once per
language a customer is likely to bring:

| binary | language | what only it exercises |
|---|---|---|
| `gust-hello` | C99 | the plain case: a C caller against a C++ library |
| `gust-hello-omp` | C++17 + OpenMP | a `libgomp` dependency that has to survive the prune, and MPI×threads together |
| `gust-hello-f03` | Fortran 2003 | `BIND(C)` struct interop, `C_NULL_PTR`, `C_F_POINTER` |

The interesting part of all three is what they do *not* contain:

```c
#include <gust/gust_core.h>     /* and, in Fortran:  use gust_core */
```

No `<mpi.h>`, no `<petscsys.h>`, no libMesh header — and on the link line,
nothing but `pkg-config --libs gust-core`. They run a parallel FEM problem
without naming a single component of the stack they run on. That is checked,
not asserted: `readelf -d` output for the three binaries is

```
gust-hello:      libgustcore.so libc.so.6
gust-hello-omp:  libgustcore.so libgomp.so.1 libc.so.6
gust-hello-f03:  libgustcore.so libgfortran.so.5 libm.so.6 libc.so.6 libgcc_s.so.1
```

— one library from the stack side, in every case, and the build fails if
`libmesh`, `libpetsc` or `libmpi` ever appears there.

They are also compiled with the **ordinary** `$CC`/`$CXX`/`$FC`, not with
`mpicc`. Package A is built with `mpicxx` because A genuinely is an MPI code;
if B needed the MPI wrappers, the encapsulation would not be real. MPI still
loads at run time — transitively, through `libgustcore.so` — which is the point.

`PKG_DEPS := gust-core`, and deliberately not `libmesh` or `petsc`. Declaring
what you actually use is the difference between a dependency graph and a wish.

Three things fall out, and all of them are the point:

- **B is C, C++ and Fortran; A is C++.** One `extern "C"` façade with no
  libMesh type in any signature is what lets three languages share it, and
  `libgustcore.so` carries its own C++ runtime dependency so none of them has
  to know.
- **B consuming A's `.pc` is itself a test of the relocation machinery.** A
  malformed or unrewritten `gust-core.pc` fails B's build, loudly, in the same
  pipeline run.
- **The OpenMP and Fortran builds each make a claim about the artifact**, not
  just about the source: `libgomp` and `libgfortran` must survive
  `conda/prune.list` and resolve through `$ORIGIN`. Both do —
  `prune.list` protects the compiler *runtime* explicitly, and
  `relocate/validate.sh` already asserts `libgfortran` resolves in-tree — and
  the binaries running from the unpacked tarball is the proof.

After `make dist`, each binary has a four-deep transitive chain —
`gust-hello → libgustcore.so → libmesh_opt.so → libpetsc.so → libmpi.so` —
and every link of it has to resolve through `$ORIGIN` once the tarball is
unpacked somewhere else. `distcheck` running them is that whole chain being
proved at once.

#### Hybrid MPI + OpenMP, done deliberately

`gust_hello_omp.cpp` makes no MPI or libMesh call from inside a parallel
region — libMesh's `LibMeshInit` does not promise `MPI_THREAD_MULTIPLE` and
the program never asks for it, so the threaded section is pure arithmetic on
local data. It also caps itself at two threads: the harness runs every
`stack-tests` binary under `mpiexec -n 4` on a 4-vCPU runner, and this branch
may not edit `test/run.sh` to set an environment.

The reduction is over **integers**, so the answer cannot depend on how
iterations were scheduled or in what order partial sums were combined. A
floating-point reduction would need a tolerance to assert on, and a tolerance
accepts a genuinely wrong answer as readily as a reordered one.

`#ifndef _OPENMP → #error` guards the whole file. Without it, a missing
`-fopenmp` would leave the pragmas silently ignored, one thread reported, and
the program passing while testing nothing.

## Source modes: local, tarball, or git

Both packages honour the framework's `PKG_SOURCE`, plus one mode added here:

| mode | source | provided by |
|---|---|---|
| `local` *(default)* | `src/` beside the recipe | `customer/common/gust_source.sh` |
| `tarball` | `PKG_URL`, cached | framework — `download_src` |
| `git` | `PKG_GIT_URL` @ `PKG_GIT_REF` | framework — `fetch_git` |

```sh
make SITE_DIRS=customer build                       # local, no network
make SITE_DIRS=customer GUST_SOURCE=git build       # both packages from git
make SITE_DIRS=customer GUST_CORE_SOURCE=tarball \
     GUST_CORE_URL=https://internal.example/gust-core-0.3.0.tar.gz build
```

`GUST_SOURCE` sets both; `GUST_CORE_SOURCE` / `GUST_APP_SOURCE` override one.
The URLs default to `*.example.invalid` placeholders — substitute your own.
`make SITE_DIRS=customer GUST_SOURCE=git print-config` lists what would be
cloned, from the framework's own `PACKAGES (git)` line.

**`local` is the only thing this directory adds**, and it is worth the
thirty lines because it is where every customer package starts: before there
is a tag or a release tarball, there is a directory of source files next to
the recipe. `tarball` and `git` delegate straight to `lib/build_common.sh`, so
there is one implementation of each in this tree and one place for a bug in
them to be fixed.

Compare with `examples/site-package/build.sh`, which emits its sources from
heredocs inside the build script. That works, but it is not where a
customer's code lives, and it cannot be compiled, linted or diffed on its own.
Here the sources are real files under `src/` — which is also what makes
switching to `tarball` or `git` a knob rather than a rewrite, since the same
tree could be tarred up or pushed to a remote unchanged.

> **Changing the mode does not by itself rebuild.** As `mk/pkg.mk` notes, the
> stamp depends on `build.sh`, not on the version, URL or source mode. Delete
> `$(WORK)/stamps/gust-core.stamp` when changing *what* is built rather than
> *how*.

## How these get tested without touching the harness

Both packages install an executable into `$STACK/libexec/stack-tests/`, which
is the documented extension point (`docs/EXTENDING.md`). `test/run.sh` finds
them by directory scan and runs each one serially and under `mpiexec`, in
place and again from the relocated tree, with no edit to the test suite.

The harness's own assertion is deliberately weak — exit 0, and some output —
because it cannot know what a customer's program prints. So both binaries
assert their own results instead. A 4×4 square refined *r* times has
`4·2ʳ` elements per side and, at first order on QUAD4, one DoF per node, so
the expected counts are exact and checked rather than merely printed. Both
also print a line per rank, so *N* processes that each believe they are rank 0
of 1 — the signature of a binary linked against a different MPI than the
launcher — cannot pass by exiting 0 quietly.

## Checking the ABI without a stack

The three-language claim is cheap to state and expensive to check the honest
way — the real article needs conda, PETSc and libMesh. So:

```sh
customer/test/abi-check.sh
```

builds a **mock of package A** (`customer/test/abi-stub/`, implementing exactly
the contract `gust_core.h` documents, including the mesh arithmetic), installs
it into a throwaway prefix with a generated `.pc`, then compiles, links and
**runs** all three front-ends against it. Seconds, on any machine with gcc,
g++ and gfortran. CI runs it on every push.

It earns its keep on one failure mode in particular: a Fortran `BIND(C)`
derived type that disagrees with the C struct is **not a diagnostic in either
language**. It is a silently wrong layout. The only thing that catches it is
executing the program and comparing field values, which is why the front-ends
assert their own arithmetic and why this harness runs them rather than
syntax-checking them.

The mock is never installed into `$STACK` and is not a fallback. What it
cannot tell you: anything about libMesh, PETSc, multi-rank behaviour or
relocation — `test/run.sh` and `distcheck` are where those are answered.

> Writing it caught a real error in this directory. The first version asserted
> that an interface-only Fortran module compiles to an object with **no
> symbols**; it does not. gfortran emits `__vtab_`/`__copy_`/`__def_init_`
> type-support symbols for the derived type regardless. The property that
> actually matters — that the module defines no *procedure* a caller must link
> — is now checked the only way that cannot be fooled: `gust-hello-f03` links
> without the module's object file at all.

## The branch contract

`customer_demo` **rides on top of `main` and only ever adds files.** No commit
on it may modify or delete anything tracked on `main`. That is what makes it
rebasable indefinitely and safe to demo from at any commit:

```sh
git fetch origin main
git rebase origin/main customer_demo
```

You should rarely need to. `.github/workflows/customer-demo.yml` **on `main`**
does it automatically on every push to `main`, plus nightly: it rebases this
branch, runs the whole gate below against the rebased tree, and only then
force-pushes — leased against the sha it rebased from, so a concurrent push
aborts rather than being discarded. A rebase conflict is never resolved
automatically. A branch that only adds files can only conflict if `main` added
a file at the same path, which is a real event and stops the job.

The gate: additive-only against `main`; the packages are discovered; the graph
orders `libmesh → gust-core → gust-app`; the default build is unchanged without
`SITE_DIRS`; the git source mode appears in the framework's own
`PACKAGES (git)` line; and all three front-ends build and run
(`customer/test/abi-check.sh`).

**Why that workflow is on `main` and not here.** Two reasons, and the first is
a hard constraint. GitHub runs `schedule:` workflows only from the default
branch, and a `push: branches: [main]` workflow is read from `main`'s copy of
the tree — so a rebase bot living on the branch it maintains would never fire.
The second is the point of this page: with the CI on `main`, this branch is
purely package additions.

A useful side effect: pushes made with `GITHUB_TOKEN` do not trigger further
workflows, which would normally land a bot's push untested. There is nothing
here left to trigger, and everything is verified before the push.

The forward-compatibility rule that follows from riding on `main`: **delegate,
never duplicate.** An earlier draft of `gust_source.sh` carried its own git
mirror-clone implementation, written from `docs/plans/GIT-SOURCE-INSTALLS.md`
— which turned out to have already landed in `lib/build_common.sh`. Anything
this directory reimplements is something that rots the next time `main`
improves it.

## Status

Built, relocated and run. The whole chain — `petsc → libmesh → gust-core →
gust-app` — has been through `make all` on `linux-64`, and all four customer
binaries were then executed from the unpacked tarball on two pristine distros
with no compiler in them: **`almalinux:8`** (glibc 2.28) and
**`ubuntu:24.04`** (glibc 2.39). Both green.

The run: `extended.yml`'s `customer-demo-stack` job, which builds *this branch*
(`source_ref: customer_demo`) with `SITE_DIRS=customer`. `make build` took 26
minutes, `make all` — relocate, validate, slim, dist, distcheck — another 7,
and the artifact is 115 MB.

Verbatim from the `almalinux:8` verify job (**glibc 2.28, the floor**),
unpacking that tarball and running what was inside it:

```
--- gust-core-selftest on 4 ranks
    gust-core: rank 0/4 … rank 3/4
    gust-core: ranks=4 elements=1024 dofs=1089 backend=libMesh 1.7.9 version=0.3.0
--- gust-hello on 4 ranks
    gust-hello: gust-core 0.3.0 (compiled against 0.3.0), libMesh 1.7.9
    gust-hello: solved on 4 rank(s): 256 elements, 289 dofs
--- gust-hello-f03 on 4 ranks
    gust-hello-f03: hello from Gust App (Fortran 2003)
    gust-hello-f03: solved on 4 rank(s): 256 elements, 289
--- gust-hello-omp on 4 ranks
    gust-hello-omp: 4 rank(s) x 1 thread(s), 289 dofs, reduction=41616 ok
--- rebuild skipped: the artifact ships no compiler (by design)
=== smoke: relocated OK
```

Three things that log settles, which nothing before it could:

- **`libgomp` and `libgfortran` resolve through `$ORIGIN`.** The OpenMP and
  Fortran binaries loaded and ran from a relocated tree on a host that has no
  compiler and never had one. That was the last claim resting on reasoning.
- **The mock was a faithful contract.** Every number the real stack produced is
  the one `abi-stub` predicted — 1024/1089 at three refinements, 256/289 at
  two, `reduction=41616`. The cheap harness was testing the right thing.
- **`gust_core.C` compiled against a real libMesh first try**, which is not what
  this file predicted. The libMesh calls needed no correction.

### Still not proven

- **`linux-aarch64`.** The job is `linux-64` only, following the precedent
  `libmesh-git` set: prove a declared-but-unproven config on one architecture
  first. Nothing here is x86-specific, but that is an expectation, not a result.
- **OpenMP threading under the harness.** Note `4 rank(s) x 1 thread(s)` above:
  the verify container reported one available processor, so
  `omp_get_max_threads()` was 1 and the parallel region ran single-threaded.
  `libgomp` genuinely loaded and the reduction is genuinely correct, but the
  *threading* was exercised by `abi-check.sh` (two threads), not here.
- **The three other verify distros.** This job runs two — the glibc floor and a
  current release — rather than the five `ci.yml` uses, because what is under
  test is the customer packages, not the distro matrix.

**Checked, and re-checked by CI:** the packages are discovered through
`SITE_DIRS`; the graph orders `petsc → libmesh → gust-core → gust-app`; the
scripts pass `bash -n` and `shellcheck --severity=warning`; `make -n all`
resolves serially and under `-j8`. And, through `abi-check.sh`: all three
front-ends **compile, link and run** clean under `-Wall -Wextra -Werror`, the
Fortran `BIND(C)` type matches the C struct field for field, the OpenMP
reduction gives the right answer on two threads, and `readelf -d` confirms none
of them links the stack directly.

**Checked once, by hand, against the real toolchain.** CI runs `abi-check.sh`
with the runner's system gcc. It has also been run against the conda-forge
**gcc 14.4.0** this stack actually builds with, from a real `make conda`, and
passes there too — same output, `libgomp.so.1` and `libgfortran.so.5` present
in the env.

That run is what found the `-rpath-link` gap now fixed in `abi-check.sh`: on the
system toolchain the harness linked cleanly by accident, because the host's
`libstdc++` sits on the default search path. On the conda toolchain it warned
and *still linked*, and the binary then resolved `libstdc++` from the host —
the harness had quietly stopped testing a self-contained tree. The recipes were
always right (`gust-app/build.sh` passes `-rpath-link`); the harness was not
reproducing them. It now fails on that warning rather than printing it.

**Reasoned, then verified against `conda-meta`:** that `libgomp` and
`libgfortran` survive `prune.list`. Ownership is not obvious and is worth
recording — `lib/libgomp.so.1`, the SONAME the loader looks for, is owned by
`_openmp_mutex`, while the real `libgomp.so.1.0.0` is owned by `libgomp`; both
are kept. The copies under `lib/gcc/…` belong to `gcc_impl_linux-64` /
`gfortran_impl_linux-64` and *are* pruned, which is correct — those are the
build-time copies.

**Not yet run anywhere:** the real `gust_core.C`, which needs `make build` on
top of the conda env (PETSc plus libMesh, tens of minutes). Its libMesh API
calls and the `libmesh-config` invocation in `gust-core`'s recipe follow the
patterns in `test/smoke/Makefile` and `pkgs/libmesh/build.sh`, but have not
been through a compiler. Everything *around* that one file is verified — the
mock proves the ABI — so a failure there should be localised to the libMesh
calls themselves, most likely an include path or an enum spelling.

Nor has relocation been exercised with these packages in the tree: that
`libgomp` and `libgfortran` resolve through `$ORIGIN` from an unpacked tarball
is the one claim still resting on reasoning rather than a measurement. The
proof is `make SITE_DIRS=customer relocate validate dist distcheck`.
