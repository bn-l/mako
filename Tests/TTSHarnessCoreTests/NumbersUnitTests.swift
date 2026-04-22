import Foundation
import Testing
@testable import TTSHarnessCore

/// Unit tests for `KokoroNumbers`. The public `expand` pathway is
/// exercised heavily through `NormalizerOutputTests`; this suite pins the
/// internal helpers (cardinal/ordinal/year/decimal) and probes edge cases
/// of individual wrappers in isolation — hypothesis-style coverage that
/// doesn't require rebuilding a golden on every change.
@Suite("KokoroNumbers — cardinal")
struct KokoroNumbersCardinalTests {
    @Test(arguments: [
        (0, "zero"),
        (1, "one"),
        (19, "nineteen"),
        (20, "twenty"),
        (21, "twenty one"),
        (99, "ninety nine"),
        (100, "one hundred"),
        (101, "one hundred one"),
        (999, "nine hundred ninety nine"),
        (1_000, "one thousand"),
        (1_234, "one thousand two hundred thirty four"),
        (1_000_000, "one million"),
        (1_234_567, "one million two hundred thirty four thousand five hundred sixty seven"),
    ])
    func cardinalMatches(n: Int, expected: String) {
        #expect(KokoroNumbers.cardinal(n) == expected)
    }

    @Test("Negative numbers prefix with 'minus'")
    func negative() {
        #expect(KokoroNumbers.cardinal(-5) == "minus five")
        #expect(KokoroNumbers.cardinal(-123) == "minus one hundred twenty three")
    }
}

@Suite("KokoroNumbers — ordinal")
struct KokoroNumbersOrdinalTests {
    @Test(arguments: [
        (1, "first"),
        (2, "second"),
        (3, "third"),
        (4, "fourth"),
        (5, "fifth"),
        (9, "ninth"),
        (12, "twelfth"),
        (20, "twentieth"),
        (21, "twenty first"),
        (23, "twenty third"),
        (100, "one hundredth"),
        (101, "one hundred first"),
    ])
    func ordinalMatches(n: Int, expected: String) {
        #expect(KokoroNumbers.ordinal(n) == expected)
    }
}

@Suite("KokoroNumbers — year")
struct KokoroNumbersYearTests {
    @Test(arguments: [
        (1900, "nineteen hundred"),
        (1905, "nineteen oh five"),
        (1999, "nineteen ninety nine"),
        // 2000 reads as "twenty hundred" via the centuries rule — the
        // 2000s "two thousand N" form only kicks in for 2001..2009 where
        // the tens digit is zero AND the ones digit is non-zero.
        (2000, "twenty hundred"),
        (2001, "two thousand one"),
        (2009, "two thousand nine"),
        (2010, "twenty ten"),
        (2026, "twenty twenty six"),
    ])
    func yearMatches(n: Int, expected: String) {
        #expect(KokoroNumbers.year(n) == expected)
    }

    @Test("Outside 1100..9999 falls back to cardinal")
    func outOfRangeFallsBack() {
        #expect(KokoroNumbers.year(500) == "five hundred")
        #expect(KokoroNumbers.year(1099) == "one thousand ninety nine")
    }
}

@Suite("KokoroNumbers — decimal")
struct KokoroNumbersDecimalTests {
    @Test("3.14 → 'three point one four'")
    func pi() {
        #expect(KokoroNumbers.decimal("3.14") == "three point one four")
    }

    @Test("Leading zero preserved: 0.5 → 'zero point five'")
    func leadingZero() {
        #expect(KokoroNumbers.decimal("0.5") == "zero point five")
    }

    @Test("Empty integer part: .5 → 'point five'")
    func impliedZero() {
        #expect(KokoroNumbers.decimal(".5") == "point five")
    }

    @Test("Non-decimal input returns input unchanged")
    func notADecimal() {
        #expect(KokoroNumbers.decimal("42") == "42")
    }
}

@Suite("KokoroNumbers — expand")
struct KokoroNumbersExpandTests {
    @Test("Money with cents")
    func moneyWithCents() {
        let out = KokoroNumbers.expand("$1.50")
        #expect(out.contains(#"alias="one dollar and fifty cents""#))
    }

    @Test("Money with 1 cent singular")
    func oneCentSingular() {
        let out = KokoroNumbers.expand("$1.01")
        #expect(out.contains("and one cent"))
    }

    @Test("Dimensions accept ASCII x")
    func dimensionsAscii() {
        let out = KokoroNumbers.expand("8.5x11 paper")
        #expect(out.contains(#"alias="eight point five by eleven""#))
    }

    @Test("Dimensions accept multiplication sign")
    func dimensionsMult() {
        let out = KokoroNumbers.expand("8.5\u{00D7}11 paper")
        #expect(out.contains(#"alias="eight point five by eleven""#))
    }

    @Test("Roman numeral gated by cue word")
    func romanNumeralWithCue() {
        let out = KokoroNumbers.expand("Chapter IV begins.")
        #expect(out.contains(#"alias="four""#))
    }

    @Test("Bare Roman-looking string without cue stays untouched")
    func bareRomanStaysUntouched() {
        let out = KokoroNumbers.expand("I am here.")
        #expect(out == "I am here.")
    }

    @Test("Percentage expands")
    func percentageExpands() {
        let out = KokoroNumbers.expand("60%")
        #expect(out.contains(#"alias="sixty percent""#))
    }

    @Test("Fraction expands")
    func fractionExpands() {
        let out = KokoroNumbers.expand("She scored 8/10.")
        #expect(out.contains(#"alias="eight out of ten""#))
    }
}
