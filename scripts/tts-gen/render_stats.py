# /// script
# requires-python = "==3.12.*"
# dependencies = []
# ///
"""Summarise throughput and memory for renders, parsed from their run logs.

    uv run scripts/tts-gen/render_stats.py /path/to/*.log

Every generator logs one completion line per render:

    wrote <path> — <audio>s audio in <wall>s wall [active .. cache .. peak .. avail ..]

Columns:

    chars     source passage length, taken live from Resources/. This is the text we
              asked for, not what the model was fed — fish's tagged mode adds
              `<|speaker:0|>` markers, and counting those would flatter its chars/s.
    audio s   duration produced.
    wall s    time to produce it.
    RTF       audio seconds per wall second. Above 1.0 is faster than real time.
    chars/s   source characters consumed per wall second.
    peak G    mx.get_peak_memory() at the end of the render — the transient high-water
              mark, which is what determines whether a run survives. Blank for VoxCPM2,
              which is a torch model and reports no MLX counters.

Duration is not a fixed property of the text: the same passage rendered with looser
sampling comes out longer because the delivery is slower and more varied, which drags
RTF and chars/s down. Slower is not worse here.
"""

import argparse
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
RESOURCE_DIR = REPO / "Sources/TTSHarnessCore/Resources"

# Which passage each output directory was rendered from.
DIR_PASSAGE = {
    "wav-fish-prosody": "micro-corpus",
    "wav-fish-itin": "itin",
    "wav-qwen-voices": "brutal",
    "wav-qwen-itin": "itin",
    "wav-voxcpm-voices": "brutal",
    "wav-fish-s2-pro-8bit": None,
    "wav-qwen3-tts-12hz-1.7b-8bit": None,
    "wav-inflect-micro-v2": None,
}

WROTE = re.compile(
    r"wrote (?P<path>\S+) — (?P<audio>[\d.]+)s audio in (?P<wall>[\d.]+)s wall"
    r"(?: \([^)]*\))?(?: \[(?P<mem>[^\]]*)\])?"
)
PEAK = re.compile(r"peak ([\d.]+)G")


def passage_chars(cache, name):
    if name not in cache:
        source = RESOURCE_DIR / f"{name}.txt"
        cache[name] = len(source.read_text(encoding="utf-8").strip()) if source.exists() else 0
    return cache[name]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("logs", nargs="+")
    args = ap.parse_args()

    cache = {}
    rows = []
    for name in args.logs:
        for line in Path(name).read_text(encoding="utf-8", errors="replace").splitlines():
            found = WROTE.search(line)
            if not found:
                continue
            path = Path(found["path"])
            audio = float(found["audio"])
            wall = float(found["wall"])
            passage = DIR_PASSAGE.get(path.parent.name) or path.stem
            chars = passage_chars(cache, passage)
            peak = PEAK.search(found["mem"] or "")
            rows.append({
                "dir": path.parent.name,
                "file": path.name,
                "chars": chars,
                "audio": audio,
                "wall": wall,
                "rtf": audio / wall if wall else 0.0,
                "cps": chars / wall if wall else 0.0,
                "peak": float(peak.group(1)) if peak else None,
            })

    if not rows:
        print("no completed renders found in those logs")
        return

    width = max(len(row["dir"]) + len(row["file"]) for row in rows) + 2
    print(f"{'render':<{width}} {'chars':>6} {'audio s':>8} {'wall s':>7} "
          f"{'RTF':>5} {'chars/s':>8} {'peak G':>7}")
    for row in sorted(rows, key=lambda item: (item["dir"], item["file"])):
        label = f"{row['dir']}/{row['file']}"
        peak = f"{row['peak']:7.1f}" if row["peak"] is not None else "      —"
        print(f"{label:<{width}} {row['chars']:6d} {row['audio']:8.1f} {row['wall']:7.1f} "
              f"{row['rtf']:5.2f} {row['cps']:8.1f} {peak}")

    print()
    for name in sorted({row["dir"] for row in rows}):
        group = [row for row in rows if row["dir"] == name]
        audio = sum(row["audio"] for row in group)
        wall = sum(row["wall"] for row in group)
        peaks = [row["peak"] for row in group if row["peak"] is not None]
        summary = (f"{name}: {len(group)} renders, {audio:.0f}s audio in {wall:.0f}s wall, "
                   f"mean RTF {audio / wall:.2f}")
        if peaks:
            summary += f", peak {min(peaks):.1f}-{max(peaks):.1f}G"
        print(summary)


if __name__ == "__main__":
    main()
