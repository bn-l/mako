# /// script
# requires-python = "==3.12.*"
# dependencies = ["mlx-audio", "numpy", "soundfile", "psutil"]
# ///
"""Render through fish while controlling what history each batch sees.

    uv run scripts/tts-gen/gen_fish_anchored.py --text-file itin-long.txt \
        --clone-wav clone-windows-2/gemini2-22.wav \
        --clone-text-file clone-windows-2/gemini2-22.txt \
        --history-window 3 --pin-first 1

Fish's own `generate()` appends every batch's codes to one conversation that is never
truncated, and rebuilds a fresh KV cache over the whole thing each batch. Measured over
a 6-minute render that costs ~35% per-batch slowdown, and pitch span narrows steadily
(19.4 -> 18.1 semitones across quarters) while drift halves: the model is conditioning
on ~8000 tokens of its own output against ~630 tokens of reference, and settling into
its own groove.

The reference itself is never lost — `_build_conversation` puts it in the SYSTEM message,
which stays at index 0 forever. What decays is its share of the context. So this drives
the batch loop directly and rebuilds the message list each time:

    [system: reference] + [first N generated turns] + [last K generated turns] + [this batch]

which is the attention-sink-plus-sliding-window arrangement from StreamingLLM. Pinning
the first turns keeps anchors that were themselves generated under maximum reference
influence, and the window keeps the immediately preceding turn so seams stay smooth.
Bounding the history also stops prefill growing, which is the speed half of the win.

--reanchor-every additionally re-inserts the reference as a user/assistant pair just
before a batch. Position matters: a copy sitting next to the generation point has far
more attention pull than the same tokens 8000 back.

Because the cache is rebuilt per batch anyway, none of this costs anything to invalidate.
"""

import argparse
import logging
import time
from pathlib import Path

import mlx.core as mx
import numpy as np
import soundfile as sf
from mlx_audio.tts.models.fish_qwen3_omni.prompt import (
    Conversation,
    Message,
    TextPart,
    VQPart,
)
from mlx_audio.tts.utils import load_model
from mlx_audio.utils import load_audio

from gen_fish import PRESETS, join_with_pauses, memory_note, speaker_tagged
from oomguard import arm

log = logging.getLogger("gen_fish_anchored")


def visible_history(history, pin_first, window):
    """The turns this batch is allowed to see: pinned anchors plus a recent window."""
    if not window:
        return history
    recent = history[max(pin_first, len(history) - window):]
    return history[:pin_first] + recent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="mlx-community/fish-audio-s2-pro-8bit")
    ap.add_argument("--text-file", required=True)
    ap.add_argument("--out", default="wav-fish-anchored")
    ap.add_argument("--label", required=True)
    ap.add_argument("--preset", choices=sorted(PRESETS), default="hot")
    ap.add_argument("--clone-wav", required=True)
    ap.add_argument("--clone-text-file", required=True)
    ap.add_argument("--history-window", type=int, default=0,
                    help="keep only this many recent turns (0 = fish's own unbounded "
                         "behaviour, for A/B against the baseline)")
    ap.add_argument("--pin-first", type=int, default=0,
                    help="always keep this many of the earliest generated turns")
    ap.add_argument("--reanchor-every", type=int, default=0,
                    help="re-insert the reference as a turn before every Nth batch")
    ap.add_argument("--gap-mean", type=float, default=0.6)
    ap.add_argument("--gap-sd", type=float, default=0.2)
    ap.add_argument("--fade-ms", type=float, default=50.0)
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
    text = (here / args.text_file).read_text(encoding="utf-8").strip()
    out_dir = here / args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    log.info("loading %s [%s]", args.model, memory_note())
    model = load_model(args.model)
    sample_rate = getattr(model, "sample_rate", 44100)

    ref_text = (here / args.clone_text_file).read_text(encoding="utf-8").strip()
    ref_audio = load_audio(str(here / args.clone_wav), sample_rate=sample_rate)
    prompt_texts, prompt_tokens = model._prepare_reference_prompt(ref_audio, ref_text)
    base = model._build_conversation(prompt_texts, prompt_tokens, instruct=None)
    anchor_turn = (
        Message(role="user", parts=[TextPart(ref_text)]),
        Message(role="assistant", parts=[VQPart(prompt_tokens[0])], modality="voice"),
    )

    options = PRESETS[args.preset]
    batches = model._split_generation_text(speaker_tagged(text, "paragraph"),
                                           args.chunk_length)
    log.info("%s: %d chars -> %d batches, window=%s pin=%d reanchor=%d", args.label,
             len(text), len(batches), args.history_window or "unbounded",
             args.pin_first, args.reanchor_every)

    mx.random.seed(args.seed)
    started = time.time()
    history, pieces = [], []
    for index, batch_text in enumerate(batches):
        messages = list(base.messages)
        for turn in visible_history(history, args.pin_first, args.history_window):
            messages.extend(turn)
        if args.reanchor_every and index and index % args.reanchor_every == 0:
            messages.extend(anchor_turn)
        user_turn = Message(role="user", parts=[TextPart(batch_text)])
        batch_started = time.time()
        codes = model._generate_codes_for_batch(
            conversation=Conversation(messages + [user_turn]),
            batch_text=batch_text,
            max_new_tokens=args.max_tokens,
            top_p=options["top_p"],
            top_k=options["top_k"],
            temperature=options["temperature"],
        )
        audio = model._decode_codes(codes)
        mx.eval(audio)
        history.append((user_turn,
                        Message(role="assistant", parts=[VQPart(codes)], modality="voice")))
        pieces.append(np.asarray(audio, dtype=np.float32).reshape(-1))
        log.info("  batch %d/%d: %d msgs, %.1fs [%s]", index + 1, len(batches),
                 len(messages), time.time() - batch_started, memory_note())

    rng = np.random.default_rng(args.seed)
    joined = join_with_pauses(pieces, sample_rate, rng, args.gap_mean, args.gap_sd,
                              args.fade_ms)
    dest = out_dir / f"{args.label}.wav"
    sf.write(dest, joined, sample_rate)
    elapsed = time.time() - started
    log.info("wrote %s — %.1fs audio in %.1fs wall (%.1f chars/s) [%s]", dest,
             len(joined) / sample_rate, elapsed, len(text) / elapsed, memory_note())


if __name__ == "__main__":
    main()
