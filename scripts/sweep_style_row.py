"""Style-row sweep on the micro-corpus.

Reviewer note: Kitten implementations disagree on how to index the 400×256
style matrix — Python uses raw text chunk length, Swift SDK uses phoneme
length, Rust port uses token count. In a StyleTTS2-style stack the style
vector conditions duration, prosody, and the decoder, so a wrong row can
change vowel quality even on correct IPA.

This script sweeps:
  - The three policies (text / phonemes / tokens) via KITTEN_STYLE_ROW_POLICY.
  - A handful of fixed rows (60, 90, 120, 150) via KITTEN_STYLE_ROW.

Trim is held at aggressive-150 + 30 ms fade so we're varying only the
style-row axis. Output lands in outputs/style-row-sweep/<name>/<passage>.wav
plus a per-run style-row log (the stderr `style:` lines) for correlation.
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
OUT_ROOT = REPO / "outputs/style-row-sweep"
PASSAGE = os.environ.get("SWEEP_PASSAGE", "micro-corpus")

BASE_ENV: dict[str, str] = {
    "KITTEN_TRIM_MODE": "aggressive",
    "KITTEN_AGGRESSIVE_TRIM": str(24 * 150),
    "KITTEN_BOUNDARY_FADE_MS": "30",
    "KITTEN_LOG_STYLE_ROW": "1",
}

CANDIDATES: list[tuple[str, dict[str, str]]] = [
    ("policy-text", {"KITTEN_STYLE_ROW_POLICY": "text"}),
    ("policy-phonemes", {"KITTEN_STYLE_ROW_POLICY": "phonemes"}),
    ("policy-tokens", {"KITTEN_STYLE_ROW_POLICY": "tokens"}),
    ("fixed-row-60", {"KITTEN_STYLE_ROW": "60"}),
    ("fixed-row-90", {"KITTEN_STYLE_ROW": "90"}),
    ("fixed-row-120", {"KITTEN_STYLE_ROW": "120"}),
    ("fixed-row-150", {"KITTEN_STYLE_ROW": "150"}),
]


def run(name: str, cfg: dict[str, str]) -> None:
    out_dir = OUT_ROOT / name
    out_dir.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix=f"kitten_style_{name}_"))
    env = {**os.environ, **BASE_ENV, **cfg}
    log_path = out_dir / f"{PASSAGE}.style.log"
    with log_path.open("w") as log:
        subprocess.run(
            [
                str(BINARY),
                "run",
                "--model",
                "kittentts-coreml-mini",
                "--passage",
                PASSAGE,
                "--output-dir",
                str(tmp),
            ],
            check=True,
            cwd=str(REPO),
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=log,
        )
    src = tmp / "kittentts-coreml-mini.wav"
    dst = out_dir / f"{PASSAGE}.wav"
    shutil.copy(src, dst)
    shutil.rmtree(tmp, ignore_errors=True)
    r = analyse(dst)
    style_lines = [
        line for line in log_path.read_text().splitlines() if line.startswith("style:")
    ]
    print(f"{name:<20} clicks={len(r.clicks):>3} pauses={len(r.pauses):>3} dur={r.duration_s:>5.2f}s rows={len(style_lines)}")


for name, cfg in CANDIDATES:
    run(name, cfg)

print(f"\nOutputs: {OUT_ROOT}")
print(f"Style-row log per run: outputs/style-row-sweep/<name>/{PASSAGE}.style.log")
