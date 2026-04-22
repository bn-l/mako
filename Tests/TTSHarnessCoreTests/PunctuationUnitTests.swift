import Foundation
import Testing
@testable import TTSHarnessCore

/// Unit tests for `KokoroPunctuation.normalize`. Each rule is covered in
/// isolation so a regression surfaces as a pointed message rather than a
/// golden break.
@Suite("KokoroPunctuation")
struct KokoroPunctuationTests {

    @Test("Curly double quotes are preserved (both are in kokoroMarks)")
    func curlyDoubleQuotesPreserved() {
        // 201C/201D are native to Kokoro's vocabulary — they survive
        // normalization intact; only the exotic quote family (201A etc.)
        // folds to ASCII.
        let input = "\u{201C}hello\u{201D}"
        #expect(KokoroPunctuation.normalize(input) == input)
    }

    @Test("Exotic double quotes fold to ASCII quote")
    func exoticDoubleQuotes() {
        // 201E (low-9 double quote) is not in kokoroMarks → folds to ".
        #expect(KokoroPunctuation.normalize("\u{201E}hi\u{201C}") == "\"hi\u{201C}")
    }

    @Test("Curly single quotes fold to ASCII apostrophe")
    func curlySingleQuotes() {
        #expect(KokoroPunctuation.normalize("don\u{2019}t") == "don't")
    }

    @Test("En-dash folds to em-dash")
    func enDashToEm() {
        #expect(KokoroPunctuation.normalize("a\u{2013}b") == "a\u{2014}b")
    }

    @Test("Three dots collapse to ellipsis")
    func threeDotsToEllipsis() {
        #expect(KokoroPunctuation.normalize("wait...") == "wait\u{2026}")
    }

    @Test("Spaced dots collapse to ellipsis")
    func spacedDotsToEllipsis() {
        #expect(KokoroPunctuation.normalize("wait . . . here") == "wait\u{2026}here")
    }

    @Test("Double hyphen collapses to em-dash")
    func doubleHyphenToEmDash() {
        #expect(KokoroPunctuation.normalize("yes--no") == "yes\u{2014}no")
    }

    @Test("Spaced single hyphen collapses to spaced em-dash")
    func spacedHyphenToSpacedEmDash() {
        #expect(KokoroPunctuation.normalize("yes - no") == "yes \u{2014} no")
    }

    @Test("Multiplication sign is preserved as ASCII x for downstream dim wrapper")
    func multiplicationSignToX() {
        #expect(KokoroPunctuation.normalize("8.5\u{00D7}11") == "8.5x11")
    }

    @Test("Brackets fold to parentheses")
    func bracketsToParens() {
        #expect(KokoroPunctuation.normalize("a[b]c{d}e") == "a(b)c(d)e")
    }

    @Test("Fullwidth comma folds to ASCII comma")
    func fullwidthComma() {
        #expect(KokoroPunctuation.normalize("a\u{FF0C}b") == "a,b")
    }

    @Test("Inverted ! folds to !")
    func invertedBang() {
        #expect(KokoroPunctuation.normalize("\u{00A1}hola!") == "!hola!")
    }

    @Test("Output contains only characters in kokoroMarks or alphanumerics/space")
    func outputStaysWithinVocabulary() {
        let input = "\u{201C}Wait\u{2026}\u{201D} said O\u{2019}Brien \u{2013} yes."
        let out = KokoroPunctuation.normalize(input)
        for ch in out where !ch.isLetter && !ch.isNumber && !ch.isWhitespace && ch != "'" {
            #expect(
                KokoroPunctuation.kokoroMarks.contains(ch),
                "unexpected punctuation '\(ch)' survived normalization"
            )
        }
    }

    @Test("Pure ASCII passage is a no-op")
    func asciiIsNoOp() {
        let s = "Hello, world! A test."
        #expect(KokoroPunctuation.normalize(s) == s)
    }

    @Test("Decorative noise glyphs collapse to spaces")
    func decorativeCollapseToSpace() {
        // U+2022 BULLET is in the `remove` set → space.
        let out = KokoroPunctuation.normalize("a\u{2022}b")
        #expect(out == "a b")
    }
}
