# /// script
# requires-python = "==3.12.*"
# dependencies = ["voxcpm", "psutil"]
# ///
# numpy/soundfile come in transitively via librosa. Listing numpy explicitly lets the
# resolver pick numpy 2.x, which drags librosa (and then numba) back to versions that
# refuse to build on Python 3.12.
"""Render mako's passages through openbmb/VoxCPM2 (2B diffusion-AR, 48 kHz out).

    uv run scripts/tts-gen/gen_voxcpm.py

Uses the official `voxcpm` package rather than mlx-audio: mlx-audio ships a
`voxcpm2` family, but it targets an MLX-converted checkpoint and rejects the
official repo's `audio_vae.encoder.*` tensors outright.

The upstream requirements say CUDA; on Apple silicon we run MPS and fall back to
CPU if an op is unimplemented there. `load_denoiser=False` skips the separate
ZipEnhancer download, which is only for cleaning reference audio (we pass none).
"""

import argparse
import logging
import tempfile
import time
from pathlib import Path

import numpy as np
import soundfile as sf
from voxcpm import VoxCPM

from chunking import chunk_text
from oomguard import arm

REPO = Path(__file__).resolve().parents[2]
RESOURCE_DIR = REPO / "Sources/TTSHarnessCore/Resources"
PASSAGE_ORDER = ["micro-corpus", "gulliver", "brutal", "foot-massage", "homographs"]

log = logging.getLogger("gen_voxcpm")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="wav-voxcpm2")
    ap.add_argument("--device", default="mps")
    ap.add_argument("--chunk-chars", type=int, default=300)
    ap.add_argument("--cfg-value", type=float, default=2.0)
    ap.add_argument("--timesteps", type=int, default=10)
    ap.add_argument("--no-pin-voice", action="store_true",
                    help="don't reuse chunk 1 as the voice prompt (voice will drift per chunk)")
    ap.add_argument("--oom-floor-mb", type=int, default=3000,
                    help="SIGKILL this process if available RAM drops below this")
    ap.add_argument("passages", nargs="*")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    arm(floor_mb=args.oom_floor_mb)

    names = args.passages if args.passages else PASSAGE_ORDER
    out_dir = Path(__file__).resolve().parent / args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    log.info("loading openbmb/VoxCPM2 on %s", args.device)
    model = VoxCPM.from_pretrained(
        "openbmb/VoxCPM2", load_denoiser=False, device=args.device, optimize=False
    )
    sample_rate = model.tts_model.sample_rate
    log.info("loaded; sample_rate=%s", sample_rate)

    gap = np.zeros(int(0.3 * sample_rate), dtype=np.float32)

    for name in names:
        src = RESOURCE_DIR / f"{name}.txt"
        if not src.exists():
            log.warning("no such passage: %s", src)
            continue
        text = src.read_text(encoding="utf-8").strip()
        chunks = chunk_text(text, args.chunk_chars)
        log.info("%s: %d chars -> %d chunks", name, len(text), len(chunks))

        pieces = []
        started = time.time()
        # VoxCPM2 samples a fresh speaker per generate() call, so chunk 2 onward would
        # arrive in a different voice. Chunk 1 is written out and handed back as the
        # prompt for the rest, which pins the timbre for the whole passage.
        prompt = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        prompt.close()
        prompt_audio = None
        prompt_text = None
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
                log.exception("%s: chunk %d/%d failed: %r", name, index, len(chunks), chunk[:60])
                continue
            piece = np.asarray(wav, dtype=np.float32).reshape(-1)
            pieces.append(piece)
            pieces.append(gap)
            if not args.no_pin_voice and prompt_audio is None and piece.size:
                sf.write(prompt.name, piece, sample_rate)
                prompt_audio, prompt_text = prompt.name, chunk
                log.info("  pinned voice to chunk 1")
            log.info("  %s: chunk %d/%d done (%.1fs elapsed)", name, index, len(chunks), time.time() - started)

        if not pieces:
            log.error("%s: produced no audio, skipping", name)
            continue
        audio = np.concatenate(pieces)
        dest = out_dir / f"{name}.wav"
        sf.write(dest, audio, sample_rate)
        log.info(
            "wrote %s — %.1fs audio in %.1fs wall",
            dest, len(audio) / sample_rate, time.time() - started,
        )


if __name__ == "__main__":
    main()
