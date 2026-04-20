"""Click / pause regression test for kittentts-coreml-mini.

Runs the built mac-tts binary against the Gulliver passage, analyses the
output WAV, and asserts click/pause counts stay below thresholds. These
thresholds tighten as engine parameters improve — a regression that adds
audible glitches makes the test fail.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

import pytest

from mac_tts_python.glitch_detection import analyse

REPO_ROOT = Path(__file__).resolve().parents[2]
BINARY = REPO_ROOT / ".xcbuild/Build/Products/Debug/mac-tts"

MAX_CLICKS = 8
MAX_PAUSES = 24


@pytest.fixture(scope="module")
def mini_wav() -> Path:
    if not BINARY.exists():
        pytest.skip(f"mac-tts binary not built at {BINARY}")
    tmp = Path(tempfile.mkdtemp(prefix="kitten_coreml_glitch_"))
    subprocess.run(
        [
            str(BINARY),
            "run",
            "--model",
            "kittentts-coreml-mini",
            "--passage",
            "gulliver",
            "--output-dir",
            str(tmp),
        ],
        check=True,
        cwd=str(REPO_ROOT),
        env={**os.environ},
    )
    wav = tmp / "kittentts-coreml-mini.wav"
    assert wav.exists(), f"expected output at {wav}"
    return wav


def test_click_count_under_threshold(mini_wav: Path) -> None:
    report = analyse(mini_wav)
    print("\n" + report.summary())
    assert len(report.clicks) <= MAX_CLICKS, (
        f"clicks={len(report.clicks)} > {MAX_CLICKS}"
    )


def test_pause_count_under_threshold(mini_wav: Path) -> None:
    report = analyse(mini_wav)
    print("\n" + report.summary())
    assert len(report.pauses) <= MAX_PAUSES, (
        f"pauses={len(report.pauses)} > {MAX_PAUSES}"
    )


def test_duration_reasonable(mini_wav: Path) -> None:
    report = analyse(mini_wav)
    assert 50.0 <= report.duration_s <= 90.0, f"duration_s={report.duration_s}"
