# /// script
# requires-python = "==3.12.*"
# dependencies = ["mlx-audio", "numpy", "soundfile", "psutil"]
# ///
"""Transcribe rendered audio to check the model said what we asked.

    uv run scripts/tts-gen/transcribe_check.py --head 12 wav-fish-itin/*.wav

Listening catches this faster, but not reliably across dozens of renders, and some
faults are easy to miss by ear late in a long file. Concretely this catches:

  * a style instruction being read aloud instead of applied — fish does exactly this
    when `instruct=` is passed without reference audio
  * text dropped, duplicated or truncated at a chunk boundary
  * a passage that stopped early because max_tokens ran out

--head N transcribes only the first N seconds, which is where a leaked system prompt
shows up and keeps this cheap.

ASR is not ground truth: it normalises numbers and punctuation and will happily
mis-hear an unusual pronunciation, so it cannot judge whether `2.7` or `ETA` was
pronounced correctly. Use it to check WHICH WORDS were spoken, not how.

WARNING, learned the hard way: parakeet returns an EMPTY string for some windows of
perfectly good audio. On one 98s render, 0-8s and 40-56s transcribed correctly while
0-30s, 8-24s and the whole file all came back empty. An empty result is therefore NOT
evidence of broken audio — re-probe with a different window (~8s works reliably) and
sanity-check the waveform RMS before concluding anything.
"""

import argparse
import logging
import tempfile
import time
from pathlib import Path

import soundfile as sf
from mlx_audio.stt.utils import load_model

from oomguard import arm

log = logging.getLogger("transcribe_check")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="mlx-community/parakeet-tdt-0.6b-v3")
    ap.add_argument("--head", type=float, default=0.0,
                    help="transcribe only N seconds (0 = whole file)")
    ap.add_argument("--start", type=float, default=0.0,
                    help="skip this many seconds first; use with --head to sample the "
                         "middle of a file, since an odd opening is not representative")
    ap.add_argument("--oom-floor-mb", type=int, default=2200)
    ap.add_argument("files", nargs="+")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    arm(floor_mb=args.oom_floor_mb)

    here = Path(__file__).resolve().parent
    log.info("loading %s", args.model)
    model = load_model(args.model)

    for name in args.files:
        path = Path(name)
        if not path.is_absolute():
            path = here / path

        source = path
        if args.head or args.start:
            audio, rate = sf.read(str(path), dtype="float32", always_2d=False)
            begin = int(args.start * rate)
            end = begin + int(args.head * rate) if args.head else len(audio)
            # Hand the ASR a path rather than an array so mlx-audio resamples to whatever
            # the model wants; these renders are 24-48 kHz and parakeet expects 16 kHz.
            trimmed = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
            trimmed.close()
            sf.write(trimmed.name, audio[begin:end], rate)
            source = Path(trimmed.name)

        started = time.time()
        try:
            result = model.generate(str(source))
        except Exception:
            log.exception("%s: transcription failed", path.name)
            continue
        print(f"\n═══ {path.parent.name}/{path.name}"
              f"{f' (first {args.head:g}s)' if args.head else ''} ═══")
        print(result.text.strip())
        log.info("%s: transcribed in %.1fs", path.name, time.time() - started)


if __name__ == "__main__":
    main()
