"""Python-reference kittentts IPA + token-ID parity diff.

Upstream mini reference (`kittentts.onnx_model._prepare_inputs`) does:
  phonemes = phonemizer.backend.EspeakBackend(
      language="en-us", preserve_punctuation=True, with_stress=True
  ).phonemize([text])[0]
  phonemes = ' '.join(re.findall(r"\\w+|[^\\w\\s]", phonemes))
  tokens = TextCleaner()(phonemes)
  tokens = [0] + tokens + [10, 0]

For each chunk text recorded in outputs/reports/token-packing-trace.md
(our engine's post-normalization, pre-phonemize string), we reproduce the
upstream pipeline and diff IPA string + token ID sequence against what
our Swift engine produced.

Output: outputs/reports/ipa-ref-diff.md
"""

from __future__ import annotations

import os
import re
from pathlib import Path

import espeakng_loader  # noqa: F401 — must run before phonemizer import so lib path is set
from phonemizer.backend import EspeakBackend  # noqa: E402
from phonemizer.backend.espeak.wrapper import EspeakWrapper  # noqa: E402

EspeakWrapper.set_library(espeakng_loader.get_library_path())
os.environ["ESPEAK_DATA_PATH"] = espeakng_loader.get_data_path()

REPO = Path(__file__).resolve().parents[1]
TRACE = REPO / "outputs/reports/token-packing-trace.md"
OUT = REPO / "outputs/reports/ipa-ref-diff.md"

PAD = "$"
PUNCTUATION = ';:,.!?¡¿—…"«»"" '
LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
LETTERS_IPA = (
    "ɑɐɒæɓʙβɔɕçɗɖðʤəɘɚɛɜɝɞɟʄɡɠɢʛɦɧħɥʜɨɪʝɭɬɫɮʟɱɯɰŋɳɲɴøɵɸθœɶʘɹɺɾɻʀʁɽʂʃʈʧʉʊʋⱱʌɣɤʍχʎʏʑʐʒʔʡʕʢǀǁǂǃˈˌːˑʼʴʰʱʲʷˠˤ˞↓↑→↗↘'̩'ᵻ"
)
SYMBOL_INDEX = {
    ch: i for i, ch in enumerate(list(PAD + PUNCTUATION + LETTERS + LETTERS_IPA))
}


def upstream_encode(phonemes_joined: str) -> list[int]:
    """Mirrors upstream TextCleaner()(phonemes) + [0]+tokens+[10,0]."""
    body = [SYMBOL_INDEX[c] for c in phonemes_joined if c in SYMBOL_INDEX]
    return [0] + body + [10, 0]


def parse_trace(path: Path) -> list[dict[str, str]]:
    """Extract per-chunk {text, ipa, tokens} from the token-packing-trace report."""
    lines = path.read_text().splitlines()
    chunks: list[dict[str, str]] = []
    cur: dict[str, str] | None = None
    for ln in lines:
        if ln.startswith("### chunk "):
            cur = {}
            chunks.append(cur)
            continue
        if cur is None:
            continue
        m = re.match(r"^- \*\*(\w+)\*\*: `(.*)`$", ln)
        if not m:
            continue
        key, val = m.group(1), m.group(2)
        if key == "text":
            cur["text"] = val.strip().strip('"')
        elif key == "ipa":
            # Format: `"IPA string" (chars=X scalars=Y)`
            m2 = re.match(r'^"(.*)"\s*\(', val)
            cur["ipa"] = m2.group(1) if m2 else val
        elif key == "tokens":
            m2 = re.search(r":\s*(.*)$", val)
            cur["tokens"] = m2.group(1) if m2 else ""
    return chunks


backend = EspeakBackend(language="en-us", preserve_punctuation=True, with_stress=True)


def upstream_pipeline(text: str) -> tuple[str, list[int]]:
    raw_ipa = backend.phonemize([text])[0]
    tokenised = " ".join(re.findall(r"\w+|[^\w\s]", raw_ipa))
    tokens = upstream_encode(tokenised)
    return raw_ipa, tokens, tokenised


chunks = parse_trace(TRACE)

rows: list[dict[str, object]] = []
ipa_mismatches = 0
token_mismatches = 0
for idx, c in enumerate(chunks):
    ours_ipa = c.get("ipa", "")
    ours_tok_str = c.get("tokens", "")
    ours_tokens = [int(x) for x in ours_tok_str.split(",") if x.strip()]

    ref_ipa_raw, ref_tokens, ref_ipa_joined = upstream_pipeline(c.get("text", ""))
    ref_ipa_compact = ref_ipa_raw.strip()

    ipa_match = ours_ipa.strip() == ref_ipa_compact
    tok_match = ours_tokens == ref_tokens
    if not ipa_match:
        ipa_mismatches += 1
    if not tok_match:
        token_mismatches += 1

    first_diff_idx = -1
    first_diff_sym = ""
    if not ipa_match:
        for i, (a, b) in enumerate(zip(ours_ipa, ref_ipa_compact, strict=False)):
            if a != b:
                first_diff_idx = i
                first_diff_sym = f"ours={a!r} ref={b!r}"
                break
        else:
            first_diff_idx = min(len(ours_ipa), len(ref_ipa_compact))
            first_diff_sym = f"len diff ours={len(ours_ipa)} ref={len(ref_ipa_compact)}"

    rows.append({
        "idx": idx,
        "text": c.get("text", ""),
        "ours_ipa": ours_ipa,
        "ref_ipa": ref_ipa_compact,
        "ipa_match": ipa_match,
        "ours_tokens": ours_tokens,
        "ref_tokens": ref_tokens,
        "tok_match": tok_match,
        "first_diff_idx": first_diff_idx,
        "first_diff_sym": first_diff_sym,
    })

OUT.parent.mkdir(parents=True, exist_ok=True)
with OUT.open("w") as f:
    f.write("# IPA + token-ID parity diff vs upstream kittentts\n\n")
    f.write(
        "Reproduces upstream `KittenTTS_1_Onnx._prepare_inputs` "
        "(phonemizer.EspeakBackend en-us with_stress preserve_punctuation → "
        "basic_english_tokenize → TextCleaner → `[0] + tokens + [10, 0]`) and "
        "compares against the Swift engine's recorded IPA and token-ID sequence "
        "for the same chunk text.\n\n"
    )
    f.write(
        f"Chunks: {len(rows)} | IPA mismatches: {ipa_mismatches} | "
        f"Token mismatches: {token_mismatches}\n\n"
    )
    f.write("## Summary\n\n")
    f.write("| # | text | IPA match | Token match | first-diff |\n")
    f.write("|---|------|-----------|-------------|------------|\n")
    for r in rows:
        text = str(r["text"]).replace("|", "\\|")
        ipa = "✅" if r["ipa_match"] else "❌"
        tok = "✅" if r["tok_match"] else "❌"
        diff = "" if r["ipa_match"] else f"@{r['first_diff_idx']} {r['first_diff_sym']}"
        f.write(f"| {r['idx']} | {text} | {ipa} | {tok} | {diff} |\n")

    f.write("\n## Per-chunk detail\n\n")
    for r in rows:
        f.write(f"### chunk {r['idx']} — `{r['text']}`\n\n")
        f.write(f"- ours IPA: `{r['ours_ipa']}`\n")
        f.write(f"- ref  IPA: `{r['ref_ipa']}`\n")
        f.write(f"- IPA match: {r['ipa_match']}\n")
        if not r["ipa_match"]:
            f.write(f"  - first diff @ {r['first_diff_idx']}: {r['first_diff_sym']}\n")
        f.write(f"- ours tokens ({len(r['ours_tokens'])}): `{r['ours_tokens']}`\n")
        f.write(f"- ref  tokens ({len(r['ref_tokens'])}): `{r['ref_tokens']}`\n")
        f.write(f"- Token match: {r['tok_match']}\n\n")

print(f"Wrote {OUT} (chunks={len(rows)}, IPA mismatches={ipa_mismatches}, token mismatches={token_mismatches})")
