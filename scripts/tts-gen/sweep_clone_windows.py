# /// script
# requires-python = "==3.12.*"
# dependencies = ["mlx-audio", "numpy", "soundfile", "psutil"]
# ///
"""Audition every part of a recording as a cloning reference.

    uv run scripts/tts-gen/sweep_clone_windows.py nice-audio-for-cloning.wav --stage refs
    uv run scripts/tts-gen/sweep_clone_windows.py nice-audio-for-cloning.wav --stage render

make_reference.py takes ONE window and hopes it is representative. It is not: which 30
seconds you clone from decides the voice, and a single sample is a lottery. This rolls
the window across the whole file in 5 s steps, so every part of the recording gets
auditioned, and renders a short numbered clip from each — the spoken "Number N" means
they can be judged by ear alone, in order, without checking filenames.

Two stages, deliberately separate processes: parakeet is loaded once for all the
transcripts, then fish once for all the renders. Interleaving them would load and drop
6.8 G of weights forty times and risk the OOM killer for no benefit.

Window edges snap to the quietest 100 ms within ±`--slack` of the nominal offset, so a
reference never begins or ends mid-word. Actual offsets land in the manifest.
"""

import argparse
import json
import logging
import time
from pathlib import Path

import numpy as np
import soundfile as sf

from gen_fish import PRESETS, join_with_pauses, memory_note, speaker_tagged
from make_reference import quietest_cut
from oomguard import arm

log = logging.getLogger("sweep_clone_windows")

ORDINALS = ("zero one two three four five six seven eight nine ten eleven twelve "
            "thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty "
            "twenty-one twenty-two twenty-three twenty-four").split()


def half_of(text):
    """First half of the passage, by characters, cut on a paragraph boundary."""
    blocks = [block.strip() for block in text.split("\n\n") if block.strip()]
    target = len(text) / 2
    kept, total = [], 0
    for block in blocks:
        kept.append(block)
        total += len(block)
        if total >= target:
            break
    return "\n\n".join(kept)


def build_refs(args, here, source, out_dir):
    from mlx_audio.stt.utils import load_model

    audio, rate = sf.read(str(source), dtype="float32", always_2d=False)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    duration = len(audio) / rate
    log.info("%s: %.1fs at %d Hz", source.name, duration, rate)

    if args.windows:
        windows = []
        for spec in args.windows.split(","):
            start, length = spec.split(":")
            windows.append((float(start), float(length)))
        log.info("%d explicit windows: %s", len(windows), args.windows)
    else:
        windows = [(start, args.seconds)
                   for start in np.arange(0.0, duration - args.seconds + 0.001, args.step)]
        log.info("%d windows of %.0fs every %.0fs", len(windows), args.seconds, args.step)

    log.info("loading %s [%s]", args.model, memory_note())
    model = load_model(args.model)

    manifest = []
    for index, (nominal, length) in enumerate(windows, start=args.number_from):
        # Snap both edges into a pause. quietest_cut works in seconds from the array
        # head, so slice for the end edge relative to the (already snapped) start.
        begin = 0 if nominal == 0 else quietest_cut(
            audio, rate, nominal - args.slack, nominal + args.slack)
        tail = audio[begin:]
        end = begin + quietest_cut(tail, rate, length - args.slack, length + args.slack)
        clip = audio[begin:end]

        dest = out_dir / f"{args.slug}-{index:02d}.wav"
        sf.write(dest, clip, rate)
        transcript = model.generate(str(dest)).text.strip()
        (dest.with_suffix(".txt")).write_text(transcript + "\n", encoding="utf-8")

        log.info("%s: %.1f-%.1fs (%.1fs), %d chars — %s", dest.name, begin / rate,
                 end / rate, len(clip) / rate, len(transcript), transcript[:70])
        manifest.append({"index": index, "wav": dest.name,
                         "txt": dest.with_suffix(".txt").name,
                         "start": round(begin / rate, 2), "end": round(end / rate, 2),
                         "transcript": transcript})

    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    log.info("wrote %s — check the transcripts before rendering", out_dir / "manifest.json")


def render(args, here, ref_dir, out_dir):
    import mlx.core as mx
    from mlx_audio.tts.utils import load_model
    from mlx_audio.utils import load_audio

    mx.set_cache_limit(args.mlx_cache_mb * 1024 ** 2)
    manifest = json.loads((ref_dir / "manifest.json").read_text(encoding="utf-8"))

    passage = Path(args.text_file)
    if not passage.is_absolute():
        passage = here / passage
    body = half_of(passage.read_text(encoding="utf-8").strip())
    log.info("%s: %d chars of %d after halving", passage.name, len(body),
             len(passage.read_text(encoding='utf-8').strip()))

    log.info("loading %s [%s]", args.tts_model, memory_note())
    model = load_model(args.tts_model)
    sample_rate = getattr(model, "sample_rate", 44100)

    for entry in manifest:
        dest = out_dir / f"{args.slug}-{entry['index']:02d}.wav"
        if dest.exists():
            log.info("%s exists, skipping", dest.name)
            continue

        # Its own paragraph, so the number is its own turn and lands before a pause
        # rather than running into the first line.
        spoken = f"Number {ORDINALS[entry['index']]}.\n\n{body}"
        options = dict(PRESETS[args.preset])
        options.update(text=speaker_tagged(spoken, "paragraph"), verbose=False,
                       max_tokens=args.max_tokens, chunk_length=args.chunk_length,
                       ref_audio=load_audio(str(ref_dir / entry["wav"]),
                                            sample_rate=sample_rate),
                       ref_text=(ref_dir / entry["txt"]).read_text(encoding="utf-8").strip())

        log.info("%s: cloning %s (%.1f-%.1fs) [%s]", dest.name, entry["wav"],
                 entry["start"], entry["end"], memory_note())
        mx.random.seed(args.seed)
        started = time.time()
        pieces = []
        for result in model.generate(**options):
            pieces.append(np.asarray(result.audio, dtype=np.float32).reshape(-1))
            log.info("  batch %d [%s]", len(pieces), memory_note())
        if not pieces:
            log.error("%s: produced no audio", dest.name)
            continue

        rng = np.random.default_rng(args.seed)
        audio = join_with_pauses(pieces, sample_rate, rng, args.gap_mean, args.gap_sd,
                                 args.fade_ms)
        sf.write(dest, audio, sample_rate)
        elapsed = time.time() - started
        mx.clear_cache()
        log.info("wrote %s — %.1fs audio in %.1fs wall [%s]", dest.name,
                 len(audio) / sample_rate, elapsed, memory_note())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", help="recording to roll the reference window across")
    ap.add_argument("--stage", choices=["refs", "render"], required=True)
    ap.add_argument("--seconds", type=float, default=30.0, help="reference window length")
    ap.add_argument("--step", type=float, default=5.0, help="roll the window by this much")
    ap.add_argument("--windows", default=None,
                    help="skip the roll and cut these 'start:length' windows, comma "
                         "separated, e.g. '0:15,0:30' to compare reference lengths")
    ap.add_argument("--number-from", type=int, default=1,
                    help="first spoken/file number; continue an earlier set rather than "
                         "restarting at one, so numbers stay unique across sources")
    ap.add_argument("--slack", type=float, default=1.2,
                    help="how far an edge may move to land in a pause")
    ap.add_argument("--slug", default=None, help="output stem (default: source stem)")
    ap.add_argument("--ref-dir", default="clone-windows")
    ap.add_argument("--out", default="wav-fish-clone-sweep")
    ap.add_argument("--text-file", default="itin-tagged.txt")
    ap.add_argument("--preset", choices=sorted(PRESETS), default="hot")
    ap.add_argument("--model", default="mlx-community/parakeet-tdt-0.6b-v3")
    ap.add_argument("--tts-model", default="mlx-community/fish-audio-s2-pro-8bit")
    ap.add_argument("--gap-mean", type=float, default=0.6)
    ap.add_argument("--gap-sd", type=float, default=0.2)
    ap.add_argument("--fade-ms", type=float, default=50.0)
    ap.add_argument("--chunk-length", type=int, default=400)
    ap.add_argument("--max-tokens", type=int, default=1536)
    ap.add_argument("--mlx-cache-mb", type=int, default=1024)
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("--oom-floor-mb", type=int, default=2200)
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    arm(floor_mb=args.oom_floor_mb)

    here = Path(__file__).resolve().parent
    source = Path(args.source)
    if not source.is_absolute():
        source = here / args.source if (here / args.source).exists() else here.parents[1] / args.source
    args.slug = args.slug or source.stem

    ref_dir = here / args.ref_dir
    ref_dir.mkdir(parents=True, exist_ok=True)
    if args.stage == "refs":
        build_refs(args, here, source, ref_dir)
    else:
        out_dir = here / args.out
        out_dir.mkdir(parents=True, exist_ok=True)
        render(args, here, ref_dir, out_dir)


if __name__ == "__main__":
    main()
