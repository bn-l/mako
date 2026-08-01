r"""Sentence chunking for the TTS generation scripts.

Every chunk returned here is a verbatim slice of the input. That matters because a
naive `[.!?]` split corrupts the very text these passages exist to test: `2.7`
becomes `2. 7`, `A.I.` becomes `A. I.`, `9:30 a.m.` becomes `9:30 a. m.`.

Three guards, all established elsewhere in this repo rather than invented here:

1. A boundary requires whitespace *after* the punctuation — the guard
   `SupertonicTokenizer.chunk` uses (`term.contains(s.value) && isWs(cps[i+1])`).
   This alone protects decimals and the interior dots of initialisms.
2. Dotted abbreviations come from `KokoroAbbreviations.swift`'s curated entry
   table (174 dotted surfaces: Mr. Dr. a.m. U.S.A. …), read at runtime so this
   script cannot drift from mako's list. That table is the source of truth.
3. Single-letter initials (`A.I.`, `E.T.A.`) mirror upstream Supertonic's own
   sentence-splitter guard, `(?<!\b[A-Z]\.)`.

Where a period is ambiguous we prefer *not* to split. Under-splitting only makes a
chunk longer; a wrong split changes what is spoken.

    python scripts/tts-gen/chunking.py     # round-trip self-test over the passages
"""

import logging
import re
from pathlib import Path

log = logging.getLogger(__name__)

ABBREVIATIONS_SWIFT = (
    Path(__file__).resolve().parents[2] / "Sources/TTSHarnessCore/KokoroAbbreviations.swift"
)

# Sentence punctuation plus any closing quote/bracket (group 1), then the whitespace
# separating it from the next sentence (group 2). Closers belong to group 1 so they stay
# attached to the sentence they end — otherwise `"working well."` loses its quote.
BOUNDARY = re.compile(r'([.!?]+["\')\]]*)(\s+)')

# Fallback if the Swift table can't be read. Deliberately minimal: the real list is
# mako's, and a silent divergence is worse than an obviously partial stopgap.
FALLBACK_ABBREVIATIONS = ["Mr.", "Mrs.", "Ms.", "Dr.", "Prof.", "St.", "a.m.", "p.m.", "etc."]


def load_abbreviations():
    """Dotted abbreviation surfaces from KokoroAbbreviations.swift."""
    try:
        source = ABBREVIATIONS_SWIFT.read_text(encoding="utf-8")
    except OSError:
        log.warning("cannot read %s; using fallback abbreviations", ABBREVIATIONS_SWIFT)
        return FALLBACK_ABBREVIATIONS
    surfaces = []
    for surface in re.findall(r'AbbreviationEntry\(\s*"([^"]+)"', source):
        if "." in surface:
            surfaces.append(surface)
    if not surfaces:
        log.warning("no dotted entries parsed from %s; using fallback", ABBREVIATIONS_SWIFT)
        return FALLBACK_ABBREVIATIONS
    return surfaces


def build_not_a_boundary():
    """Regex matching text whose trailing '.' is not a sentence end."""
    alternatives = [r"\d", r"\b[A-Za-z]"]
    # Longest first so U.S.A. wins over U.S.; strip the final '.' since the pattern adds it.
    for surface in sorted(load_abbreviations(), key=len, reverse=True):
        alternatives.append(re.escape(surface[:-1]) if surface.endswith(".") else re.escape(surface))
    return re.compile(r"(?:" + "|".join(alternatives) + r")\.\s*$", re.IGNORECASE)


NOT_A_BOUNDARY = build_not_a_boundary()


def split_sentences(text):
    """Split into sentences, each a verbatim slice of `text`."""
    pieces = []
    start = 0
    for match in BOUNDARY.finditer(text):
        end = match.end(1)
        if end <= start:
            continue
        if NOT_A_BOUNDARY.search(text[start:end]):
            continue
        piece = text[start:end].strip()
        if piece:
            pieces.append(piece)
        start = match.end(2)
    tail = text[start:].strip()
    if tail:
        pieces.append(tail)
    return pieces


def chunk_text(text, limit):
    """Group sentences into <=limit-char chunks, splitting oversize ones on whitespace."""
    chunks = []
    current = ""
    for sentence in split_sentences(text):
        if len(sentence) > limit:
            if current:
                chunks.append(current)
                current = ""
            for word in sentence.split():
                if current and len(current) + len(word) + 1 > limit:
                    chunks.append(current)
                    current = ""
                current = f"{current} {word}".strip()
            continue
        if current and len(current) + len(sentence) + 1 > limit:
            chunks.append(current)
            current = ""
        current = f"{current} {sentence}".strip()
    if current:
        chunks.append(current)
    return chunks


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    print(f"loaded {len(load_abbreviations())} dotted abbreviations from {ABBREVIATIONS_SWIFT.name}")
    resources = Path(__file__).resolve().parents[2] / "Sources/TTSHarnessCore/Resources"
    for path in sorted(resources.glob("*.txt")):
        source = path.read_text(encoding="utf-8").strip()
        chunks = chunk_text(source, 300)
        # Whitespace-insensitive round trip: no character added, dropped or reordered.
        verdict = "ok" if " ".join(chunks).split() == source.split() else "MUTATED"
        longest = max(len(chunk) for chunk in chunks)
        print(f"{verdict:8} {path.name:18} {len(source):5d} chars -> {len(chunks):3d} chunks (max {longest})")
