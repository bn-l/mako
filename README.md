<p align="center">
  <img src="./assets/logo.webp" alt="mako" width="220">
</p>

<h1 align="center">mako</h1>

<p align="center"><b>Ma</b>c <b>Ko</b>koro</p>

Local text-to-speech on macOS via the Kokoro-82M CoreML model ([FluidAudio](https://github.com/FluidInference/FluidAudio)), with the [`kokorog2p`](https://github.com/holgern/kokorog2p) normalizer ported and the [G2P pipeline](https://en.wikipedia.org/wiki/Grapheme-to-phoneme) implemented in Swift.

Plays audio directly via `afplay` by default. With `-o`, writes M4A when `ffmpeg` is on `PATH`, WAV otherwise.

## Install

Builds from source (no prebuilt bottle):

```sh
brew install bn-l/tap/mako
```

Or build it yourself:

```sh
swift build -c release
cp .build/release/mako /usr/local/bin/
```

Requires macOS 15+ and Apple Silicon.

## Usage

```sh
mako say "Hello from Kokoro."                  # plays via afplay
mako say -o out.m4a "Hello."                   # writes a file instead
mako say -o out.wav --format wav "Hello."
echo "Reading from stdin." | mako say -
mako list-voices
mako doctor                                    # check what's installed
```

## High quality: `--hq`

`--hq` swaps Kokoro for [fish S2 Pro](https://huggingface.co/fishaudio/s2-pro) (8-bit MLX), cloned from a bundled 29 s reference clip. It sounds markedly better — prosody carries across batches, and the voice holds over passages minutes long — and it costs a great deal more:

|                   | default (Kokoro) | `--hq` (fish S2 Pro) |
|-------------------|------------------|----------------------|
| weights           | ~300 MB          | 6.8 GB, **~14.5 GB peak** |
| cold start        | ~1 s             | ~20 s                |
| speed             | ~10x realtime    | ~0.43x realtime      |
| runtime           | Swift + CoreML   | Python sidecar via `uv` |

Download the weights once, then use it per invocation:

```sh
brew install uv                                # one-off prerequisite
mako hq install                                # ~7 GB, once
mako say --hq "The release goes out at four."
mako say --hq --markers "[laughing] Sorry about that."
mako say --hq --voice-ref clip.wav --voice-ref-text clip.txt "Cloned from my own clip."
```

Notes:

- **Nothing stays resident.** Each `--hq` call loads the weights and exits, which is why it is opt-in rather than the default.
- **16 GB Macs are expected to fail.** A watchdog inside mako kills the render the moment available memory crosses a floor, and reports why. It does not silently fall back to Kokoro — rerun without `--hq`.
- **You do not need Python.** `uv` provisions its own CPython 3.12 for the sidecar.
- **Inline `[tag]` markers** are stripped by default, because an unrecognised one gets read aloud. `--markers` keeps them; see the register in [`scripts/tts-gen/README.md`](scripts/tts-gen/README.md) for which ones actually do anything. `[sigh]` is stripped unconditionally.
- **`--voice` is a Kokoro setting.** With `--hq` the voice comes from the reference clip; use `--voice-ref` / `--voice-ref-text` to change it. Fish clones in context, so the transcript must be exactly what the clip says.
- **Playback waits for the whole passage.** Streaming batch by batch would break the cross-batch prosody that makes fish worth the cost. Per-batch progress goes to stderr as it happens; `--quiet` silences it.

Measured on this machine (M-series, 32 GB): 6,644 characters → 367 s of audio in ~19 minutes, peak physical footprint 14 GB. Note that `ps`/RSS reports only ~65 MB for the sidecar because MLX allocates through Metal — use `footprint -p <pid>` if you want to watch it.

## Performance

Benchmarked on M5 (baseline mbp). Figures aggregated across four prose passages totalling 591 words / 3,377 characters / ~222 s of synthesized audio. (This actual
paragraph takes ~3s to generate.)

| metric             | value          |
|--------------------|----------------|
| real-time factor   | 0.099 (≈10×)   |
| words / sec        | 27             |
| chars / sec        | 153            |
| peak resident set  | ~1.35 GB       |

RTF 10x = one-minute clip is rendered in ~6s.

## Model storage

FluidAudio puts the files it needs into `~/.cache/fluidaudio/Models/kokoro/` (~774 MB of model files, G2P encoder/decoder, gold/silver lexicons, voice embeddings). It's pulled from HuggingFace `FluidInference/kokoro-82m-coreml` on first `mako say`. If the dir is missing, FluidAudio re-downloads it on the next run.

The `--hq` weights go to the Hugging Face cache (`HF_HOME` / `HF_HUB_CACHE`, `~/.cache/huggingface` by default), ~7 GB, and are only ever fetched by an explicit `mako hq install` — never implicitly mid-render.

## Development
 
`mako dev say` (run `mako dev say --help` for the full list):

- `--g2p ported|classic` — pick the normalizer pipeline. Default
  `ported`; `classic` falls back to the legacy normalizer.
- `--raw-text` — skip normalization entirely.
- `--speed <float>` — playback-speed multiplier (default `1.0`).
- `--preview-ssml` — dump the emitted SSML to stderr.
- `--trace` — full per-chunk trace + provenance summary.
- `--chunk-length`, `--max-tokens`, `--gap-mean`, `--gap-sd`, `--fade-ms`,
  `--temperature`, `--top-p`, `--top-k` — `--hq` knobs. Each sets the matching
  `MAKO_FISH_*` environment variable, so scripts can use either form.

`mako dev fish-preview` shows the turns `--hq` would send to the model — markers
resolved, paragraphs segmented — without paying for a render.
