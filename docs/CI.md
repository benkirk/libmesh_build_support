# CI

The workflows in `.github/workflows/`, what each answers, and how to read a run.
Everything here drives `docker compose` against `docker/`, so a job and the local
dev loop run the same images and the same commands. `A<n>` cites the amendments
in [`plans/implemented/RELOCATABLE-STACK-PLAN.md`](plans/implemented/RELOCATABLE-STACK-PLAN.md).

## The workflows

| workflow | trigger | what it answers |
|---|---|---|
| `checks.yml` | pushes to `main`, every PR, on demand | the fast gate: does it parse, lint, order itself, do the ISA regexes still match, does every base image build, do the docs' links resolve — about two minutes |
| `ci.yml` | PRs and `main` (not `**.md`, `docs/**`) | the default configuration on `linux-64` **and** `linux-aarch64`, verified on all five base images; on `main` it also publishes the builder and devel images |
| `stack.yml` | called, never triggered | the reusable build-and-verify implementation, parameterized |
| `extended.yml` | Mondays 06:17 UTC, and on demand | the knobs nobody runs daily: fresh conda solve, MKL, parallel HDF5, libMesh from git, a Debian-family builder, the `customer_demo` branch |
| `customer-demo.yml` | push to `main`, nightly | rebases the `customer_demo` branch onto `main`, verifies it, force-pushes with lease — the one workflow with `contents: write` |
| `prune-ghcr.yml`, `prune-runs.yml` | monthly, and on demand | keep N images per configuration line; delete runs older than N days. Manual dispatch is a dry run by default; the cron is not |

A docs-only PR runs `checks` and nothing else — which is why the link check
lives there.

## Build once, verify everywhere

The shape is **build once, validate the same tarball everywhere** — because that
is what the artifact's claim actually is. A build job publishes a tarball; a
fan-out of consume-and-test jobs unpacks that one tarball on a pristine, poorer
image and runs it. That is `docker/compose.yaml`'s `build`/`verify` service split
scaled out, and it is implemented by *invoking* those services rather than by
reimplementing them: every job shells out to `docker compose` against that file,
so the builder image, the verify image, the volume layout and the verify command
are the ones a developer exercises locally. There is no second description of
the pipeline to keep in sync — a green local `compose run verify` is supposed to
mean something about CI.

Four decisions behind that shape:

- **`docker/bases.env` is read, not transcribed.** `docker/bases.sh --json`
  emits the list and the verify matrix expands from it, so adding a distro to
  the local loop adds it to CI in the same commit. `checks.yml`'s image-build
  job is the one place the list is duplicated — GitHub will not let a job
  compute its own matrix — so it asserts its copy matches rather than trusting it.
- **Both platforms build natively.** `linux-aarch64` gets an `ubuntu-24.04-arm`
  runner, not QEMU: it is a shipping target, the `armv8.1-a` floor was measured
  there, and under emulation the ISA scan alone would dominate the run.
- **The fast gate is separate from the expensive one.** Most mistakes here are
  catchable in two minutes without building anything; A1 was that class of
  break, and `make -n all` under `-j8` is what catches it.
- **`ci.yml` builds from the checked-in lock where one exists; `extended.yml`'s
  `fresh-solve` solves from the spec.** A lock can never report that `conda/env/*.yml` has
  stopped resolving to something that works, so `fresh-solve` ignores it weekly
  and publishes the lock that solve produced. Today only `linux-aarch64` has a
  lock; `linux-64` re-solves on every run (A37).

## The fast gate: `checks.yml`

One job, one step per question, all inline shell: scripts parse (`bash -n`,
before shellcheck so a syntax error is not buried in lint noise); `shellcheck
--severity=warning` (a gate that fires on things you keep is a gate you learn to
ignore; it still found two real bugs, A36); Python compiles, including the
summary renderer that otherwise runs only after a 50-minute build; `isa-scan.py
--self-test`, because the x86 patterns cannot be exercised on an aarch64
developer machine; `make -n all`, `make -j8 -n all`, `make help`,
`make print-config`; `docker/bases.sh --json` is well formed; `docker compose
config`; `actionlint`; and every relative link and back-ticked `.md` path in
tracked markdown resolves (`.github/scripts/check-md-links.py`). A second job
builds the builder and verify images on all five bases — A14 is what happens
when that goes untested.

## `stack.yml`: plan → build → verify → summarise

`plan` runs `docker/bases.sh --json` and hands the list to the matrix. `build`
runs `make conda`, `make build`, `make all` as three `docker compose run`
invocations, each under its own `timeout --signal=INT`, then uploads three
things. `verify (<base>)` fans out one job per base image, downloads the tarball
into `dist/`, and runs the compose `verify` service. `summarise` collects every
job's result sidecar into one table, whether or not the jobs passed.

**Budgets are per step, not per job.** `make conda` 45 min, `make build`
120, `make all` 90 (the ISA bench, when requested, another 45), asserted at
the start of the job to fit under a 350-minute backstop. A *job* timeout
cancels the job, and a canceled job does not run its remaining steps — not
even `if: always()` ones — so the run that most needs its logs is exactly the
run that would lose them. `--signal=INT` because `docker compose run` treats
SIGINT as "stop this container"; the default TERM would orphan it.

**Artifacts** (14 days):

| name | contents |
|---|---|
| `stack-<platform>-<blas>-<mpi>-hdf5<yes/no>[-libmeshgit]-<base>` | the tarball, `dist/*.tar.gz` |
| `…-diagnostics` | `logs/<pkg>.log`, `relocate/{before,after}.json`, `relocate/isa-scan.json`, `relocate/fixup-report.txt`, `lock/` (the checked-in locks, overwritten by the fresh solve when `refresh_lock` ran), `df.txt` |
| `result-build-…`, `result-verify-…-<base>` | one JSON per job, for `summarise` |

**Images.** On `main`, `ci.yml` also pushes two images per configuration to
GHCR: `builder` (the provisioned toolchain, after `make conda`) and `devel`
(toolchain plus the built stack, before relocation). The tag is a content hash
of the config tuple and the recipes, computed by `.github/scripts/inputs-sha.sh`
— the same script `make image-shell` and `docker/pull-shell.sh` use locally, so
on the commit that built an image `make image-shell` pulls it (`STAGE=builder`
for the toolchain alone), and a tree CI never built resolves to a tag that is
not there. Pull requests read; pushes to `main` and manual dispatches write.

## Reading the run summary

Each build job writes a block headed `<platform> · <blas> · <mpi>`:

| row | meaning |
|---|---|
| built on `<base>`, env from … | the lock actually used, or "a fresh conda-forge solve" — the outcome, not the request. An earlier version printed the input and claimed "from the checked-in lock" on a run that had solved from scratch (A37) |
| tarball, size, packages | as shipped; `packages` from `etc/stack-manifest.json` |
| glibc floor | requested vs **measured** over the final tree — the floor is checked, not asserted (A4) |
| ISA baseline | what the wrappers capped to and the scan gated on |
| libstdc++ | the runtime actually shipped, next to the gcc pin (A13) |
| ELF objects scanned / with ISA features / CPUID-dispatching | counts from `isa-scan.json`, **not a verdict** — the scan runs pre-prune, so it counts the sysroot and compilers too (899/890 at a61f0d6, against 335/333 in the shipped tree). The verdict is `validate`'s "all N objects within ISA baseline" line in the log. CPUID is the number to watch: it is the bucket that gets a pass |

`summarise` then renders one **Stack matrix** table (configuration, result,
time, tarball, size, packages, floor, ISA), a **Verify** grid — one column per
base image, each cell ✅/❌ and duration, with a collapsed list underneath of the
glibc each image *actually* ran, parsed back out of the verify log —
and, when an `experimental: true` job failed, a section saying so. The run stays
green; the failure is on the page. Before that section existed an experimental
red was invisible (PR #14).

## The second axis: `extended.yml`

| job | configuration | why |
|---|---|---|
| `fresh-solve` | both platforms, `ignore_lock`, `refresh_lock` | the spec still resolves; the produced lock is in the diagnostics artifact |
| `mkl` | `linux-64`, `BLAS_PROVIDER=mkl` | x86 only by construction; watch the tarball size |
| `hdf5-parallel` | `linux-64`, `HDF5_PARALLEL=yes` | the `mpi_*` variant pulls MPI into everything touching HDF5 (A3) |
| `libmesh-git` | both platforms, `LIBMESH_SOURCE=git` | the git-source path, and the only job needing git in the image *and* autotools in the env |
| `builder-distro` | `linux-64` on `ubuntu:24.04` | the builder's own distro should be irrelevant; PR #20 found it lending us `ar` |
| `customer-demo-stack` | `linux-64`, `source_ref: customer_demo`, `site_dirs: customer` | a customer's own two packages layered on through `SITE_DIRS`, from the branch that carries them — the `EXTENDING.md` extension point built for real |
| `host-boost` | `linux-64` on `almalinux:8` with `host_extras: boost-devel` | a deliberately dirtied builder: the Rocky 8 + Boost 1.66 case that broke libMesh's configure, now expected to build identically to a clean host (`DESIGN.md`, host dev packages) |

All but `fresh-solve` are `experimental: true`; all but `fresh-solve` and `mkl`
verify on two bases (`almalinux:8`, `ubuntu:24.04`) rather than five — if a
closure change breaks relocation it breaks on both, and the middle three add
nothing. On dispatch `only=<job>` runs one; a job added here needs its own
`only` guard, or it runs on every named dispatch. GitHub disables a schedule after 60 days of repository inactivity, and
a silent extended matrix is a green one — check that it is still running.

Not wired, deliberately: `MPI_FAMILY=openmpi` (needs an env spec, a meaningful
`MPI_VERSION`, prune-list entries for its plugins, and a pinned transport in the
smoke harness) and `GLIBC_FLOOR=2.17` (no maintained glibc-2.17 image to verify
on). Each is a missing prerequisite, named, not a technical obstacle. `linux-64`
still has no checked-in lock, so its `ci` build re-solves every run (A37); commit
one only from a solve someone watched succeed.

## Reproducing a failure locally

| CI step | locally, from `docker/` |
|---|---|
| `build` job, default config | `docker compose run --rm build` (its command is `make all`); on Apple Silicon add `PLATFORM=linux/amd64 TARGET_PLATFORM=linux-64` for the x86 column |
| one `verify (<base>)` job | `VERIFY_IMAGE=<base> docker compose run --rm --build verify` — **`--build` is load-bearing**: without it compose reuses the last image and silently ignores `VERIFY_IMAGE`. Check the `=== verify on <distro>, glibc <v>` line |
| the `host-boost` job | `BASE_IMAGE=almalinux:8 HOST_EXTRAS=boost-devel docker compose -p dirty build build && docker compose -p dirty run --rm build` — a separate project name, so the dirtied image and its build root do not become tomorrow's clean build |
| the fast gate | `make -n all && make help`, `shellcheck --severity=warning $(git ls-files '*.sh')`, `python3 relocate/isa-scan.py --self-test`, `python3 .github/scripts/check-md-links.py` |
| the published image | `make image-shell` on the commit CI built |

The build root and the conda package cache are named volumes, so a re-solve
costs no network and `BUILD_ROOT` is never a bind mount on macOS. Runners have
4 cores; the compose service reads the same knobs CI passes with `-e`
(`HDF5_PARALLEL`, `LIBMESH_SOURCE`, `SITE_DIRS`, `SMOKE_RANKS`, `IGNORE_LOCK`).

In the diagnostics artifact: a package that failed to build is
`logs/<pkg>.log` (PETSc's `configure.log` is `petsc-configure.log`); a validate
or ISA failure is `relocate/isa-scan.json` plus the job log's `validate` block;
`fixup-report.txt` lists what still named the build prefix; `df.txt` is the
disk at the end.

## Why the matrix exists

From A34, which is the whole argument in one finding:

> **A34 — a `grep -l` behind `xargs` truncated its own work list, silently and
> non-deterministically. CI found it; repeated local runs did not.** The first CI
> run of the full pipeline failed identically on both platforms with five files
> still naming the build prefix […]
>
> Two things worth keeping from this. **A list-building failure is invisible by
> construction**: nothing errors, you simply get less work done, and the eventual
> symptom points at the files rather than at the generator. And it is the argument
> for the CI matrix paying for itself on its first green-ish run — this had
> survived four clean local `make all` cycles.

The verify fan-out earned its keep on its first run too: `opensuse/leap:15`
ships no `gzip`, so the tarball could not even be unpacked there, on both
architectures identically (A38). And the lint gate found two real bugs on
arrival (A36).

## What CI cannot tell us

Worth stating so a green matrix is not read as more than it is. The runners are
4-vCPU single machines, so `SMOKE_RANKS=4` on one node is the ceiling — multi-node MPI
was already out of scope, and CI does not change that. Nothing
here runs on old hardware; `relocate/isa-scan.py` is the stand-in for the customer's
2015 Xeon and it is a static check, not a run. And CI verifies distros, not CPUs:
five base images on two architectures says nothing about the ISA floor that the ISA
gate does not already say by itself.

## Cost

At a61f0d6, `make all` is 2173 s on `linux-64` and 1826 s on `linux-aarch64`
(4-vCPU runners); `checks` is about two minutes; a verify job about one. The ISA
scan was once 18 of the first x86 build's 21 minutes; scanning with processes
(PR #16) and prefix-factoring the x86 patterns (PR #19,
[`plans/implemented/ISA_SCAN_MATCHING.md`](plans/implemented/ISA_SCAN_MATCHING.md))
took it to about three.
