"""Run a model supported by mlx-speech and write a WAV file.

Used for: longcat-audiodit, fishaudio-s2-pro.
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

import mlx_speech
import numpy as np
import soundfile as sf

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("mlx_speech_runner")


MODEL_ALIAS = {
    "mlx-community/longcat-audiodit-3.5b-8bit-mlx": "longcat",
    "appautomaton/longcat-audiodit-3.5b-8bit-mlx": "longcat",
    "mlx-community/fishaudio-s2-pro-8bit-mlx": "fish-s2-pro",
    "appautomaton/fishaudio-s2-pro-8bit-mlx": "fish-s2-pro",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, help="HuggingFace repo id or mlx-speech alias")
    parser.add_argument("--text", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--reference-audio", default=None)
    parser.add_argument("--reference-text", default=None)
    args = parser.parse_args()

    alias = MODEL_ALIAS.get(args.model, args.model)
    log.info("loading mlx-speech model: %s", alias)
    model = mlx_speech.tts.load(alias)

    args.output.parent.mkdir(parents=True, exist_ok=True)

    kwargs: dict[str, object] = {"text": args.text}
    if args.reference_audio:
        kwargs["reference_audio"] = args.reference_audio
    if args.reference_text:
        kwargs["reference_text"] = args.reference_text

    log.info("generating")
    result = model.generate(**kwargs)
    waveform = np.asarray(result.waveform)
    sf.write(str(args.output), waveform, result.sample_rate)

    if not args.output.exists():
        log.error("no output produced at %s", args.output)
        return 1

    log.info("wrote %s", args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
