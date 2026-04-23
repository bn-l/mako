# mako

Mac [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M)

Local text-to-speech on macOS via the Kokoro-82M CoreML model (served
through [FluidAudio](https://github.com/FluidInference/FluidAudio)), with
a ported [`kokorog2p`](https://github.com/holgern/kokorog2p) normalizer
+ [G2P pipeline](https://en.wikipedia.org/wiki/Grapheme-to-phoneme)
implemented in Swift.

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

Benchmarked on Apple Silicon (release build, model already cached,
wall-clock including process start, G2P, CoreML inference, and WAV
write). Figures aggregated across four prose passages totalling 591
words / 3,377 characters / ~222 s of synthesized audio. (This actual
paragraph takes 3.49 s to generate.)

| metric             | value          |
|--------------------|----------------|
| real-time factor   | 0.099 (≈10×)   |
| words / sec        | 27             |
| chars / sec        | 153            |
| peak resident set  | ~1.35 GB       |

RTF < 1 means synthesis is faster than playback — a one-minute passage
synthesizes in roughly six seconds.

## Model storage

FluidAudio drops the Kokoro CoreML bundle into
`~/.cache/fluidaudio/Models/kokoro/` (~774 MB — 5s/15s model variants,
G2P encoder/decoder, gold/silver lexicons, voice embeddings). It's
pulled from HuggingFace `FluidInference/kokoro-82m-coreml` on first
`mako say`. If the dir is missing or damaged, FluidAudio re-downloads on
next run; there's no offline bundle, so the first invocation needs
network.

## Binary size

The release binary is ~44 MB (static Swift stdlib + ArgumentParser +
the ported G2P dictionaries).

## Dev knobs

Exposed under `mako dev say` (run `mako dev say --help` for the
full list):

- `--g2p ported|classic` — pick the normalizer pipeline. Default
  `ported`; `classic` falls back to the legacy normalizer.
- `--raw-text` — skip normalization entirely.
- `--speed <float>` — playback-speed multiplier (default `1.0`).
- `--preview-ssml` — dump the emitted SSML to stderr.
- `--trace` — full per-chunk trace + provenance summary.
