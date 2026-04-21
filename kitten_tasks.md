# Kitten TTS follow-up tasks

Archived from the main task list on 2026-04-21. These belong to the
pre-Kokoro KittenTTS CoreML investigation (see `summary.md` for the
full history). The project has since pivoted to Kokoro via FluidAudio
+ the kokorog2p port (Phase 9b closed). These tasks are not stale in
content — they describe real open questions about KittenTTS — but
they are stale in priority. Revisit only if Kitten becomes relevant
again.

Ordering below reflects the original dependency chain: consolidation
(#48 → "Round 3 summary") depended on every probe landing first.

---

## 1. Investigations (probes)

Each probe attacks a different axis of the `live` / `kettle` / `boil`
/ `clarity` mispronunciation failure mode in Kitten-mini.

### 1a. IPA variant sweep (consolidates original #43 + #51)

**Original tasks merged:** the mechanism half of #43
(`KITTEN_IPA_OVERRIDE`) is now superseded by the per-word override
mechanism delivered in #52 (completed). The surviving work is the
probe itself — systematic IPA substitution for each stuck word.

Generate per-word candidate transcriptions, render each, A/B listen:

- **live** (lˈaɪv → "leeve"): lˈaɪv, lˈɑɪv, laɪv (no stress),
  lˌaɪv (2nd stress), ɫˈaɪv (dark l), lˈaɪːv (long diphthong),
  lˈaɪv̥ (devoiced v), lˈaʲv, lˈaɪvə (epenthetic schwa),
  lˈaɪf (test fricative swap), lˈæɪv.
- **kettle** (kˈɛɾəl → "keeetle"): kˈɛtəl (non-flapped),
  kˈɛtl̩ (syllabic l), kˈɛt̬əl, kˈɛɾl̩, kˈɛʔəl (glottal),
  kˈɛdəl, kˈɛɾᵊl, kˈɛɾʊl, kˈɛɾɑl, kˈɛɾˌəl, kˈɛtəɫ.
- **boil**: bˈɔɪl, bˈɔjl, bɔɪl.
- **clarity**: klˈæɹɪɾi, klˈæɹəɾi, klˈæɹəti (full-t), klˈæɹɪti.
- **Stochasticity characterization:** render "AI tools are live" 5×
  with identical IPA to measure variance; then test whether any
  variant stabilises it.

**Deliverable:** `outputs/ipa-variants/{word}/v{N}.wav` plus manifest
JSON with IPA used. Goal: find a transcription the model renders
reliably per word; failing that, characterise the stochasticity.

### 1b. espeak-ng upstream IPA comparison (original #44)

EPhonemizer hardcodes en-us and uses a minimal espeak-ng C++ port with
single en_rules/en_list data files — no runtime dialect swap without
replacing data files, and cross-dialect data wouldn't cleanly work.

**Redirected approach:** use upstream Python `phonemizer.EspeakBackend`
as the reference, pipe its IPA into Swift via a new
`KITTEN_IPA_CHUNK_OVERRIDE_FILE` (JSON text→IPA map) to test whether
feeding bit-exact upstream IPA rescues `live` / `four` / `more` etc.

- **If yes:** our Swift phonemizer is the weak link.
- **If no:** it's model-side, escalate.

### 1c. Voice/speed sweep on micro-corpus (original #34)

Conditional gate is met (style-row, phonemizer local parity,
dur-aligned all came up empty on live/kettle/boil/clarity).

1. Enumerate available Kitten mini voices (read from model
   config / voices manifest — do not guess).
2. Script `scripts/voice_speed_sweep.py`: for each voice × speed in
   {0.9, 1.0, 1.05, 1.1}, render micro-corpus at baseline trim
   (aggressive-150 + 30 ms fade). Output:
   `outputs/voice-speed-sweep/<voice>-<speed>/<passage>.wav`.
3. Tabulate clicks/pauses/duration via glitch_detection; write
   `outputs/reports/voice-speed-sweep.md` with a grid.
4. Hand to user to listen for live/kettle/boil/clarity/whispered.
5. **Decision:** if one voice/speed materially fixes the bad vowels
   without wrecking passage quality, that is the workaround; if all
   fail similarly, this is strong evidence of Kitten-mini acoustic
   limits and routes toward Kokoro fallback (which is now the
   shipping path).

Do NOT select winners by click count — listening gates this.

### 1d. Stress-mark ablation + Unicode/combining-mark sanity (original #45)

Two-part phoneme-string hygiene check.

**Part 1 (stress ablation):** Add
`KITTEN_STRIP_STRESS=primary|secondary|both|none`. Render micro-corpus
under each setting and listen for vowel-quality response on
live/kettle/boil.

- If removing primary stress moves vowel quality → stress placement
  is the conditioning signal, not vowel IPA.
- If nothing moves → stress is not the handle.

**Part 2 (Unicode sanity):** Write `scripts/unicode_scalars_trace.py`
that dumps, for each phoneme-string our engine sees: raw UTF-8 bytes,
Unicode scalars (U+XXXX), NFC vs NFD form, any combining marks
(U+0300-036F) or zero-width chars (U+200B-200F, U+FEFF). Verify
stress marks are ˈ (U+02C8) and ˌ (U+02CC), not decomposed; confirm
no stray ZWJ/ZWNJ from espeak-ng or normalization. Any anomaly is
a concrete implementation bug.

### 1e. Chunk / context sweep (original #47)

Exercise the axis the reports flagged: Python chunks text THEN
phonemizes; Swift phonemizes whole text THEN token-chunks; local
runner uses small text chunks. Add/verify env knobs:

- `KITTEN_MAX_CHARS` (existing?) — values: current, 120, 150, 200
- `KITTEN_CHUNK_POLICY`: `text-first` | `phonemize-first` |
  `whole-sentence-single-pass` (fall back to `text-first` if input
  exceeds the 140-token cap)

Script `scripts/chunk_context_sweep.py` renders micro-corpus under
each variant → `outputs/chunk-context-sweep/<policy>-<max>/<passage>.wav`
plus per-chunk IPA logs.

**Decision rules (record in devlog):**

- live/kettle/boil pronunciation changes across variants →
  context-dependent; adopt the best variant.
- only seams/pauses change → boundary policy only; does not rescue
  the bad words.
- nothing changes → model-limit pushed stronger.

Particularly important: test whole-sentence single-pass on short
sentences where `"Version 2.7 is live."` fits in one chunk — does
the model render `live` correctly when there's no prior chunk seam?

### 1f. Swift EPhonemizer word-acronym gaps (original #53)

Our Swift EPhonemizer mashes `UNESCO` / `UNICEF` / `ASAP` / `AIDS` /
`SARS` / `COVID` into letter-spelled runs (no dictionary entries),
while upstream espeak-ng knows them as words.

**Fix:** add IPA patches to `KittenWordNormalizer.ipaReplacements`
mapping the mashed forms to the correct word IPA (from Python
phonemizer):

- UNESCO → ʌnˈɛskoʊ
- UNICEF → jˈuːnɪsˌɛf
- AIDS → ˈeɪdz
- SARS → sˈɑːɹz
- COVID → kˈɑːvɪd
- ASAP is actually letter-spelled in real English — keep as-is.

Verify no collateral damage to letter-spelling of genuinely
letter-spelled acronyms (FBI, CIA, etc.).

---

## 2. Consolidation (original #48)

After every probe in section 1 has a listening verdict, update
`summary.md` with a "Round 3" section covering: IPA ref-diff outcome,
IPA-override + espeak-variant + stress/unicode results, token-packing
trace result, chunk-context sweep result, voice/speed sweep result.

Write `outputs/reports/kittentts-coreml-followup-<date>.md` mapping
each bad word (live, kettle, boil, clarity, whispered) to its final
diagnosis:

- **Frontend bug** (fixed); or
- **Conditioning** (fixable via X); or
- **Acoustic-model limit.**

Do NOT mark as "acoustic-model limit" unless all of:

- IPA parity clean vs ref,
- token packing clean,
- no dialect variant rescues it,
- no voice/speed combo rescues it,
- no chunk/context variant rescues it,
- no IPA override rescues it.

If it IS a model limit, propose Kokoro fallback routing policy in
code comments and devlog. (Kokoro is now the default path
post–Phase 9b; a Kitten→Kokoro fallback hook is moot unless Kitten
is revived.)

---

## References

- `summary.md` — full KittenTTS CoreML iteration journal
- `DEVLOG/kitten-*` — per-subsystem devlog sections
- `PLAN_port_kokorog2p.md` — the workstream that replaced this one
