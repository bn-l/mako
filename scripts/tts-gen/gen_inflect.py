# /// script
# requires-python = "==3.12.*"
# dependencies = [
#   "torch>=2.6", "huggingface-hub>=0.36", "numpy>=1.26,<3", "scipy>=1.13",
#   "soundfile>=0.13", "phonemizer>=3.3", "espeakng-loader>=0.2.4",
#   "num2words>=0.5.14", "Unidecode>=1.3.8", "psutil",
# ]
# ///
"""Render mako's passages through owensong/Inflect-Micro-v2 (VITS, 24 kHz).

    uv run scripts/tts-gen/gen_inflect.py

The repo ships its own `inference.py` + `runtime/`, so we import from the
downloaded snapshot rather than a published package. Unlike the autoregressive
models, Inflect chunks long text itself (`split_text`, 280-char limit) and joins
with punctuation-dependent silence, so whole passages are handed over intact.
"""

import argparse
import logging
import sys
import time
from pathlib import Path

import soundfile as sf
from huggingface_hub import snapshot_download

from oomguard import arm

REPO = Path(__file__).resolve().parents[2]
RESOURCE_DIR = REPO / "Sources/TTSHarnessCore/Resources"
MODEL_ID = "owensong/Inflect-Micro-v2"
PASSAGE_ORDER = ["micro-corpus", "gulliver", "brutal", "foot-massage", "homographs"]

log = logging.getLogger("gen_inflect")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="wav-inflect-micro-v2")
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--speed", type=float, default=1.0)
    ap.add_argument("--variation", type=float, default=0.667)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--oom-floor-mb", type=int, default=3000,
                    help="SIGKILL this process if available RAM drops below this")
    ap.add_argument("passages", nargs="*")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    arm(floor_mb=args.oom_floor_mb)

    names = args.passages if args.passages else PASSAGE_ORDER
    out_dir = Path(__file__).resolve().parent / args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    log.info("resolving %s", MODEL_ID)
    model_dir = Path(snapshot_download(MODEL_ID))
    # inference.py bare-imports `commons`, `models`, `text`, … from its runtime/ dir,
    # and normally puts them on sys.path itself via Path(__file__).resolve().parent.
    # That breaks inside an HF snapshot: the files are symlinks into ../../blobs, so
    # resolve() escapes the snapshot and its runtime/ insert points at a missing dir.
    # Insert both paths here instead (model_dir is still passed explicitly below, so
    # the module's own PACKAGE_ROOT is only used for argparse defaults).
    sys.path.insert(0, str(model_dir / "runtime"))
    sys.path.insert(0, str(model_dir))
    from inference import InflectTTS

    log.info("loading model from %s (device=%s)", model_dir, args.device)
    tts = InflectTTS(model_dir, device=args.device)

    for name in names:
        src = RESOURCE_DIR / f"{name}.txt"
        if not src.exists():
            log.warning("no such passage: %s", src)
            continue
        text = src.read_text(encoding="utf-8").strip()
        log.info("%s: %d chars", name, len(text))
        started = time.time()
        try:
            sample_rate, waveform = tts.synthesize(
                text, speed=args.speed, variation=args.variation, seed=args.seed
            )
        except Exception:
            log.exception("%s: synthesis failed", name)
            continue
        dest = out_dir / f"{name}.wav"
        sf.write(dest, waveform, sample_rate)
        log.info(
            "wrote %s — %.1fs audio in %.1fs wall",
            dest, len(waveform) / sample_rate, time.time() - started,
        )


if __name__ == "__main__":
    main()
