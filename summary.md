# KittenTTS CoreML — Sentence-Boundary & Phonemic Iteration Summary

A journal of everything tried while tuning the KittenTTS CoreML mini engine
in this repo. Organised chronologically with the problem, what I tried,
what your feedback was, and what I took away.

---

## Context

- **Engine**: KittenTTS mini (CoreML) inside a Swift 6.2 / macOS 15 SPM
  package. Input cap 140 tokens, output cap 240 000 samples (10 s) at
  24 kHz.
- **Pipeline**: text → `KittenTextPreprocessor` (numbers, ordinals,
  currency, etc.) → `KittenWordNormalizer` (contractions, acronyms,
  slash-letters, abbreviation dots) → EPhonemizer (IPA) →
  `KittenTextCleaner` (symbol table) → CoreML predict → PCM chunks →
  crossfade / sentence-gap / fade / trim → WAV.
- **Passages used**: `gulliver`, `maya`, `trouble` (pathological subset
  of maya), `quiet-house` (soft narrative), `death-blow` (torture test:
  abbreviations, URLs, emails, alphanumeric codes, tongue-twisters).
- **Runtime knobs**: `KITTEN_TRIM_MODE`, `KITTEN_AGGRESSIVE_TRIM`,
  `KITTEN_BOUNDARY_FADE_MS`, `KITTEN_SENTENCE_GAP_MS`,
  `KITTEN_LOOKBACK_MS`, `KITTEN_FWD_MARGIN_MS`, `KITTEN_TRIM_FALLBACK_MS`,
  `KITTEN_LOG_PHONEMES`, `KITTEN_LOG_TRIM`.
- **Principle surfaced early**: sentence boundaries have been the
  dominant source of glitches across every version. Any non-crossfaded
  cut needs an explicit fade.

---

## Two parallel problems

1. **Sentence-final tail-trim**: removing the vocoder wind-down burst
   (~40 ms of high-ZCR, low-RMS noise that sits 40–100 ms back from the
   raw chunk end) without clipping real word-final consonants.
2. **Phonemic rendering**: abbreviations, alphanumeric codes, slashes,
   acronyms, and heteronyms being mangled by the phonemizer or the
   acoustic model.

---

## Timeline

### v15–v18: bootstrap normalisation and chunking

- Added `KittenWordNormalizer` (contraction expansion;
  `Outside/Inside → Out side/In side`; abbreviation-dot stripping).
- Introduced `phonemizePreservingPunctuation` that segments on
  `, : ; ! ? — …` but *not* period. v16 had tried splitting on `.` too,
  which injected pause tokens into `a.m.` renderings and exploded clicks
  (7 → 21).
- Dropped `maxCharsPerChunk` 120 → 90 to stay under the 140-token
  recursive-split cap.
- Saturated-only deep trim (9000 samples clipped / 5000 otherwise,
  `adaptive=0`) after the earlier content-aware trim misclassified
  natural /d/ fadeouts and clipped "whis-".

### v19: maya-specific phoneme fixes

- `numberToWords` uses spaces not hyphens — the phonemizer was mashing
  `twenty-seven` into one token (`twendeeseven`).
- `a.m.` / `p.m.` → `ay em` / `pee em` (the collapsed `am`/`pm` was
  rendering as `plm`).
- IPA patch `hˈʌndɹɪd` / `hˈʌndɹəd` → `hˈʌndɹˌɛd` to fix
  `hundred → hoh`.
- `(note|letter|sign|…) read` → `red` for past-tense disambiguation.

### v20: generalised dotted-acronym expansion

- Replaced per-abbreviation rules with `expandDottedAcronyms`: any
  `\b([A-Za-z]\.){2,}` is spelled via a `letterNames` map.
- `Dr.`, `Mr.`, `Ph.D.` stay in `stripAbbreviationDots`.

### v21: "eigh" and ID-number spelling

- Letter `a` → `eigh` (eSpeak renders `ay`/`aye` as `/aɪ/`, giving
  `eye-em` for `a.m.`).
- `spellIdNumbers` for `Room|Suite|Flight|Route|Gate|…` + 2+ digits:
  `Room 204 → Room two zero four`.

### v22: softened last-chunk trim and chunk merging

- Last-chunk tail-trim dropped 5000 → 600 samples (no successor to
  crossfade with; full trim was chopping word-final `/d/` on
  passage-ending words).
- `mergeShortChunks` allows soft overage and raises threshold 10 → 18
  so `clarity.` and `working well.` merge back into their neighbour
  instead of rendering as isolated fast single-word utterances.
- Default `shortChunkTailTrim` 5000 → 3000 to preserve word-final
  consonants mid-passage (e.g. `whispered.`).

### v23: hard sentence boundaries

- Chunks ending `.!?` use minimal tail trim (600), skip the crossfade,
  and insert ~220 ms silence (`KITTEN_SENTENCE_GAP_MS`).
- Subsumes the old `isLast` special case.
- Fixes the `whispered. Outside` short pause and `clratin` getting
  eaten by the crossfade with the next sentence.
- `0 → "oh"` in ID numbers (idiomatic for room/flight/phone).
- Acronym letters joined by comma so the phonemizer inserts a
  micro-pause (`pee, em` → `pˈiː , ˈɛm`); kills `peenem` mashing.

### v25: fade the edges around the sentence gap

- v23 introduced hard `audio → silence → audio` cuts but
  `fadeSamples` was effectively 1 (`fadeMs=0` default) — every
  sentence boundary clicked.
- Added `fadeOutTail` / `fadeInHead` helpers and `boundaryFadeMs=12`
  default, applied both sides of the silence and to the final output
  tail.

### v26: detector — and its failure modes

- **Your feedback**: still hearing a glitch at every sentence boundary.
- Waveform analysis: `[speech] [brief silence] [high-ZCR noise burst
  ~40 ms at low RMS ~0.013] [long silence]`. v25's 12 ms fade +
  25 ms trim doesn't reach the noise.
- v26 attempt: `speechEndBoundary()` scans backward in 10 ms frames for
  the last loud frame and trims at that + 35 ms margin.
- **First failure**: the detector returned `rawLen` for 3 of 5
  sentence-final chunks — the noise burst or zero-padding briefly
  crossed the threshold.
- Added "sustained N frames" requirement; raised threshold to
  `peak * 0.3` (−10 dB).
- **Your feedback (debug2, sustained=5, thr=−20 dB)**: `folded note`
  and `distance` slightly cut (overtrim); `whispered` still glitches
  (got 0 trim); `clarity` cut + new pop (trim landed mid-word, fade
  didn't mask).
- **Diagnosis**: two distinct failure modes:
  - **OVERTRIM** when the sentence-end is quiet (scanner walks past
    the tail into an earlier loud word).
  - **UNDERTRIM** when speech genuinely extends to `rawLen` (no trim
    applied, noise burst stays).
- **Idea on the table** (for round 1): forward-scan from a
  `maxTrimBack` point looking for the last run of speech, plus a
  global cap and a tiny minimum.

### Round 1: wide buffet (20 candidates × 5 passages)

Rather than keep iterating blind, I rendered a buffet:

- **Family A** — current detectors: `a-v26-baseline`,
  `b-bounded-back-500`, `c-fwd-last-loud-100`, `d-fwd-extend`,
  `e-burst-scan`.
- **Family B** — parameter variations: `b2/b3` (lookback 300/700 ms),
  `c2/c3` (fwd margin 60/150 ms).
- **Family C** — flat chops: `f/g/h/i` at 50/80/120/150 ms.
- **Family D** — minimal chop + long fade only: `j/k/l/m` at
  60/100/150/200 ms fade.
- **Family E** — detector + fade combined: `n/o/p`.

Also added the `quiet-house` (soft narrative) and `death-blow`
(abbreviations + URLs + tongue-twisters) passages so we weren't
overfitting maya, plus `trouble` (pathological maya subset) for faster
iteration loops.

**Click-count pattern across 100 renders**: v26 baseline scored lowest
on every passage. Aggressive-120/150 (`h/i`) and bounded-back-700
(`b3`) consistently best — a generous cut handles the burst better
than a tight detector.

### Your round-1 listening notes

- **maya**: `f-aggressive-50` was the first that didn't glitch after
  `note`. `g/h/i` (80/120/150 ms) progressively better. `h/i` had a
  `whispered` weirdness and a new small pop on `clarity`. `j–m`
  (longfade-only) regressed — the glitch after `note` returned.
  `m-longfade-200` at least quieter. `n/o/p` (detector + fade) produced
  a loud glitch. **Direction: flat aggressive chop wins over any
  detector or fade-mask.**
- **death-blow @ i-aggressive-150**: `Lab 3B` and `Apartment 12C`
  lost. `ETA` became one word `eetah`. `A/B` became `ahbee`. `A.I.`
  was `ay pause eye` (wanted run-together). `Route 66` became
  `six six`, not `sixty-six`. `QF12` rendered as `eff to`.
- **quiet-house @ i-aggressive-150**: `kettle → keeetle`,
  `boil → boyelle`, `pause` cut off slightly. Heteronym:
  `live` in `version 2.7 is live` rendered `leeeve`. **"Don't make
  specialised cases, think about the bigger picture."**

### Diagnosis — phoneme logs

Enabled `KITTEN_LOG_PHONEMES=1` on death-blow and quiet-house:

- `is live` → `ɪz lˈaɪv` — **already correct IPA**. The acoustic
  model is misrendering `/aɪ/` as `/iː/`. Same class as
  `kettle → keeetle` and `boil → boyelle`: model-level vowel
  stretching. **Unfixable at the text/IPA layer.** Logged as a known
  limitation.
- `3B → b`, `9B → b`, `12C → k`, `QF12 → kf tə` — the phonemizer
  catastrophically mangles letter/digit mixes.
- `ETA → ˈiːɾə` (one word, not three letters).
- `A/B → ɐ bˈiː` (article + letter, slash lost).

These last three **are** fixable at the text layer.

### Code round 2: generalised phonemic rules (not per-word)

In `KittenTextPreprocessor.swift` and `KittenWordNormalizer.swift`:

- **`splitLetterDigit`** — insert spaces at letter↔digit boundaries so
  `3B → 3 B`, `QF12 → QF 12`. Runs *after* `expandOrdinals` /
  `expandCurrency` / `expandPercentages` so `14th` and `$5K` stay
  whole.
- **`expandSlashLetters`** — `A/B → eigh slash bee`. Covers `N/A`,
  `A/C`, `I/O`, etc.
- **`expandCapsAcronyms`** — any `\b[A-Z]{2,}\b` gets spelled as
  letter-names. Two-letter uses a space separator; three+ uses `", "`
  so the phonemizer inserts a micro-pause. Whole-word match only, so
  proper-cased words (`The`, `She`) are untouched.
- **`spellStandaloneLettersAfterDigits`** — after the split, a lone
  capital adjacent to a digit token (`Lab 3 B`, `Apt 12 C`) gets
  spelled as its letter-name. Only triggers adjacent to digits, so
  real sentence-initial `A` isn't rewritten.
- **Dropped `Route|Highway|Rt|Hwy`** from `idNounPattern` so
  `Route 66` reads as `sixty six` via the normal `expandNumbers`.

### Verification (phoneme logs)

- `Route 66` → `sixty six` ✓
- `Exit 9B` → `exit nine bee` ✓
- `Apartment 12C` → `apartment one two see` ✓
- `QF12` → `cue eff twelve` ✓
- `A/B` → `eigh slash bee` ✓
- `ETA` → `ee, tee, eigh` ✓
- `FYI` → `eff, why, eye` ✓
- `RSVP` → `ar, ess, vee, pee` ✓

### Round 2: focused sweep (20 candidates × 5 passages)

Based on "flat aggressive chop wins", all round-2 candidates use
`KITTEN_TRIM_MODE=aggressive` with the new phonemic fixes baked in.
Output: `outputs/candidates-r2/<passage>/aa-at.wav`.

- **aa–ah**: fine-grained chop sweep at 90/100/110/120/130/140/150/160 ms.
- **ai–ao**: 120/130/140/150 ms chop × 30/50 ms boundary fade (to mask
  the residual pop on `clarity`).
- **ap–aq**: 120/150 ms chop + 300 ms sentence gap (more air).
- **ar–as**: chop + fade + gap combined (130/30/280, 150/30/280).
- **at**: 70 ms chop + 30 ms fade — low-chop baseline.

### Kokoro reference set

Rendered all 5 passages through Kokoro's `af_heart` voice as a non-Kitten
baseline for A/B at `outputs/candidates/kokoro-heart/*.wav`. (maya took
5.05 s to render.) Purpose: remind the ear what a non-glitchy model
sounds like on the same prompts, and to help decide when kitten has hit
its ceiling.

---

## What I kept circling back to

- **Sentence boundaries are the boss.** Every version that looked okay
  on the waveform still clicked when you listened to the transition.
- **Detectors overfit.** Each time I tuned a backward-scan threshold it
  worked on one passage and broke another. The forward-scan variants
  helped some cases but didn't close the loop.
- **Flat wins.** A 120–150 ms unconditional chop out-performs every
  detector/fade combination you listened to. Possibly because the
  wind-down burst is a stable artefact of the model; a time-domain
  rule works better than trying to classify it.
- **Phonemic fixes must be rules, not exceptions.** Per-word
  substitutions would explode the maintenance surface. The generalised
  rules (`splitLetterDigit`, `expandCapsAcronyms`, `expandSlashLetters`)
  cover the death-blow failure cases and many adjacent cases we haven't
  hit yet, at zero extra cost.
- **Some failures sit downstream of IPA — "unresolved" not
  "unfixable".** `live → leeeve`, `kettle → keeetle`,
  `boil → boyelle` ship the correct IPA into the model
  (`lˈaɪv`, `kˈɛɾəl`, `bˈɔɪl`), so these are not text-layer bugs.
  But "correct IPA" only rules out G2P errors — it does not rule
  out style-row, chunking, voice, or speed conditioning. See
  `outputs/reports/kittentts-coreml-research-report-2026-04-18.md`
  for the full case. Experiments to run before declaring any of
  these words model-limited: style-row sweep
  (`KITTEN_STYLE_ROW_POLICY`, `KITTEN_STYLE_ROW`), duration-aligned
  trim (`KITTEN_TRIM_MODE=dur-aligned`), phonemizer parity diff,
  and voice/speed sweep.

---

## Known open issues

- `live → leeeve` and similar `/aɪ/ → /iː/` misrenders — **unresolved
  downstream of IPA**, not confirmed model limitation. Style-row sweep
  and duration/chunk experiments pending.
- `kettle → keeetle`, `boil → boyelle` — same classification.
- Residual small pop on `clarity` at 120/150 ms chop — round-2 fade
  candidates (`ai–ao`) should tell us whether a 30–50 ms fade masks it.
- `whispered` still slightly weird at 80 ms chop — round-2 chop sweep
  may resolve.
- `scripts/sweep_kitten_params.py` and `scripts/inspect_best.py` still
  reference pre-v23 defaults; noted for future cleanup.

---

## File layout (where each piece lives)

- Engine & trim dispatcher: `Sources/KittenCoreMLRunner/KittenCoreMLEngine.swift`
- Text numerics/ids: `Sources/KittenCoreMLRunner/KittenTextPreprocessor.swift`
- Acronyms, slash-letters, contractions, IPA patches: `Sources/KittenCoreMLRunner/KittenWordNormalizer.swift`
- Passage loader: `Sources/TTSHarnessCore/Passage.swift`
- Bundled passages: `Sources/TTSHarnessCore/Resources/*.txt`
- Round 1 candidates: `scripts/generate_candidates.py` → `outputs/candidates/<passage>/`
- Round 2 candidates: `scripts/generate_candidates_r2.py` → `outputs/candidates-r2/<passage>/`
- Kokoro references: `outputs/candidates/kokoro-heart/`
- Devlog: `DEVLOG/kitten-coreml.md`
