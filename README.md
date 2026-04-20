# mac-tts

A Swift Package Manager harness that runs a fixed passage (a Gulliver's Travels
excerpt, ~992 chars / 178 words) through multiple CoreML / MLX / ONNX TTS
models on Apple Silicon and records wall-clock time, peak & average RSS, and
per-character / per-word throughput.

## Running

```bash
xcodebuild -scheme mac-tts -derivedDataPath .xcbuild -destination 'platform=macOS' build
.xcbuild/Build/Products/Debug/mac-tts list
.xcbuild/Build/Products/Debug/mac-tts run --model <id>
.xcbuild/Build/Products/Debug/mac-tts run --all
```

`--all` writes a `outputs/summary.md` table with per-model metrics.

Python subprocess models (`pythonMLX*` backends) are run via `uv` inside `python/`.

## Models

### Tested — opinions

| model | verdict |
|---|---|
| `qwen3-tts-12hz-17b-mlx-bf16` | **Best.** Really good reading. Shame about the speed — no 1.7B CoreML conversion exists publicly. |
| `kokoro-fluidaudio` | Good at first, but got glitchy about halfway through. Length-of-passage issue. |
| `pocket-tts-fluidaudio` | Pretty good reading, slightly worse than kokoro. Didn't like the voice. |
| `voxtral-4b-tts-mlx-4bit` | Fluid but strange reading. About as good as kokoro when it wasn't going haywire. Didn't like the voice. |
| `kittentts-swift` | Not bad. Some glitches. Voice speaks a little slow. |
| `cosyvoice3-mlx-4bit` | Too crap to comment. |
| `fishaudio-s2-pro-mlx-8bit` | Too crap to comment. |
| `longcat-audiodit-mlx-8bit` | Too crap to comment. |
| `qwen3-tts-coreml-06b` | 0.6B CoreML port. 256-token KV cache → output truncates to ~2.6s on long passages. Useful only for short utterances. |

### Performance (see `outputs/summary.md`)

Passage: 992 chars, 178 words.

| model | wall (s) | chars/s | words/s | peak (MB) |
|---|---:|---:|---:|---:|
| kittentts-swift | 4.86 | 204.1 | 36.6 | 803 |
| kokoro-fluidaudio | 6.20 | 160.0 | 28.7 | 1255 |
| cosyvoice3-mlx-4bit | 15.54 | 63.8 | 11.5 | 1952 |
| pocket-tts-fluidaudio | 25.95 | 38.2 | 6.9 | 1551 |
| voxtral-4b-tts-mlx-4bit | 35.01 | 28.3 | 5.1 | 2826 |
| longcat-audiodit-mlx-8bit | 40.41 | 24.5 | 4.4 | 4959 |
| qwen3-tts-12hz-17b-mlx-bf16 | 42.76 | 23.2 | 4.2 | 4591 |
| qwen3-tts-coreml-06b | 115.23 | 8.6 | 1.5 | 1015 |
| fishaudio-s2-pro-mlx-8bit | 276.88 | 3.6 | 0.6 | 5230 |

## kittentts-coreml — how it works & iteration log

`alexwengg/kittentts-coreml` is a CoreML port of KittenML/KittenTTS. Two
variants ship in this harness: `kittentts-coreml-nano` and
`kittentts-coreml-mini`. The mini variant sounds noticeably better and is the
one we've been tuning.

### Pipeline

```
input text
  → KittenTextPreprocessor.process      (punctuation normalisation, abbr expansion, etc.)
  → chunkText(maxChars=80)              (sentence-aware; falls back to word boundaries)
  → for each chunk:
        EPhonemizer.phonemize           (IPA)
        basic_english_tokenize_join     (regex: `\w+|[^\w\s]`, joined by spaces)
        KittenTextCleaner.encode        (IPA → int64 token ids via 178-entry symbol table)
        MLModel.prediction              (input_ids, attention_mask, style, speed)
        trim to audio_length_samples - chunkTailTrim
        microfade(fade_ms)
  → concatenate chunks (no inserted silence)
  → WAV @ 24 kHz float32
```

Key module: `Sources/KittenCoreMLRunner/KittenCoreMLEngine.swift`.

### Model I/O specifics

- Input: fixed-width `[1, 140]` `input_ids` + `attention_mask` (int32); a 256-d
  `style` vector; `speed` scalar (mini) or `random_phases [1,9]` +
  `source_noise [1, 240000, 9]` (nano — source module of the ISTFTNet vocoder).
- Output: `audio [1, 1, 240020]` (fixed zero-padded 10-second tensor) plus
  `audio_length_samples` (int32, valid length) and `pred_dur`.
- Mini style indexing: `ref_id = min(len(text_chunk_chars), 399)` into the
  `(400, 256)` voice matrix — this is the **character count** of the chunk,
  not the phoneme-token count. Matches upstream Python exactly.
- Nano style: single 256-d vector per voice, no row indexing.

### Iteration log

v0 — naive port against KittenTTS-swift's symbol table & no chunking. Dropped
symbols on every utterance; single inference truncated at 10 s.

v1 — **symbol-table fix**. Dumped upstream Python codepoints and found 5
positions where KittenTTS-swift uses curly quotes (U+2019, U+201C/D, U+2018)
but the trained tokeniser expects **straight** quotes (U+0022, U+0027). Our
`KittenTextCleaner` now duplicates the exact upstream table; previously-dropped
phonemes now tokenise correctly. See the comment at the top of
`KittenTextCleaner.swift`.

v2 — **text-domain chunking**. Mirrored `chunk_text` from
`kittentts/onnx_model.py`: split on `.!?` first, then word-fallback at
`maxChars`. Added `ensurePunctuation` so each chunk gets a trailing `,` if it
doesn't already end in punctuation (helps prosody stability). Reduced
`maxCharsPerChunk` from 180 → 110 → 80 after finding the empirical
chars-to-tokens ratio (~1.07 tok/char) could overflow the 140-token hard cap.

v3 — **saturation-based recursive auto-split**. The mini model hard-caps
output at 240 000 samples (10 s). Dense chunks can sit well under the token
cap yet still produce >10 s of speech, which the model truncates mid-word.
`synthChunkWithAutoSplit` runs the chunk; if `audio_length_samples` lands
within `saturationMargin=1500` of the cap, it splits on the word axis and
recurses (up to 4 levels). Logs warn when it can't split further.

v4 — **trailing-artefact trim** (`chunkTailTrim = 5_000`, ~208 ms). Even
though the CoreML port exposes `audio_length_samples`, the last ~5 000
samples of that "valid" region still contain vocoder wind-down artefacts that
cause an audible click at every chunk boundary. Upstream ONNX Python also
does `audio[:-5000]`, so we match that.

v5 — **dropped 40 ms inter-chunk silence**. Upstream Python uses plain
`np.concatenate`. Adding our own 40 ms spacer produced noticeable extra
pauses; removing it brings timing in line with upstream.

v6 — **experiment: no trim, use `audio_length_samples` alone**. Based on the
model card claim that this field is the correct valid-length marker. Result:
boundary clicks returned. Reverted — the trim is empirically necessary even
though the port also zero-pads past `audio_length_samples`.

v7 — **longer fade** (3 ms → 20 ms, linear, on both ends of every chunk).
Masks the discontinuity introduced by the trim without adding inserted
silence. Click events (threshold = 40× robust MAD σ on first-difference)
dropped 19 → 6 on the Gulliver passage.

v8 — **equal-power crossfade + deeper trim**. Instead of butt-joining chunks
with a V-shaped microfade notch (fade-out → fade-in, summing to zero at the
boundary), overlap the last N samples of chunk *i* with the first N samples
of chunk *i+1* using sin/cos curves (summed power = 1). Parameters sweeped
via `scripts/sweep_kitten_params.py`. Best combo: `trim=9000` (375 ms) +
`xfade=60 ms` → **2 clicks**, down from 19. Duration of the 992-char
passage: 67.42 s → 61.83 s. Runtime-tunable via env vars
`KITTEN_CHUNK_TAIL_TRIM`, `KITTEN_FADE_MS`, `KITTEN_XFADE_MS`.

| version | trim | fade | xfade | clicks | pauses | duration |
|---|---:|---:|---:|---:|---:|---:|
| v4 (old default) | 5000 | 3 ms | 0 | 19 | 30 | 67.42 s |
| v7              | 5000 | 20 ms | 0 | 6 | 23 | 64.72 s |
| v8 (current)    | 9000 | —    | 60 ms | 2 | 21 | 61.83 s |

v9 — **verified click floor is legitimate signal**. Instrumented chunk seam
positions (`KITTEN_LOG_BOUNDARIES=1`) and cross-referenced them against click
timestamps. The two remaining clicks on the Gulliver passage (44.82 s, 48.60 s)
fall mid-chunk inside chunks 9 and 10 — they are plosive/fricative speech
transients in the audio itself, not boundary artefacts. All twelve chunk
seams are now click-free by our detector.

Also researched further techniques (StyleTTS2 `s_prev` carry, full-sequence
ALBERT + chunked vocoder, WSOLA, PVSOLA, zero-crossing snap, energy-based
adaptive trim, DC-block). None improved on v8 in the sweep. Pinning the mini
style row to a fixed value (instead of `min(chunk_len, 399)`) made things
dramatically worse (8–56 clicks). Upstream per-chunk indexing turns out to
be correct. Results in `scripts/sweep_kitten_params.py`; additional knobs
are exposed as env vars (`KITTEN_ADAPTIVE_TRIM_MS`, `KITTEN_ZC_SNAP_SAMPLES`,
`KITTEN_DC_BLOCK`, `KITTEN_STYLE_ROW`, `KITTEN_LOG_BOUNDARIES`) for further
experimentation.

### Measurement

`python/tests/test_kitten_coreml_glitches.py` runs `mac-tts run --model
kittentts-coreml-mini`, analyses the WAV, and asserts:
- click events (|Δx| > 40× robust MAD σ on first-difference) below threshold
- long-silence windows (RMS > 40 dB below peak, ≥150 ms) below threshold

Current thresholds: ≤10 clicks, ≤28 pauses on the 992-char Gulliver passage.

## Backends

- `fluidAudio` — FluidInference FluidAudio Swift SDK (CoreML)
- `speechSwift` — soniqo/speech-swift (CosyVoice3 MLX, Qwen3-TTS CoreML)
- `kittenTTS` — KittenML/KittenTTS-swift (ONNX Runtime)
- `pythonMLXAudio` — `mlx_audio` subprocess
- `pythonMLXSpeech` — `mlx_speech` subprocess
- `qwen3TtsCoreML` — speech-swift `Qwen3TTSCoreML` product

MLX-backed runners require the Metal shader bundle built by xcodebuild
(`swift build` alone cannot compile `.metal` → `default.metallib`), so use the
xcodebuild invocation above.

## Layout

```
Sources/
  TTSHarnessCore/        Passage loader, RSSSampler, Runner protocol, WAVWriter, ModelRegistry
  FluidAudioRunner/      Kokoro + PocketTTS (FluidAudio SDK)
  SpeechSwiftRunner/     CosyVoice3 + Qwen3TTSCoreML
  KittenTTSRunner/       KittenTTS ONNX
  PythonSubprocessRunner/ uv-invoked Python subprocess harness
  mac-tts/               CLI entry (List, Run, RunnerFactory)
python/
  src/mac_tts_python/runners/
    mlx_audio_runner.py  Qwen3-TTS MLX, Voxtral MLX
    mlx_speech_runner.py Fishaudio S2-Pro, Longcat
```
