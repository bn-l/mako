# TTS generation scripts

Bakeoff and rendering harness for the local TTS models. Every generation run must be
guarded by an OOM watchdog — see `oomguard.py` (in-process) and `../oom_watchdog.sh`
(external). One model at a time, never two runs at once.

## Production voice

Fish S2 Pro, cloned from a 29.3 s reference:

```sh
uv run --script gen_fish.py --text-file itin-tagged.txt --out wav-fish-itin \
    --label out --preset hot \
    --clone-wav clone-windows-2/gemini2-22.wav \
    --clone-text-file clone-windows-2/gemini2-22.txt \
    --chunk-length 400 --max-tokens 900 --mlx-cache-mb 512
```

There is no per-voice model to save. Fish clones in-context: `_prepare_reference_prompt`
encodes the reference wav to VQ codes and puts them in the system message. The voice is
therefore a **runtime dependency** — ship `gemini2-22.wav` and `gemini2-22.txt` together,
and do not edit the transcript, which must remain exactly what the audio says.

Peak RAM is ~14.5 G regardless of input length (measured to 7119 chars); the cost of long
input is time, at roughly 2.3× realtime.

### This has shipped — `mako say --hq`

The production path is no longer this script. It is
`Sources/TTSHarnessCore/Resources/fish_say.py`, a self-contained sidecar that mako spawns
via `uv run --script`, with `gemini2-22.{wav,txt}` copied into the same directory and
bundled into the binary. The originals stay here as the provenance chain back to
`manifest.json`.

That sidecar **duplicates** roughly 100 lines from `gen_fish.py` and `oomguard.py` —
`PRESETS`, paragraph tagging, `join_with_pauses`, the guard — because inside the resource
bundle it has no siblings to import from. The duplication is deliberate and one-way:
**this script is free to drift, the sidecar is not.** Change behaviour that matters to
production in `fish_say.py`.

Two differences worth knowing, both places the sidecar is right and this script is not:

* Its defaults are the *validated* ones — `--chunk-length 400`, `--max-tokens 900`,
  `--mlx-cache-mb 512` — where this script still defaults to the lab values 150 and 1536.
* mako subdivides paragraphs over the byte budget before handing text over.
  `group_turns_into_batches` refuses to split an oversized turn, and `max_tokens` then
  truncates that batch mid-sentence, so a long unbroken paragraph rendered through *this*
  script silently loses its tail. The sidecar warns when it sees one.

---

# Inline marker register

Fish S2 Pro takes `[tag]` markers inline in the text. They are **ordinary text to the
model**, not control tokens: S2 was trained on transcripts containing these descriptions
and learned the mapping implicitly. That is why behaviour is a matter of evidence rather
than specification, and why a tag can simply do nothing.

Everything below was judged **by ear**, on this configuration only:
`mlx-community/fish-audio-s2-pro-8bit`, `hot` preset, cloned from `gemini2-22.wav`.
Verdicts may not transfer to another voice, preset or model.

## Verdicts

| Tag | Verdict | What it actually does | Heard in |
|---|---|---|---|
| `[laughing]` | **works** | Produces an audible laugh. | `markers-split` |
| `[confident]` | **works** | Audible on a sentence whose content is confident. | `official-tags` |
| `[curious]` | **works** | Audible on a genuinely questioning sentence. | `official-tags` |
| `[whisper]` | **works, misnamed** | Not a whisper: a calm, soft register, like an aside. Worth using — for that, not for whispering. | `contrast-cloned` |
| `[shouting]` | **works, misnamed** | Not volume: a mildly emphatic, emotionally raised delivery. Use for emphatic passages. | `contrast-cloned`, `strong-cloned` |
| `[soft tone]` | **partial** | Sort of worked. | `official-tags` |
| `[determined]` | **partial** | Slightly worked. | `official-tags` |
| `[very excited]` | **partial** | Slightly enthused — short intensity modifiers do something, unlike long descriptions. | `official-tags` |
| `[emphasis]` | **partial, inconsistent** | Stresses the following word, but weakly, and not on every render. Place immediately before the target word. | `markers-split`, `official-tags` |
| `[slow]` | **fails on real prose** | Worked only on the artificial `Every. Single. Word. Deliberately.`; no audible effect on an ordinary sentence. Do not rely on it. | `contrast-cloned`, `official-tags` |
| `[whispering]` | **no effect** | Failed even though it is the officially documented spelling — while the undocumented `[whisper]` worked. | `official-tags` |
| `[excited]` | **no effect** | Indistinguishable from no tag. | `markers-split` |
| `[sarcastic]` | **no effect** | Also unwanted. | `official-tags` |
| `[break]` `[long-break]` | **no effect** | Neither produced a pause. | `official-tags` |
| `[sad][whispering]` | **no effect** | Documented stacking; nothing audible. | `official-tags` |
| `[sigh]` | **banned** | Works, but never generate it. Product decision. | — |
| `[low volume]` `[volume up]` `[calm]` `[angry]` `[short pause]` | **untested** | Rendered in `contrast-cloned.wav`, never judged. | — |

### Invented free-form descriptions — all inert

Every long free-form description tested did nothing: `[conspiratorial, leaning in
close]`, `[slow, weary, end of a long day]`, `[crisp and decisive]`, `[whispering under
her breath, barely voiced, almost inaudible]`, `[SHOUTING at the top of her lungs,
furious, at maximum volume]`, `[wildly excited, breathless, talking far too fast]`.

Verbose restatement does not strengthen a tag — `[SHOUTING at the top of her lungs…]`
was no stronger than plain `[shouting]`. Fish's "15,000+ tags, free-form textual
descriptions" claim describes the breadth of the training distribution, not a guarantee
that arbitrary prose works. **Short intensity modifiers (`[very excited]`) are the one
free-form form that has shown any effect.**

## Rules that follow

* **Content congruence looks like the deciding factor.** Every tag that worked sat on a
  sentence whose meaning already supported it (`[confident]` on "The fix is correct and
  the tests prove it"). Tags on semantically neutral or mismatched text have uniformly
  done nothing. Working hypothesis, not established — but it predicts the results so far.
* **Volume is not controllable.** Measured loudness range is 9–11 dB in every
  configuration tried: one marker per batch, contrasting markers within one batch,
  intensified wording, and reference-free. Use post-processing gain for dynamics.
* **Documented spelling is not a guide.** `[whisper]` works and `[whispering]` does not,
  the opposite of what the official docs imply. Test, do not assume.
* **Tags cost bytes** against `--chunk-length`, changing how text is batched.
* **Overall delivery comes from the reference clip**, not from tags.

## Test method — and a known-bad one

`exp_official_tags.py` renders all 108 documented markers on one shared carrier sentence
("The report is finished and the release goes out at four") with a spoken index number.
**That test came back inconclusive**: tags 1–35 all sounded identical to the listener.
Two likely reasons, either fatal on its own:

1. The carrier is emotionally neutral and unrelated to the tag, so there is nothing for
   e.g. `[grateful]` to attach to.
2. Twenty-plus near-identical turns accumulate in one conversation, and fish feeds each
   batch's codes back as context, so the model locks into one delivery.

A better test gives each tag a **short, semantically congruent sentence**, and puts only
a handful of tags in any one render. Do not read the bulk sweep as evidence that a tag
does nothing.

## Official tag vocabulary

Recorded for reference. Presence here means documented, **not** that it works — see the
verdict table.

**Basic emotions** — `[happy]` `[sad]` `[angry]` `[excited]` `[calm]` `[nervous]`
`[confident]` `[surprised]` `[satisfied]` `[delighted]` `[scared]` `[worried]` `[upset]`
`[frustrated]` `[depressed]` `[empathetic]` `[embarrassed]` `[disgusted]` `[moved]`
`[proud]` `[relaxed]` `[grateful]` `[curious]` `[sarcastic]`

**Advanced emotions** — `[disdainful]` `[unhappy]` `[anxious]` `[hysterical]`
`[indifferent]` `[uncertain]` `[doubtful]` `[confused]` `[disappointed]` `[regretful]`
`[guilty]` `[ashamed]` `[jealous]` `[envious]` `[hopeful]` `[optimistic]` `[pessimistic]`
`[nostalgic]` `[lonely]` `[bored]` `[contemptuous]` `[sympathetic]` `[compassionate]`
`[determined]` `[resigned]`

**Tone** — `[in a hurry tone]` `[shouting]` `[screaming]` `[whispering]` `[soft tone]`
`[emphasis]` `[low voice]` `[loud]` `[low volume]` `[volume up]` `[volume down]` `[slow]`
`[excited tone]` `[laughing tone]` `[flirty]` `[singing]` `[with strong accent]` `[echo]`
`[interrupting]`

**Audio effects** — `[laughing]` `[chuckling]` `[giggling]` `[sobbing]` `[crying loudly]`
`[groaning]` `[panting]` `[gasping]` `[yawning]` `[snoring]` `[clear throat]`
`[clearing throat]` `[inhale]` `[exhale]` `[tsk]` `[moaning]` `[shocked]` `[delight]`
`[pause]` `[short pause]` `[break]` `[long-break]` — plus `[sigh]` / `[sighing]`, banned.

**Crowd** — `[audience laughing]` `[background laughter]` `[crowd laughing]`
`[audience laughter]`

**Intensity modifiers** — `[slightly sad]` `[very excited]` `[slightly angry]`
`[very calm]` (any `[slightly X]` / `[very X]`)

**Stacking** — up to two or three at one position, e.g. `[sad][whispering]`,
`[excited][laughing]`. Do not combine physically impossible pairs
(`[whispering]` + `[shouting]`).

**Placement** — emotion cues work best at the start of a sentence; tone and effect tags
can go anywhere. `[emphasis]` goes immediately before its target word.

**Paralanguage (parentheses, a separate mechanism)** — `(break)` `(long-break)`
`(breath)` `(laugh)` `(cough)` `(sigh)` `(lip-smacking)`. Documented as requiring
`settings.normalize=false`; the MLX port exposes no normalize option and appears to do no
text normalisation, so these may work here. Rendered in `wav-fish-tags/paralanguage.wav`,
not yet judged.

**Pronunciation override** — `<|phoneme_start|>R IY1 D<|phoneme_end|>`, CMU Arpabet with
stress digits, replaces exactly one word, punctuation after the closing tag. Also
documented as needing `normalize=false`. Untested — relevant to the homograph work.

**Speaker turns** — `<|speaker:0|>` / `<|speaker:1|>`, max 5 turns per batch.

Sources: [emotion docs](https://docs.fish.audio/developer-guide/core-features/emotions),
[fishaudio/s2-pro model card](https://huggingface.co/fishaudio/s2-pro),
[fish.audio/s2](https://fish.audio/s2/),
[Runware S2.1 Pro guide](https://runware.ai/docs/models/fish-audio-s2-1-pro/guides/emotion-and-expression).

---

## Scripts

| Script | Purpose |
|---|---|
| `gen_fish.py` | Main fish renderer: cloning, paragraph tagging, randomised inter-batch pauses. |
| `gen_fish_anchored.py` | Drives the batch loop directly so history can be windowed or re-anchored. Tested and rejected — sounded worse than fish's unbounded history for a 6.5% speed gain. |
| `exp_official_tags.py` | Renders all 108 documented markers with spoken index numbers. Test design known to be flawed — see above. |
| `make_reference.py` | Turns a recording into a cloning reference: trims to a pause, then transcribes the trimmed clip so the transcript matches by construction. |
| `sweep_clone_windows.py` | Rolls the reference window across a recording and renders a numbered clip from each, to audition which part of a clip clones best. |
| `check_voice.py` | Median F0, pitch span, drift, centroid — for comparing voices and detecting mid-render speaker changes. |
| `marker_check.py` | Per-segment loudness and pitch, split at joining silences or breath pauses. Verifies a marker was *obeyed*, not merely unspoken. |
| `transcribe_check.py` | Parakeet ASR check — verifies markers are not read aloud. Returns empty for some windows of perfectly good audio. |
| `render_stats.py` | Parses run logs into a throughput and memory table. |
