import Foundation

/// Swift port of `kokorog2p/token.py`. A `GToken` carries a word (or
/// punctuation unit), its span in the original input, optional POS tag,
/// and phoneme/rating slots populated later in the pipeline.
///
/// The key delta over upstream is `sourceRange`: kokorog2p infers
/// offsets from text scanning (see `tokenization.ensure_gtoken_positions`),
/// which breaks down on duplicate surface forms. We capture offsets at
/// tokenization time so every downstream override can key on the exact
/// source slice (checkpoint F).
public struct GToken: Sendable, Equatable {
    /// The token text as observed in the source. For punctuation this
    /// is the single character (possibly normalized — e.g. `…` in place
    /// of `...`).
    public let text: String

    /// NSRange into the original (pre-normalization) input string. For
    /// tokens whose `text` was produced by punctuation normalization
    /// (e.g. `…` for a `...` run), the range still points at the full
    /// un-normalized source slice.
    public let sourceRange: NSRange

    /// NLTag rawValue at the token's primary location (empty string
    /// when POS tagging is off). Populated by `KokoroTokenizer` using
    /// `NLTagger.tag(at:unit:scheme:)` against the lexical-class scheme.
    public var tag: String

    /// Whitespace that followed the token in the source (the string
    /// between this token's `sourceRange.upperBound` and the next
    /// token's `sourceRange.lowerBound`, or EOF). Preserving this
    /// lets Phase 7 reconstruct spacing when emitting markup.
    public var trailingWhitespace: String

    /// Phoneme string assigned later in the pipeline (Phase 7).
    public var phonemes: String?

    /// Per-token quality rating (higher is better), used when the
    /// resolver has multiple candidate sources.
    public var rating: Int?

    public init(
        text: String,
        sourceRange: NSRange,
        tag: String = "",
        trailingWhitespace: String = "",
        phonemes: String? = nil,
        rating: Int? = nil
    ) {
        self.text = text
        self.sourceRange = sourceRange
        self.tag = tag
        self.trailingWhitespace = trailingWhitespace
        self.phonemes = phonemes
        self.rating = rating
    }

    /// True when every character of `text` is in the Kokoro-supported
    /// punctuation set. Mirrors upstream `GToken.is_punctuation`.
    public var isPunctuation: Bool {
        !text.isEmpty && text.allSatisfy { KokoroPunctuation.kokoroMarks.contains($0) }
    }

    /// True when the token contains at least one letter or digit.
    public var isWord: Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
