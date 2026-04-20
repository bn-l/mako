import Foundation
import NaturalLanguage

/// Swift port of `kokorog2p/tokenization.py`. Produces offset-aware
/// `[GToken]` with a strict round-trip contract: concatenating each
/// token's `sourceRange` substring (in order) reconstructs the original
/// text modulo inter-token whitespace.
///
/// Boundary rules mirror kokorog2p's regex (which implements spaCy's
/// `custom_tokenizer` overrides faithfully):
///   - hyphenated compounds are ONE token (`state-of-the-art`)
///   - contractions are ONE token (`don't`, `I'd've`, `O'Malley`)
///   - every other non-word/non-space character is its own token
///   - whitespace is NOT tokenized; it's captured in the preceding
///     token's `trailingWhitespace`
///
/// An abbreviation-aware merge pass collapses `Dr` + `.` → `Dr.` (and
/// multi-period acronyms like `U.S.A.`) when the combined surface is a
/// known `KokoroAbbreviations` entry.
///
/// POS tagging is optional. When enabled, each word-token's `tag` is
/// filled from `NLTagger.tag(at:unit:scheme:)` against the lexical-class
/// scheme. Punctuation tokens keep the empty string.
public enum KokoroTokenizer {

    // Match order mirrors upstream: hyphenated compound, contraction,
    // bare word, non-word non-space, whitespace. ICU Unicode classes
    // cover accented letters so `Châteauneuf` tokenizes as one word.
    private static let tokenPattern: NSRegularExpression = {
        let word = "[\\p{L}\\p{M}\\p{N}_]+"
        let pattern =
            "(\(word)(?:-\(word))+)"
            + "|(\(word)(?:'\(word))+)"
            + "|(\(word))"
            + "|([^\\p{L}\\p{M}\\p{N}\\s_])"
            + "|(\\s+)"
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Tokenize `text` into `[GToken]`. When `posTag` is true, each
    /// word token is annotated with its NLTag lexical class.
    public static func tokenize(_ text: String, posTag: Bool = true) -> [GToken] {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = tokenPattern.matches(in: text, range: fullRange)

        // Pass 1: build raw tokens with trailing-whitespace capture.
        var raw: [GToken] = []
        raw.reserveCapacity(matches.count)
        var pendingWhitespace = ""
        for match in matches {
            let slice = ns.substring(with: match.range)
            // Group 5 is whitespace — attach to previous token.
            if match.range(at: 5).location != NSNotFound {
                pendingWhitespace += slice
                continue
            }
            if !pendingWhitespace.isEmpty, let last = raw.popLast() {
                var updated = last
                updated.trailingWhitespace = pendingWhitespace
                raw.append(updated)
                pendingWhitespace = ""
            }
            raw.append(GToken(text: slice, sourceRange: match.range))
        }
        if !pendingWhitespace.isEmpty, let last = raw.popLast() {
            var updated = last
            updated.trailingWhitespace = pendingWhitespace
            raw.append(updated)
        }

        let merged = mergeAbbreviations(raw, in: ns)
        guard posTag else { return merged }
        return annotatePOS(merged, source: text)
    }

    // MARK: - Abbreviation merge

    /// Surface → caseSensitive map, built once per process from
    /// `KokoroAbbreviations.surfaceForms`. Longest abbreviation length
    /// caps the look-ahead window.
    private static let abbreviationIndex: (caseSensitive: Set<String>, caseInsensitive: Set<String>, maxCount: Int) = {
        var cs = Set<String>()
        var ci = Set<String>()
        var maxLen = 0
        for (surface, isCaseSensitive) in KokoroAbbreviations.surfaceForms {
            if isCaseSensitive {
                cs.insert(surface)
            } else {
                ci.insert(surface.lowercased())
            }
            if surface.count > maxLen { maxLen = surface.count }
        }
        return (cs, ci, maxLen)
    }()

    /// Collapse consecutive tokens whose combined surface is a known
    /// abbreviation. Only merges when the tokens are directly adjacent
    /// (no whitespace between them, except when the abbreviation itself
    /// contains whitespace — which today's table never does).
    private static func mergeAbbreviations(_ tokens: [GToken], in ns: NSString) -> [GToken] {
        let (cs, ci, maxLen) = abbreviationIndex
        guard maxLen > 0, tokens.count >= 2 else { return tokens }

        var merged: [GToken] = []
        merged.reserveCapacity(tokens.count)
        var i = 0
        while i < tokens.count {
            var bestEnd: Int? = nil
            var bestText: String? = nil
            var combined = ""
            var lastEnd = tokens[i].sourceRange.location + tokens[i].sourceRange.length
            for j in i..<tokens.count {
                if j > i {
                    // Non-contiguous tokens (any whitespace or gap)
                    // end the candidate. Abbreviations in our table
                    // are always contiguous in the source.
                    if tokens[j].sourceRange.location != lastEnd { break }
                }
                combined += tokens[j].text
                lastEnd = tokens[j].sourceRange.location + tokens[j].sourceRange.length
                if combined.count > maxLen { break }
                if cs.contains(combined) || ci.contains(combined.lowercased()) {
                    bestEnd = j
                    bestText = combined
                }
            }
            if let end = bestEnd, end > i, let mergedText = bestText {
                let startRange = tokens[i].sourceRange
                let endRange = tokens[end].sourceRange
                let span = NSRange(
                    location: startRange.location,
                    length: endRange.location + endRange.length - startRange.location
                )
                merged.append(GToken(
                    text: mergedText,
                    sourceRange: span,
                    tag: "",
                    trailingWhitespace: tokens[end].trailingWhitespace
                ))
                i = end + 1
                continue
            }
            merged.append(tokens[i])
            i += 1
        }
        _ = ns  // kept for symmetry with Python signature; no slice needed
        return merged
    }

    // MARK: - POS tagging

    private static func annotatePOS(_ tokens: [GToken], source: String) -> [GToken] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = source
        return tokens.map { token in
            guard token.isWord else { return token }
            // Tag at the token's start position — NLTagger returns the
            // word-level tag covering that index.
            guard let startIdx = Range(token.sourceRange, in: source)?.lowerBound,
                let (tag, _) = Optional(tagger.tag(
                    at: startIdx, unit: .word, scheme: .lexicalClass
                )),
                let tagValue = tag?.rawValue
            else {
                return token
            }
            var updated = token
            updated.tag = tagValue
            return updated
        }
    }
}
