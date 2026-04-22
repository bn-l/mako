import Foundation
import Testing
@testable import TTSHarnessCore

/// Focused unit tests for `KokoroTokenizer`. The round-trip invariant is
/// already pinned in `TokenSpanTests`; this suite pins the boundary rules
/// one phrase at a time so a regression surfaces with a pointed diagnostic
/// rather than a passage-wide golden break.
@Suite("KokoroTokenizer")
struct KokoroTokenizerTests {

    private static func surfaces(_ text: String) -> [String] {
        KokoroTokenizer.tokenize(text, posTag: false).map(\.text)
    }

    @Test("Plain ASCII words split on whitespace")
    func plainWords() {
        #expect(Self.surfaces("hello world") == ["hello", "world"])
    }

    @Test("Punctuation is its own token")
    func punctuationIsSeparate() {
        #expect(Self.surfaces("hello, world!") == ["hello", ",", "world", "!"])
    }

    @Test("Hyphenated compound stays a single token")
    func hyphenatedCompoundSingleToken() {
        let s = Self.surfaces("state-of-the-art system")
        #expect(s == ["state-of-the-art", "system"])
    }

    @Test("Contraction stays a single token")
    func contractionSingleToken() {
        #expect(Self.surfaces("don't stop") == ["don't", "stop"])
    }

    @Test("Multi-apostrophe contraction stays a single token")
    func multiApostropheContraction() {
        #expect(Self.surfaces("I'd've known") == ["I'd've", "known"])
    }

    @Test("Celtic name stays a single token via apostrophe rule")
    func celticNameSingleToken() {
        #expect(Self.surfaces("O'Malley called") == ["O'Malley", "called"])
    }

    @Test("Abbreviation + period merge: Dr.")
    func abbreviationMergeDr() {
        #expect(Self.surfaces("Dr. Smith") == ["Dr.", "Smith"])
    }

    @Test("Multi-dot acronym merge: U.S.A.")
    func abbreviationMergeUSA() {
        #expect(Self.surfaces("U.S.A. wins") == ["U.S.A.", "wins"])
    }

    @Test("Ph.D. multi-dot merge")
    func abbreviationMergePhD() {
        #expect(Self.surfaces("A Ph.D. student") == ["A", "Ph.D.", "student"])
    }

    @Test("Whitespace is not tokenized; attaches to preceding token")
    func whitespaceAttaches() {
        let tokens = KokoroTokenizer.tokenize("foo bar", posTag: false)
        #expect(tokens.map(\.text) == ["foo", "bar"])
        #expect(tokens[0].trailingWhitespace == " ")
        #expect(tokens[1].trailingWhitespace == "")
    }

    @Test("Tab and newline collapse into trailing whitespace, not their own tokens")
    func mixedWhitespaceAttaches() {
        let tokens = KokoroTokenizer.tokenize("foo \t\nbar", posTag: false)
        #expect(tokens.map(\.text) == ["foo", "bar"])
        #expect(tokens[0].trailingWhitespace == " \t\n")
    }

    @Test("Accented letters stay within a single word token")
    func accentedLettersStayWithinWord() {
        #expect(Self.surfaces("Châteauneuf wines") == ["Châteauneuf", "wines"])
    }

    @Test("Digits are word tokens (non-alpha numerics)")
    func digitsAreWords() {
        #expect(Self.surfaces("room 12") == ["room", "12"])
    }

    @Test("Empty input returns no tokens")
    func emptyInput() {
        #expect(KokoroTokenizer.tokenize("", posTag: false).isEmpty)
    }

    @Test("Single punctuation mark tokenizes to itself")
    func lonePunctuation() {
        #expect(Self.surfaces("!") == ["!"])
    }

    @Test("sourceRange concatenation round-trip on an inline phrase")
    func sourceRangeRoundTrip() {
        let src = "Dr. Smith left."
        let tokens = KokoroTokenizer.tokenize(src, posTag: false)
        let ns = src as NSString
        let concatenated = tokens.map { ns.substring(with: $0.sourceRange) }.joined()
        let expected = src.filter { !$0.isWhitespace }
        #expect(concatenated == expected)
    }

    @Test("POS tagging fills a tag on word tokens when enabled")
    func posTagsWordsWhenEnabled() {
        let tokens = KokoroTokenizer.tokenize("The quick fox jumped.", posTag: true)
        let taggedWords = tokens.filter { $0.isWord && !$0.tag.isEmpty }
        #expect(!taggedWords.isEmpty, "POS tagging should fill at least one word tag")
    }
}
