"""A/B the new duration-aligned trim against round-2's aggressive-150.

Baseline: aggressive-150 + 30 ms fade (round-2 best from listening notes).
Test: dur-aligned with margin 10/20/30/50 ms.

Listening focus is on the sentence-final boundaries that round-1 called
out — 'whispered', 'clarity', 'note', 'folded note'. The point isn't
just fewer clicks; it's whether the new cut lands on the content-token
boundary instead of inside the pause region.

Output: outputs/dur-aligned-ab/<passage>/<candidate>.wav
Passages: micro-corpus, maya, trouble (covers the known glitch cases).
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
OUT_ROOT = REPO / "outputs/dur-aligned-ab"
PASSAGES = ["micro-corpus", "maya", "trouble"]

CANDIDATES: list[tuple[str, dict[str, str]]] = [
    (
        "agg-150-fade-30",
        {
            "KITTEN_TRIM_MODE": "aggressive",
            "KITTEN_AGGRESSIVE_TRIM": str(24 * 150),
            "KITTEN_BOUNDARY_FADE_MS": "30",
        },
    ),
    (
        "dur-margin-10",
        {
            "KITTEN_TRIM_MODE": "dur-aligned",
            "KITTEN_DUR_MARGIN_MS": "10",
            "KITTEN_BOUNDARY_FADE_MS": "30",
        },
    ),
    (
        "dur-margin-20",
        {
            "KITTEN_TRIM_MODE": "dur-aligned",
            "KITTEN_DUR_MARGIN_MS": "20",
            "KITTEN_BOUNDARY_FADE_MS": "30",
        },
    ),
    (
        "dur-margin-30",
        {
            "KITTEN_TRIM_MODE": "dur-aligned",
            "KITTEN_DUR_MARGIN_MS": "30",
            "KITTEN_BOUNDARY_FADE_MS": "30",
        },
    ),
    (
        "dur-margin-50",
        {
            "KITTEN_TRIM_MODE": "dur-aligned",
            "KITTEN_DUR_MARGIN_MS": "50",
            "KITTEN_BOUNDARY_FADE_MS": "30",
        },
    ),
]


def render(passage: str) -> None:
    out_dir = OUT_ROOT / passage
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"\n=== {passage} ===")
    for name, cfg in CANDIDATES:
        tmp = Path(tempfile.mkdtemp(prefix=f"kitten_dab_{passage}_{name}_"))
        env = {**os.environ, **cfg}
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
        dst = out_dir / f"{name}.wav"
        shutil.copy(src, dst)
        shutil.rmtree(tmp, ignore_errors=True)
        r = analyse(dst)
        print(f"  {name:<20} clicks={len(r.clicks):>3} pauses={len(r.pauses):>3} dur={r.duration_s:>5.2f}s")


for p in PASSAGES:
    render(p)

print(f"\nOutputs: {OUT_ROOT}")
