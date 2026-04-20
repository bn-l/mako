"""Objective glitch / pause detection for TTS output WAVs.

`analyse(path)` returns an `AudioReport` with:
- click events: indices where |Δx| > `click_sigma` × robust MAD σ on the
  first-difference. Nearby clicks (within `merge_ms`) are merged.
- pauses: contiguous windows where a short-window RMS is `silence_db` below
  the peak, longer than `min_pause_ms`.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np
import soundfile as sf


@dataclass
class Click:
    time: float
    magnitude: float


@dataclass
class Pause:
    start: float
    end: float

    @property
    def duration_ms(self) -> float:
        return (self.end - self.start) * 1000.0


@dataclass
class AudioReport:
    path: Path
    sample_rate: int
    duration_s: float
    peak_db: float
    clicks: list[Click]
    pauses: list[Pause]
    click_cutoff: float

    def summary(self) -> str:
        lines = [
            f"{self.path.name} ({self.duration_s:.2f}s @ {self.sample_rate}Hz)",
            f"  peak {self.peak_db:.1f} dB | clicks {len(self.clicks)} | pauses {len(self.pauses)}",
        ]
        for c in self.clicks[:20]:
            lines.append(f"    click t={c.time:.2f}s |Δ|={c.magnitude:.3f}")
        for p in self.pauses[:20]:
            lines.append(
                f"    pause {p.start:.2f}s→{p.end:.2f}s ({p.duration_ms:.0f} ms)"
            )
        return "\n".join(lines)


def analyse(
    path: Path,
    click_sigma: float = 40.0,
    merge_ms: float = 5.0,
    silence_db: float = 40.0,
    min_pause_ms: float = 150.0,
    rms_window_ms: float = 10.0,
) -> AudioReport:
    x, sr = sf.read(str(path), dtype="float32", always_2d=False)
    if x.ndim > 1:
        x = x.mean(axis=1)
    n = len(x)
    duration_s = n / sr

    peak = float(np.max(np.abs(x)) + 1e-12)
    peak_db = 20 * np.log10(peak)

    win = max(1, int(sr * rms_window_ms / 1000))
    frames = n // win
    windowed = x[: frames * win].reshape(frames, win)
    rms = np.sqrt(np.mean(windowed**2, axis=1) + 1e-12)
    rms_db = 20 * np.log10(rms + 1e-12)
    silent = rms_db < (peak_db - silence_db)

    pauses: list[Pause] = []
    i = 0
    while i < len(silent):
        if silent[i]:
            j = i
            while j < len(silent) and silent[j]:
                j += 1
            length_ms = (j - i) * rms_window_ms
            if length_ms >= min_pause_ms:
                pauses.append(Pause(start=i * win / sr, end=j * win / sr))
            i = j
        else:
            i += 1

    diff = np.abs(np.diff(x))
    median = float(np.median(diff))
    mad = float(np.median(np.abs(diff - median)) * 1.4826 + 1e-9)
    cutoff = median + click_sigma * mad

    click_idx = np.where(diff > cutoff)[0]
    merge_gap = max(1, int(sr * merge_ms / 1000))
    clicks: list[Click] = []
    if len(click_idx) > 0:
        group_start = int(click_idx[0])
        prev = group_start
        peak_delta = float(diff[group_start])
        for raw in click_idx[1:]:
            idx = int(raw)
            if idx - prev <= merge_gap:
                if diff[idx] > peak_delta:
                    peak_delta = float(diff[idx])
                prev = idx
            else:
                clicks.append(Click(time=group_start / sr, magnitude=peak_delta))
                group_start = idx
                prev = idx
                peak_delta = float(diff[idx])
        clicks.append(Click(time=group_start / sr, magnitude=peak_delta))

    return AudioReport(
        path=path,
        sample_rate=sr,
        duration_s=duration_s,
        peak_db=peak_db,
        clicks=clicks,
        pauses=pauses,
        click_cutoff=cutoff,
    )
