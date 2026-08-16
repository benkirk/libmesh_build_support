# Plan: make the x86 ISA patterns cheap to match

**Status:** DONE. Landed as the two commits ahead of this one on the same
branch; measured on the real stack via a `profile_isa_scan` dispatch
(run 31925100526).

## Outcome, measured where the plan's numbers were measured

| phase | before | after | |
|---|---:|---:|---:|
| objdump | 51.9 s | 57.4 s | (runner noise) |
| `instructions()` | 32.5 s | 35.7 s | (untouched) |
| **searches** | **454.0 s** | **99.4 s** | **4.6×** |
| **scan total** | **538.4 s** | **192.4 s** | **2.8×** |

aarch64, untouched by design, stayed put: searches 17.8 s against the
recorded 17.9, scan 80.8 s against 81.1. The gate reports exactly what it
reported before, on both platforms: `all 341 objects within ISA baseline
x86-64-v2` with the same `7 object(s) above baseline but carrying CPUID
dispatch`, and `all 339 objects within ISA baseline armv8.1-a`.

The realized multiple on the searches is 4.6×, not the projected 7.15× —
that projection assumed X86_V3's factoring multiple carried uniformly to
all four passes, and it does not: CPUID is a single branch with nothing to
factor, and V2/V4 had less to gain. The verification the plan demanded all
ran: per-branch cases (self-test 21 → 82), 345,618-string brute-force
equivalence over every single-character mutation of every mnemonic, and
`isa-bench.py --compare-patterns` per-file diffs — identical on 1003
system-library objects locally. The one surprise worth recording:
`\bcrc32\b` never matched the suffixed `crc32b/q` forms objdump emits for
memory operands, a pre-existing false negative deliberately preserved,
since changing the accepted language was exactly what this change was not
allowed to do.

---

The plan as written, kept for the reasoning and the dead ends:

## Context

`relocate/isa-scan.py` disassembles every ELF object and looks for instructions
above the declared baseline. It was 40% of the linux-64 build. #16 changed its
executor from threads to processes and took **11 minutes off every x86 build**
(1267 s → 538 s, byte-identical output). What remains is a matching problem, and
this document exists so the next person does not re-derive it — two plausible
hypotheses were measured and killed on the way here, and a third was nearly
shipped with a bug.

All numbers below are from the real stack, 4 vCPU GitHub runners, via
`relocate/isa-bench.py` (`ci.yml` → *Run workflow* → `profile_isa_scan`).

### Where the time goes, after #16

| phase | linux-64 | | linux-aarch64 | |
|---|---:|---:|---:|---:|
| objdump | 51.9 s | 9.6% | 42.1 s | 51.9% |
| `instructions()` | 32.5 s | 6.0% | 21.0 s | 26.0% |
| **searches** | **454.0 s** | **84.3%** | 17.9 s | 22.1% |
| **total** | **538.4 s** | | **81.1 s** | |

Supporting figures: 915 vs 906 ELF objects, 4.21 vs 4.01 GB of disassembly,
1.93 vs 1.37 GB retained as instruction text.

**The searches are 84% of the linux-64 scan and 25× the aarch64 cost.** Per GB
per pattern that is **58.7 s against 4.4 s — 14×.** aarch64 has no problem worth
solving: after #16, objdump is 52% of its 81 s and matching is 18 s.

### Two hypotheses that were wrong

Recorded because both were plausible, both were written down as fact at some
point, and measuring is what settled them.

1. **"x86 disassembly is bulkier."** The guess was that OpenBLAS `DYNAMIC_ARCH`
   shipping kernels for every microarchitecture explained the 7× gap. It does
   not: 4.21 vs 4.01 GB, 915 vs 906 objects, objdump 52 s vs 42 s. The volumes
   match within 5%.
2. **"`instructions()` dominates."** It does two regex operations per line — a
   match and a sub — over ~100 million lines, and x86 AT&T output carries
   `# 404018 <sym>` comments on many lines, so the sub *matches and rebuilds a
   string* there where it mostly no-ops on aarch64. Sound reasoning, wrong
   answer: `instructions()` is **6%** of linux-64's scan and only 1.5× aarch64's.

What is left is the patterns themselves.

## The change

`X86_V3` is a 21-branch alternation, most branches `\b`-anchored. Python's `re`
does not factor common prefixes, so it retries every branch at every position.
Many branches share prefixes: `vfmadd|vfmsub|vfnmadd|vfnmsub` all begin `vf`,
`blsi|blsr|blsmsk` all begin `bls`.

Factoring those prefixes, measured on 66 MB of genuine x86 instruction text
(`--platform linux/amd64`, objdump over the six largest `/usr/lib64/*.so*`,
piped through the real `instructions()`):

```
X86_V3 as written        5.53 s
X86_V3 prefix-factored   0.77 s   -> 7.15x
```

If that multiple carries to all four patterns, the linux-64 searches go
454 s → roughly 65 s and the scan 538 s → ~150 s, taking the build from ~43 to
~36 minutes. **Combining the four patterns into one alternation is NOT the fix
on its own** — alternation cost is roughly (branches × text length) whether the
branches are split across four passes or merged into one, so merging buys only
the memory traffic of three fewer passes over 1.9 GB, not a factor of four.

### The trap, found in the draft patch

The 7.15× measurement above was taken with a factored pattern that **was not
equivalent**. `\bblsi\b|\bblsr\b|\bblsmsk\b` was rewritten as
`bls[imr]\b|blsmsk\b`, which also accepts `blsm` — a mnemonic the original never
matched. It does not exist in x86, so a corpus test reported "same verdict" and
the widening went unnoticed.

That is the whole risk of this change in one example. This is a gate whose job
is to not produce false positives; `isa-scan.py`'s own header records that
`libquadmath`'s eight `tzcnt` were "this scanner's last false positive on
x86-64", and `SELF_TEST_NEGATIVE` carries six line shapes it really produced. A
faster pattern that accepts one extra mnemonic is a worse gate, not a better one.

### What "verified" has to mean here

Three things, none of which the draft did:

1. **Factoring that provably preserves the accepted language**, argued branch by
   branch in the diff — not inferred from a corpus.
2. **A self-test case per branch.** `SELF_TEST` currently exercises about three
   of `X86_V3`'s 21 alternatives. Every branch that gets factored needs a
   positive case, and the near-misses (`blsm`, `vfnmadds`) need negative ones.
3. **A full-tree per-file diff**, not a boolean. `isa-bench.py --compare-executors`
   already has the shape: run old patterns and new over all 915 objects and
   require the per-file `features` dicts to be equal. Extending it to compare
   *pattern sets* rather than *executors* is the natural next step, and is
   probably the first commit of this work.

## Files

| File | Change |
|---|---|
| `relocate/isa-scan.py` | factor `X86_V4`, `X86_V3`, `X86_V2`; extend `SELF_TEST` / `SELF_TEST_NEGATIVE` |
| `relocate/isa-bench.py` | compare two pattern sets over the same tree, per-file |

Nothing else. No workflow, gate-semantics or manifest changes.

## Verification

- `relocate/isa-scan.py --self-test` — currently 21/21; must stay green and grow
  by roughly one case per factored branch.
- Per-file diff over a real built stack, old patterns vs new, via the extended
  bench. Any difference fails the change outright.
- A dispatch with `profile_isa_scan=true` for the before/after `searches_seconds`.
- The end-to-end gate: `validate` must still report `all N objects within ISA
  baseline x86-64-v2` and the same `7 object(s) above baseline but carrying CPUID
  dispatch` on linux-64.

## Considered and deprioritised: scanning fewer objects

Scan only the objects *we* compiled in fast CI, exhaustively on main and
`extended`. Attractive on the numbers — conda owns 88% of post-slim ELF objects
(301 of 342, 72% of bytes), and far more of the pre-slim tree the scanner
actually walks, since `prune` later removes 31 conda packages including
`gcc_impl` (200 MB) and `sysroot` (243 MB).

Rejected for now, on two grounds:

- **Cost.** Six files, and two of them change what "verified" means:
  `validate.sh` gains a third state between checked and unchecked, and
  `stack-manifest.json` — the artifact's own claim about itself — has to carry
  the scope, or a tarball asserts an ISA baseline it only partly verified.
- **It is the wrong trade if matching gets cheap.** Making the whole tree
  affordable keeps full coverage *and* the time. Scoping trades coverage for
  time, and only on pull requests.

Two notes for whoever revisits it. **Timestamps will not work**: `mk/stages.mk`
runs PATCHELF (:123) immediately before ISA-SCAN (:131), rewriting rpaths in
place and bumping every mtime. The right ownership signal is conda-meta, which
`relocate/prune.sh:4` already uses for exactly this reason — *"driven by each
package's conda-meta file list, never by path"*. And if it is ever built, the
non-negotiable rule is that a partial scan must never certify a `dist` tarball.
