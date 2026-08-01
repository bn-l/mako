# /// script
# requires-python = "==3.12.*"
# dependencies = ["mlx-audio", "numpy", "soundfile", "psutil"]
# ///
"""Why does fish-audio-s2-pro sound monotone, and which lever fixes it?

    uv run scripts/tts-gen/exp_fish_prosody.py

Renders micro-corpus once per variant into wav-fish-prosody/, named so they sort in
the order you should listen to them.

Three causes of the flatness in wav-fish-s2-pro-8bit/micro-corpus.wav, in order of
how much they cost us:

1. We chunked a 434-char passage. `_split_generation_text` returns the text
   UNCHANGED unless it contains `<|speaker:N|>` tags, so `chunk_length` is inert for
   plain prose — fish never wanted chunking here. Worse, fish's own long-form path
   keeps a running Conversation and appends each batch's VQ codes back as an
   assistant turn, so its batches carry prosodic context. One generate() per chunk
   throws that away: every chunk is a cold start with a fresh system prompt.

2. --pin-voice fed chunk 1's own audio back as ref_audio. With a reference present
   the system prompt becomes "convert the provided text to speech reference to the
   following", so the reference dictates *delivery*, not just timbre. Pinning to our
   own flat chunk 1 is a prosody echo chamber.

3. temperature/top_p/top_k default to 0.7/0.7/30, which is conservative; and
   `instruct` (a "Style instruction:" line in the system prompt) plus S2 Pro's inline
   [tag] markup were never used at all.

Caveat worth keeping in mind while listening: micro-corpus is thirteen clipped
declaratives written to test homographs and normalisation. It is inherently flat
prose, so no setting will make it lively — judge the variants against each other.
"""

import argparse
import logging
import time
from pathlib import Path

import mlx.core as mx
import numpy as np
import psutil
import soundfile as sf
from mlx_audio.tts.utils import load_model

from chunking import split_sentences
from oomguard import arm

REPO = Path(__file__).resolve().parents[2]
PASSAGE = REPO / "Sources/TTSHarnessCore/Resources/micro-corpus.txt"

LIVELY = (
    "Read this as an engaging audiobook narrator. Warm and animated, with varied "
    "pitch and pacing, natural emphasis on the important words, and clear "
    "sentence-final intonation. Do not read it as a flat list."
)
CONVERSATIONAL = (
    "Speak casually, like explaining something to a friend across a table. "
    "Relaxed pace, uneven rhythm, audible interest in your voice."
)

# S2 Pro takes free-form bracketed instructions inline, at word level. The homograph
# and normalisation content (2.7, A.I., ETA, 9:30 a.m.) is left untouched so this stays
# comparable to the other variants as a pronunciation test.
TAGGED = (
    'Version 2.7 is live. [short pause] The live stream is live. '
    'The kettle began to boil. [short pause] The kettle is on the stove. '
    'Bring the water to a boil. [short pause] A.I. tools are live. AI tools are live. '
    'ETA is 9:30 a.m. [short pause] FYI, RSVP by 5:15 p.m. '
    'Room 204 is near Apartment 12C. Flight QF12 leaves from Gate 17B. '
    '[short pause] Nobody laughed, [chuckle] but a few people whispered. '
    '[low voice] Outside, a dog barked twice in the distance. '
    'The folded note read, [emphasis] "working well." '
    '[short pause] Clarity mattered more than speed.'
)

# Each variant is one generate() call over the whole passage. Ordered so that each step
# adds exactly one lever to the one before it.
VARIANTS = [
    {"name": "01-single-default", "temperature": 0.7, "top_p": 0.7, "top_k": 30,
     "note": "no chunking, no pinning, stock sampling — isolates causes 1+2"},
    {"name": "02-single-warm", "temperature": 0.9, "top_p": 0.9, "top_k": 50,
     "note": "looser sampling"},
    {"name": "03-single-hot", "temperature": 1.0, "top_p": 0.95, "top_k": 80,
     "note": "looser still; watch for slurring or mispronunciation"},
    {"name": "04-instruct-lively", "temperature": 0.7, "top_p": 0.7, "top_k": 30,
     "instruct": LIVELY, "note": "style instruction, stock sampling"},
    {"name": "05-instruct-lively-warm", "temperature": 0.9, "top_p": 0.9, "top_k": 50,
     "instruct": LIVELY, "note": "style instruction + looser sampling"},
    {"name": "06-instruct-conversational-warm", "temperature": 0.9, "top_p": 0.9,
     "top_k": 50, "instruct": CONVERSATIONAL, "note": "different style wording"},
    {"name": "07-inline-tags-warm", "temperature": 0.9, "top_p": 0.9, "top_k": 50,
     "text": TAGGED, "note": "S2 Pro inline [tag] markup; text differs from the rest"},
]

log = logging.getLogger("exp_fish_prosody")


def speaker_tagged(text):
    """Turn prose into fish's long-form batching path, with prosody carried across.

    `_split_generation_text` only batches when the text contains `<|speaker:N|>` tags;
    plain prose is returned as one string and generated in a single pass. That single
    pass decodes ~40s of 44.1 kHz audio at once, which on top of 6.8 G of weights blows
    past our RAM headroom and gets the run SIGKILLed.

    Tagging each sentence makes fish batch internally instead, and its long-form loop
    appends each batch's VQ codes back into the running Conversation as an assistant
    turn — so unlike our own external chunking, later batches still hear the earlier
    ones and the prosody carries. Everything stays one speaker, index 0.

    Sentence splitting goes through chunking.split_sentences so `2.7`, `A.I.` and
    `9:30 a.m.` survive intact.
    """
    return "".join(f"<|speaker:0|>{sentence}\n" for sentence in split_sentences(text))


def memory_note():
    """No clear_cache() here on purpose — MLX keeps freed buffers in its own cache
    rather than returning them to the OS, and clearing here would mask the growth that
    gets this run SIGKILLed mid-render."""
    return (f"active {mx.get_active_memory() / 1024 ** 3:.1f}G "
            f"cache {mx.get_cache_memory() / 1024 ** 3:.1f}G "
            f"peak {mx.get_peak_memory() / 1024 ** 3:.1f}G "
            f"avail {psutil.virtual_memory().available / 1024 ** 3:.1f}G")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="mlx-community/fish-audio-s2-pro-8bit")
    ap.add_argument("--out", default="wav-fish-prosody")
    # micro-corpus is ~40s of audio; fish's codec runs about 21 Hz, so ~850 tokens.
    # 4096 only inflates the KV cache, and that is what got the first attempt killed.
    ap.add_argument("--max-tokens", type=int, default=1536)
    # Cap MLX's buffer cache so freed buffers return to the OS. Without this, system
    # available RAM falls through a render while active memory looks flat.
    ap.add_argument("--mlx-cache-mb", type=int, default=1024)
    ap.add_argument("--mode", choices=["tagged", "single"], default="tagged",
                    help="tagged: fish batches internally with running context (fits in "
                         "RAM). single: one AR pass over the whole passage (needs ~16G "
                         "free on top of the weights; currently does not fit)")
    ap.add_argument("--chunk-length", type=int, default=150,
                    help="tagged mode: max bytes per internal batch")
    # Same seed before every call, so the sampled speaker stays comparable across
    # variants and you are hearing prosody differences rather than a new voice.
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("--oom-floor-mb", type=int, default=3000)
    ap.add_argument("only", nargs="*", help="variant name prefixes (default: all)")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    arm(floor_mb=args.oom_floor_mb)
    mx.set_cache_limit(args.mlx_cache_mb * 1024 ** 2)

    text = PASSAGE.read_text(encoding="utf-8").strip()
    out_dir = Path(__file__).resolve().parent / args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    log.info("loading %s [%s]", args.model, memory_note())
    model = load_model(args.model)
    sample_rate = getattr(model, "sample_rate", 44100)
    log.info("loaded; sample_rate=%s [%s]", sample_rate, memory_note())

    for variant in VARIANTS:
        if args.only and not variant["name"].startswith(tuple(args.only)):
            continue
        body = variant.get("text", text)
        if args.mode == "tagged":
            body = speaker_tagged(body)
        options = {
            "text": body,
            "max_tokens": args.max_tokens,
            "temperature": variant["temperature"],
            "top_p": variant["top_p"],
            "top_k": variant["top_k"],
            "chunk_length": args.chunk_length,
            "verbose": False,
        }
        if variant.get("instruct"):
            options["instruct"] = variant["instruct"]

        log.info("%s: %s", variant["name"], variant["note"])
        mx.random.seed(args.seed)
        started = time.time()
        pieces = []
        try:
            for result in model.generate(**options):
                pieces.append(np.asarray(result.audio, dtype=np.float32).reshape(-1))
                log.info("  batch %d, %.1fs so far [%s]", len(pieces),
                         time.time() - started, memory_note())
        except Exception:
            log.exception("%s: failed", variant["name"])
            continue
        if not pieces:
            log.error("%s: produced no audio", variant["name"])
            continue

        audio = np.concatenate(pieces)
        dest = out_dir / f"{variant['name']}.wav"
        sf.write(dest, audio, sample_rate)
        mx.clear_cache()
        log.info("wrote %s — %.1fs audio in %.1fs wall [%s]",
                 dest, len(audio) / sample_rate, time.time() - started, memory_note())


if __name__ == "__main__":
    main()
