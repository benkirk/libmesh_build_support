# Plan: documentation reorganisation

**Status: implemented.** The layout below is what was built: `README.md`,
`docs/DESIGN.md`, `docs/CI.md`, a refreshed `docs/EXTENDING.md`, the sprint
documents moved here, and `.github/scripts/check-md-links.py` gating every
link. Two corrections found on the way: the amendments run A1–A39 (A35 was
never issued), and there are seven workflows, not four. What follows is the
plan as written.

## Context

The sprint that built this repo produced its documentation as it went, which
means the docs are currently organised around *how it was built* rather than
*how it is used*. Three files carry nearly everything:

| file | lines | what it really is |
|---|---:|---|
| `docs/RELOCATABLE-STACK-PLAN.md` | 1454 | the sprint plan **plus** amendments A1–A34 |
| `docs/HANDOFF.md` | 283 | current state, measured numbers, hard-won gotchas |
| `docs/EXTENDING.md` | 168 | the customer contract — already the right shape |

`RELOCATABLE-STACK-PLAN.md` is 1454 lines and opens with a staged
implementation plan for work that is now finished. Nobody arriving at this repo
should have to read that to learn what the stack is. But roughly half of it —
the amendments — is the most valuable writing in the project, because each one
records a claim that turned out to be false and the measurement that disproved
it.

The goal is a README someone can read in five minutes, three reference documents
behind it, and the sprint material preserved as history rather than presented as
current.

## Target layout

```
README.md                                   ≤ 2 pages, two audiences, links out
docs/
  DESIGN.md                                 how and why it works
  EXTENDING.md                              adding your own packages (exists)
  CI.md                                     the matrix, and how to read it
  plans/
    DOCS_HANDOFF.md                         this file — in-work plans live here
    implemented/
      RELOCATABLE-STACK-PLAN.md             moved verbatim; the historical record
      HANDOFF.md                            moved after its live content migrates
```

`docs/plans/` holds work not yet done; `docs/plans/implemented/` holds finished
plans kept for their reasoning. Nothing in `implemented/` should be linked as
though it were current documentation.

## The rule that matters

**Do not paraphrase the measured material.** Amendments A1–A34 and HANDOFF's
"gotchas already paid for" are valuable precisely because they carry numbers and
mechanisms — *"4828 headers, so xargs runs grep in several batches, and a batch
matching nothing makes xargs exit 123"*. A tidier summary that drops the number
is worth less than the sentence it replaced. Move that text; do not rewrite it.

When DESIGN.md needs to state a constraint, state it and cite the amendment
(`see A29`), leaving the evidence where it lives.

## README.md — refresh, keep to two pages

It already exists and is roughly right in tone. It needs restructuring around
the fact that there are **two audiences**, and today it only serves one:

1. **What this is** — the claim in three sentences, and the fact that
   `make distcheck` proves rather than asserts it. Keep the existing text.
2. **Using the artifact** (new, and it should come first — most readers are
   here): download/unpack the tarball, `source activate.sh`, build against it
   with `pkg-config` / `libmesh-config`. Note that the tarball ships **no
   compiler** by design, and the whitespace-in-path limitation (A32).
3. **Building the stack** — the container loop, `make all`, roughly how long.
4. **What you get** — one table: packages and versions, both platforms, tarball
   size, ELF count, glibc floor, ISA baseline. Take the numbers from
   `docs/HANDOFF.md`; they are measured, not estimated.
5. **The knobs worth knowing** — 6–8 rows at most (`TARGET_PLATFORM`,
   `BLAS_PROVIDER`, `MPI_FAMILY`, `GLIBC_FLOOR`, `ISA_BASELINE_*`, `PROFILE`,
   `SHIP_PYTHON`). Everything else is `make print-config`.
6. **Where to go next** — the three docs, one line each.

Keep the CI badges. Cut anything that duplicates DESIGN.md.

## docs/DESIGN.md — new

The reference for how it works and why it is shaped this way. Assembled from
existing text, not written fresh:

- **The core decision** — the conda env *is* the redistributable prefix; there
  is no staging tree and no harvest step. Take the argument from
  RELOCATABLE-STACK-PLAN's design section, including why the harvest approach
  was rejected: "did I delete something needed?" is a bounded question that
  `distcheck` answers; "did I copy everything?" is not.
- **The pipeline** — conda → wrappers → build → test → relocate → validate →
  test → slim → prune → validate → dist → distcheck, with one paragraph per
  stage on what it guarantees. `mk/stages.mk` is the authority; keep this
  descriptive.
- **Why RPATH not RUNPATH**, why `$ORIGIN`, why whole-package prune granularity
  (`dlopen`ed plugins are invisible to any dependency closure).
- **The ISA baseline and the compiler wrappers** — `-march` is last-wins,
  `CFLAGS` go first, so the only place to stand is between the build system and
  the compiler. Summarise `wrappers/README.md`; do not duplicate it.
- **Constraints found by measurement** — a scannable list, each one sentence
  plus a citation: the aarch64 floor is `armv8.1-a` (A21), the prefix is sealed
  after `make conda` (A28), nothing is re-runnable over its own output (A20,
  A30), build tools are pinned to the era of the sources (A23), a space in the
  install path breaks the make fragments (A32). Move HANDOFF's "gotchas already
  paid for" here wholesale.
- **What is verified, and how** — the measured results table and the
  cross-distro runs.

## docs/CI.md — new

Nothing documents the CI today; it arrived as `.github/workflows/*.yml` with the
reasoning in the workflow comments.

- The four workflows and what each is for (`checks`, `ci`, `extended`, `stack`).
- **Build once, verify everywhere** — one build job publishes a tarball
  artifact, a fan-out of verify jobs consumes it on other base images. This is
  the same split as `docker/compose.yaml`'s `build`/`verify` services, scaled
  out, and that is deliberate: a green local `compose run verify` is supposed to
  mean something about CI.
- How to reproduce a CI failure locally — the `docker compose` equivalents, and
  the diagnostics artifact each build job uploads.
- How to read the run summary (ISA baseline, glibc floor, CPUID counts) and what
  each number means.
- **Worth stating plainly:** CI caught a bug that four clean local `make all`
  runs did not (A34). That is the argument for the matrix, and it belongs in the
  document that explains it.

## docs/EXTENDING.md — light refresh

Already the right shape and recently updated. Only:
- point at `DESIGN.md` rather than `RELOCATABLE-STACK-PLAN.md`;
- make sure the worked example (`examples/site-package/`) and the
  `libexec/stack-tests/` contract are near the top, since they are what a reader
  actually needs.

## Mechanics

1. `git mv` the two sprint documents into `docs/plans/implemented/` so history
   follows them.
2. **Audit every reference.** The path `docs/RELOCATABLE-STACK-PLAN.md` is cited
   from README, both other docs, and several shell scripts' comments; amendment
   numbers (`A5`, `A10`, `A15`, `A17`, `A19`, `A20`, `A29`) are cited from inside
   `relocate/*.sh`, `conda/*.sh`, `pkgs/*/build.sh` and `mk/*.mk`. Amendment
   *numbers* stay valid; the *path* does not. Fix with:
   ```sh
   grep -rn "RELOCATABLE-STACK-PLAN\|docs/HANDOFF" --include='*.md' \
        --include='*.sh' --include='*.mk' --include='*.yml' .
   ```
3. **Add a link check to `.github/workflows/checks.yml`** so this cannot rot:
   every relative link in every tracked `*.md` must resolve to a file that
   exists. That check is a few lines of shell and is exactly the kind of thing
   this repo already does elsewhere — assert the artifact, not the intention.

## Verification

- `README.md` is ≤ 2 pages rendered, and a reader who only wants to *consume*
  the tarball never has to leave it.
- The new link check passes, and fails if you deliberately break a link.
- No file outside `docs/plans/implemented/` reads as a plan for future work.
- Amendments A1–A34 survive **verbatim**; `git log --follow` still reaches their
  history.
- Every measured number in README/DESIGN traces to `docs/HANDOFF.md` as it
  stands before the move — no new estimates introduced.

## Explicitly out of scope

Rewriting the amendments, renumbering them, or "cleaning up" their prose.
