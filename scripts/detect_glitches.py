"""Detect clicks and long pauses in a WAV file.

Usage:
    uv run --with numpy --with soundfile python scripts/detect_glitches.py FILE [FILE ...]

Clicks:   first-order-difference outliers (|Δx| > outlier_k × robust_scale).
Pauses:   contiguous RMS-below-threshold windows longer than min_pause_ms.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import soundfile as sf


def analyse(path: Path) -> None:
    x, sr = sf.read(str(path), dtype="float32", always_2d=False)
    if x.ndim > 1:
        x = x.mean(axis=1)
    n = len(x)
    dur = n / sr
    print(f"\n=== {path.name} ===  ({dur:.2f}s @ {sr}Hz, {n} samples)")

    # ---------- pause detection via 10ms RMS windows ----------
    win = sr // 100  # 10 ms
    frames = n // win
    rms = np.sqrt(
        np.mean(x[: frames * win].reshape(frames, win) ** 2, axis=1) + 1e-12
    )
    rms_db = 20 * np.log10(rms + 1e-12)
    peak_db = 20 * np.log10(np.max(np.abs(x)) + 1e-12)
    threshold_db = peak_db - 40  # silence = 40 dB below peak
    silent = rms_db < threshold_db

    pauses = []
    i = 0
    while i < len(silent):
        if silent[i]:
            j = i
            while j < len(silent) and silent[j]:
                j += 1
            length_ms = (j - i) * 10
            if length_ms >= 150:
                pauses.append((i * win / sr, j * win / sr, length_ms))
            i = j
        else:
            i += 1

    print(f"  peak: {peak_db:.1f} dB   silence threshold: {threshold_db:.1f} dB")
    print(f"  pauses ≥150ms: {len(pauses)}")
    for start, end, ms in pauses[:30]:
        print(f"    {start:6.2f}s → {end:6.2f}s  ({ms} ms)")
    if len(pauses) > 30:
        print(f"    ... (+{len(pauses) - 30} more)")

    # ---------- click detection via first-difference outliers ----------
    diff = np.abs(np.diff(x))
    # robust scale: median absolute deviation * 1.4826 ≈ σ
    median = np.median(diff)
    mad = np.median(np.abs(diff - median)) * 1.4826 + 1e-9
    k = 40.0  # outlier threshold in σ
    cutoff = median + k * mad

    click_idx = np.where(diff > cutoff)[0]
    # merge clicks that are within 5ms of each other (one event)
    merge_gap = sr // 200
    clicks = []
    if len(click_idx) > 0:
        group_start = click_idx[0]
        prev = click_idx[0]
        peak = diff[group_start]
        for idx in click_idx[1:]:
            if idx - prev <= merge_gap:
                if diff[idx] > peak:
                    peak = diff[idx]
                prev = idx
            else:
                clicks.append((group_start / sr, float(peak)))
                group_start = idx
                prev = idx
                peak = diff[idx]
        clicks.append((group_start / sr, float(peak)))

    print(f"  Δ median: {median:.5f}   Δ MAD-σ: {mad:.5f}   cutoff: {cutoff:.4f}")
    print(f"  click events (|Δx|>{k}σ): {len(clicks)}")
    for t, amp in clicks[:30]:
        print(f"    t={t:6.2f}s  |Δ|={amp:.3f}")
    if len(clicks) > 30:
        print(f"    ... (+{len(clicks) - 30} more)")


for arg in sys.argv[1:]:
    analyse(Path(arg))
