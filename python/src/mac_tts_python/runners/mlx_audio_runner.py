"""Run any model supported by mlx-audio and write a WAV file.

Used for: Qwen3-TTS (MLX) and Voxtral-4B mlx-4bit.
Invoked by the Swift harness via `uv run python -m ...`.
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from mlx_audio.tts.generate import generate_audio
from mlx_audio.tts.utils import load_model

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("mlx_audio_runner")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, help="HuggingFace repo id")
    parser.add_argument("--text", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--voice", default=None)
    args = parser.parse_args()

    log.info("loading %s", args.model)
    model = load_model(args.model)

    out_dir = args.output.parent
    out_dir.mkdir(parents=True, exist_ok=True)
    file_prefix = str(out_dir / args.output.stem)

    kwargs: dict[str, object] = {
        "model": model,
        "text": args.text,
        "file_prefix": file_prefix,
        "audio_format": "wav",
        "join_audio": True,
        "verbose": True,
    }
    if args.voice is not None:
        kwargs["voice"] = args.voice

    log.info("generating audio: voice=%s", args.voice)
    generate_audio(**kwargs)

    produced = out_dir / f"{args.output.stem}.wav"
    if produced != args.output and produced.exists():
        produced.rename(args.output)

    if not args.output.exists():
        log.error("no output produced at %s", args.output)
        return 1

    log.info("wrote %s", args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
