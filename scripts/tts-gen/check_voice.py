# /// script
# requires-python = "==3.12.*"
# dependencies = ["librosa", "numpy", "soundfile"]
# ///
"""Detect speaker changes inside a rendered passage.

The cloning models sample a fresh speaker per generate() call, so chunking a
passage can make the voice lurch mid-file. That is audible immediately but tedious
to confirm by ear across dozens of renders, so this reports a per-window voice
fingerprint (median F0 + spectral centroid) and flags the largest jump.

    uv run scripts/tts-gen/check_voice.py wav-fish-s2-pro-8bit/micro-corpus.wav ...
    uv run scripts/tts-gen/check_voice.py --summary wav-qwen-voices/*.wav

A stable voice holds F0 roughly flat across windows. A speaker switch shows up as a
step change — a jump of tens of Hz that persists, rather than a one-window blip.

--summary prints one row per file for comparing renders side by side:

    F0 Hz     median pitch — voice identity. Distinct voices differ here.
    span st   mean p10..p90 pitch movement WITHIN a window, in semitones. This is a
              proxy for how flat the delivery is: bigger means more intonation. It is
              only a proxy — it cannot tell expressive intonation from wobble, so treat
              it as a pointer to what to listen to, not a verdict.
    drift     std of per-window median F0. Large values mean the voice moved across the
              file, i.e. a speaker change rather than expressiveness.
"""

import argparse
from pathlib import Path

import librosa
import numpy as np


def profile(path, window):
    audio, sample_rate = librosa.load(str(path), sr=None, mono=True)
    step = int(window * sample_rate)
    rows = []
    for start in range(0, len(audio) - step // 2, step):
        segment = audio[start : start + step]
        if segment.size < sample_rate // 2:
            continue
        f0 = librosa.yin(segment, fmin=60, fmax=400, sr=sample_rate)
        voiced = f0[np.isfinite(f0)]
        centroid = librosa.feature.spectral_centroid(y=segment, sr=sample_rate)
        # p10..p90 of F0 inside the window, in semitones: how far the pitch actually
        # moves while speaking. A flat delivery keeps this small.
        if voiced.size:
            low, high = np.percentile(voiced, [10, 90])
            span = 12.0 * np.log2(high / low) if low > 0 else float("nan")
        else:
            span = float("nan")
        rows.append((start / sample_rate,
                     float(np.median(voiced)) if voiced.size else float("nan"),
                     float(np.median(centroid)),
                     float(span)))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--window", type=float, default=3.0, help="seconds per window")
    ap.add_argument("--summary", action="store_true",
                    help="one line per file: voice identity plus a flatness proxy, for "
                         "comparing many renders at once")
    ap.add_argument("files", nargs="+")
    args = ap.parse_args()

    if args.summary:
        print(f"{'file':<38} {'F0 Hz':>6} {'span st':>8} {'drift':>6} {'centroid':>9}")
    for name in args.files:
        path = Path(name)
        if not path.is_absolute():
            path = Path(__file__).resolve().parent / path
        rows = profile(path, args.window)
        pitches = np.array([f0 for _, f0, _, _ in rows])
        jumps = np.abs(np.diff(pitches))

        if args.summary:
            spans = np.array([span for _, _, _, span in rows])
            centroids = np.array([c for _, _, c, _ in rows])
            print(f"{path.name:<38} {np.nanmedian(pitches):6.1f} "
                  f"{np.nanmean(spans):8.2f} {np.nanstd(pitches):6.1f} "
                  f"{np.nanmedian(centroids):9.0f}")
            continue

        print(f"\n═══ {path.name}  ({path.parent.name}) ═══")
        print(f"{'t':>7}  {'F0 Hz':>7}  {'centroid':>9}  {'span st':>8}")
        for seconds, f0, centroid, span in rows:
            print(f"{seconds:7.1f}  {f0:7.1f}  {centroid:9.0f}  {span:8.2f}")
        if jumps.size and np.isfinite(jumps).any():
            worst = int(np.nanargmax(jumps))
            print(f"largest F0 jump: {jumps[worst]:.1f} Hz at t≈{rows[worst + 1][0]:.1f}s "
                  f"({pitches[worst]:.0f} -> {pitches[worst + 1]:.0f} Hz)")


if __name__ == "__main__":
    main()
