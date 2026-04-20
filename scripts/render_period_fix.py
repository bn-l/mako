"""Render micro-corpus + maya + trouble with the sentence-final period fix.

Output goes to outputs/period-fix/<passage>/after.wav at the round-2
baseline (aggressive-150 + 30 ms fade). Compare against the matching
outputs/dur-aligned-ab/<passage>/agg-150-fade-30.wav from before the fix.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "python/src"))
from mac_tts_python.glitch_detection import analyse  # noqa: E402

BINARY = REPO / ".xcbuild/Build/Products/Debug/mac-tts"
OUT_ROOT = REPO / "outputs/period-fix"
PASSAGES = ["micro-corpus", "maya", "trouble"]

env = {
    **os.environ,
    "KITTEN_TRIM_MODE": "aggressive",
    "KITTEN_AGGRESSIVE_TRIM": str(24 * 150),
    "KITTEN_BOUNDARY_FADE_MS": "30",
}

for passage in PASSAGES:
    out_dir = OUT_ROOT / passage
    out_dir.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix=f"kitten_pf_{passage}_"))
    subprocess.run(
        [
            str(BINARY),
            "run",
            "--model",
            "kittentts-coreml-mini",
            "--passage",
            passage,
            "--output-dir",
            str(tmp),
        ],
        check=True,
        cwd=str(REPO),
        env=env,
        stdout=subprocess.DEVNULL,
    )
    src = tmp / "kittentts-coreml-mini.wav"
    dst = out_dir / "after.wav"
    shutil.copy(src, dst)
    shutil.rmtree(tmp, ignore_errors=True)
    r = analyse(dst)
    print(f"{passage:<14} clicks={len(r.clicks):>3} pauses={len(r.pauses):>3} dur={r.duration_s:>5.2f}s → {dst}")

print(f"\nCompare against outputs/dur-aligned-ab/<passage>/agg-150-fade-30.wav (before the period fix).")
