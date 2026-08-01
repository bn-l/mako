# /// script
# requires-python = "==3.12.*"
# dependencies = ["mlx-audio", "numpy", "soundfile", "psutil"]
# ///
"""Render the brutal corpus once per built-in Qwen3-TTS voice.

    uv run scripts/tts-gen/exp_qwen_voices.py
    uv run scripts/tts-gen/exp_qwen_voices.py --list

The checkpoint we benchmarked, PowerBeef02/Qwen3-TTS-12Hz-1.7B-Base-8bit, has NO
built-in voices: its config reports tts_model_type "base" with `spk_id: {}`, so
`get_supported_speakers()` is an empty list and every voice you heard was a speaker
the model sampled at random per generate() call. That is the same mechanism behind
the mid-passage voice lurch in wav-fish-s2-pro-8bit/micro-corpus.wav.

Named voices live in a different checkpoint family:

  CustomVoice  nine named speakers + an `instruct` string for emotion/style
  VoiceDesign  a voice built from a free-text description
  Base         reference-audio cloning only (what we had)

So this uses CustomVoice, whose config lists nine speakers. Emotion control is
available here too via generate_custom_voice(instruct=...) — worth a separate pass if
any of these voices are worth keeping.
"""

import argparse
import logging
import time
from pathlib import Path

import mlx.core as mx
import numpy as np
import psutil
import soundfile as sf
import mlx_audio.tts.models.qwen3_tts as qwen3_tts
from mlx_audio.tts.utils import load_model

from chunking import chunk_text
from oomguard import arm

REPO = Path(__file__).resolve().parents[2]
RESOURCE_DIR = REPO / "Sources/TTSHarnessCore/Resources"

log = logging.getLogger("exp_qwen_voices")


def qwen3_quant_predicate(self, path, module):
    """Permit a quantized `text_embedding`; stock mlx-audio refuses and then rejects
    the checkpoint's .scales/.biases. Harmless for repos that don't quantize it,
    because apply_quantization falls back to testing `<path>.scales in weights`."""
    skip_patterns = ["codec_embedding", "speech_tokenizer", "speaker_encoder"]
    for pattern in skip_patterns:
        if pattern in path:
            return False
    return True


qwen3_tts.Model.model_quant_predicate = qwen3_quant_predicate


def memory_note():
    """Deliberately does NOT clear the cache: MLX holds freed buffers in its own cache
    and does not hand them back to the OS, so a clear_cache() here would hide exactly
    the growth that gets the watchdog to SIGKILL us mid-render."""
    return (f"active {mx.get_active_memory() / 1024 ** 3:.1f}G "
            f"cache {mx.get_cache_memory() / 1024 ** 3:.1f}G "
            f"peak {mx.get_peak_memory() / 1024 ** 3:.1f}G "
            f"avail {psutil.virtual_memory().available / 1024 ** 3:.1f}G")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit")
    ap.add_argument("--passage", default="brutal")
    ap.add_argument("--out", default="wav-qwen-voices")
    ap.add_argument("--instruct", default=None,
                    help="optional emotion/style instruction applied to every voice")
    ap.add_argument("--temperature", type=float, default=0.9)
    ap.add_argument("--top-k", type=int, default=50)
    ap.add_argument("--top-p", type=float, default=1.0)
    # 12 Hz codec: brutal is ~70s of audio, so ~850 tokens. 4096 buys nothing and sizes
    # the KV cache for 341s of speech.
    ap.add_argument("--max-tokens", type=int, default=2048)
    # Cap MLX's buffer cache so freed buffers go back to the OS instead of being hoarded.
    # Without this the system's available RAM falls steadily through a render even though
    # active memory is flat, and the OOM watchdog kills us.
    ap.add_argument("--mlx-cache-mb", type=int, default=1536)
    # _generate_with_instruct does not split text: it is one AR pass bounded by
    # max_tokens, and a passage past ~1000 chars needs more tokens than fits alongside
    # the transient decode spike. Chunking is safe here in a way it is not for the
    # reference-free cloning models — the speaker is a fixed named voice, so it cannot
    # drift between chunks. Prosody still restarts per chunk, so keep chunks large.
    ap.add_argument("--chunk-chars", type=int, default=0,
                    help="0 renders the passage in one call; else max chars per call")
    ap.add_argument("--list", action="store_true", help="print the voice list and exit")
    ap.add_argument("--oom-floor-mb", type=int, default=3000)
    ap.add_argument("voices", nargs="*", help="voice names (default: all supported)")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    arm(floor_mb=args.oom_floor_mb)
    mx.set_cache_limit(args.mlx_cache_mb * 1024 ** 2)

    text = (RESOURCE_DIR / f"{args.passage}.txt").read_text(encoding="utf-8").strip()
    out_dir = Path(__file__).resolve().parent / args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    log.info("loading %s [%s]", args.model, memory_note())
    model = load_model(args.model)
    sample_rate = getattr(model, "sample_rate", 24000)
    supported = model.get_supported_speakers()
    log.info("loaded; sample_rate=%s voices=%s [%s]", sample_rate, supported, memory_note())

    if args.list:
        return

    gap = np.zeros(int(0.25 * sample_rate), dtype=np.float32)
    names = args.voices if args.voices else supported
    for voice in names:
        if voice not in supported:
            log.warning("skipping unsupported voice %r (supported: %s)", voice, supported)
            continue
        parts = chunk_text(text, args.chunk_chars) if args.chunk_chars else [text]
        log.info("%s: rendering %s (%d chars -> %d call(s)) [%s]", voice, args.passage,
                 len(text), len(parts), memory_note())
        started = time.time()
        pieces = []
        try:
            for part in parts:
                for result in model.generate_custom_voice(
                    text=part,
                    speaker=voice,
                    instruct=args.instruct,
                    temperature=args.temperature,
                    top_k=args.top_k,
                    top_p=args.top_p,
                    max_tokens=args.max_tokens,
                    verbose=False,
                ):
                    pieces.append(np.asarray(result.audio, dtype=np.float32).reshape(-1))
                    log.info("  %s: segment %d, %.1fs so far [%s]", voice, len(pieces),
                             time.time() - started, memory_note())
                pieces.append(gap)
        except Exception:
            log.exception("%s: failed", voice)
            continue
        if not pieces:
            log.error("%s: produced no audio", voice)
            continue

        audio = np.concatenate(pieces)
        dest = out_dir / f"{voice}.wav"
        sf.write(dest, audio, sample_rate)
        seconds = len(audio) / sample_rate
        elapsed = time.time() - started
        mx.clear_cache()
        log.info("wrote %s — %.1fs audio in %.1fs wall (%.1f chars/s, RTF %.2f) [%s]",
                 dest, seconds, elapsed, len(text) / elapsed, seconds / elapsed,
                 memory_note())


if __name__ == "__main__":
    main()
