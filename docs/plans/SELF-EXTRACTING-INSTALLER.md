# Plan: a self-extracting installer for the redistributable stack

**Status:** planned, not started. Pick this up in a fresh session.

`A<n>` cites the amendments in
[`implemented/RELOCATABLE-STACK-PLAN.md`](implemented/RELOCATABLE-STACK-PLAN.md),
the same convention `docs/DESIGN.md` uses.

## What this is for

Ranked, because everything below is judged against this list and the ranking is
what makes the design fall out:

1. **Refuse an unsuitable host before writing 111 MB.** glibc under the *measured*
   floor, a CPU under `ISA_BASELINE`, no disk, no write permission — a named
   refusal in seconds, on the machine, at install time. This is the only goal a
   `.tar.gz` cannot serve, and it is the reason to build the thing at all. Today
   the failure mode is `Illegal instruction` in someone's batch job three days
   later, or a loader error naming a symbol version rather than a distro.
2. **One file.** `scp` it, run it, get a working stack. No README step, no
   two-artifact handoff.
3. **Integrity now, provenance later.** An embedded SHA-256 the artifact checks
   against itself, plus `dist/SHA256SUMS` for the `.run` itself. Signing and
   attestation are named in "Not doing" — they are a different project.
4. **A tree that can verify itself after install**, with no repo present.
5. **No second packing path.** The payload is the `distcheck`-proven `.tar.gz`,
   byte for byte. If it is repacked, the `.run` inherits none of the guarantees
   that make this repo worth anything.
6. **No new builder dependency, and still reproducible** (`SOURCE_DATE_EPOCH`).

Goal 1 is the product. Extraction is plumbing — `tar xzf` has done it correctly
for forty years, and a wrapper that only wraps it is a worse `tar`.

## What is already done

`make dist` builds the relocatable `stack/` tree and tars it reproducibly
(`mk/stages.mk:175-181`) into
`dist/$(DIST_NAME)-$(DIST_VERSION)-$(TARGET_PLATFORM)-$(BLAS_PROVIDER)-glibc$(GLIBC_FLOOR).tar.gz`
(`mk/common.mk:80`). `make distcheck` then *proves* that tarball: it unpacks at a
different path depth, under a directory whose name contains a space, moves the
original aside so nothing resolves back to it, validates, runs the prebuilt
binaries, and repeats read-only (`test/distcheck.sh`). The unpacked tree
self-activates via `stack/activate.sh`, which derives its own root from
`$BASH_SOURCE` and bakes in no absolute paths (`stack/activate.sh.in`).

The repo also already *consumes* this pattern: `conda/bootstrap.sh:49-51`
downloads `Miniforge3-Linux-*.sh` and runs `bash miniforge.sh -b -f -p $PREFIX`.

So the hard part — a payload that actually relocates — is done. What is missing is
the part that runs *before* the payload lands.

## Why not `makeself`

An earlier revision of this plan dismissed `makeself` in one clause — "no
dependency, keeps the artifact auditable". That is a preference, not a
measurement, and it is not why. The decision survives, but the reasons are
different and worth writing down so nobody re-opens it on the wrong grounds.

**It is not a licensing question.** `makeself` is GPL-2.0, and its README states
that archives it generates need not be placed under that license. Whatever
objection a reader is about to raise, it is not this one.

**What we give up is real,** and pretending otherwise is how a plan gets
overturned six months later: `--list`, `--check`, `--info`, `--lsm`, `--keep`,
`--nodiskspace`, `--license`, `--nooverwrite`, a choice of compressors, and
roughly twenty-five years of accumulated edge cases (2.7.1 at the time of
writing). That is not nothing, and most of it is UX we now have to write.

**What decides it, in order:**

- **Payload identity.** `makeself` tars a *directory*. Pointing it at `$STACK`
  creates a second packing path that can drift from `mk/stages.mk:178-180`, and
  re-opens reproducibility, which then has to be re-established through
  `--tar-extra` and `--packaging-date`. Nesting our existing `.tar.gz` inside a
  `makeself` archive instead preserves identity — but the archive stages its
  payload through a temporary directory before the startup script runs, so a
  111 MB artifact costs a full extra copy on disk and double the I/O, on hosts
  whose `/tmp` we do not control. `tail -c +N "$0" | tar -xzf - -C "$prefix"`
  materializes nothing.
- **Ordering.** `makeself`'s startup script runs *after* extraction.
  `--notemp` / `--current` / runtime `--target` change *where*, not *when*. Goal 1
  requires before. We would be fighting the tool over its central design choice,
  and losing that fight quietly.
- **Portability we do not have to buy.** `makeself`'s value is breadth: AIX,
  Solaris, HP-UX, Cygwin, WSL. The support matrix here is five glibc Linux images
  (`docker/bases.env`). That is ~1600 lines of generality bought for none of it.

**And what we therefore owe:** progress output, traps that clean up a partial
extraction, umask and chown-as-root behavior (`makeself` has `--nochown` for a
reason — extracting as root can rewrite ownership in ways the caller did not
ask for), and a documented exit-code table. These are header requirements below,
not omissions.

## How a self-extracting installer works

A `.run` is three things concatenated into one executable file:
**`[shell header]` + `[marker line]` + `[raw tarball bytes]`**. When run:

1. The shell executes the header text at the top. **The header must end in
   `exit 0`.** `sh` reads a script in blocks, and without a terminating `exit` it
   can read on into the payload — on some shells, on some block boundaries, which
   is the worst way to find out.
2. The header locates the payload by **byte offset**, not by line number:
   `tail -c +$((OFFSET + 1)) "$0"`.
3. That streams into the extractor:
   `tail -c +$((OFFSET + 1)) "$0" | tar -xzf - -C "$prefix"`. `$0` is the script
   itself, which is how it reads its own payload — and therefore `curl … | sh` can
   never work, because `$0` is then the shell. The header refuses that by name
   (exit 2) rather than reading a nonexistent file.
4. Everything else is header: preflight, checksum, argument parsing, output.

Three hazards, all of which the obvious implementation walks straight into:

- **Marker self-match.** The usual trick —
  `N=$(awk '/^__PAYLOAD_BELOW__$/{print NR+1; exit}' "$0")` — searches for a
  string the header itself contains, and takes the *first* match. Byte offsets
  sidestep it. Keep a marker line anyway, as a boundary a human (or `file`, or
  `head`) can see; just do not compute from it.
- **`awk` over binary.** Line-scanning a mostly-binary file is a locale and NUL
  hazard for no benefit once the offset is known at assembly time.
- **Leading zeros are octal.** The tempting way to hold the header's width stable
  is to pad the offset itself — `PAYLOAD_OFFSET=0000012345`. POSIX arithmetic then
  reads it as octal, so `$((PAYLOAD_OFFSET + 1))` is 5350 rather than 12346, the
  `.run` extracts from the wrong byte, and it fails as a corrupt payload rather
  than as a bug. Which of the two ways it fails depends on the digits: an offset
  containing an 8 or a 9 is not valid octal at all, so `dash` says
  `Illegal number: 0000019759` and `sh` says `value too great for base` —
  confusing, but at least loud. Every other offset is silently wrong. Pad the
  *line*, never the number.

**Getting the offset without a fixpoint:** the header carries the placeholder on a
line of its own, `PAYLOAD_OFFSET=@PAYLOAD_OFFSET@`. The assembler replaces it with
the decimal offset **right-padded to a fixed width with spaces** —
`PAYLOAD_OFFSET=0             ` at ten columns — measures the assembled header's
byte length, then substitutes the real value at the same total width. Trailing
spaces are not part of the value, so no leading zero ever reaches `$(( ))`; the
length does not change, so one measurement pass is exact. No iteration, no
guessing, and `installer-check`'s payload-identity diff is what proves it.

## Design in this repo

One stage after `dist`, reusing the existing tarball byte for byte:

```
... -> dist (tar.gz) -> installer (.run = header + that tar.gz) -> installer-check
```

The `.run` payload **is** the proven tarball, so the installer inherits every
guarantee `distcheck` establishes; the header adds preflight, integrity and UX.
Naming mirrors `TARBALL`:
`INSTALLER := $(DIST_DIR)/$(DIST_NAME)-$(DIST_VERSION)-$(TARGET_PLATFORM)-$(BLAS_PROVIDER)-glibc$(GLIBC_FLOOR).run`.

### Preflight — the substance of the header

Order is **preflight → integrity → extract → post-validate**, and each stage owns
an exit code, so a batch install can branch on *why* rather than on a log:

| code | meaning |
|---|---|
| 0 | installed |
| 2 | usage error |
| 3 | host unsuitable — preflight refused |
| 4 | integrity failure |
| 5 | extraction failure |
| 6 | post-install validation failure |

Every check below needs only `/proc`, `df` and shell:

- **glibc** — the host's (`getconf GNU_LIBC_VERSION`, else `ldd --version`) against
  the baked-in **`glibc_floor_measured`**. Measured, not requested: the manifest
  records both because they are not the same number
  (`relocate/validate.sh:475-476`; 2.27 measured against a 2.28 request, per the
  README table). Refusing on the requested floor would turn away hosts the
  artifact demonstrably runs on — and A4 is the amendment that exists because that
  distinction was learned the hard way.
- **ISA** — against the baked-in `isa_baseline`, which is a knob and not a
  constant (`mk/common.mk:48-49`, resolved at `:78`), so the header carries a
  table rather than one hardcoded list: `x86-64-v2` needs
  `cx16 lahf_lm popcnt sse3 sse4_1 sse4_2 ssse3` in `/proc/cpuinfo` `flags`, `v3`
  adds `avx avx2 bmi1 bmi2 f16c fma movbe`, `v4` adds the `avx512` set;
  `armv8.1-a` needs `atomics` (LSE) in `Features` and `armv8.2-a` adds `asimddp`.
  A baseline the table does not know **refuses** (exit 3) — passing everything
  would silently turn the check off the first time someone raises the knob. The
  aarch64 case is A21 exactly: conda-forge emits unguarded LSE atomics in
  libraries we do not build, so "it is only a compiler flag" is false and the
  binary really will not run.
- **Disk** — `df -Pk` against a baked-in installed size, measured at the nearest
  **existing** ancestor of the prefix. `df` on a path that does not exist yet
  fails, and the prefix is exactly the thing we have not created.
- **glibc and version compares are numeric, field by field.** `2.9` sorts above
  `2.34` as a string, which would refuse a perfectly good host — so split on `.`
  and compare as integers, never with `[ "$a" \> "$b" ]` or `sort -V`, which is
  not guaranteed present.
- **Prefix** — writable; refuse a non-empty target unless `--force`.
- **Tools** — `tar` *and* `gzip`. A38 is the reason `gzip` is named separately:
  `opensuse/leap:15` ships `tar` without it, GNU tar's `-z` execs `gzip`, and the
  resulting `tar (child): gzip: Cannot exec` reads like a corrupt download. The
  installer should say the true thing instead.
- **SHA-256 — degrade, do not block.** Try `sha256sum`, then `shasum -a 256`, then
  `openssl dgst -sha256`; if none exists, warn and continue. gzip's CRC and tar's
  own structure already catch *corruption*, so the checksum is the tamper check,
  not the integrity check, and a missing tool must not block an install that is
  about to verify itself anyway. `--check` on its own is the exception: there the
  user asked for exactly that answer, so no tool means exit 4.

### UX

- **`--prefix DIR` installs *as* `DIR`.** `activate.sh` lands at
  `DIR/activate.sh`, via `tar --strip-components=1`. This is Miniforge's `-p`,
  which this repo already drives (`conda/bootstrap.sh:49-51`), and Intel's and
  NVIDIA's convention — a customer typing `--prefix /opt/libmesh-stack` and
  getting `/opt/libmesh-stack/stack/` would be right to file a bug. The assembler
  asserts the tarball has exactly one top-level entry, `stack/`, so the strip can
  never be silently wrong. Note that `--strip-components` is a GNU extension, not
  POSIX: GNU tar, bsdtar and busybox all have it, and all five base images ship
  GNU tar, so the narrowed claim is "`sh`, GNU-or-compatible `tar`, `gzip`" and
  the preflight says so when it refuses.
- Default prefix `$PWD/<DIST_NAME>-<DIST_VERSION>`. Never splat into `$PWD`.
- **`--extract-only [--dest DIR]`** reproduces the literal `DIR/stack` layout —
  what `tar xzf` gives today. This is the mode `installer-check` diffs against a
  plain untar of `$TARBALL`.
- Non-interactive by default: scripted installs on a login node are the normal
  case, not the exception. `--confirm` prompts; `-b` / `--batch` is accepted as
  quiet-and-no-prompt, for muscle memory carried over from Miniforge.
- `--info` (the baked-in metadata), `--check`, `--list`, `--force`,
  `--skip-validate`, `--quiet`, `--help`, `--version`.
- On success, print the activate line for the prefix that was actually resolved,
  not a generic one.

### Metadata comes from the manifest, not from make

The header's facts are read out of `stack/etc/stack-manifest.json` **inside the
tarball**, with `tar -xzOf "$TARBALL" stack/etc/stack-manifest.json` — the same
move CI already makes at `.github/workflows/stack.yml:605`. The `.run` then
describes the artifact rather than the build that was requested, which is the
distinction A37 was issued over. Bake in: name, version, platform, BLAS/MPI,
`glibc_floor_measured` *and* `_requested`, `isa_baseline`, `package_count`,
`git_sha`, `build_date`, payload SHA-256, payload bytes, installed KB.

### Files to add

- **`relocate/installer-header.sh.in`** — the header template, `#!/bin/sh`, POSIX.
  Placeholders substituted by the assembler (`@PAYLOAD_OFFSET@`,
  `@PAYLOAD_SHA256@`, `@PAYLOAD_BYTES@`, `@INSTALLED_KB@`, and the manifest
  fields). Implements the preflight, exit codes, UX and post-extract self-check
  above.
- **`relocate/make-installer.sh`** — the assembler. Reads `TARBALL`, extracts the
  manifest, computes SHA-256 / payload bytes / installed size, does the two
  width-stable substitution passes, concatenates header + marker + payload,
  `chmod +x`. No timestamps of its own (`SOURCE_DATE_EPOCH`); the payload is the
  reproducible tarball, so the `.run` is reproducible too. Also writes
  `dist/SHA256SUMS` covering both artifacts — the embedded checksum covers the
  payload, and nothing else covers the header. It lives here rather than in `dist`
  because it must name the `.run`; the consequence, stated so it is not a
  surprise, is that `make dist` alone produces no `SHA256SUMS`.
- **`test/installer-check.sh`** — the gate, mirroring `test/distcheck.sh` and both
  of its deliberate cruelties (different depth, a space in the path). Runs
  `--check`; installs into `".../a b/c/install"`; sources `activate.sh`; runs the
  smoke binaries via `test/run.sh relocated`; re-runs read-only. Plus two checks
  `distcheck` has no reason to make:
  - **`--extract-only` output diffed against a plain `tar xzf` of `$TARBALL`.**
    Payload identity is the premise this entire design rests on; assert it.
  - **Assemble twice, compare SHA-256.** Reproducibility is a claim this repo
    tests rather than states.

### Files to modify

- **`relocate/fixup-text.sh:299-302`**, where `activate.sh` is installed: also
  install `relocate/validate.sh` as `stack/libexec/stack-validate.sh`, so the
  *installed* tree can verify itself with no repo present. `--runtime` is
  loader-only and never reaches `depsolve.py` (`relocate/validate.sh:291`), so it
  ships cleanly. Two consequences to handle rather than discover:
  - It is `#!/usr/bin/env bash`. On a host without bash the post-extract
    self-check is **skipped with a notice** — it must never turn a working install
    into a failed one, and the minimal-host claim is `sh`, `tar`, `gzip`.
  - `docker/compose.yaml:95` mounts `../relocate` into the verify service for the
    sole purpose of reaching this script. Once it ships in the tree, that mount is
    removable — a smaller, more honest verify surface.
- **`mk/common.mk`** — `INSTALLER := ...` beside `TARBALL` (line 80).
- **`mk/stages.mk`** — `installer: dist` and `installer-check: installer`, each
  with a `## ` help line and a `.PHONY` entry, env-passing shaped like the
  `distcheck` recipe (lines 184-190); `all: distcheck installer-check`; `INSTALLER`
  added to `print-config` (lines 244-263). Both depend transitively on `dist`; the
  extra work is seconds.
- **`docker/compose.yaml:101-112`** — the `verify` service runs **both** legs in
  the one job: the tarball at a different depth exactly as today, then the `.run`
  into a second prefix, when one is present in `/dist`. Not "prefer the `.run`" —
  that would quietly retire the tarball path that `distcheck` and A38 were won on.
  The `.run` leg needs nothing mounted but `/dist`, which states the minimal-host
  claim more sharply than the current path does.
- **`.github/workflows/stack.yml`** — the build job already runs `make all`, so
  extending `all` gates the `.run` in CI for free. Widen the publish step
  (lines 690-697) to carry the `.run` and `SHA256SUMS` alongside the tarball. The
  `verify` matrix needs no new dimension: both legs run inside each of the five
  existing jobs, which is coverage without ten more runners.
- **`README.md`** — the one-file path in "Using the artifact", beside `tar xzf`.

## Where it gets proven

Inside the builder image is the *weakest* place to gate this: it is the one host
guaranteed to have every tool, so "needs only `sh`, `tar` and `gzip`" would stay
an assertion. The real gate is the five-distro `verify` matrix, on pristine images
poorer than the one that built the artifact — the same reasoning that makes
`Dockerfile.verify`'s package list "the honest answer to what a customer's machine
needs", and the same matrix that produced A38.

- `make installer-check` — payload-identity diff, reproducibility, checksum,
  install into a deep path containing a space, activate, smoke, read-only re-run.
  Runs under `make all`, on `linux-64` and `linux-aarch64`.
- The CI `verify` matrix runs the `.run` itself on all five base images, in the
  same job that runs the tarball, so neither path is traded for the other.
- Locally, the interesting one:
  `VERIFY_IMAGE=opensuse/leap:15 docker compose run --rm --build verify`.

By hand, once built:

```sh
make all                      # ... dist -> distcheck -> installer -> installer-check
RUN=dist/libmesh-stack-*.run

sh "$RUN" --info                            # what it is, measured not requested
sh "$RUN" --check                           # embedded SHA-256
sh "$RUN" --prefix "/tmp/it works/deep/stack"
. "/tmp/it works/deep/stack/activate.sh"    # the line the installer printed
mpicc --version                             # a prebuilt binary resolves and runs
```

## Not doing

Named so a future session does not re-derive them: signing and provenance
attestation (a different project, with key management attached); delta or split
payloads; a modulefile or Spack-package generator; anything Windows or macOS. The
`.tar.gz` stays either way — the `.run` is additive, and the day it becomes the
only way to get the stack is the day this was a mistake.
