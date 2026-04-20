# Kokorog2p Python-to-Swift Port Mapping

## Module Overview

### `en/g2p.py` — English G2P Orchestrator
**Purpose:** Main entry point; orchestrates normalization, tokenization, POS tagging, and phoneme lookup with fallback.

**Public API:**
- `EnglishG2P(language: str, use_espeak_fallback: bool, use_spacy: bool, ...)` — init with options
- `__call__(text: str) -> list[GToken]` — main phonemization (lazy spaCy/normalizer init)
- `process_with_debug(text: str) -> ProcessedText` — full provenance tracking
- `lookup(word: str, tag: str|None) -> str|None` — single-word lookup
- Properties: `fallback`, `nlp`, `normalizer`, `regex_tokenizer`, `spacy_tokenizer`

**Key algorithm:**
- Process tokens in **reverse order** for context (future-vowel/future-to detection)
- POS fallback: `tag → get_parent_tag(tag) → DEFAULT` in lexicon dicts
- Contraction exceptions added to spaCy for apostrophe preservation

**Hard to port:**
- Lazy spaCy loading + model download — use Swift NLTagger or cached model instead
- Contraction exception registration (language-model specific)

---

### `en/normalizer.py` — Text Normalization
**Purpose:** Multi-phase normalization (abbrev expansion, apostrophe/quote/ellipsis/dash normalization).

**Public API:**
- `EnglishNormalizer(track_changes: bool, expand_abbreviations: bool)` — init
- `normalize(text: str) -> tuple[str, list[NormalizationStep]]` — apply all rules in order
- `normalize_token(text: str, before: str, after: str) -> str` — single-token normalization
- `add_abbreviation(abbr: str, expansion: str|dict[str, str])` — custom abbrev

**Critical ordering (Phase 0–6):**
1. Time/temp patterns (prevent "37°C." → "37°circa")
2. Abbreviation expansion
3. Apostrophe variants → `'` (right quote, left quote, prime, etc.)
4. Smart backtick/acute (inside words → `'`, standalone → quote)
5. Quote normalization (all directional → curly)
6. Ellipsis & dash normalization

**Regex patterns (first 20):**
```
Time: r"\b(\d{1,2}):(\d{2})\b"
Temp: r"(-?\d+)\s*°?\s*([FCfc])(\.?)(?=\s|[,;:!?]|$)"
Apostrophe right: \u2019
Backtick contraction: r"(\w)`(\w)"
Ellipsis four dots: r"\.\.\.\."
Spaced ellipsis: r"\. \. \."
Em-dash: -- or - with spaces
```

**Hard to port:**
- Time/temp callbacks use `_number_to_words()` (num2words dependency)
- Abbreviation expansion uses singleton pattern with context detection

---

### `en/numbers.py` — Number-to-Words Conversion
**Purpose:** Convert digits, ordinals, years, decimals, currency using `num2words`.

**Public API:**
- `NumberConverter(lookup_fn, stem_s_fn)` — init with lexicon callbacks
- `convert(word: str, currency: str|None, is_head: bool) -> tuple[str|None, int|None]` — main
- `_convert_ordinal()`, `_convert_year()`, `_convert_phone_sequence()`, `_convert_currency()` — helpers
- Helpers: `is_digit()`, `is_roman_numeral()`, `is_currency_amount()`

**Key constants:**
```python
_THOUSANDS_GROUPED_RE = r"^\d{1,3}(?:,\d{3})+(?:\.\d+)?$"  # 30,000 or 1,234,567.89
ORDINALS = {"st", "nd", "rd", "th"}
CURRENCIES = {"$": ("dollar", "cent"), "£": ("pound", "pence"), "€": ("euro", "cent")}
```

**Algorithm:** Roman → cardinal, ordinal suffix, 4-digit year, phone/dotted, currency, then regular.

**Hard to port:**
- Tight coupling to `num2words` library — must port num2words or hardcode for common numbers

---

### `en/abbreviations.py` — English Abbrev Lexicon
**Purpose:** ~200+ hardcoded English abbreviations (titles, days, months, places, units, degrees).

**Public API:**
- `EnglishAbbreviationExpander` (subclass of `AbbreviationExpander`)
- `get_expander(enable_context_detection: bool) -> EnglishAbbreviationExpander` — singleton
- `add_custom_abbreviation(abbr: str, expansion: str|dict[str, str], ...)` — user API

**Structure:** Each `AbbreviationEntry` has:
- `abbreviation`, `expansion` (default)
- `context_expansions: dict[AbbreviationContext, str]` (e.g., `"St." → PLACE:"Street", RELIGIOUS:"Saint"`)
- `only_if_preceded_by` / `only_if_followed_by` — regex guards (e.g., `"in." only before `\s*\d`)

**Hard to port:**
- 200+ hardcoded entries — keep as data file or dictionary
- Context detection uses `ContextDetector` with heuristics (place number pattern, saint/city names, etc.)

---

### `pipeline/abbreviations.py` — Generic Abbreviation Framework
**Purpose:** Base classes for language-specific abbreviation expansion.

**Public API:**
- `AbbreviationEntry` — dataclass with entry, expansion, context_expansions
- `AbbreviationContext` enum — DEFAULT, TITLE, PLACE, TIME, ACADEMIC, RELIGIOUS
- `AbbreviationExpander(ABC)` — abstract base; subclassed by `EnglishAbbreviationExpander`
- `ContextDetector` — detects context from surrounding text
- `expand(text: str) -> str` — expand all abbrevs (longest-first)

**Key algorithm:** Process abbrevs longest-first, apply regex + optional guards (before/after patterns).

---

### `en/lexicon.py` — Gold/Silver Dictionary Lookup
**Purpose:** ~170k gold + ~100k silver word→IPA mappings with POS-dependent variants and suffix handling.

**Public API:**
- `Lexicon(british: bool, load_gold: bool, load_silver: bool)` — init
- `lookup(word: str, tag: str|None, stress: float|None, ctx: TokenContext|None) -> tuple[str|None, int|None]` — single lookup
- `__call__(...)` — same as lookup but with Greek normalization, number conversion
- `get_word()`, `get_special_case()` — internal fallback chains
- Suffix handlers: `stem_s()`, `stem_ed()`, `stem_ing()` — rate 3–4
- `get_NNP()` — proper noun spelling (A, B, C → ə, bē, sē)

**Critical constants:**
```python
LEXICON_ORDS = [39, 45, *range(65, 91), *range(97, 123)]  # ' - A-Z a-z
CONSONANTS = frozenset("bdfhjklmnpstvwzðŋɡɹɾʃʒʤʧθ")
VOWELS = frozenset("AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ")
DIPHTHONGS = frozenset("AIOQWYʤʧ")
US_TAUS = frozenset("AIOWYiuæɑəɛɪɹʊʌ")  # flap trigger for /t/ → [ɾ]
PRIMARY_STRESS, SECONDARY_STRESS = "ˈ", "ˌ"
GREEK_LETTERS = {"α": "alpha", ...}  # 24 Greek letters
```

**POS fallback order** (in `lookup` for dicts):
1. Exact tag match
2. `get_parent_tag()` — VB* → VERB, NN* → NOUN, etc.
3. DEFAULT key

**Special cases** (high-priority in `get_special_case()`):
- `"a"` / `"A"` — ə if DT (article), ˈA otherwise
- `"am"` / `"an"` / `"the"` / `"to"` / `"in"` — context-aware schwas/reduced forms
- `"I"` as PRP → secondary stress
- `"used"` as VBD/JJ — check future_to context
- Abbreviations with periods — spell out letter-by-letter
- Roman numerals — cardinal conversion
- Currency amounts — num2words with lexicon lookup

**_grow_dictionary(d):** Adds capitalized variants (lowercase ↔ titlecase pairs).

**Hard to port:**
- Lazy num2words import in `_convert_number()` — static or build time dep
- Rating system (0–5) maps to source tier — gold=4, silver=3, etc.

**Unused in this port:**
- Numbers module (fallback only, Swift will use simple hardcoding)

---

### `en/fallback.py` — OOV Fallback (espeak/goruut)
**Purpose:** Convert OOV words using espeak-ng or goruut; convert IPA → Kokoro phonemes.

**Public API:**
- `EspeakFallback(british: bool, use_cli: bool)` — fallback via espeak-ng
- `GoruutFallback(british: bool)` — fallback via goruut (not ported)
- Both inherit `FallbackBase`, have `__call__(word: str) -> tuple[str|None, int|None]`

**Status for Swift port:**
- **NOT PORTING.** Swift port will skip espeak/goruut; unknown words return `None` → UNK marker.
- Flag: Only read to know what we're dropping.

---

### `token.py` — Token Dataclass
**Purpose:** Lightweight token representation with text, tag, phonemes, timestamps, rating, and extension dict.

**Public API:**
```python
@dataclass
class GToken:
    text: str
    tag: str = ""
    whitespace: str = " "
    phonemes: str|None = None
    start_ts: float|None = None  # For audio alignment
    end_ts: float|None = None
    rating: str|None = None  # "3" (silver) or "4" (gold)
    _: dict[str, Any] = field(default_factory=dict)  # Extension dict
    
    @property has_phonemes: bool
    @property is_punctuation: bool
    @property is_word: bool
    get(key: str, default=None) -> Any
    set(key: str, value: Any) -> None
    copy() -> GToken
```

**Critical:** `sourceRange` in Swift maps to `(start_ts, end_ts)` or char positions.

---

### `punctuation.py` — Punctuation Handling
**Purpose:** Normalize Unicode punctuation to Kokoro-safe ASCII, preserve/restore positions.

**Public API:**
- `Punctuation(marks: str|Pattern)` — init with mark set
- `normalize(text: str) -> str` — Unicode → Kokoro punctuation
- `remove(text: str|list[str]) -> str|list[str]` — strip all marks
- `preserve(text: str|list[str]) -> tuple[list[str], list[MarkIndex]]` — extract marks
- `restore(text: str|list[str], marks: list[MarkIndex]) -> list[str]` — reinject marks

**Kokoro-safe punctuation:**
```python
KOKORO_PUNCTUATION = {";", ":", ",", ".", "!", "?", "—", "…", '"', "()", """, """}
```

**Normalization map (first 20):**
```python
PUNCTUATION_NORMALIZATION = {
    "\u2019": "'",  # ' → ' (right single quote)
    "\u2018": "'",  # ' → '
    "`": "'",       # backtick → apostrophe (in contractions)
    "\u2013": "—",  # – → em-dash
    "…": "…",       # (keep ellipsis)
    """: """, """: """,  # Smart quotes → curly
}
```

**Algorithm:** `_SEQ_RE` matches multi-dot/hyphen sequences, `_CHAR_MAP` handles single chars; remove → replace with space.

---

### `pipeline/models.py` — Generic Pipeline Models
**Purpose:** Rich data structures for tracking phonemization provenance.

**Public API:**
- `PhonemeSource` enum — LEXICON_GOLD/SILVER/BRONZE, ESPEAK, RULE_BASED, PUNCTUATION, UNKNOWN
- `NormalizationStep` — rule_name, position, original, normalized, context
- `ProcessingToken` — text, pos_tag, phoneme, phoneme_source, phoneme_rating, quote_depth, normalizations
- `ProcessedText` — original, normalized, tokens, normalization_log
- `ProcessingToken.to_gtoken()` / `.from_gtoken()` — bidirectional conversion

**Hard to port:**
- Extensive debug metadata (language_metadata dict) — keep for future extensibility

---

### `pipeline/normalizer.py` — Generic Normalization Framework
**Purpose:** Abstract base for language-specific normalizers.

**Public API:**
- `NormalizationRule` — name, pattern (str|regex), replacement (str|callable), description
- `rule.apply(text: str, track_changes: bool) -> tuple[str, list[NormalizationStep]]`
- `TextNormalizer(ABC)` — abstract; subclassed by `EnglishNormalizer`
- `add_rule()`, `normalize()`, `_apply_rules()`, `__call__()`

**Hard to port:**
- Pattern compilation and callable replacement functions — straightforward in Swift with regex

---

### `pipeline/tokenizer.py` — Generic Tokenization
**Purpose:** Abstract tokenizer with position tracking, quote-nesting detection, and POS tagging support.

**Public API:**
- `BaseTokenizer(ABC)` — abstract base
- `RegexTokenizer` — simple word/punct/whitespace splitting
- `SpacyTokenizer` — spaCy NLP pipeline integration
- Main: `tokenize(text: str) -> list[ProcessingToken]`
- Helpers: `_detect_quote_depth()`, `_bracket_matching_quotes()`, `_convert_quote_direction()`

**Quote-nesting algorithm (bracket matching):**
- Stack of open quote chars; encounter quote → search stack for matching type
- No match → OPEN (push, depth = stack size)
- Match found → CLOSE (pop, depth = stack size after pop)
- Supports nested different-type quotes: `"outer `inner` text"` → depths [1, 2, 2, 1]

**Hard to port:**
- spaCy integration — use NLTagger instead; lazy loading of large model
- Abbreviation merging (`_merge_abbreviation_tokens`) — keep simple heuristics

---

### `vocab.py` — Phoneme Inventory & Encoding
**Purpose:** Kokoro vocabulary mapping (phoneme/punct ↔ token ID) and validation.

**Public API:**
- `encode(text: str, add_spaces: bool, model: str) -> list[int]` — phoneme string → token IDs
- `decode(indices: list[int], skip_special: bool, model: str) -> str` — token IDs → phoneme string
- `validate_for_kokoro(text: str, model: str) -> tuple[bool, list[str]]` — check validity
- `filter_for_kokoro(text: str, replacement: str, model: str) -> str` — remove invalid chars
- Constants: `US_ENGLISH_PHONEMES`, `GB_ENGLISH_PHONEMES`, `PUNCTUATION`, `N_TOKENS=178`
- Functions: `get_vocab()`, `get_vocab_reverse()`, `phonemes_to_ids()`, `ids_to_phonemes()`

**Phoneme sets:**
```python
US_VOWELS = "AIOWYiuæɑɔəɛɜɪʊʌᵻ"  # 18
US_CONSONANTS = "bdfhjklmnpstvwzðŋɡɹɾʃʒʤʧθ"  # 23
GB_VOWELS = "aAIQWYiuɑɒɔəɛɜɪʊʌ"  # Q instead of O
STRESS = "ˈˌ"
```

---

## CRITICAL INVARIANTS FOR THE SWIFT PORT

1. **Span offset semantics:** `GToken.start_ts/end_ts` (or char positions) must map exactly to source text. After normalization, update spans to match normalized indices. Unicode handling required (multi-byte chars).

2. **_grow_dictionary capitalization rule:** For each lowercase entry, add titlecase variant if not already present; for titlecase entries, add lowercase variant. Enables "Hello" → lookup "hello" → "HELLO" NNP fallback → spell-out.

3. **POS fallback order:** Try exact tag → `get_parent_tag()` (VB* → VERB, NN* → NOUN, etc.) → DEFAULT. Do NOT skip steps; order matters for phoneme quality (e.g., "read" as VB vs. VBD).

4. **Reverse processing (context):** Process tokens **in reverse** to detect future-vowel (for "to", "the" reduction) and future-to (for "used" VBD). Context must propagate backward.

5. **Stress mark convention:** Use `ˈ` (U+02C8) for primary, `ˌ` (U+02CC) for secondary. Never mix with combining diacritics; always preface vowel.

6. **Normalization order:** Time/temp → abbrev → apostrophe → quote → ellipsis → dash. No reordering; earlier rules enable later ones (e.g., abbrev expander depends on apostrophe normalization).

7. **Special cases (high priority):** "a"/"the"/"to"/"in"/"am" have context-sensitive schwas/reductions. Check special_case() BEFORE general lookup; bypass suffix handling for these words.

8. **Rating system:** Gold=4, Silver=3, Suffix=2–3. Use rating to prefer lexicon over fallback; missing rating → Unknown (don't guess).

9. **Proper noun NNP fallback:** If word is all-caps or capitalized but not in lexicon and tag=NNP, spell letter-by-letter (A→ə, B→bē, etc.) with PRIMARY_STRESS on last letter. Only fallback if no stress found in normal lookup.

10. **Abbreviation longest-first + context:** Expand abbrevs sorted by length (longest first) to avoid "Ph." matching within "Ph.D.". Use context (surrounding text) to disambiguate (e.g., "St." as Street vs. Saint based on house number or saint name).

11. **Quote nesting (bracket matching):** Maintain stack of open quote chars. Different-type quotes can nest; same-type quotes alternate (open/close pairs). Assign quote_depth as nesting level for later directionality conversion.

12. **Unicode normalization:** Apply NFKC to input; normalize numeric chars (Unicode digits → ASCII); replace Greek letters (α → "alpha") BEFORE lexicon lookup. Preserve apostrophe variants until apostrophe normalization phase.

13. **No espeak/goruut fallback in Swift port:** OOV words → return None/UNK marker. Do not attempt to call external tools; keep module pure and offline.

14. **Phoneme validation:** All output must match Kokoro vocab (178 tokens). Validate during lookup; filter invalid chars (or warn/error) before returning.

15. **Contraction preservation:** Apostrophes inside words ("don't", "y'all") are NOT quotes and must NOT be normalized away. Mark as contractions early; only normalize/expand quote-like apostrophes at word boundaries.

---

## Module Dependency Graph

```
EnglishG2P
  ├─ Normalizer (EnglishNormalizer, abbreviations.get_expander)
  ├─ Lexicon (gold + silver dicts)
  ├─ Fallback (EspeakFallback – NOT PORTED)
  ├─ Tokenizer (RegexTokenizer or SpacyTokenizer)
  └─ Token (GToken)

Lexicon
  ├─ numbers.NumberConverter (num2words – see note)
  └─ vocab (phoneme validation)

Tokenizer
  ├─ ProcessingToken (pipeline/models)
  └─ abbreviations.merge (abbreviation merging)

Normalizer
  ├─ NormalizationRule (pipeline/normalizer)
  └─ abbreviations.Expander

Punctuation
  └─ MarkIndex, Position (for preserve/restore)
```

---

## Dead Code / Out-of-Scope

- **`fallback.py` (EspeakFallback, GoruutFallback):** NOT ported. Swift will accept UNK for OOV.
- **`numbers.py` → `num2words`:** Not ported. If needed, hardcode common English number words; skip complex multi-thousand support.
- **spaCy integration:** Replace with NLTagger (macOS/iOS). Remove lazy `nlp` property; use pre-cached tagger or offline model.
- **Context detection heuristics in abbreviations:** Simplify for Swift (fewer saint/city names); keep core logic (place number pattern, time indicators).

---

## Key Porting Notes

- Use **Swift regex literals** (`#"pattern"#`) instead of `re.compile()`
- Store dicts (gold, silver, abbreviations) as **JSON or plist** for embedded use
- Implement lazy initialization via Swift properties with `?`
- Use `NSRange` / `String.Index` for position tracking (careful with Unicode)
- Port stress application algorithm (`apply_stress()`) exactly; it's critical
- Test on **minimal corpus** first (10–50 words) to validate POS tagging & suffix handling

