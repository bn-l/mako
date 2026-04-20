"""Sweep KITTEN_* env vars over the mac-tts binary and report glitch metrics."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "python/src"))
from mac_tts_python.glitch_detection import analyse  # noqa: E402

BINARY = REPO / ".xcbuild/Build/Products/Debug/mac-tts"


def base(
    trim: int = 9000,
    short_trim: int = 3000,
    fade: int = 0,
    xfade: int = 60,
    adapt: int = 500,
    zc: int = 0,
    dc: int = 0,
    style_row: int = -1,
    max_chars: int = 80,
):
    return {
        "KITTEN_CHUNK_TAIL_TRIM": trim,
        "KITTEN_SHORT_TAIL_TRIM": short_trim,
        "KITTEN_FADE_MS": fade,
        "KITTEN_XFADE_MS": xfade,
        "KITTEN_ADAPTIVE_TRIM_MS": adapt,
        "KITTEN_ZC_SNAP_SAMPLES": zc,
        "KITTEN_DC_BLOCK": dc,
        "KITTEN_STYLE_ROW": style_row,
        "KITTEN_MAX_CHARS": max_chars,
    }


configs: list[dict[str, int]] = [
    # content-aware trim (9000 on quiet tails, 3000 on loud) + xfade variants
    base(),                              # default
    base(xfade=100),
    base(xfade=120, zc=500),
    base(xfade=150, zc=500),
    # larger max_chars → fewer mid-phrase boundaries
    base(max_chars=100),
    base(max_chars=120),
    base(max_chars=130),
    base(max_chars=120, xfade=100),
    base(max_chars=120, xfade=120, zc=500),
    # loud-tail short trim variants
    base(short_trim=1500),
    base(short_trim=5000),
    base(max_chars=120, short_trim=1500, xfade=100),
]


PASSAGE = os.environ.get("SWEEP_PASSAGE", "gulliver")


def run(cfg: dict[str, int]) -> tuple[int, int, float, float]:
    tmp = Path(tempfile.mkdtemp(prefix="kitten_sweep_"))
    env = {**os.environ, **{k: str(v) for k, v in cfg.items()}}
    t0 = time.time()
    subprocess.run(
        [
            str(BINARY), "run",
            "--model", "kittentts-coreml-mini",
            "--passage", PASSAGE,
            "--output-dir", str(tmp),
        ],
        check=True,
        cwd=str(REPO),
        env=env,
        stdout=subprocess.DEVNULL,
    )
    elapsed = time.time() - t0
    r = analyse(tmp / "kittentts-coreml-mini.wav")
    return len(r.clicks), len(r.pauses), r.duration_s, elapsed


cols = ["trim", "short", "xfade", "adapt", "zc", "chars", "clicks", "pauses", "dur", "wall"]
print("  ".join(f"{c:>6}" for c in cols))
for cfg in configs:
    clicks, pauses, dur, wall = run(cfg)
    print(
        f"{cfg['KITTEN_CHUNK_TAIL_TRIM']:>6} "
        f"{cfg['KITTEN_SHORT_TAIL_TRIM']:>6} "
        f"{cfg['KITTEN_XFADE_MS']:>6} "
        f"{cfg['KITTEN_ADAPTIVE_TRIM_MS']:>6} "
        f"{cfg['KITTEN_ZC_SNAP_SAMPLES']:>6} "
        f"{cfg['KITTEN_MAX_CHARS']:>6}  "
        f"{clicks:>6} {pauses:>6} {dur:>6.2f} {wall:>5.2f}"
    )
