"""Render passages with upstream-Python IPA substituted for our Swift IPA.

Pipeline:
  1. Run the binary with KITTEN_LOG_PHONEMES=1 on each passage, capture
     each `phonemes@depth0: "CHUNK_TEXT" → IPA` line from stderr so we get
     the exact post-normalization chunk text our engine actually hands to
     the phonemizer.
  2. Feed each CHUNK_TEXT to upstream `phonemizer.EspeakBackend` (en-us,
     preserve_punctuation, with_stress) and record the IPA.
  3. Write a JSON map {chunk_text: upstream_ipa} to /tmp.
  4. Re-run the binary with KITTEN_IPA_CHUNK_OVERRIDE_FILE=<that map> so
     the Swift engine uses upstream IPA verbatim instead of EPhonemizer.
  5. Output audio lands in outputs/ref-ipa/<passage>/after.wav.

Question it answers: does feeding bit-exact upstream IPA change how the
model renders `live` / `four` / `more` / etc., or is the issue on the
model side regardless of IPA provenance?
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import espeakng_loader  # noqa: F401
from phonemizer.backend import EspeakBackend
from phonemizer.backend.espeak.wrapper import EspeakWrapper

EspeakWrapper.set_library(espeakng_loader.get_library_path())
os.environ["ESPEAK_DATA_PATH"] = espeakng_loader.get_data_path()

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "python/src"))
from mac_tts_python.glitch_detection import analyse  # noqa: E402

BINARY = REPO / ".xcbuild/Build/Products/Debug/mac-tts"
OUT_ROOT = REPO / "outputs/ref-ipa"
PASSAGES = ["micro-corpus", "maya", "trouble"]

PHON_RE = re.compile(r'^phonemes@depth\d+: "(.+)" → (.*)$')
backend = EspeakBackend(language="en-us", preserve_punctuation=True, with_stress=True)


def capture_chunks(passage: str) -> list[str]:
    tmp = Path(tempfile.mkdtemp(prefix=f"kitten_cap_{passage}_"))
    env = {
        **os.environ,
        "KITTEN_LOG_PHONEMES": "1",
    }
    proc = subprocess.run(
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
        stderr=subprocess.PIPE,
        text=True,
    )
    shutil.rmtree(tmp, ignore_errors=True)
    chunks: list[str] = []
    for ln in proc.stderr.splitlines():
        # Handle both straight and curly quotes (depth log uses “…”)
        m = re.match(r'^phonemes@depth\d+: [“"](.+)[”"] → (.*)$', ln)
        if m:
            chunks.append(m.group(1))
    return chunks


def main() -> None:
    OUT_ROOT.mkdir(parents=True, exist_ok=True)
    for passage in PASSAGES:
        print(f"\n=== {passage} ===")
        out_dir = OUT_ROOT / passage
        out_dir.mkdir(parents=True, exist_ok=True)

        chunks = capture_chunks(passage)
        print(f"  captured {len(chunks)} chunk texts")

        ipa_map: dict[str, str] = {}
        for c in chunks:
            ipa = backend.phonemize([c])[0].strip()
            ipa_map[c] = ipa

        map_file = out_dir / "override.json"
        map_file.write_text(json.dumps(ipa_map, ensure_ascii=False, indent=2))
        print(f"  wrote {map_file}")

        tmp = Path(tempfile.mkdtemp(prefix=f"kitten_ri_{passage}_"))
        env = {
            **os.environ,
            "KITTEN_IPA_CHUNK_OVERRIDE_FILE": str(map_file),
            "KITTEN_TRIM_MODE": "aggressive",
            "KITTEN_AGGRESSIVE_TRIM": str(24 * 150),
            "KITTEN_BOUNDARY_FADE_MS": "30",
        }
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
        print(f"  clicks={len(r.clicks)} pauses={len(r.pauses)} dur={r.duration_s:.2f}s → {dst}")

    print(f"\nA/B vs outputs/compound-split/<passage>/after.wav (current post-period post-compound-split baseline).")


if __name__ == "__main__":
    main()
