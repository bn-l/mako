# Phase 0 — Phoneme-inventory parity report

**Date.** 2026-04-19

**Kokoro vocab source.** `/Users/bml/.cache/fluidaudio/Models/kokoro/vocab_index.json`
(114 entries, downloaded by FluidAudio on first run). Contains the union of
punctuation + phonemes — every IPA token the Kokoro token-id vocabulary accepts.

**Dict sources tested.**
- `scratch/kokorog2p/kokorog2p/en/data/us_gold.json` (90 213 entries)
- `scratch/kokorog2p/kokorog2p/en/data/us_silver.json` (93 361 entries)

**Method.** For each `(word, pos-variant)` pair, split the IPA string by Unicode
scalar and assert every scalar is in the Kokoro vocab set.

## Results

| Dict       | Total (word × variant) | Clean | Dirty | `null` IPA |
|------------|-----------------------:|------:|------:|-----------:|
| us_gold    |                 91 019 | 90 952 |     0 |         67 |
| us_silver  |                 93 361 | 93 361 |     0 |          0 |

**Unique invalid tokens.** Zero.

**`null` IPA entries.** 67 in us_gold. These are POS variants explicitly marked
unpronounceable in that context (example: `'AA': {'DEFAULT': 'ˈɑˌɑ', 'NOUN': None}`
means "AA has no NOUN pronunciation distinct from DEFAULT — treat as absent").
They are not parity failures, they are a lookup signal.

## Conclusions

1. **Phase 6 (IPA→Kokoro phoneme conversion) is NOT needed.** Parity is clean
   at the Unicode-scalar level. The current `ipa.unicodeScalars.map { String($0) }`
   shortcut continues to work for the ported dicts. The plan's Phase 6 exit
   criterion ("zero FluidAudio `no tokens in Kokoro vocabulary` warnings") can
   be satisfied without any translation table.
2. The `null` variants should be materialised into the Swift `LexiconEntry`
   type as a "no variant-specific pronunciation" signal — not dropped.
   `LexiconEntry.byPOS` must allow `Optional<[String]>` values or use a
   sentinel.
3. Kokoro's vocab is already pure per-Unicode-scalar, so no "multi-scalar
   atom" issue materialises for us_gold/us_silver either. The checkpoint F
   concern about `tˈɹ`-style atoms is moot for these dicts.
