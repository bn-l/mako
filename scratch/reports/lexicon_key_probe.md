# Phase 0 — lexicon-key empirical check

**Purpose.** Verify that `TtsCustomLexicon` keys line up with the
tokens the chunker emits after `SSMLProcessor` + `TtsTextPreprocessor`.
If they don't, every auto-lexicon entry we add is silently dead.

**Method.** `KOKORO_G2P_TRACE=1 KOKORO_CUSTOM_LEXICON_AUTO=1`, synthesize
a short passage containing known-gold words, read the `words` array out
of `ChunkInfo`.

**Probe input.**

    Maya stopped by with Worcestershire sauce. The sommelier mentioned Châteauneuf.
    Colonel Martinez sipped his lemonade. Maya said hello.

**`ChunkInfo.words` emitted.**

    Maya | stopped | by | with | Worcestershire | sauce | The | sommelier |
    mentioned | Châteauneuf | Colonel | Martinez | sipped | his | lemonade |
    Maya | said | hello

## Findings

1. **Capitalisation preserved.** Source "Maya" → word "Maya". A lexicon
   key of `"Maya"` matches on the exact-match step of
   `TtsCustomLexicon.phonemes(for:)`. `"maya"` also matches via the
   case-insensitive fallback.
2. **Unicode preserved.** `Châteauneuf` with combining mark survives
   the preprocessing chain.
3. **Multi-word proper nouns are tokenised per-word.** `Colonel Martinez`
   becomes two separate tokens; any "Colonel Martinez" compound-key
   lexicon entry would never hit. The port must only register
   single-word keys via the auto-lexicon scanner (this is already true
   of the current code — confirming behaviour).
4. **Dotted abbreviations are distorted by `TtsTextPreprocessor`.**
   Source `9:30 a.m.` with our current SSML wrapper
   `<sub alias="9 30 in the morning.">9:30 a.m.</sub>` becomes the
   chunk text `"nine thirty inches the morning."` — FluidAudio's
   unit-expansion pass is matching `30 in` as "30 inches". This is a
   **live bug**, independent of the port, but the port's Phase 3
   abbreviation-expansion exit criterion must catch it. Our alias
   text must avoid emitting `in/on/at/per/per kg/mg/...` tokens that
   the unit pass will grab.

## Contract (lands in Phase 1)

- Custom-lexicon keys for auto-scanned proper nouns: use the source
  form verbatim. Case variance handled by FluidAudio's multi-step
  lookup.
- Never assume a key spanning multiple words will hit.
- Never emit an SSML `<sub alias>` whose replacement text contains a
  bare unit shorthand (`in`, `kg`, `mg`, `m`, `ft`, `lb`, `oz`, …) —
  FluidAudio's unit pass will rewrite it.

## Outstanding

- Cross-check what `ChunkInfo.words` does with quoted / parenthesised
  tokens, e.g. `"Maya"` or `(Maya)`. Not needed to unblock Phase 1;
  revisit if Phase 5 tokenisation shows drift.
