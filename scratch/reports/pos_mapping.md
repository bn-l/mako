# Phase 0 — POS mapping table

**Observed POS variant keys** across us_gold + us_silver:

| Key       | Count | Interpretation                              |
|-----------|------:|---------------------------------------------|
| DEFAULT   |  800  | fallback when no POS-specific variant hits  |
| NOUN      |  425  | universal POS: noun                         |
| VERB      |  272  | universal POS: verb                         |
| ADJ       |   63  | universal POS: adjective                    |
| None      |   32  | stressed variant of function words          |
| ADV       |    3  | universal POS: adverb                       |
| VBD       |    4  | Penn: past-tense verb                       |
| VBP       |    3  | Penn: present-tense non-3sg verb            |
| VBN       |    3  | Penn: past-participle verb                  |
| DT        |    1  | Penn: determiner                            |

## The "the dict uses coarse POS" finding

The overwhelming majority of POS variants use **universal POS tags**
(`NOUN`, `VERB`, `ADJ`, `ADV`), not Penn tags. Only 11 entries across the
entire merged dict use Penn tags (VBD/VBP/VBN/DT), and they cover a
finite enumerable list:

- `read`, `reread`, `used`, `wound` → VBD/VBP/VBN variants
- `that` → DT variant
- (+32 `None` variants for function words — stressed vs reduced)

This lets us skip a Penn-tag parser entirely. NLTagger's
`NLTagScheme.lexicalClass` already gives us universal tags (`.noun`,
`.verb`, `.adjective`, `.adverb`, `.determiner`). The 4 Penn-tag words
above stay on the hand-tuned homograph path.

## NLTag → variant-key mapping

| NLTag                 | Variant key  |
|-----------------------|--------------|
| `.noun`               | `NOUN`       |
| `.verb`               | `VERB`       |
| `.adjective`          | `ADJ`        |
| `.adverb`             | `ADV`        |
| `.determiner`         | `DT`         |
| `.pronoun`            | → DEFAULT    |
| `.preposition`        | → DEFAULT    |
| `.conjunction`        | → DEFAULT    |
| `.particle`           | → DEFAULT    |
| `.interjection`       | → DEFAULT    |
| `.number`             | → DEFAULT    |
| `.idiom`              | → DEFAULT    |
| `.otherWord`, `nil`   | → DEFAULT (see plan rule G — safety default) |

## `None` (null POS) handling

32 function words expose a "stressed" pronunciation under the `None` key.
In kokorog2p these are reached when the word appears in an emphatic /
contrastive context (spaCy's implementation detail — not tied to Penn
tag at all). Without spaCy we can't easily detect emphasis. Decision:

- Default to DEFAULT for all function-word lookups.
- The stressed variant is reachable only via explicit override
  (markdown `[word](/ipa/)` or SSML `<emphasis>` in a later phase).

## `get_parent_tag` (lexicon.py line 279) — Penn → universal collapse

kokorog2p already collapses Penn tags to universal tags inside the
lookup path:

- `VB*` (any verb form) → `VERB`
- `NN*`                 → `NOUN`
- `ADV*` / `RB*`        → `ADV`
- `ADJ*` / `JJ*`        → `ADJ`

This runs **after** an exact-tag lookup miss. Port contract:

1. Try `variants[tag]` if tag is one of the keys we actually stored
   (DEFAULT, NOUN, VERB, ADJ, ADV, DT, or Penn-specific VBD/VBP/VBN).
2. Fall back to `variants[get_parent_tag(tag)]`.
3. Fall back to `variants["DEFAULT"]`.
4. Fall back to first non-null variant value.

## Penn-tag handling (read / reread / used / wound)

These need past-tense vs present-tense discrimination. NLTagger does
not expose tense natively. Options:

1. Keep today's hand-tuned homograph rules for these specific words.
2. Regex pass: `\b(read|wound|used)\s+(?:to|by|\w+ed)` → past.
3. Punt: always return DEFAULT, emit no override for these; BART handles.

**Decision.** Option 1 for Phase 2. This matches the plan's rule G
("emit DEFAULT when in doubt") while preserving the existing targeted
rules for read/wound that the current codebase already ships.
