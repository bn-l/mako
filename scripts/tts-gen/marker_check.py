# /// script
# requires-python = "==3.12.*"
# dependencies = ["librosa", "numpy", "soundfile"]
# ///
"""Per-segment loudness and pitch for a render joined by join_with_pauses.

    uv run scripts/tts-gen/marker_check.py wav-fish-markers/markers.wav

Renders assembled by gen_fish are separated by digitally silent gaps, so the segments
can be recovered exactly by splitting on runs of zeros — no energy threshold to tune.
That makes it possible to check whether an inline [tag] actually did anything: line up
the segments with the source paragraphs and compare, e.g., [whisper] against [shouting].

Transcription proves a marker was not read aloud. It does not prove the marker was
obeyed. This is the other half of that check.
"""

import argparse
from pathlib import Path

import librosa
import numpy as np
import soundfile as sf


def segments(audio, rate, min_gap):
    """Spans of audio separated by runs of exact silence at least `min_gap` long."""
    silent = audio == 0.0
    edges = np.diff(silent.astype(np.int8))
    starts = np.flatnonzero(edges == 1) + 1
    ends = np.flatnonzero(edges == -1) + 1
    if silent[0]:
        starts = np.insert(starts, 0, 0)
    if silent[-1]:
        ends = np.append(ends, len(audio))
    gaps = [(s, e) for s, e in zip(starts, ends) if e - s >= min_gap * rate]

    spans, cursor = [], 0
    for gap_start, gap_end in gaps:
        if gap_start > cursor:
            spans.append((cursor, gap_start))
        cursor = gap_end
    if cursor < len(audio):
        spans.append((cursor, len(audio)))
    return spans


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("--min-gap", type=float, default=0.2, help="shortest joining silence")
    ap.add_argument("--speech", action="store_true",
                    help="split on breath pauses rather than the joining silences, so "
                         "markers that contrast INSIDE one batch can be compared")
    args = ap.parse_args()

    path = Path(args.source)
    audio, rate = sf.read(str(path), dtype="float32", always_2d=False)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)

    spans = (librosa.effects.split(audio, top_db=32, frame_length=2048, hop_length=512)
             if args.speech else segments(audio, rate, args.min_gap))

    print(f"{'seg':>3} {'start':>7} {'secs':>6} {'dBFS':>7} {'peak dB':>8} {'F0 Hz':>7}")
    for index, (begin, end) in enumerate(spans, start=1):
        piece = audio[begin:end]
        rms = 20 * np.log10(max(float(np.sqrt(np.mean(piece ** 2))), 1e-9))
        peak = 20 * np.log10(max(float(np.max(np.abs(piece))), 1e-9))
        f0 = librosa.yin(piece, fmin=70, fmax=400, sr=rate)
        print(f"{index:>3} {begin / rate:>7.1f} {len(piece) / rate:>6.1f} "
              f"{rms:>7.1f} {peak:>8.1f} {float(np.median(f0)):>7.1f}")


if __name__ == "__main__":
    main()
