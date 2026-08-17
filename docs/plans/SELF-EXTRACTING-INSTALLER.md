# Plan: a self-extracting installer for the redistributable stack

**Status:** planned, not started. Pick this up in a fresh session.

## Context

Vendor toolchains ship as a single executable shell script with a compressed
payload baked in — Intel oneAPI, NVIDIA's `.run` files, `makeself` output,
Miniforge. You run one file, it unpacks and installs itself. This repo is already
one header away from producing the same thing, because the hard part — a payload
that actually relocates — is done and proven.

`make dist` builds the relocatable `stack/` tree and tars it
(`mk/stages.mk:177-184`) into
`dist/$(DIST_NAME)-$(DIST_VERSION)-$(TARGET_PLATFORM)-$(BLAS_PROVIDER)-glibc$(GLIBC_FLOOR).tar.gz`
(`mk/common.mk:62`). `make distcheck` then *proves* that tarball: it unpacks at a
different path depth, under a directory whose name contains a space, moves the
original aside so nothing resolves back to it, validates, runs the prebuilt
binaries, and repeats read-only (`test/distcheck.sh`). The unpacked tree
self-activates via `stack/activate.sh`, which derives its own root from
`$BASH_SOURCE` and bakes in no absolute paths (`stack/activate.sh.in`).

The repo also already *consumes* this pattern: `conda/bootstrap.sh:49-51`
downloads `Miniforge3-Linux-*.sh` and runs `bash miniforge.sh -b -f -p $PREFIX` —
a self-extracting installer, used as a build-time input.

We want to **wrap the same, already-proven tarball** into a single self-extracting
`.run`, add a gate that proves the `.run` the way `distcheck` proves the tarball,
and upload it from CI. The `.tar.gz` stays; the `.run` is an additive
convenience — one file to get the stack onto real hardware.

Decisions taken up front: **hand-rolled `#!/bin/sh` header** (no `makeself`
dependency — it keeps the artifact auditable and matches this repo's
hand-written scripts and its minimal-host claim), and a **full self-installing
UX** (`--prefix`, `--extract-only`, `-b`/batch, `--check`, `--info`, an activate
hint, and an optional post-extract runtime validate).

## How a self-extracting installer works

A `.run` is three things concatenated into one executable file:
**`[shell header]` + `[marker line]` + `[raw tarball bytes]`**. When run:

1. The shell executes the header text at the top and stops at the last header
   command; it never parses the binary payload below it.
2. The header finds where the payload starts — a unique marker line, then
   `N=$(awk '/^__PAYLOAD_BELOW__$/{print NR+1; exit}' "$0")`.
   `tail -n +$N "$0"` streams every byte from that line onward verbatim (safe for
   binary: `tail` copies bytes once it has located the Nth line start).
3. It pipes those bytes into the extractor:
   `tail -n +$N "$0" | tar -xzf - -C "$prefix"`. `$0` is the script itself, which
   is how it reads its own payload.
4. Everything else is header polish: argument parsing, an embedded SHA-256 checked
   before extracting, a license gate (Intel), progress output, post-install steps.

`makeself`, `shar`, and the Intel/NVIDIA/Miniforge installers are all this shape,
differing only in header richness. We hand-roll so there is no build-time
dependency and nothing in the shipped artifact we did not write.

## Design in this repo

One stage, after `dist`, reusing the existing tarball byte-for-byte:

```
... -> dist (tar.gz) -> installer (.run = header + that tar.gz) -> installer-check
```

The `.run` payload **is** the proven tarball, so the installer inherits every
guarantee `distcheck` establishes; the header only adds extraction and UX. Naming
mirrors `TARBALL`:
`INSTALLER := $(DIST_DIR)/$(DIST_NAME)-$(DIST_VERSION)-$(TARGET_PLATFORM)-$(BLAS_PROVIDER)-glibc$(GLIBC_FLOOR).run`.

### Files to add

- **`relocate/installer-header.sh.in`** — the header template, `#!/bin/sh`, POSIX.
  Build-time placeholders substituted by the assembler: `@DIST_NAME@`,
  `@DIST_VERSION@`, `@TARGET_PLATFORM@`, `@GLIBC_FLOOR@`, `@ISA_BASELINE@`,
  `@PAYLOAD_SHA256@`, `@PAYLOAD_BYTES@`. Behavior:
  - `--help` / `--version` / `--info` (name, version, platform, glibc floor, size,
    sha256 — like `makeself --info`); `--prefix DIR` (default `$PWD`);
    `--extract-only`; `-b`/`--batch` (non-interactive, quiet); `--check` (verify
    the embedded SHA-256 against the payload, then exit without extracting);
    `--skip-validate`; `--force`.
  - Preconditions: require `tar`, `gzip`, and a sha256 tool
    (`sha256sum`/`shasum -a 256`); refuse to overwrite a non-empty `$prefix/stack`
    unless `--force`.
  - Verify `tail -n +$N "$0" | sha256sum` equals `@PAYLOAD_SHA256@` before
    extracting (escape hatch only via an explicit flag).
  - Extract with `tail -n +$N "$0" | tar -xzf - -C "$prefix"` → `$prefix/stack`.
  - Post-extract self-check (unless `--extract-only`/`--skip-validate`): run the
    shipped runtime validator (below) in `--runtime` mode — loader-only, no host
    Python — with the baked-in `GLIBC_FLOOR`/`ISA_BASELINE`.
  - On success, print the activate hint: `source <prefix>/stack/activate.sh`.

- **`relocate/make-installer.sh`** — the assembler. Reads `TARBALL`, computes its
  SHA-256 and byte count, substitutes the header placeholders, writes
  `header` + `\n__PAYLOAD_BELOW__\n` + `<tarball bytes>` to `INSTALLER`, then
  `chmod +x`. No timestamps of its own (respects `SOURCE_DATE_EPOCH`); since the
  payload is the reproducible tarball, the `.run` is reproducible too.

- **`test/installer-check.sh`** — the gate, mirroring `test/distcheck.sh`: run
  `INSTALLER --check` (checksum), then `--prefix` into a **deep path containing a
  space**, confirm `activate.sh` works, run the smoke binaries via
  `test/run.sh relocated`, and re-run **read-only**. Reuses `test/run.sh` and
  `relocate/validate.sh` exactly as `distcheck.sh` does.

### Files to modify

- **`relocate/fixup-text.sh`** (~line 267, where `activate.sh` is installed): also
  install `relocate/validate.sh` into the tree as `stack/libexec/stack-validate.sh`
  so the *installed* tree can self-verify with no repo present. `--runtime` mode is
  loader-only and never touches `depsolve.py` (that is on the `--full` path), so it
  ships cleanly. This makes both the tarball and the installer self-verifying — in
  keeping with the project's "prove it, don't claim it" ethos.

- **`mk/common.mk`** — add the `INSTALLER := ...` variable next to `TARBALL`
  (line 62); add it to the `print-config` block (`mk/stages.mk:209-222`).

- **`mk/stages.mk`** — add targets and `.PHONY` entries, each with a `## ` help
  line:
  - `installer: dist` → `$(SAY) RUN` then `bash relocate/make-installer.sh`,
    passing `DIST_NAME/DIST_VERSION/TARGET_PLATFORM/GLIBC_FLOOR/ISA_BASELINE/
    TARBALL/INSTALLER` in the env, like the other stage recipes.
  - `installer-check: installer` → `bash test/installer-check.sh`, with the same
    env shape as the `distcheck` recipe (`mk/stages.mk:187-192`).
  - Extend the default goal to `all: distcheck installer-check` so `make all`
    proves the installer too. Both depend transitively on `dist`; the extra `tar`
    is seconds. (Alternative: `installer: distcheck`, wrapping only a
    distcheck-passed tarball, with `all: installer-check`.)

- **`.github/workflows/stack.yml`** — the build job already runs `make all`
  (~line 412), so extending `all` builds and gates the `.run` in CI for free.
  Widen the tarball upload (path `dist/*.tar.gz`, ~lines 572-579) to include
  `dist/*.run` so it is downloadable as a workflow artifact alongside the
  `.tar.gz`.

## Verification (end to end)

```sh
make all                      # now ends: ... dist -> distcheck -> installer -> installer-check
ls -l dist/*.run              # exists and is executable

RUN=dist/libmesh-stack-*.run
sh "$RUN" --info                          # metadata
sh "$RUN" --check                         # verify embedded SHA-256
sh "$RUN" --prefix "/tmp/it works/deep"   # install into a path with a space
. "/tmp/it works/deep/stack/activate.sh"  # hint printed by the installer
mpicc --version                            # a prebuilt binary resolves and runs
```

- `make installer-check` is the automated gate (checksum + weird-depth extract +
  validate + smoke + read-only re-run). It and `distcheck` both run under
  `make all`, on `linux-64` and `linux-aarch64`, across the CI base images.
- Container loop unchanged: `cd docker && docker compose run --rm shell` then
  `make all`; the pristine `verify` service exercises the tarball, and the `.run`
  can be spot-checked the same way.

## Notes / decisions

- **Hand-rolled, not `makeself`** — zero new dependency; the header stays
  auditable and matches the repo's hand-written scripts.
- **Payload = the existing tarball** — no second packing path to drift; the `.run`
  is strictly the proven `tar.gz` plus a header.
- **`#!/bin/sh` POSIX header** — must run on a bare host, the same minimal-host
  claim `docker/Dockerfile.builder` encodes; depends only on `sh`, `tar`, `gzip`,
  and a sha256 tool.
- **Additive artifact** — the `.tar.gz` remains; the `.run` is an extra
  convenience for getting the stack onto real hardware in one file.
