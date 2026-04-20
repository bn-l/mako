"""Produce 20 candidate WAVs under different KITTEN_TRIM_MODE settings per passage.

Renders every passage in PASSAGES through every candidate and writes to
outputs/candidates/<passage>/<name>.wav plus a README per passage dir. The
candidate set is designed so a single listening pass covers five families:

    A. current detectors (a, b, c, d, e)
    B. detector-parameter variations (b2, b3, c2, c3)
    C. flat-chop baselines (f, g, h, i)
    D. long-fade-only, no detector (j, k, l, m)
    E. detector + fade combined defense (n, o, p)

One passage can be run in isolation via `GEN_PASSAGE=<name>` (and useful when
iterating on code). With `GEN_PASSAGE=all` or unset we render every passage.
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
CAND_ROOT = REPO / "outputs/candidates"
ALL_PASSAGES = ["maya", "trouble", "gulliver", "quiet-house", "death-blow"]
REQUESTED = os.environ.get("GEN_PASSAGE", "all")
PASSAGES = ALL_PASSAGES if REQUESTED == "all" else [REQUESTED]

# (name, env overrides, description).
CANDIDATES: list[tuple[str, dict[str, str], str]] = [
    # Family A — current detectors
    (
        "a-v26-baseline",
        {"KITTEN_TRIM_MODE": "v26"},
        "Original v26 backward scan. Returns rawLen if no loud run found (UNDERTRIM).",
    ),
    (
        "b-bounded-back-500",
        {"KITTEN_TRIM_MODE": "bounded-back", "KITTEN_LOOKBACK_MS": "500", "KITTEN_TRIM_FALLBACK_MS": "80"},
        "v26 scan capped at 500 ms lookback; rawLen − 80 ms fallback.",
    ),
    (
        "c-fwd-last-loud-100",
        {"KITTEN_TRIM_MODE": "fwd-last-loud", "KITTEN_LOOKBACK_MS": "500", "KITTEN_FWD_MARGIN_MS": "100", "KITTEN_TRIM_FALLBACK_MS": "80"},
        "Forward scan, last loud frame + 100 ms margin.",
    ),
    (
        "d-fwd-extend",
        {"KITTEN_TRIM_MODE": "fwd-extend", "KITTEN_LOOKBACK_MS": "500", "KITTEN_TRIM_FALLBACK_MS": "80"},
        "Last loud, then extend through quiet-non-burst frames (RMS > −34 dB, ZCR gate at 0.45).",
    ),
    (
        "e-burst-scan",
        {"KITTEN_TRIM_MODE": "burst-scan", "KITTEN_TRIM_FALLBACK_MS": "80"},
        "Classify RMS + ZCR in last 300 ms; cut at earliest burst-signature run.",
    ),
    # Family B — parameter variations on the leading detectors
    (
        "b2-bounded-back-300",
        {"KITTEN_TRIM_MODE": "bounded-back", "KITTEN_LOOKBACK_MS": "300", "KITTEN_TRIM_FALLBACK_MS": "60"},
        "Tighter bounded-back: 300 ms window, 60 ms fallback. Cuts closer to rawLen when scan fails.",
    ),
    (
        "b3-bounded-back-700",
        {"KITTEN_TRIM_MODE": "bounded-back", "KITTEN_LOOKBACK_MS": "700", "KITTEN_TRIM_FALLBACK_MS": "100"},
        "Looser bounded-back: 700 ms window, 100 ms fallback. More forgiving of long quiet tails.",
    ),
    (
        "c2-fwd-last-loud-60",
        {"KITTEN_TRIM_MODE": "fwd-last-loud", "KITTEN_LOOKBACK_MS": "500", "KITTEN_FWD_MARGIN_MS": "60", "KITTEN_TRIM_FALLBACK_MS": "80"},
        "Tighter fwd margin (60 ms). Risks clipping final stops; kills more burst.",
    ),
    (
        "c3-fwd-last-loud-150",
        {"KITTEN_TRIM_MODE": "fwd-last-loud", "KITTEN_LOOKBACK_MS": "500", "KITTEN_FWD_MARGIN_MS": "150", "KITTEN_TRIM_FALLBACK_MS": "80"},
        "Looser fwd margin (150 ms). Preserves stops/fricatives; risks letting burst through.",
    ),
    # Family C — flat chops (no detector)
    (
        "f-aggressive-50",
        {"KITTEN_TRIM_MODE": "aggressive", "KITTEN_AGGRESSIVE_TRIM": "1200"},
        "Flat 50 ms chop off every sentence-final chunk.",
    ),
    (
        "g-aggressive-80",
        {"KITTEN_TRIM_MODE": "aggressive", "KITTEN_AGGRESSIVE_TRIM": "1920"},
        "Flat 80 ms chop.",
    ),
    (
        "h-aggressive-120",
        {"KITTEN_TRIM_MODE": "aggressive", "KITTEN_AGGRESSIVE_TRIM": "2880"},
        "Flat 120 ms chop.",
    ),
    (
        "i-aggressive-150",
        {"KITTEN_TRIM_MODE": "aggressive", "KITTEN_AGGRESSIVE_TRIM": "3600"},
        "Flat 150 ms chop. Likely clips short word-finals; bounds the 'how much is too much' axis.",
    ),
    # Family D — minimal trim + long fadeOutTail mask
    (
        "j-longfade-60",
        {"KITTEN_TRIM_MODE": "aggressive", "KITTEN_AGGRESSIVE_TRIM": "500", "KITTEN_BOUNDARY_FADE_MS": "60"},
        "Minimal (~20 ms) chop + 60 ms boundary fade. Ramp attenuates anything in last 60 ms.",
    ),
    (
        "k-longfade-100",
        {"KITTEN_TRIM_MODE": "aggressive", "KITTEN_AGGRESSIVE_TRIM": "500", "KITTEN_BOUNDARY_FADE_MS": "100"},
        "Minimal chop + 100 ms boundary fade.",
    ),
    (
        "l-longfade-150",
        {"KITTEN_TRIM_MODE": "aggressive", "KITTEN_AGGRESSIVE_TRIM": "500", "KITTEN_BOUNDARY_FADE_MS": "150"},
        "Minimal chop + 150 ms boundary fade. Expected to produce an audible fade-out on sentence ends.",
    ),
    (
        "m-longfade-200",
        {"KITTEN_TRIM_MODE": "aggressive", "KITTEN_AGGRESSIVE_TRIM": "500", "KITTEN_BOUNDARY_FADE_MS": "200"},
        "Minimal chop + 200 ms boundary fade. Upper bound on masking-only strategy.",
    ),
    # Family E — detector + long-fade combined defense
    (
        "n-boundedback-plus-fade80",
        {"KITTEN_TRIM_MODE": "bounded-back", "KITTEN_LOOKBACK_MS": "500", "KITTEN_TRIM_FALLBACK_MS": "80", "KITTEN_BOUNDARY_FADE_MS": "80"},
        "Bounded-back detector + 80 ms fade. Detector picks the cut, fade masks any residual.",
    ),
    (
        "o-fwdextend-plus-fade60",
        {"KITTEN_TRIM_MODE": "fwd-extend", "KITTEN_LOOKBACK_MS": "500", "KITTEN_TRIM_FALLBACK_MS": "80", "KITTEN_BOUNDARY_FADE_MS": "60"},
        "fwd-extend detector + 60 ms fade.",
    ),
    (
        "p-burstscan-plus-fade60",
        {"KITTEN_TRIM_MODE": "burst-scan", "KITTEN_TRIM_FALLBACK_MS": "80", "KITTEN_BOUNDARY_FADE_MS": "60"},
        "burst-scan detector + 60 ms fade.",
    ),
]


def render_passage(passage: str) -> None:
    out_dir = CAND_ROOT / passage
    out_dir.mkdir(parents=True, exist_ok=True)
    readme_lines = [
        f"# Sentence-final trim candidates — {passage}\n",
        "Each WAV was produced by one invocation of `mac-tts run` with the env overrides below.",
        "All other engine params (voice, speed, sentence-gap default 220 ms) are defaults unless noted.",
        "",
    ]
    for name, cfg, desc in CANDIDATES:
        readme_lines.append(f"## {name}\n\n{desc}\n")
        readme_lines.append("Env: " + ", ".join(f"`{k}={v}`" for k, v in cfg.items()))
        readme_lines.append("")
    (out_dir / "README.md").write_text("\n".join(readme_lines) + "\n")

    print(f"\n=== passage: {passage} ===")
    print(f"{'name':<28} {'clicks':>6} {'pauses':>6} {'dur':>6}")
    for name, cfg, _ in CANDIDATES:
        tmp = Path(tempfile.mkdtemp(prefix=f"kitten_cand_{passage}_{name}_"))
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
        print(f"{name:<28} {len(r.clicks):>6} {len(r.pauses):>6} {r.duration_s:>6.2f}")


for p in PASSAGES:
    render_passage(p)

print(f"\nDone — wrote {len(CANDIDATES)} WAVs per passage for: {', '.join(PASSAGES)}")
print(f"Root: {CAND_ROOT}")
