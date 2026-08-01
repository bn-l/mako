# /// script
# requires-python = "==3.12.*"
# dependencies = ["voxcpm", "torch>=2.6", "psutil"]
# ///
# numpy/soundfile arrive transitively via librosa. Naming numpy explicitly lets the
# resolver pick numpy 2.x, which drags librosa (and then numba) back to versions that
# refuse to build on Python 3.12.
"""Render the brutal corpus in several different VoxCPM2 voices.

    uv run scripts/tts-gen/exp_voxcpm_voices.py

VoxCPM2 has no voice list and no speaker argument — `generate()` takes only
prompt_wav_path/prompt_text for cloning. Reference-free, it samples a fresh speaker
every call, which is why chunking it without a pinned prompt makes the voice lurch
mid-passage. Here that mechanism is the point: seeding torch differently before each
render selects a different speaker, so each seed becomes one "voice".

Within a single render the voice still has to be held steady, so chunk 1 is written out
and handed back as the prompt for the remaining chunks — same approach as
gen_voxcpm.py. One consequence worth knowing while listening: a pinned prompt conveys
delivery as well as timbre, so each file inherits chunk 1's prosody.
"""

import argparse
import logging
import tempfile
import time
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
from voxcpm import VoxCPM

from chunking import chunk_text
from oomguard import arm

REPO = Path(__file__).resolve().parents[2]
RESOURCE_DIR = REPO / "Sources/TTSHarnessCore/Resources"

log = logging.getLogger("exp_voxcpm_voices")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--passage", default="brutal")
    ap.add_argument("--out", default="wav-voxcpm-voices")
    ap.add_argument("--device", default="mps")
    ap.add_argument("--chunk-chars", type=int, default=300)
    ap.add_argument("--cfg-value", type=float, default=2.0)
    ap.add_argument("--timesteps", type=int, default=10)
    ap.add_argument("--oom-floor-mb", type=int, default=3000)
    ap.add_argument("seeds", nargs="*", type=int, default=[1, 2, 3, 4, 5],
                    help="one voice per seed; rendered in order")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    arm(floor_mb=args.oom_floor_mb)

    text = (RESOURCE_DIR / f"{args.passage}.txt").read_text(encoding="utf-8").strip()
    chunks = chunk_text(text, args.chunk_chars)
    out_dir = Path(__file__).resolve().parent / args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    log.info("loading openbmb/VoxCPM2 on %s", args.device)
    model = VoxCPM.from_pretrained(
        "openbmb/VoxCPM2", load_denoiser=False, device=args.device, optimize=False
    )
    sample_rate = model.tts_model.sample_rate
    log.info("loaded; sample_rate=%s; %s -> %d chunks", sample_rate, args.passage, len(chunks))

    gap = np.zeros(int(0.3 * sample_rate), dtype=np.float32)

    for seed in args.seeds:
        log.info("voice seed=%d: rendering %s", seed, args.passage)
        torch.manual_seed(seed)
        started = time.time()
        prompt = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        prompt.close()
        prompt_audio = None
        prompt_text = None
        pieces = []
        for index, chunk in enumerate(chunks, 1):
            options = {
                "text": chunk,
                "cfg_value": args.cfg_value,
                "inference_timesteps": args.timesteps,
            }
            if prompt_audio is not None:
                options["prompt_wav_path"] = prompt_audio
                options["prompt_text"] = prompt_text
            try:
                wav = model.generate(**options)
            except Exception:
                log.exception("seed=%d chunk %d/%d failed: %r", seed, index, len(chunks), chunk[:60])
                continue
            piece = np.asarray(wav, dtype=np.float32).reshape(-1)
            pieces.append(piece)
            pieces.append(gap)
            if prompt_audio is None and piece.size:
                sf.write(prompt.name, piece, sample_rate)
                prompt_audio, prompt_text = prompt.name, chunk
            log.info("  seed=%d chunk %d/%d done (%.1fs elapsed)",
                     seed, index, len(chunks), time.time() - started)

        if not pieces:
            log.error("seed=%d produced no audio", seed)
            continue
        audio = np.concatenate(pieces)
        dest = out_dir / f"seed-{seed:02d}.wav"
        sf.write(dest, audio, sample_rate)
        log.info("wrote %s — %.1fs audio in %.1fs wall",
                 dest, len(audio) / sample_rate, time.time() - started)


if __name__ == "__main__":
    main()
