import Foundation
import NaturalLanguage

/// Text preparation for the fish engine.
///
/// Fish needs almost none of the Kokoro pipeline. `KokoroG2P` resolves to Kokoro-vocab
/// phonemes, which are meaningless here, and the normalizer emits SSML that fish would
/// read out loud rather than interpret.
///
/// Whether it needs the *structural* normalization at all is an open question, which is
/// why `normalize` exists and defaults to off. Fish is an autoregressive model on a
/// Qwen3-omni backbone: unlike Kokoro it has read `$1,234.56` and `7:03 a.m.` in training,
/// and every render judged during the bakeoff — including the deliberately
/// number-heavy `itin` passage — went in as raw text. Turning the normalizer on is
/// offered for A/B comparison, not assumed to be better.
public enum FishText {
    /// Fish takes `[tag]` markers inline. They are ordinary text to the model, not
    /// control tokens — S2 was trained on transcripts containing these descriptions and
    /// learned the mapping — so an unrecognised one is silently spoken aloud. Stripping
    /// is the default for that reason; `--markers` is for text an LLM authored knowing
    /// the vocabulary.
    ///
    /// Bounded on purpose: an unterminated `[` in ordinary prose must not swallow the
    /// rest of the passage, and no real marker runs to 60 characters.
    private static let marker = try! NSRegularExpression(pattern: #"\[[^\]\n]{1,60}\]"#)

    /// Banned unconditionally, `--markers` or not. It is one of the tags that reliably
    /// works, which is exactly why a stray one from an LLM has to be caught here rather
    /// than discovered in the audio.
    ///
    /// Word-bounded: an unbounded `sigh` also matches inside `insightful` and
    /// `sight unseen`, and silently deleting a legitimate marker is its own bug.
    private static let sigh = try! NSRegularExpression(
        pattern: #"\[[^\]\n]{0,55}\bsigh(?:s|ing|ed)?\b[^\]\n]{0,55}\]"#
            + #"|\(sigh(?:s|ing|ed)?\)"#,
        options: [.caseInsensitive])

    private static let runsOfSpaces = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)

    /// Full preparation: markers, structural normalization, then segmentation into
    /// blank-line-separated turns the sidecar can tag one-per-paragraph.
    public static func prepare(
        _ text: String, keepMarkers: Bool, normalize: Bool, maxTurnBytes: Int
    ) -> String {
        var out = stripMarkers(text, keepMarkers: keepMarkers)
        if normalize {
            out = flattenAliases(KokoroSSMLNormalizer.compensatorsOnly(out))
        }
        return segment(out, maxTurnBytes: maxTurnBytes).joined(separator: "\n\n")
    }

    /// The normalizer emits `<sub alias="one thousand dollars">$1,000</sub>`, because
    /// Kokoro's downstream layer consumes SSML. Fish has no idea what that is and would
    /// read the markup out loud, so the span collapses to its alias — the spoken form,
    /// which is the whole point of running the normalizer in the first place.
    ///
    /// The whole of `compensatorsOnly` runs, not a hand-picked pair of stages: its order
    /// is load-bearing. `wrapTimeMeridiem` has to claim `7:03 a.m.` before
    /// `KokoroNumbers` reaches it, or the ratio handler reads it as "seven to three".
    static func flattenAliases(_ text: String) -> String {
        let flattened = aliasSpan.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        // `KokoroAbbreviations` appends `. …` to a sentence-final dotted acronym as a cue
        // to Kokoro's prosody layer. To fish that is just an ellipsis, and an unasked-for
        // pause in the middle of a passage.
        return flattened.replacingOccurrences(of: ". …", with: ".")
    }

    private static let aliasSpan = try! NSRegularExpression(
        pattern: #"<sub alias="([^"]*)">[^<]*</sub>"#)

    public static func stripMarkers(_ text: String, keepMarkers: Bool) -> String {
        let range = { (s: String) in NSRange(s.startIndex..., in: s) }
        var out = sigh.stringByReplacingMatches(
            in: text, range: range(text), withTemplate: "")
        if !keepMarkers {
            out = marker.stringByReplacingMatches(
                in: out, range: range(out), withTemplate: "")
        }
        out = runsOfSpaces.stringByReplacingMatches(
            in: out, range: range(out), withTemplate: " ")
        return out
            .replacingOccurrences(of: " \n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split into turns, guaranteeing none exceeds `maxTurnBytes`.
    ///
    /// A paragraph is the right unit: each `<|speaker:0|>` marks a conversational turn,
    /// and tagging per sentence made renders sound like the recording stopped and
    /// restarted between sentences. But the size cap is not optional — fish's
    /// `group_turns_into_batches` refuses to split a single oversized turn, and
    /// `max_tokens` then truncates that batch mid-sentence, silently dropping the rest of
    /// the paragraph. So long paragraphs get subdivided here, at sentence boundaries,
    /// which is the least-bad place to put a seam.
    public static func segment(_ text: String, maxTurnBytes: Int) -> [String] {
        var turns: [String] = []
        for block in text.components(separatedBy: blankLine) {
            let paragraph = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paragraph.isEmpty else { continue }
            if paragraph.utf8.count <= maxTurnBytes {
                turns.append(paragraph)
            } else {
                turns.append(contentsOf: pack(sentences(of: paragraph), limit: maxTurnBytes))
            }
        }
        return turns
    }

    private static let blankLine = try! NSRegularExpression(pattern: #"\n\s*\n"#)

    /// `NLTokenizer` rather than a hand-rolled `[.!?]` split: Apple's sentence tokenizer
    /// already knows that `Dr.`, `a.m.` and `2.7` are not sentence ends, and this repo
    /// has been bitten by naive splitting before.
    private static func sentences(of paragraph: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = paragraph
        var pieces: [String] = []
        tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
            let piece = paragraph[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            return true
        }
        return pieces.isEmpty ? [paragraph] : pieces
    }

    /// Greedy packing. A single sentence over the limit falls back to packing words —
    /// rare, and still better than handing fish a turn it will truncate.
    private static func pack(_ pieces: [String], limit: Int) -> [String] {
        var packed: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { packed.append(current); current = "" }
        }
        func add(_ piece: String, joinedBy separator: String) {
            if current.isEmpty {
                current = piece
            } else if current.utf8.count + separator.utf8.count + piece.utf8.count <= limit {
                current += separator + piece
            } else {
                flush()
                current = piece
            }
        }
        for piece in pieces {
            if piece.utf8.count > limit {
                flush()
                for word in piece.split(separator: " ") {
                    add(String(word), joinedBy: " ")
                }
                flush()
                continue
            }
            add(piece, joinedBy: " ")
        }
        flush()
        return packed
    }
}

private extension String {
    func components(separatedBy pattern: NSRegularExpression) -> [String] {
        let marked = pattern.stringByReplacingMatches(
            in: self, range: NSRange(startIndex..., in: self), withTemplate: "\u{0}")
        return marked.components(separatedBy: "\u{0}")
    }
}
