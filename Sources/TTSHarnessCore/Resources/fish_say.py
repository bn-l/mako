# /// script
# requires-python = "==3.12.*"
# dependencies = ["mlx-audio==0.4.6", "numpy", "soundfile", "psutil"]
# ///
"""Fish S2 Pro speech sidecar — the engine behind `mako say --hq`.

    printf 'Hello there.' | uv run --script fish_say.py --out /tmp/out.wav \
        --ref-wav gemini2-22.wav --ref-text gemini2-22.txt
    uv run --script fish_say.py --prefetch     # download weights, then exit
    uv run --script fish_say.py --check        # report weight availability as JSON

There is no Swift or CoreML implementation of fish, so mako shells out to mlx-audio.
`requires-python` makes `uv run --script` fetch a managed CPython 3.12, which is why a
user never has to install Python themselves.

This file is DELIBERATELY SELF-CONTAINED. It ships as a bundled resource inside
`mako_TTSHarnessCore.bundle`, where it has no siblings to import from — the lab scripts
in `scripts/tts-gen/` are a research surface that must stay free to drift. The ~100 lines
duplicated from `gen_fish.py` and `oomguard.py` are the price of that separation.

Defaults here are the settings the production voice was validated on, which are NOT
`gen_fish.py`'s defaults (its `--chunk-length` is 150 and `--max-tokens` 1536).

Contract with the caller:
  * text arrives on stdin — no argv length limits, no shell quoting hazards
  * progress goes to stderr, one JSON summary line to stdout
  * a non-zero exit means no audio was written; stderr carries the reason
"""

import argparse
import json
import logging
import os
import re
import signal
import sys
import threading
import time
from pathlib import Path

import mlx.core as mx
import numpy as np
import psutil
import soundfile as sf
from huggingface_hub import snapshot_download
from mlx_audio.tts.utils import load_model
from mlx_audio.utils import DEFAULT_ALLOW_PATTERNS, get_model_path, load_audio

log = logging.getLogger("fish_say")

MODEL = "mlx-community/fish-audio-s2-pro-8bit"

# Named after how they landed by ear during the bakeoff. `hot` is above fish's own
# recommended range and is why the voice is animated rather than flat.
PRESETS = {
    "default": {"temperature": 0.7, "top_p": 0.7, "top_k": 30},
    "expressive": {"temperature": 0.75, "top_p": 0.7, "top_k": 30},
    "warm": {"temperature": 0.9, "top_p": 0.9, "top_k": 50},
    "hot": {"temperature": 1.0, "top_p": 0.95, "top_k": 80},
}


# --- OOM guard ---------------------------------------------------------------------
#
# Loading 6.8 GB of weights and peaking near 14.5 GB, this process is the single biggest
# memory consumer on the machine. When macOS runs out it does not fail fast, it thrashes
# into a multi-minute freeze — so we SIGKILL ourselves while the system is still
# responsive rather than waiting for an allocation to fail. mako runs a second watchdog
# in the parent, because a thrashing child may not get scheduled to run this one.

def watch_memory(floor_mb, swap_delta_mb, interval):
    previous_swap = psutil.swap_memory().sout
    while True:
        time.sleep(interval)
        available_mb = psutil.virtual_memory().available / (1024 * 1024)
        if available_mb < floor_mb:
            trip(f"available RAM {available_mb:.0f}MiB < floor {floor_mb}MiB")
        current_swap = psutil.swap_memory().sout
        swapped_mb = (current_swap - previous_swap) / (1024 * 1024)
        previous_swap = current_swap
        if swapped_mb > swap_delta_mb:
            trip(f"swap storm: {swapped_mb:.0f}MiB paged out in {interval}s "
                 f"(>{swap_delta_mb}MiB)")


def trip(reason):
    # Bypass logging handlers and buffering — we are about to die on purpose. mako
    # greps stderr for this marker so it can report the reason instead of a bare signal.
    message = f"\n[oomguard] !!! TRIGGER: {reason} -> SIGKILL self (pid {os.getpid()}) NOW\n"
    try:
        os.write(2, message.encode())
    except OSError:
        pass
    os.kill(os.getpid(), signal.SIGKILL)


def arm(floor_mb, swap_delta_mb=1024, interval=1.0):
    if os.environ.get("TTS_NO_OOMGUARD"):
        log.warning("oomguard DISABLED via TTS_NO_OOMGUARD — this can hang the machine")
        return
    threading.Thread(target=watch_memory, daemon=True,
                     args=(floor_mb, swap_delta_mb, interval)).start()
    log.info("oomguard armed: floor=%dMiB swap_delta=%dMiB (machine %.0f GiB)",
             floor_mb, swap_delta_mb, psutil.virtual_memory().total / 1024 ** 3)


# --- text and audio shaping --------------------------------------------------------

def memory_note():
    """No clear_cache() here: it would mask the growth that gets runs SIGKILLed."""
    return (f"active {mx.get_active_memory() / 1024 ** 3:.1f}G "
            f"peak {mx.get_peak_memory() / 1024 ** 3:.1f}G "
            f"avail {psutil.virtual_memory().available / 1024 ** 3:.1f}G")


def speaker_tagged(text, chunk_length):
    """Route prose through fish's long-form batching so prosody carries across batches.

    Batching only engages when the text holds `<|speaker:N|>` tags; plain prose comes
    back from `_split_generation_text` unsplit as a single batch. Fish appends each
    batch's VQ codes back into the running conversation, so later batches hear the
    earlier ones — which is exactly what chunking from outside cannot give you.

    One tag wraps one PARAGRAPH, not one sentence. Each `<|speaker:0|>` marks a
    conversational turn, so sentence-level tagging tells fish to deliver every sentence
    as its own take, and renders came out sounding stop-start.

    Turns are never split here, and `group_turns_into_batches` will not split one
    either — an oversized turn becomes an oversized batch, and `max_tokens` then
    truncates it mid-sentence. mako's caller subdivides long paragraphs before we see
    them; standalone callers get a warning rather than silent truncation.
    """
    tagged = ""
    for block in re.split(r"\n\s*\n", text):
        block = block.strip()
        if not block:
            continue
        size = len(block.encode("utf-8"))
        if size > chunk_length:
            log.warning("paragraph of %d bytes exceeds --chunk-length %d; it becomes one "
                        "batch and may be truncated by --max-tokens", size, chunk_length)
        tagged += f"<|speaker:0|>{block}\n"
    return tagged


def join_with_pauses(pieces, sample_rate, rng, mean, sd, fade_ms):
    """Concatenate batches with a randomised silence and a short fade at each join.

    Butt-joining batches leaves a hard discontinuity where one generation ends and the
    next begins. A ~50 ms fade removes the click and any clipped breath at the seam; a
    silence whose length varies avoids the mechanical feel of a constant gap. Natural
    sentence boundaries sit around 0.6-1.2 s, so the draw is clamped to [0.25, 1.5] s —
    below ~0.25 s it stops reading as a pause, past ~2 s comprehension suffers.
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


# --- modes -------------------------------------------------------------------------

def weights_present(model):
    """True when the weights are already cached, without reaching the network.

    Uses mlx-audio's own allow-patterns so this answers the question `load_model` will
    actually ask, and huggingface_hub's own resolution so HF_HOME / HF_HUB_CACHE are
    honoured instead of guessed at.
    """
    try:
        snapshot_download(model, allow_patterns=DEFAULT_ALLOW_PATTERNS,
                          local_files_only=True)
        return True
    except Exception as error:
        log.debug("weights not cached: %s", error)
        return False


def render(args, text):
    arm(floor_mb=args.oom_floor_mb)
    mx.set_cache_limit(args.mlx_cache_mb * 1024 ** 2)

    log.info("loading %s [%s]", args.model, memory_note())
    started = time.time()
    # Hand it the repo string, not a resolved Path: base_load_model only derives the
    # architecture-remapping name parts on the str branch.
    model = load_model(args.model)
    sample_rate = getattr(model, "sample_rate", 44100)
    log.info("loaded in %.1fs; sample_rate=%s [%s]", time.time() - started, sample_rate,
             memory_note())

    options = dict(PRESETS[args.preset])
    if args.temperature is not None:
        options["temperature"] = args.temperature
    if args.top_p is not None:
        options["top_p"] = args.top_p
    if args.top_k is not None:
        options["top_k"] = args.top_k
    options.update(text=speaker_tagged(text, args.chunk_length), verbose=False,
                   max_tokens=args.max_tokens, chunk_length=args.chunk_length)

    # Fish clones in context: there is no per-voice model, so the reference clip and its
    # exact transcript are runtime dependencies. `_prepare_reference_prompt` goes straight
    # to `audio.ndim`, so it must be handed decoded audio rather than a path.
    ref_text = Path(args.ref_text).read_text(encoding="utf-8").strip()
    options["ref_audio"] = load_audio(str(args.ref_wav), sample_rate=sample_rate)
    options["ref_text"] = ref_text
    log.info("cloning from %s (%d-char transcript)", Path(args.ref_wav).name, len(ref_text))

    mx.random.seed(args.seed)
    started = time.time()
    pieces = []
    for result in model.generate(**options):
        pieces.append(np.asarray(result.audio, dtype=np.float32).reshape(-1))
        log.info("  batch %d, %.1fs so far [%s]", len(pieces), time.time() - started,
                 memory_note())
    if not pieces:
        raise RuntimeError("model produced no audio")

    rng = np.random.default_rng(args.seed)
    audio = (join_with_pauses(pieces, sample_rate, rng, args.gap_mean, args.gap_sd,
                              args.fade_ms)
             if args.gap_mean > 0 else np.concatenate(pieces))
    sf.write(args.out, audio, sample_rate)
    elapsed = time.time() - started
    log.info("wrote %s — %.1fs audio in %.1fs wall [%s]", args.out,
             len(audio) / sample_rate, elapsed, memory_note())
    return {
        "ok": True,
        "path": str(args.out),
        "seconds": len(audio) / sample_rate,
        "sample_rate": sample_rate,
        "batches": len(pieces),
        "wall": elapsed,
        "peak_gb": mx.get_peak_memory() / 1024 ** 3,
    }


def main():
    ap = argparse.ArgumentParser(description="Fish S2 Pro sidecar for `mako say --hq`.")
    ap.add_argument("--out", help="destination WAV; text is read from stdin")
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--ref-wav", help="reference clip to clone the voice from")
    ap.add_argument("--ref-text", help="file holding the reference clip's exact transcript")
    ap.add_argument("--preset", choices=sorted(PRESETS), default="hot")
    ap.add_argument("--temperature", type=float, default=None, help="override the preset")
    ap.add_argument("--top-p", type=float, default=None)
    ap.add_argument("--top-k", type=int, default=None)
    ap.add_argument("--chunk-length", type=int, default=400,
                    help="max bytes of text per internal batch")
    ap.add_argument("--max-tokens", type=int, default=900,
                    help="per batch; sizes the KV cache, so keep it near what a batch "
                         "actually needs (the fish codec runs at roughly 21 Hz)")
    ap.add_argument("--mlx-cache-mb", type=int, default=512)
    ap.add_argument("--gap-mean", type=float, default=0.6,
                    help="mean silence between batches, seconds (0 concatenates flush)")
    ap.add_argument("--gap-sd", type=float, default=0.2)
    ap.add_argument("--fade-ms", type=float, default=50.0)
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("--oom-floor-mb", type=int, default=2200)
    ap.add_argument("--prefetch", action="store_true",
                    help="download the weights and exit; no synthesis")
    ap.add_argument("--check", action="store_true",
                    help="report whether the weights are cached, as JSON; no synthesis")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, stream=sys.stderr,
                        format="%(asctime)s %(levelname)s %(message)s")

    if args.check:
        print(json.dumps({"ok": True, "weights": weights_present(args.model),
                          "model": args.model}))
        return
    if args.prefetch:
        log.info("fetching %s (about 7 GB on a cold cache)", args.model)
        path = get_model_path(args.model)
        print(json.dumps({"ok": True, "path": str(path), "model": args.model}))
        return

    missing = []
    for name in ("out", "ref_wav", "ref_text"):
        if not getattr(args, name):
            missing.append("--" + name.replace("_", "-"))
    if missing:
        ap.error(f"{', '.join(missing)} are required unless --check or --prefetch is given")

    text = sys.stdin.read().strip()
    if not text:
        ap.error("no text on stdin")
    print(json.dumps(render(args, text)))


if __name__ == "__main__":
    main()
