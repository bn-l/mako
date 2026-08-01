# /// script
# requires-python = "==3.12.*"
# dependencies = ["mlx-audio", "numpy", "soundfile", "psutil"]
# ///
"""Render any passage through fish-audio-s2-pro, with optional voice cloning.

    uv run scripts/tts-gen/gen_fish.py --passage itin --preset hot
    uv run scripts/tts-gen/gen_fish.py --passage itin --preset hot \
        --clone-wav wav-fish-prosody/03-single-hot.wav --clone-text micro-corpus

exp_fish_prosody.py is the fixed 7-variant experiment; this is the reusable renderer
that came out of its results.

What that experiment established:

* `instruct=` is UNUSABLE without reference audio — the model reads the instruction
  aloud. In `_build_conversation`'s no-reference branch the system turn simply ends with
  "Style instruction: ...", with nothing marking where speech should begin. The
  reference branch instead wraps things in "Text:\\n" ... "\\n\\nSpeech:\\n", so the
  instruction may well behave there; --instruct is kept only to test that, paired with
  --clone-wav.
* Sampling is the lever that works. `hot` (1.0/0.95/80) gave markedly more animated
  delivery than the 0.7/0.7/30 defaults.
* Long text must go through --mode tagged. Plain prose is returned unsplit by
  `_split_generation_text`, and one pass over a whole passage decodes tens of seconds of
  44.1 kHz audio at once, which overruns RAM on top of 6.8 G of weights.

Reference-free, every generate() call samples a new speaker, so a voice you liked is
not reproducible by seed alone across different text — clone it with --clone-wav.
"""

import argparse
import logging
import re
import time
from pathlib import Path

import mlx.core as mx
import numpy as np
import psutil
import soundfile as sf
from mlx_audio.tts.utils import load_model
from mlx_audio.utils import load_audio

from chunking import split_sentences
from oomguard import arm

REPO = Path(__file__).resolve().parents[2]
RESOURCE_DIR = REPO / "Sources/TTSHarnessCore/Resources"

# Named after how they landed by ear on micro-corpus.
PRESETS = {
    "default": {"temperature": 0.7, "top_p": 0.7, "top_k": 30},
    # Fish's own docs put the sweet spot for expressive-but-natural speech at 0.7-0.8,
    # against shipped defaults of 0.7/0.7 and repetition_penalty 1.2 (which mlx-audio
    # discards outright). "hot" is above spec: fun, but it is why voices come out
    # unpredictable and occasionally slurred.
    "expressive": {"temperature": 0.75, "top_p": 0.7, "top_k": 30},
    "warm": {"temperature": 0.9, "top_p": 0.9, "top_k": 50},
    "hot": {"temperature": 1.0, "top_p": 0.95, "top_k": 80},
}

log = logging.getLogger("gen_fish")


def memory_note():
    """No clear_cache() here: it would mask the growth that gets runs SIGKILLed."""
    return (f"active {mx.get_active_memory() / 1024 ** 3:.1f}G "
            f"cache {mx.get_cache_memory() / 1024 ** 3:.1f}G "
            f"peak {mx.get_peak_memory() / 1024 ** 3:.1f}G "
            f"avail {psutil.virtual_memory().available / 1024 ** 3:.1f}G")


def speaker_tagged(text, unit):
    """Route prose through fish's long-form batching so prosody carries across batches.

    Batching only engages when the text holds `<|speaker:N|>` tags. Fish's loop appends
    each batch's VQ codes back into the running Conversation as an assistant turn, so
    later batches hear the earlier ones — unlike chunking from outside, where every
    chunk is a cold start.

    `unit` decides what one tag wraps, and it matters more than it looks. Each
    `<|speaker:0|>` marks a conversational TURN, so tagging per sentence tells fish to
    deliver every sentence as its own separate turn — which is what made renders sound
    like the recording stopped and restarted between sentences. Tagging per paragraph
    lets whole paragraphs run as continuous speech and confines turn boundaries to
    places a human would actually pause.

    Sentence mode splits via chunking.split_sentences, so `2.7`, `A.I.` and `9:30 a.m.`
    survive; paragraph mode splits on blank lines and needs no such care.
    """
    if unit == "paragraph":
        parts = [block.strip() for block in re.split(r"\n\s*\n", text) if block.strip()]
    else:
        parts = split_sentences(text)
    return "".join(f"<|speaker:0|>{part}\n" for part in parts)


def join_with_pauses(pieces, sample_rate, rng, mean, sd, fade_ms):
    """Concatenate batches with a randomised silence and a short fade at each join.

    Butt-joining batches is what makes a passage sound assembled: there is a hard
    discontinuity where one generation ends and the next begins. Two fixes, both from
    the literature:

    * A short fade (~50 ms) at each boundary removes clicks and clipped breath sounds
      at the seam.
    * A silence whose length VARIES. Natural sentence boundaries sit around 0.6-1.2 s,
      with English storytelling measured at a mean of 0.94 s and SD 0.23 s, so a
      constant gap reads as mechanical in the same way a fixed phoneme duration does.
      Drawn from a normal and clamped to [0.25, 1.5] s: under ~0.25 s the boundary
      stops reading as a pause, and past ~2 s comprehension suffers.

    Worth being honest that the randomisation itself is the less-evidenced half. The
    0.6-1.2 s range is well supported, but the one published sweep of gap length at
    concatenation points reported inconclusive results, and nothing A/B-tests random
    against fixed. The fade is the safer of the two changes.
    """
    fade = int(sample_rate * fade_ms / 1000)
    shaped = []
    for piece in pieces:
        if fade and piece.size > 2 * fade:
            piece = piece.copy()
            piece[:fade] *= np.linspace(0.0, 1.0, fade, dtype=np.float32)
            piece[-fade:] *= np.linspace(1.0, 0.0, fade, dtype=np.float32)
        shaped.append(piece)
        seconds = float(np.clip(rng.normal(mean, sd), 0.25, 1.5))
        shaped.append(np.zeros(int(seconds * sample_rate), dtype=np.float32))
    return np.concatenate(shaped[:-1]) if shaped else np.zeros(0, dtype=np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="mlx-community/fish-audio-s2-pro-8bit")
    ap.add_argument("--passage", default=None, help="basename in Resources/, e.g. itin")
    ap.add_argument("--text-file", default=None,
                    help="read the text from this file instead of Resources/; used for "
                         "tag-marked-up variants, which are kept beside this script so "
                         "the Resources/ corpus stays the canonical plain text")
    ap.add_argument("--out", default="wav-fish-itin")
    ap.add_argument("--label", default=None, help="output filename stem (default: preset)")
    ap.add_argument("--preset", choices=sorted(PRESETS), default="hot")
    ap.add_argument("--clone-wav", default=None,
                    help="reference clip to clone the voice from, relative to this script")
    ap.add_argument("--clone-text", default=None,
                    help="passage basename whose text is the clone-wav transcript")
    ap.add_argument("--clone-text-file", default=None,
                    help="file holding the clone-wav transcript; use for references "
                         "prepared by make_reference.py, which are not corpus passages")
    ap.add_argument("--instruct", default=None,
                    help="style instruction; only meaningful with --clone-wav, and even "
                         "then verify it is not read aloud")
    ap.add_argument("--mode", choices=["tagged", "single"], default="tagged")
    ap.add_argument("--tag-unit", choices=["paragraph", "sentence"], default="paragraph",
                    help="what one <|speaker:0|> turn wraps; sentence-level makes every "
                         "sentence its own take, which sounds stop-start")
    ap.add_argument("--gap-mean", type=float, default=0.6,
                    help="mean silence inserted between batches, seconds (0 disables)")
    ap.add_argument("--gap-sd", type=float, default=0.2)
    ap.add_argument("--fade-ms", type=float, default=50.0,
                    help="fade at each batch boundary, to kill seam clicks")
    ap.add_argument("--chunk-length", type=int, default=150,
                    help="tagged mode: max bytes per internal batch")
    ap.add_argument("--max-tokens", type=int, default=1536,
                    help="per internal batch; sizes the KV cache, so keep it near what "
                         "the batch actually needs (fish codec is roughly 21 Hz)")
    ap.add_argument("--mlx-cache-mb", type=int, default=1024)
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("--oom-floor-mb", type=int, default=2200)
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    arm(floor_mb=args.oom_floor_mb)
    mx.set_cache_limit(args.mlx_cache_mb * 1024 ** 2)

    here = Path(__file__).resolve().parent
    if args.text_file:
        source = Path(args.text_file)
        if not source.is_absolute():
            source = here / source
    elif args.passage:
        source = RESOURCE_DIR / f"{args.passage}.txt"
    else:
        ap.error("need --passage or --text-file")
    text = source.read_text(encoding="utf-8").strip()
    out_dir = here / args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    log.info("loading %s [%s]", args.model, memory_note())
    model = load_model(args.model)
    sample_rate = getattr(model, "sample_rate", 44100)
    log.info("loaded; sample_rate=%s [%s]", sample_rate, memory_note())

    options = dict(PRESETS[args.preset])
    options["max_tokens"] = args.max_tokens
    options["chunk_length"] = args.chunk_length
    options["verbose"] = False
    options["text"] = speaker_tagged(text, args.tag_unit) if args.mode == "tagged" else text
    if args.instruct:
        options["instruct"] = args.instruct

    if args.clone_wav:
        if not (args.clone_text or args.clone_text_file):
            ap.error("--clone-wav requires --clone-text or --clone-text-file")
        clip = here / args.clone_wav
        if args.clone_text_file:
            transcript_path = Path(args.clone_text_file)
            if not transcript_path.is_absolute():
                transcript_path = here / transcript_path
        else:
            transcript_path = RESOURCE_DIR / f"{args.clone_text}.txt"
        transcript = transcript_path.read_text(encoding="utf-8").strip()
        # fish has no preserve_ref_audio_path, and _prepare_reference_prompt goes straight
        # to audio.ndim, so a path would raise AttributeError. Hand it decoded audio.
        options["ref_audio"] = load_audio(str(clip), sample_rate=sample_rate)
        options["ref_text"] = transcript
        log.info("cloning voice from %s (transcript: %s, %d chars) [%s]",
                 args.clone_wav, transcript_path.name, len(transcript), memory_note())

    label = args.label or args.preset
    log.info("%s: %s, %d chars, preset=%s mode=%s", label, source.name, len(text),
             args.preset, args.mode)
    mx.random.seed(args.seed)
    started = time.time()
    pieces = []
    for result in model.generate(**options):
        pieces.append(np.asarray(result.audio, dtype=np.float32).reshape(-1))
        log.info("  batch %d, %.1fs so far [%s]", len(pieces), time.time() - started,
                 memory_note())
    if not pieces:
        log.error("%s: produced no audio", label)
        return

    rng = np.random.default_rng(args.seed)
    audio = (join_with_pauses(pieces, sample_rate, rng, args.gap_mean, args.gap_sd,
                              args.fade_ms)
             if args.gap_mean > 0 else np.concatenate(pieces))
    dest = out_dir / f"{label}.wav"
    sf.write(dest, audio, sample_rate)
    seconds = len(audio) / sample_rate
    elapsed = time.time() - started
    mx.clear_cache()
    log.info("wrote %s — %.1fs audio in %.1fs wall (%.1f chars/s, RTF %.2f) [%s]",
             dest, seconds, elapsed, len(text) / elapsed, seconds / elapsed, memory_note())


if __name__ == "__main__":
    main()
