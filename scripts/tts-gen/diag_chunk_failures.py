# /// script
# requires-python = "==3.12.*"
# dependencies = ["mlx-audio", "numpy", "soundfile", "psutil"]
# ///
"""Probe why individual chunks fail on an mlx-audio model, with full tracebacks.

gen_mlx.py deliberately swallows a failing chunk so one bad chunk can't cost a whole
passage, which hides the reason. This loads the model once and pushes a handful of
targeted probes through it, printing the actual exception for each.

    uv run scripts/tts-gen/diag_chunk_failures.py --model mlx-community/fish-audio-s2-pro-8bit

Probes cover the suspects for the homographs passage: plain ASCII, IPA symbols,
`===` banner lines, embedded newlines, and a verbatim failing chunk.
"""

import argparse
import logging
import traceback

import numpy as np
import mlx_audio.tts.models.qwen3_tts as qwen3_tts
from mlx_audio.tts.utils import load_model

from oomguard import arm

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("diag")


def qwen3_quant_predicate(self, path, module):
    for pattern in ["codec_embedding", "speech_tokenizer", "speaker_encoder"]:
        if pattern in path:
            return False
    return True


qwen3_tts.Model.model_quant_predicate = qwen3_quant_predicate

PROBES = [
    ("plain ascii", "The parking permit expired last week."),
    ("ipa in parens", "The increase (/ˈɪnkriːs/) was small."),
    ("banner line", "=== increase (NOUN /ˈɪnkriːs/ vs VERB /ɪnˈkriːs/) ==="),
    ("embedded newline", "The swimmer dove from the board.\nA dove landed nearby."),
    ("verbatim failing chunk",
     "=== used (VBD-past /juːzd/ vs ADJ-accustomed /juːst/) ===\n"
     "She used to walk here. He is used to the noise."),
    ("long ascii ~290 chars",
     "The kettle began to boil and the water was hot. " * 6),
]


def probe_ref_audio(model, max_tokens):
    """Does the --pin-voice path work? Generate once, feed it back as ref_audio."""
    import soundfile as sf
    import tempfile

    rate = getattr(model, "sample_rate", 44100)
    seed_text = "The parking permit expired last week."
    print(f"\n{'=' * 70}\nPROBE: ref_audio pinning (the --pin-voice path)")
    pieces = []
    for result in model.generate(text=seed_text, max_tokens=max_tokens, verbose=False):
        pieces.append(np.asarray(result.audio, dtype=np.float32).reshape(-1))
    seed = np.concatenate(pieces)
    handle = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    handle.close()
    sf.write(handle.name, seed, rate)
    print(f"  seed clip: {seed.size / rate:.1f}s -> {handle.name}")

    from gen_mlx import reference_argument

    for label, reference in [("raw path (what gen_mlx used to pass)", handle.name),
                             ("via reference_argument()", reference_argument(model, handle.name))]:
        text = "He is used to the noise."
        print(f"  -- {label}: {text!r}")
        try:
            total = 0
            for result in model.generate(text=text, max_tokens=max_tokens, verbose=False,
                                         ref_audio=reference, ref_text=seed_text):
                total += np.asarray(result.audio).reshape(-1).size
            print(f"     OK -> {total / rate:.1f}s")
        except Exception:
            print("     FAILED:")
            traceback.print_exc()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--max-tokens", type=int, default=4096)
    ap.add_argument("--oom-floor-mb", type=int, default=2000)
    ap.add_argument("--ref-audio-only", action="store_true",
                    help="skip the content probes, only test the ref_audio pinning path")
    args = ap.parse_args()

    arm(floor_mb=args.oom_floor_mb)
    log.info("loading %s", args.model)
    model = load_model(args.model)
    log.info("loaded; sample_rate=%s", getattr(model, "sample_rate", "?"))

    probes = [] if args.ref_audio_only else PROBES
    for label, text in probes:
        print(f"\n{'=' * 70}\nPROBE: {label}\n  text: {text[:90]!r}")
        try:
            total = 0
            for result in model.generate(text=text, max_tokens=args.max_tokens, verbose=False):
                total += np.asarray(result.audio).reshape(-1).size
            rate = getattr(model, "sample_rate", 1)
            print(f"  OK -> {total} samples ({total / rate:.1f}s)")
        except Exception:
            print("  FAILED:")
            traceback.print_exc()

    probe_ref_audio(model, args.max_tokens)


if __name__ == "__main__":
    main()
