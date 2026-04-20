"""Scoped phonemizer parity diff for the micro-corpus.

Renders the micro-corpus with phoneme/style/duration logging enabled,
parses the per-chunk records from stderr, and writes a Markdown table
to outputs/reports/phonemizer-parity.md.

Columns per chunk:
  - input chunk text
  - IPA (post-normalizer)
  - text length, phoneme length, token count
  - style row chosen
  - rawLen samples, totalFrames, samples/frame
  - any dropped symbols (from KittenTextCleaner)

Deferred: full Python-reference comparison. That requires running the
upstream `kittentts` package against the same lines and diffing IPA.
Not done yet; keep this first pass local-only so we can see whether
any symbols are dropped, stress is preserved, and punctuation lands
where expected.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BINARY = REPO / ".xcbuild/Build/Products/Debug/mac-tts"
OUT = REPO / "outputs/reports/phonemizer-parity.md"

PHON_RE = re.compile(r"^phonemes@depth\d+: “(.+)” → (.*)$")
STYLE_RE = re.compile(
    r"^style: textLen=(\d+) phonLen=(\d+) tokLen=(\d+) policy=(\w+) override=(-?\d+) → row=(\d+)$"
)
DUR_RE = re.compile(
    r"^duration: rawLen=(\d+) totalFrames=([\d.]+) samplesPerFrame=([\d.]+)$"
)
DROP_RE = re.compile(r"dropped: (.+)$")

tmp = Path(tempfile.mkdtemp(prefix="kitten_parity_"))
env = {
    **os.environ,
    "KITTEN_LOG_PHONEMES": "1",
    "KITTEN_LOG_STYLE_ROW": "1",
    "KITTEN_LOG_DURATION": "1",
    "KITTEN_TRIM_MODE": "aggressive",
    "KITTEN_AGGRESSIVE_TRIM": str(24 * 150),
}
proc = subprocess.run(
    [
        str(BINARY),
        "run",
        "--model",
        "kittentts-coreml-mini",
        "--passage",
        "micro-corpus",
        "--output-dir",
        str(tmp),
    ],
    check=True,
    cwd=str(REPO),
    env=env,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.PIPE,
    text=True,
)
shutil.rmtree(tmp, ignore_errors=True)

lines = proc.stderr.splitlines()

records: list[dict[str, str]] = []
cur: dict[str, str] = {}
for ln in lines:
    m = PHON_RE.match(ln)
    if m:
        if cur:
            records.append(cur)
        cur = {"text": m.group(1), "ipa": m.group(2)}
        continue
    m = STYLE_RE.match(ln)
    if m and cur:
        cur["textLen"] = m.group(1)
        cur["phonLen"] = m.group(2)
        cur["tokLen"] = m.group(3)
        cur["policy"] = m.group(4)
        cur["override"] = m.group(5)
        cur["row"] = m.group(6)
        continue
    m = DUR_RE.match(ln)
    if m and cur:
        cur["rawLen"] = m.group(1)
        cur["totalFrames"] = m.group(2)
        cur["samplesPerFrame"] = m.group(3)
if cur:
    records.append(cur)

dropped = ""
for ln in lines:
    m = DROP_RE.search(ln)
    if m:
        dropped = m.group(1)

OUT.parent.mkdir(parents=True, exist_ok=True)
with OUT.open("w") as f:
    f.write("# Phonemizer parity diff — micro-corpus\n\n")
    f.write("Local pipeline only. See script header for scope.\n\n")
    f.write(f"Dropped symbols across all chunks: `{dropped or '(none)'}`\n\n")
    f.write("| # | text | textLen | phonLen | tokLen | row | rawLen | frames | s/frame | IPA |\n")
    f.write("|---|------|---------|---------|--------|-----|--------|--------|---------|-----|\n")
    for i, r in enumerate(records):
        text = r.get("text", "").replace("|", "\\|")
        ipa = r.get("ipa", "").replace("|", "\\|")
        f.write(
            f"| {i} | {text} | {r.get('textLen','')} | {r.get('phonLen','')} | "
            f"{r.get('tokLen','')} | {r.get('row','')} | {r.get('rawLen','')} | "
            f"{r.get('totalFrames','')} | {r.get('samplesPerFrame','')} | `{ipa}` |\n"
        )

print(f"Wrote {OUT} ({len(records)} chunks)")
if dropped:
    print(f"Dropped symbols: {dropped}")
else:
    print("No symbols dropped.")

# Quick sanity checks: stress marks present, punctuation present.
stress_seen = any("ˈ" in r.get("ipa", "") or "ˌ" in r.get("ipa", "") for r in records)
punct_seen = any(any(p in r.get("ipa", "") for p in [",", ":", ";", "!", "?"]) for r in records)
print(f"Primary/secondary stress marks in any chunk: {stress_seen}")
print(f"Pause punctuation preserved in any chunk: {punct_seen}")
