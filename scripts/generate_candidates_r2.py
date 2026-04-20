"""Round 2 candidates — 20 per passage, focused on the aggressive sweet spot.

Listening round 1 told us: flat aggressive chop beats every detector and
every masking-only fade. The remaining issues are:
  • subtle pop on 'clarity' at 120/150 ms chop
  • slight weirdness after 'whispered' at 80 ms chop
  • 'clariteen' style truncation if the chop eats into the /i/ tail

Round-2 candidates sweep the aggressive chop around 90–160 ms, combine it
with a stronger boundary fade, and test wider sentence gaps — all with the
new phonemic fixes (alphanumeric split, caps-acronym letter-spelling,
slash-letter handling) baked in. Outputs go to outputs/candidates-r2/.
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
CAND_ROOT = REPO / "outputs/candidates-r2"
ALL_PASSAGES = ["maya", "trouble", "gulliver", "quiet-house", "death-blow"]
REQUESTED = os.environ.get("GEN_PASSAGE", "all")
PASSAGES = ALL_PASSAGES if REQUESTED == "all" else [REQUESTED]


def agg(trim_ms: int) -> dict[str, str]:
    return {"KITTEN_TRIM_MODE": "aggressive", "KITTEN_AGGRESSIVE_TRIM": str(int(24 * trim_ms))}


def agg_fade(trim_ms: int, fade_ms: int) -> dict[str, str]:
    return {**agg(trim_ms), "KITTEN_BOUNDARY_FADE_MS": str(fade_ms)}


def agg_fade_gap(trim_ms: int, fade_ms: int, gap_ms: int) -> dict[str, str]:
    return {**agg_fade(trim_ms, fade_ms), "KITTEN_SENTENCE_GAP_MS": str(gap_ms)}


CANDIDATES: list[tuple[str, dict[str, str], str]] = [
    # Fine-grained aggressive sweep (no extra fade or gap)
    ("aa-agg-90", agg(90), "Flat 90 ms chop."),
    ("ab-agg-100", agg(100), "Flat 100 ms chop."),
    ("ac-agg-110", agg(110), "Flat 110 ms chop."),
    ("ad-agg-120", agg(120), "Flat 120 ms chop (round-1 h winner region)."),
    ("ae-agg-130", agg(130), "Flat 130 ms chop."),
    ("af-agg-140", agg(140), "Flat 140 ms chop."),
    ("ag-agg-150", agg(150), "Flat 150 ms chop (round-1 i winner)."),
    ("ah-agg-160", agg(160), "Flat 160 ms chop — slightly past the round-1 envelope."),
    # Aggressive + stronger boundary fade to mask the residual pop on 'clarity'
    ("ai-agg-120-fade-30", agg_fade(120, 30), "120 ms chop + 30 ms fade."),
    ("aj-agg-120-fade-50", agg_fade(120, 50), "120 ms chop + 50 ms fade."),
    ("ak-agg-130-fade-30", agg_fade(130, 30), "130 ms chop + 30 ms fade."),
    ("al-agg-130-fade-50", agg_fade(130, 50), "130 ms chop + 50 ms fade."),
    ("am-agg-140-fade-30", agg_fade(140, 30), "140 ms chop + 30 ms fade."),
    ("an-agg-150-fade-30", agg_fade(150, 30), "150 ms chop + 30 ms fade (direct target for round-1 pop)."),
    ("ao-agg-150-fade-50", agg_fade(150, 50), "150 ms chop + 50 ms fade."),
    # Aggressive + longer sentence gap — more air between sentences
    ("ap-agg-120-gap-300", {**agg(120), "KITTEN_SENTENCE_GAP_MS": "300"}, "120 ms chop + 300 ms sentence gap."),
    ("aq-agg-150-gap-300", {**agg(150), "KITTEN_SENTENCE_GAP_MS": "300"}, "150 ms chop + 300 ms sentence gap."),
    # Combined: trim + fade + longer gap
    ("ar-agg-130-fade-30-gap-280", agg_fade_gap(130, 30, 280), "130 ms chop + 30 ms fade + 280 ms gap."),
    ("as-agg-150-fade-30-gap-280", agg_fade_gap(150, 30, 280), "150 ms chop + 30 ms fade + 280 ms gap."),
    # Conservative lower bound for the sweep
    ("at-agg-70-fade-30", agg_fade(70, 30), "70 ms chop + 30 ms fade — minimum case for the pop under a larger fade."),
]


def render_passage(passage: str) -> None:
    out_dir = CAND_ROOT / passage
    out_dir.mkdir(parents=True, exist_ok=True)
    readme_lines = [
        f"# Round-2 trim candidates — {passage}\n",
        "All candidates use `KITTEN_TRIM_MODE=aggressive` (flat chop) with varying chop ms, boundary-fade ms, and sentence-gap ms.",
        "Phonemic fixes baked in: alphanumeric split (3B→3 B), caps-acronym spelling (ETA→ee,tee,eigh), slash-letter (A/B→eigh slash bee), Route/Highway dropped from ID-spelling.",
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
        tmp = Path(tempfile.mkdtemp(prefix=f"kitten_r2_{passage}_{name}_"))
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

print(f"\nDone — {len(CANDIDATES)} WAVs per passage for: {', '.join(PASSAGES)}")
print(f"Root: {CAND_ROOT}")
