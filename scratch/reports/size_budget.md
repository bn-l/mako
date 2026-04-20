# Phase 0 — dict size budget

**Measured 2026-04-19, CPython 3.13, Apple Silicon.**

| Dict       | on-disk JSON | gzipped | in-memory dict | load time |
|------------|-------------:|--------:|---------------:|----------:|
| us_gold    |    2 930.7 K |  716.5 K|     18 593.9 K |   14.6 ms |
| us_silver  |    3 026.9 K |  675.7 K|     18 838.5 K |   14.9 ms |

**Entry count.** us_gold: 90 213 words; us_silver: 93 361 words.

## Finding: the plan's size claim is partly reconciled

PLAN_port_kokorog2p.md states `kokorog2p ships us_gold.json (~179k) + us_silver.json (~187k)`.
The raw on-disk JSON entry counts are 90 213 + 93 361.

The 179k/187k in kokorog2p's README refers to the **post-expansion** dict
exposed at runtime — `EnLexicon._grow_dictionary` (en/lexicon.py line 257)
auto-generates a capitalised variant for every lowercase entry and vice
versa, roughly doubling the key count without adding new pronunciations.

So both numbers are "right" depending on whether you count pre- or
post-grow entries. The port must decide:

- **Ship raw 90k/93k JSON and reproduce `_grow_dictionary` at load.**
  Simpler, smaller bundle, ~20 lines of Swift.
- **Ship pre-expanded 180k/187k JSON.** Faster cold start, but ~2×
  bundle size and the build pipeline has to run a Python generator.

**Decision.** Ship raw JSON; reproduce `_grow_dictionary` in Swift at
load. The 14.6 ms current load time doubles at most.

The comparison against FluidAudio's cached `us_gold.json` (~90k raw)
is therefore apples-to-apples: both dicts are the same physical size.
kokorog2p's advantage on lexicon coverage over Misaki is **unverified**
and probably marginal — the key motivation for the port shifts entirely
to pipeline + span API, not coverage. The plan's "why port" points 4-5
need rewriting to reflect this.
The port's actual value is:

1. Context-aware abbreviation expansion.
2. Number/ordinal/currency/unit expansion.
3. Span-based override API.
4. POS-variant machinery we control in Swift (FluidAudio's runtime variant
   handling remains opaque).
5. Offline oracle independent of FluidAudio's bundled cache refresh schedule.

Point 4 in the original plan ("larger proper-name coverage") should be
re-verified before we claim it — see `scratch/reports/coverage_diff.md`
(TODO) for the gold-key set diff.

## Swift bundle impact

Both dicts combined = 5 957 K on disk = ~1.4 MB gzipped. For comparison,
the existing app binary is order-of-magnitude larger. Ship uncompressed
in `Resources/`: the 14-15 ms per-dict load is negligible (far under any
TTS synthesis path).

**Decision.** Ship both as uncompressed bundled resources at
`Sources/TTSHarnessCore/Resources/kokorog2p/`. No lazy-load needed.
Lazy-loading silver would save ~19 MiB of resident memory, but the TTS
stack's own model memory is two orders of magnitude larger — not worth
the code complexity.
