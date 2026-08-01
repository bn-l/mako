# /// script
# requires-python = "==3.12.*"
# dependencies = ["mlx-audio", "numpy", "soundfile", "psutil"]
# ///
"""Turn any recording into a fish voice-cloning reference: a short clip + its transcript.

    uv run scripts/tts-gen/make_reference.py nice-audio-for-cloning.wav --seconds 25

Fish clones from `ref_audio` plus `ref_text`, and the text must be what the clip
actually says — a mismatch degrades the clone. Two things therefore have to be right:

  * Length. Fish's docs put useful references at 10-30s. Feeding a two-minute clip
    encodes hundreds of prompt tokens for no benefit and inflates memory.
  * Exactness. Rather than transcribing the whole recording and hoping a slice of the
    text lines up with a slice of the audio, this trims FIRST and transcribes the
    trimmed clip, so the transcript matches by construction.

The cut lands on the quietest 100 ms window inside a search band around the target
length, so it falls in a pause instead of mid-word. Output goes beside the script as
<stem>-ref.wav and <stem>-ref.txt.

Check the printed transcript before using it: ASR mistakes become a wrong ref_text,
which is exactly the mismatch we are trying to avoid.
"""

import argparse
import logging
from pathlib import Path

import numpy as np
import soundfile as sf
from mlx_audio.stt.utils import load_model

from oomguard import arm

log = logging.getLogger("make_reference")


def quietest_cut(audio, rate, low, high):
    """Index of the quietest 100 ms window between `low` and `high` seconds."""
    window = int(0.1 * rate)
    begin, end = int(low * rate), min(int(high * rate), len(audio) - window)
    if end <= begin:
        return min(int(high * rate), len(audio))
    # RMS per candidate window, striding by 20ms to keep this cheap on long files.
    stride = max(1, int(0.02 * rate))
    starts = range(begin, end, stride)
    energies = [float(np.sqrt(np.mean(audio[s:s + window] ** 2))) for s in starts]
    return list(starts)[int(np.argmin(energies))] + window // 2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", help="recording to build a reference from")
    ap.add_argument("--seconds", type=float, default=25.0, help="target clip length")
    ap.add_argument("--search", type=float, default=6.0,
                    help="seconds either side of the target to hunt for a pause")
    ap.add_argument("--start", type=float, default=0.0, help="skip this much lead-in")
    ap.add_argument("--model", default="mlx-community/parakeet-tdt-0.6b-v3")
    ap.add_argument("--oom-floor-mb", type=int, default=2200)
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    arm(floor_mb=args.oom_floor_mb)

    here = Path(__file__).resolve().parent
    source = Path(args.source)
    if not source.is_absolute():
        source = (here.parents[1] / args.source) if not (here / args.source).exists() else here / args.source

    audio, rate = sf.read(str(source), dtype="float32", always_2d=False)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    log.info("%s: %.1fs at %d Hz", source.name, len(audio) / rate, rate)

    begin = int(args.start * rate)
    audio = audio[begin:]
    cut = quietest_cut(audio, rate, args.seconds - args.search, args.seconds + args.search)
    clip = audio[:cut]

    dest_wav = here / f"{source.stem}-ref.wav"
    sf.write(dest_wav, clip, rate)
    log.info("wrote %s — %.1fs", dest_wav, len(clip) / rate)

    log.info("loading %s", args.model)
    model = load_model(args.model)
    result = model.generate(str(dest_wav))
    transcript = result.text.strip()

    dest_txt = here / f"{source.stem}-ref.txt"
    dest_txt.write_text(transcript + "\n", encoding="utf-8")
    print(f"\n═══ transcript ({len(transcript)} chars) — CHECK THIS ═══\n{transcript}\n")
    log.info("wrote %s", dest_txt)


if __name__ == "__main__":
    main()
