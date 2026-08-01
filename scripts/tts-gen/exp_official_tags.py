# /// script
# requires-python = "==3.12.*"
# dependencies = ["mlx-audio", "numpy", "soundfile", "psutil"]
# ///
"""Render every documented fish S2 marker so the register can be filled in by ear.

    uv run scripts/tts-gen/exp_official_tags.py

Fish's markers are ordinary text to the model — it was trained on transcripts containing
these descriptions and learned the mapping — so which ones work is a question of evidence,
not specification. Fish's own marketing claims "15,000+ tags" and free-form descriptions;
testing on this setup has already shown invented prose descriptions doing nothing at all.
This renders the documented vocabulary exhaustively so each entry gets a verdict.

Every tag gets the SAME carrier sentence, so the tag is the only variable, and a spoken
number so a listener can identify a clip without watching filenames. Numbers are unique
across the whole sweep and map to tags via tag-index.md.

Sources for the vocabulary:
  docs.fish.audio/developer-guide/core-features/emotions   (emotions, tone, effects)
  huggingface.co/fishaudio/s2-pro                          (model card list)
  fish.audio/s2                                            (site examples)
  runware.ai/docs/models/fish-audio-s2-1-pro/guides        (paralanguage, phonemes)

[sigh] and [sighing] are deliberately excluded: they work, and are never to be generated.
"""

import argparse
import logging
import time
from pathlib import Path

import mlx.core as mx
import numpy as np
import soundfile as sf
from mlx_audio.tts.utils import load_model
from mlx_audio.utils import load_audio

from gen_fish import PRESETS, join_with_pauses, memory_note, speaker_tagged
from oomguard import arm

log = logging.getLogger("exp_official_tags")

CARRIER = "The report is finished and the release goes out at four."

CATEGORIES = {
    "basic-emotions": [
        "happy", "sad", "angry", "excited", "calm", "nervous", "confident", "surprised",
        "satisfied", "delighted", "scared", "worried", "upset", "frustrated", "depressed",
        "empathetic", "embarrassed", "disgusted", "moved", "proud", "relaxed", "grateful",
        "curious", "sarcastic",
    ],
    "advanced-emotions": [
        "disdainful", "unhappy", "anxious", "hysterical", "indifferent", "uncertain",
        "doubtful", "confused", "disappointed", "regretful", "guilty", "ashamed",
        "jealous", "envious", "hopeful", "optimistic", "pessimistic", "nostalgic",
        "lonely", "bored", "contemptuous", "sympathetic", "compassionate", "determined",
        "resigned",
    ],
    "tone": [
        "in a hurry tone", "shouting", "screaming", "whispering", "soft tone", "emphasis",
        "low voice", "loud", "low volume", "volume up", "volume down", "slow",
        "excited tone", "laughing tone", "flirty", "singing", "with strong accent",
        "echo", "interrupting",
    ],
    "effects": [
        "laughing", "chuckling", "giggling", "sobbing", "crying loudly", "groaning",
        "panting", "gasping", "yawning", "snoring", "clear throat", "clearing throat",
        "inhale", "exhale", "tsk", "moaning", "shocked", "delight", "pause",
        "short pause", "break", "long-break",
    ],
    "crowd": ["audience laughing", "background laughter", "crowd laughing",
              "audience laughter"],
    "intensity": ["slightly sad", "very excited", "slightly angry", "very calm"],
    "stacked": ["sad][whispering", "excited][laughing", "angry][shouting",
                "nervous][whispering"],
}

# Parenthesis paralanguage is a different mechanism, documented as requiring
# normalize=false. The MLX port exposes no normalize option and appears to do no text
# normalisation at all, so these may simply work — worth knowing either way.
PARALANGUAGE = ["break", "long-break", "breath", "laugh", "cough", "lip-smacking"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="mlx-community/fish-audio-s2-pro-8bit")
    ap.add_argument("--out", default="wav-fish-tags")
    ap.add_argument("--preset", choices=sorted(PRESETS), default="hot")
    ap.add_argument("--clone-wav", default="clone-windows-2/gemini2-22.wav")
    ap.add_argument("--clone-text-file", default="clone-windows-2/gemini2-22.txt")
    ap.add_argument("--chunk-length", type=int, default=400)
    ap.add_argument("--max-tokens", type=int, default=900)
    ap.add_argument("--mlx-cache-mb", type=int, default=512)
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("--oom-floor-mb", type=int, default=2200)
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    arm(floor_mb=args.oom_floor_mb)
    mx.set_cache_limit(args.mlx_cache_mb * 1024 ** 2)

    here = Path(__file__).resolve().parent
    out_dir = here / args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    # Number every clip across the whole sweep, and build the paragraph text per file.
    passages, index_lines, number = {}, [], 0
    for category, tags in CATEGORIES.items():
        paragraphs = []
        for tag in tags:
            number += 1
            paragraphs.append(f"[{tag}] Number {number}. {CARRIER}")
            index_lines.append(f"| {number} | `[{tag}]` | {category} | |")
        passages[category] = "\n\n".join(paragraphs)

    paragraphs = []
    for cue in PARALANGUAGE:
        number += 1
        paragraphs.append(f"Number {number}. The report is finished ({cue}) and the "
                          "release goes out at four.")
        index_lines.append(f"| {number} | `({cue})` | paralanguage | |")
    passages["paralanguage"] = "\n\n".join(paragraphs)

    index = ["| # | tag | category | verdict |", "|---|---|---|---|"] + index_lines
    (out_dir / "tag-index.md").write_text("\n".join(index) + "\n", encoding="utf-8")
    log.info("%d tags across %d files; index at %s", number, len(passages),
             out_dir / "tag-index.md")

    log.info("loading %s [%s]", args.model, memory_note())
    model = load_model(args.model)
    sample_rate = getattr(model, "sample_rate", 44100)
    ref_text = (here / args.clone_text_file).read_text(encoding="utf-8").strip()
    ref_audio = load_audio(str(here / args.clone_wav), sample_rate=sample_rate)

    for category, text in passages.items():
        dest = out_dir / f"{category}.wav"
        if dest.exists():
            log.info("%s exists, skipping", dest.name)
            continue
        options = dict(PRESETS[args.preset])
        options.update(text=speaker_tagged(text, "paragraph"), verbose=False,
                       max_tokens=args.max_tokens, chunk_length=args.chunk_length,
                       ref_audio=ref_audio, ref_text=ref_text)
        mx.random.seed(args.seed)
        started = time.time()
        pieces = []
        for result in model.generate(**options):
            pieces.append(np.asarray(result.audio, dtype=np.float32).reshape(-1))
        if not pieces:
            log.error("%s: produced no audio", category)
            continue
        rng = np.random.default_rng(args.seed)
        audio = join_with_pauses(pieces, sample_rate, rng, 0.6, 0.2, 50.0)
        sf.write(dest, audio, sample_rate)
        mx.clear_cache()
        log.info("wrote %s — %.1fs audio in %.1fs wall [%s]", dest.name,
                 len(audio) / sample_rate, time.time() - started, memory_note())


if __name__ == "__main__":
    main()
