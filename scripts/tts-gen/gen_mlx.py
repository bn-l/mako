# /// script
# requires-python = "==3.12.*"
# dependencies = ["mlx-audio", "numpy", "soundfile", "psutil"]
# ///
"""Render mako's passages through an mlx-audio TTS model.

    uv run scripts/tts-gen/gen_mlx.py --model mlx-community/fish-audio-s2-pro-bf16 --out wav-fish-s2-pro-bf16
    uv run scripts/tts-gen/gen_mlx.py --model mlx-community/fish-audio-s2-pro-8bit --out wav-fish-s2-pro-8bit
    uv run scripts/tts-gen/gen_mlx.py --model PowerBeef02/Qwen3-TTS-12Hz-1.7B-Base-8bit --out wav-qwen3-tts-12hz-1.7b-8bit

These are voice-cloning models and we pass no reference audio, so each
`generate()` call samples its own speaker. One call per chunk therefore makes the
voice lurch mid-passage. Two modes avoid that:

  single  (default) one generate() call for the whole passage — the model does its
          own internal chunking (fish: chunk_length; qwen3_tts: split_pattern) under
          a single sampled speaker.
  chunked our own sentence chunker, one call per chunk. Use --pin-voice to feed
          chunk 1's audio back as ref_audio so later chunks keep its timbre.

Chunking goes through chunking.py, which returns verbatim slices — a naive
`[.!?]` split corrupts `2.7`, `A.I.` and `9:30 a.m.`.
"""

import argparse
import logging
import tempfile
import time
from pathlib import Path

import mlx.core as mx
import numpy as np
import psutil
import soundfile as sf
import mlx_audio.tts.models.qwen3_tts as qwen3_tts
import mlx_audio.utils
from mlx_audio.tts.utils import load_model
from mlx_audio.utils import load_audio

from chunking import chunk_text
from oomguard import arm


def qwen3_quant_predicate(self, path, module):
    """Allow a quantized `text_embedding`, which stock mlx-audio refuses to quantize.

    PowerBeef02/Qwen3-TTS-12Hz-1.7B-Base-8bit additionally quantizes
    `talker.model.text_embedding` (affine 8-bit, group 64). mlx-audio's own
    predicate skips anything matching "text_embedding", so it builds a plain
    Embedding and then rejects the checkpoint's .scales/.biases. Dropping that one
    pattern is safe for unquantized repos too: apply_quantization falls back to
    checking `<path>.scales in weights`, which is absent for them.
    """
    skip_patterns = ["codec_embedding", "speech_tokenizer", "speaker_encoder"]
    for pattern in skip_patterns:
        if pattern in path:
            return False
    return True


qwen3_tts.Model.model_quant_predicate = qwen3_quant_predicate


def patch_model_remapping():
    """Repair mlx-audio's model_type remapping, which is dead whenever model_name is set.

    get_model_class resolves a config's model_type to a directory under tts/models. It
    looks the type up in MODEL_REMAPPING (stage 1), then guards the branch that USES that
    result behind `elif`:

        model_type_mapped = model_remapping.get(model_type, None)
        if model_name is not None and model_type_mapped != model_type:
            ...scan the repo-name parts...
        elif model_type_mapped is not None:
            model_type = model_type_mapped

    base_load_model always passes model_name, and the condition `model_type_mapped !=
    model_type` is true precisely when a remap is needed, so the first branch always
    wins. It then scans the repo name ("bosonai", "higgs-tts-3-4b"), matches nothing,
    and imports the unmapped type. bosonai/higgs-tts-3-4b therefore fails with
    "Model type higgs_multimodal_qwen3 not supported for tts" even though
    MODEL_REMAPPING maps it to the higgs_audio_v3 family that ships in the package.

    Passing model_name=None when the type has an exact remapping forces the working
    branch. Models without a remapping keep the existing repo-name-scanning behaviour.
    """
    original = mlx_audio.utils.get_model_class

    def resolve(model_type, model_name, category, model_remapping):
        if model_remapping and model_type in model_remapping:
            model_name = None
        return original(model_type, model_name, category, model_remapping)

    mlx_audio.utils.get_model_class = resolve


patch_model_remapping()

REPO = Path(__file__).resolve().parents[2]
RESOURCE_DIR = REPO / "Sources/TTSHarnessCore/Resources"

# Short passages first; the 8k-char homograph torture test last.
PASSAGE_ORDER = ["micro-corpus", "gulliver", "brutal", "foot-massage", "homographs"]

log = logging.getLogger("gen_mlx")


def memory_note():
    """MLX counters + process-visible RAM, for tracking creep across chunks.

    Deliberately does NOT clear the cache first. An earlier version did, which hid the
    growth that was getting runs SIGKILLed: active read flat while the system's
    available RAM drained away. peak is the number that decides whether a run survives.
    """
    return (f"active {mx.get_active_memory() / 1024 ** 3:.1f}G "
            f"cache {mx.get_cache_memory() / 1024 ** 3:.1f}G "
            f"peak {mx.get_peak_memory() / 1024 ** 3:.1f}G "
            f"avail {psutil.virtual_memory().available / 1024 ** 3:.1f}G")


def reference_argument(model, path):
    """What this model wants for ref_audio: a path, or decoded audio.

    mlx_audio's own generate_audio() switches on `preserve_ref_audio_path`; models
    without it (fish_qwen3_omni) get a decoded array, and its
    `_prepare_reference_prompt` immediately does `audio.ndim`, so handing it a path
    raises AttributeError: 'str' object has no attribute 'ndim'. Calling
    model.generate() directly bypasses that wrapper, so we apply the same rule here.
    """
    if getattr(model, "preserve_ref_audio_path", False) is True:
        return str(path)
    return load_audio(str(path), sample_rate=model.sample_rate)


def render(model, text, max_tokens, ref_audio, ref_text):
    """One generate() call -> concatenated float32 mono."""
    options = {"text": text, "max_tokens": max_tokens, "verbose": False}
    if ref_audio is not None:
        options["ref_audio"] = reference_argument(model, ref_audio)
        options["ref_text"] = ref_text
    pieces = []
    for result in model.generate(**options):
        pieces.append(np.asarray(result.audio, dtype=np.float32).reshape(-1))
    if not pieces:
        return np.zeros(0, dtype=np.float32)
    return np.concatenate(pieces)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, help="HF model id")
    ap.add_argument("--out", required=True, help="output dir name, created beside this script")
    ap.add_argument("--mode", choices=["single", "chunked"], default="single")
    ap.add_argument("--pin-voice", action="store_true",
                    help="chunked mode: reuse chunk 1's audio as ref_audio for later chunks")
    ap.add_argument("--chunk-chars", type=int, default=300)
    # Keep this modest: these AR models size their KV cache from max_tokens, so a big
    # value gets the OOM guard to SIGKILL the run mid-passage. 4096 is already generous
    # for a <=300-char chunk (fish ~21Hz, qwen3 ~12Hz => a few hundred tokens).
    ap.add_argument("--max-tokens", type=int, default=4096)
    ap.add_argument("--oom-floor-mb", type=int, default=3000,
                    help="SIGKILL this process if available RAM drops below this")
    # Cap MLX's buffer cache so freed buffers go back to the OS rather than being held.
    ap.add_argument("--mlx-cache-mb", type=int, default=1536)
    ap.add_argument("passages", nargs="*", help="passage basenames (default: all)")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    arm(floor_mb=args.oom_floor_mb)
    mx.set_cache_limit(args.mlx_cache_mb * 1024 ** 2)

    names = args.passages if args.passages else PASSAGE_ORDER
    out_dir = Path(__file__).resolve().parent / args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    log.info("before load: %s", memory_note())
    log.info("loading %s", args.model)
    model = load_model(args.model)
    sample_rate = getattr(model, "sample_rate", 24000)
    log.info("loaded; sample_rate=%s mode=%s max_tokens=%d [%s]",
             sample_rate, args.mode, args.max_tokens, memory_note())

    gap = np.zeros(int(0.3 * sample_rate), dtype=np.float32)

    for name in names:
        src = RESOURCE_DIR / f"{name}.txt"
        if not src.exists():
            log.warning("no such passage: %s", src)
            continue
        text = src.read_text(encoding="utf-8").strip()
        started = time.time()

        if args.mode == "single":
            log.info("%s: %d chars, single call", name, len(text))
            try:
                audio = render(model, text, args.max_tokens, None, None)
            except Exception:
                log.exception("%s: synthesis failed", name)
                continue
        else:
            chunks = chunk_text(text, args.chunk_chars)
            log.info("%s: %d chars -> %d chunks", name, len(text), len(chunks))
            pieces = []
            ref_audio = None
            ref_text = None
            reference = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
            reference.close()
            for index, chunk in enumerate(chunks, 1):
                try:
                    piece = render(model, chunk, args.max_tokens, ref_audio, ref_text)
                except Exception:
                    # One bad chunk shouldn't cost us the whole passage.
                    log.exception("%s: chunk %d/%d failed: %r", name, index, len(chunks), chunk[:60])
                    continue
                pieces.append(piece)
                pieces.append(gap)
                if args.pin_voice and ref_audio is None and piece.size:
                    sf.write(reference.name, piece, sample_rate)
                    ref_audio, ref_text = reference.name, chunk
                    log.info("  pinned voice to chunk 1 (%s)", reference.name)
                # Release MLX's cached GPU buffers between chunks. Without this the
                # cache grows across a long passage until the OOM guard fires.
                log.info("  %s: chunk %d/%d done (%.1fs elapsed) [%s]",
                         name, index, len(chunks), time.time() - started, memory_note())
            audio = np.concatenate(pieces) if pieces else np.zeros(0, dtype=np.float32)

        if not audio.size:
            log.error("%s: produced no audio, skipping", name)
            continue
        dest = out_dir / f"{name}.wav"
        sf.write(dest, audio, sample_rate)
        log.info("wrote %s — %.1fs audio in %.1fs wall",
                 dest, len(audio) / sample_rate, time.time() - started)


if __name__ == "__main__":
    main()
