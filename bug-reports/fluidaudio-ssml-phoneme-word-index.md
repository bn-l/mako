# FluidAudio: `<phoneme>` SSML tags land at wrong word index when mixed with other tags

## Summary

`SSMLProcessor.process(_:)` computes `wordIndex` for each `<phoneme>` tag by
counting words in `workingText`, but at the moment `countWordsBeforeIndex` is
called, `workingText` still contains the raw source of all tags that appear
*before* the current one in reverse-processing order. The literal characters
inside those unprocessed tags (`sub`, `alias`, `Doctor`, `say`, `as`,
`interpret`, etc.) are counted as if they were words, so the phoneme
override's `wordIndex` is inflated by the tag count ahead of it, and the IPA
lands on a completely unrelated word downstream.

## Reproduction

### Input

```
<sub alias="Doctor">Dr.</sub> Maya <phoneme alphabet="ipa" ph="OˈbɹaɪƏn">O'Brien</phoneme>
```

Expected: `Doctor Maya O'Brien`, with the IPA attached to "O'Brien" (word
index 2 in the final cleaned text).

### Actual

The `<phoneme>` is processed in reverse document order. When its
`wordIndex` is calculated (line 27 of `SSMLProcessor.swift`), `workingText`
still contains the *raw* `<sub alias="Doctor">Dr.</sub>` source. The word
counter at line 70 iterates that prefix and counts `sub` + `alias` +
`Doctor` + `Dr` + `Maya` = 5 "words". The phoneme override is recorded
with `wordIndex = 5`, several words past "O'Brien" in the final text.

Downstream, `KokoroChunker.resolveOverride(...)` applies the IPA to
whatever word happens to sit at index 5, corrupting the synthesis.

## Impact

- `<phoneme>` is effectively unusable in documents that also contain
  `<sub>` or `<say-as>` tags.
- Empirically the audio output for passages that combine the three tag
  kinds is severely degraded — in our testing this surfaced as garbage
  sounds, missing words, and the literal tag attributes (`"sub"`,
  `"alias"`) being spoken.
- Workaround: downstream consumers must avoid `<phoneme>` and use only
  `<sub>` / `<say-as>`, or use the markdown `[word](/ipa/)` override (which
  goes through a different code path — `TtsTextPreprocessor.processPhoneticReplacement`
  — whose `WordAccumulator` assigns indices correctly).

## Proposed fix

Move the `wordIndex` calculation from "count in the tag-riddled source" to
"count in the already-cleaned text". Two approaches:

**Option A — two-pass.** Do a first pass that strips all tags to their
replacement text, recording each tag's *cleaned* start offset. Then on a
second pass emit phoneme overrides using those offsets.

**Option B — process tags in forward document order instead of reverse**,
maintaining a running offset delta between source and cleaned indices.
Phoneme overrides see a cleaned prefix because all prior tags have already
been replaced.

Option B is closer to how `processPhoneticReplacement` already works
(`WordAccumulator` walks once in forward order, tracking `completedWords`
as it goes) and would make the two override paths symmetric.

## Minimal test case

```swift
let input = #"<sub alias="Doctor">Dr.</sub> Maya <phoneme alphabet="ipa" ph="OˈbɹaɪƏn">O'Brien</phoneme>"#
let result = SSMLProcessor.process(input)
// Expected: result.text == "Doctor Maya O'Brien"
//           result.phoneticOverrides.first?.wordIndex == 2
// Actual:   result.phoneticOverrides.first?.wordIndex == 5  (or similar)
```

## Environment

- FluidAudio HEAD (`Sources/FluidAudio/TTS/SSML/SSMLProcessor.swift` line 27
  and line 70 as of this writing)
- Swift 6.2 on macOS 15

## Origin

Discovered while building a SSML-emitting normalizer on top of
`KokoroTtsManager`. We initially used `<phoneme>` for per-word IPA
overrides and hit this bug; pivoted to the markdown `[word](/ipa/)` path
which is unaffected.
