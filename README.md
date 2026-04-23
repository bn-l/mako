<p align="center">
  <img src="./assets/logo.webp" alt="mako" width="220">
</p>

<h1 align="center">mako</h1>

<p align="center"><b>Ma</b>c <b>Ko</b>koro</p>

Local text-to-speech on macOS via the Kokoro-82M CoreML model ([FluidAudio](https://github.com/FluidInference/FluidAudio)), with the [`kokorog2p`](https://github.com/holgern/kokorog2p) normalizer ported and the [G2P pipeline](https://en.wikipedia.org/wiki/Grapheme-to-phoneme) implemented in Swift.

Outputs M4A when `ffmpeg` is on `PATH`, WAV otherwise.

## Install

```sh
swift build -c release
cp .build/release/mako /usr/local/bin/
```

Requires macOS 15+ and Apple Silicon.

## Usage

```sh
mako say "Hello from Kokoro."
mako say -o out.wav --format wav "Hello."
echo "Reading from stdin." | mako say -
mako list-voices
```

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

## Development
 
`mako dev say` (run `mako dev say --help` for the full list):

- `--g2p ported|classic` — pick the normalizer pipeline. Default
  `ported`; `classic` falls back to the legacy normalizer.
- `--raw-text` — skip normalization entirely.
- `--speed <float>` — playback-speed multiplier (default `1.0`).
- `--preview-ssml` — dump the emitted SSML to stderr.
- `--trace` — full per-chunk trace + provenance summary.
