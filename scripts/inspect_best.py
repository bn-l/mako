"""Run the current best config and show where clicks fall."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "python/src"))
from mac_tts_python.glitch_detection import analyse  # noqa: E402

BINARY = REPO / ".xcbuild/Build/Products/Debug/mac-tts"

cfg = {"KITTEN_CHUNK_TAIL_TRIM": "9000", "KITTEN_FADE_MS": "0", "KITTEN_XFADE_MS": "60"}
tmp = Path(tempfile.mkdtemp(prefix="kitten_inspect_"))
PASSAGE = os.environ.get("INSPECT_PASSAGE", "gulliver")
subprocess.run(
    [
        str(BINARY), "run",
        "--model", "kittentts-coreml-mini",
        "--passage", PASSAGE,
        "--output-dir", str(tmp),
    ],
    check=True,
    cwd=str(REPO),
    env={**os.environ, **cfg},
    stdout=subprocess.DEVNULL,
)
wav = tmp / "kittentts-coreml-mini.wav"
print(f"wav: {wav}")

for sigma in (40, 30, 25, 20):
    r = analyse(wav, click_sigma=sigma)
    print(f"\nsigma={sigma}: clicks={len(r.clicks)} pauses={len(r.pauses)}")
    for c in r.clicks:
        print(f"  t={c.time:6.2f}s |Δ|={c.magnitude:.3f}")
