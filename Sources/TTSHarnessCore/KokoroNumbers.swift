import Foundation

/// Structural number expansion for `KokoroSSMLNormalizer`. Pre-expands every
/// digit we claim into English words so FluidAudio's second preprocessing
/// pass sees no bare digits inside our `<sub alias>` output. Each entry
/// produces exactly one span; the alias is a sequence of space-separated
/// words (no hyphens — those can trigger FluidAudio's compound-word path).
///
/// Port of `kokorog2p/en/numbers.py`. Unlike upstream, we emit alias text
/// rather than IPA — phoneme emission is Phase 7.
public enum KokoroNumbers {
    public static func expand(_ text: String) -> String {
        var out = text
        // Sigil-bearing patterns first; each has a unique anchor.
        out = wrapMoney(out)
        out = wrapCurrency(out)
        out = wrapPercentages(out)
        out = wrapTemperatures(out)
        // Roman numerals gated by a noun cue ("Chapter V", "Volume III").
        // Runs before other number handlers — purely alphabetic, so no
        // interference with digit claims downstream.
        out = wrapRomanNumerals(out)
        // Dimensions (digit x|× digit) before units so `8.5×11 mg` (if
        // it ever appeared) isn't half-claimed by wrapUnits first.
        out = wrapDimensions(out)
        // Years (cue-word + 4-digit) before ranges, so "in 1999" reads as
        // a year and the range handler doesn't re-frame "1990–1999" as a
        // plain cardinal range.
        out = wrapYears(out)
        // Course codes (`<Subject> <3 digits>`) after years so
        // `September 2026` isn't confused with a 3-digit code.
        out = wrapCourseCodes(out)
        // Ranges (digit – digit) before units so `250–500 ms` is claimed
        // as one span with the trailing unit absorbed, not as two halves.
        out = wrapRanges(out)
        // Unit abbreviations (preceded by digits) — after ranges so units
        // that landed inside a range don't double-wrap.
        out = wrapUnits(out)
        // Score/fraction (N/M) after units so "3/4 mg" edge cases are
        // resolved as the score (no unit handler fires for /4 mg).
        out = wrapFractions(out)
        // Ratios after HH:MM clock times have already been claimed upstream.
        out = wrapRatios(out)
        // Ordinals (Nth, Nst, Nnd, Nrd).
        out = wrapOrdinals(out)
        return out
    }

    // MARK: - English cardinals / ordinals / years / decimals

    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven",
        "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
        "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = [
        "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
        "eighty", "ninety",
    ]
    private static let scales = ["", "thousand", "million", "billion", "trillion"]

    private static let ordinalSuffixMap: [String: String] = [
        "one": "first", "two": "second", "three": "third",
        "four": "fourth", "five": "fifth", "six": "sixth",
        "seven": "seventh", "eight": "eighth", "nine": "ninth",
        "ten": "tenth", "eleven": "eleventh", "twelve": "twelfth",
        "thirteen": "thirteenth", "fourteen": "fourteenth",
        "fifteen": "fifteenth", "sixteen": "sixteenth",
        "seventeen": "seventeenth", "eighteen": "eighteenth",
        "nineteen": "nineteenth",
        "twenty": "twentieth", "thirty": "thirtieth", "forty": "fortieth",
        "fifty": "fiftieth", "sixty": "sixtieth", "seventy": "seventieth",
        "eighty": "eightieth", "ninety": "ninetieth",
        "hundred": "hundredth", "thousand": "thousandth",
        "million": "millionth", "billion": "billionth",
        "trillion": "trillionth",
    ]

    static func cardinal(_ n: Int) -> String {
        if n < 0 { return "minus " + cardinal(-n) }
        if n < 20 { return ones[n] }
        if n < 100 {
            let t = n / 10
            let o = n % 10
            return o == 0 ? tens[t] : "\(tens[t]) \(ones[o])"
        }
        if n < 1000 {
            let h = n / 100
            let r = n % 100
            return r == 0 ? "\(ones[h]) hundred" : "\(ones[h]) hundred \(cardinal(r))"
        }
        var parts: [String] = []
        var num = n
        var scaleIdx = 0
        while num > 0 {
            let group = num % 1000
            if group > 0 && scaleIdx < scales.count {
                let groupWords = cardinal(group)
                let scale = scales[scaleIdx]
                parts.insert(scale.isEmpty ? groupWords : "\(groupWords) \(scale)", at: 0)
            }
            num /= 1000
            scaleIdx += 1
        }
        return parts.joined(separator: " ")
    }

    static func ordinal(_ n: Int) -> String {
        let cardinalStr = cardinal(n)
        let words = cardinalStr.split(separator: " ").map(String.init)
        guard let last = words.last else { return cardinalStr }
        let replacement = ordinalSuffixMap[last] ?? (last + "th")
        return (words.dropLast() + [replacement]).joined(separator: " ")
    }

    /// Four-digit year formatting: `1984` → "nineteen eighty four",
    /// `1900` → "nineteen hundred", `2001` → "two thousand one",
    /// `1905` → "nineteen oh five". Falls back to plain cardinal outside
    /// 1100..9999.
    static func year(_ n: Int) -> String {
        if n < 1100 || n > 9999 { return cardinal(n) }
        let high = n / 100
        let low = n % 100
        if low == 0 { return "\(cardinal(high)) hundred" }
        // 2000s like 2001, 2009 read naturally as "two thousand one" rather
        // than "twenty oh one".
        if high % 10 == 0 && low < 10 { return cardinal(n) }
        if low < 10 { return "\(cardinal(high)) oh \(cardinal(low))" }
        return "\(cardinal(high)) \(cardinal(low))"
    }

    /// Decimal fraction: "3.14" → "three point one four", ".5" → "point five".
    static func decimal(_ s: String) -> String {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return s }
        let intPart = parts[0].isEmpty ? "" : (Int(parts[0]).map { cardinal($0) } ?? parts[0])
        let fracDigits = parts[1].compactMap { c -> String? in
            guard let d = Int(String(c)) else { return nil }
            return cardinal(d)
        }
        let fracWords = fracDigits.joined(separator: " ")
        if intPart.isEmpty { return "point \(fracWords)" }
        return "\(intPart) point \(fracWords)"
    }

    /// Cardinal for an integer optionally written with thousands commas.
    /// "1,234" → "one thousand two hundred thirty four". Returns nil on
    /// parse failure.
    static func cardinalFromGrouped(_ s: String) -> String? {
        let stripped = s.replacingOccurrences(of: ",", with: "")
        guard let v = Int(stripped) else { return nil }
        return cardinal(v)
    }

    // MARK: - Money ($)

    /// `$1,234.56` / `$42` → `<sub alias="one thousand two hundred thirty four dollars and fifty six cents">$1,234.56</sub>`.
    private static func wrapMoney(_ text: String) -> String {
        let pattern = #"\$(\d{1,3}(?:,\d{3})*|\d+)(?:\.(\d{1,2}))?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            guard let r = Range(match.range, in: out),
                let dollars = cardinalFromGrouped(ns.substring(with: match.range(at: 1)))
            else { continue }
            let dollarsInt = Int(ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")) ?? 0
            let centsStr: String? = match.range(at: 2).location != NSNotFound
                ? ns.substring(with: match.range(at: 2))
                : nil
            let dollarUnit = dollarsInt == 1 ? "dollar" : "dollars"
            var alias = "\(dollars) \(dollarUnit)"
            if let c = centsStr, let cv = Int(c), cv > 0 {
                let centUnit = cv == 1 ? "cent" : "cents"
                alias += " and \(cardinal(cv)) \(centUnit)"
            }
            let source = String(out[r])
            out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(source)</sub>"#)
        }
        return out
    }

    // MARK: - Currency (£, €)

    private static func wrapCurrency(_ text: String) -> String {
        let currencies: [(symbol: String, singular: String, plural: String, subSingular: String, subPlural: String)] = [
            ("£", "pound", "pounds", "penny", "pence"),
            ("€", "euro", "euros", "cent", "cents"),
        ]
        var out = text
        for (symbol, singular, plural, subSing, subPlur) in currencies {
            let pattern = NSRegularExpression.escapedPattern(for: symbol)
                + #"(\d{1,3}(?:,\d{3})*|\d+)(?:\.(\d{1,2}))?"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = out as NSString
            let matches = re.matches(in: out, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard let r = Range(match.range, in: out),
                    let major = cardinalFromGrouped(ns.substring(with: match.range(at: 1)))
                else { continue }
                let majorInt = Int(ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")) ?? 0
                let centsStr: String? = match.range(at: 2).location != NSNotFound
                    ? ns.substring(with: match.range(at: 2))
                    : nil
                let majorUnit = majorInt == 1 ? singular : plural
                var alias = "\(major) \(majorUnit)"
                if let c = centsStr, let cv = Int(c), cv > 0 {
                    let minorUnit = cv == 1 ? subSing : subPlur
                    alias += " and \(cardinal(cv)) \(minorUnit)"
                }
                let source = String(out[r])
                out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(source)</sub>"#)
            }
        }
        return out
    }

    // MARK: - Percentages

    /// `60%` → "sixty percent", `3.14%` → "three point one four percent".
    private static func wrapPercentages(_ text: String) -> String {
        let pattern = #"(\d+)(?:\.(\d+))?%"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            guard let r = Range(match.range, in: out),
                let intVal = Int(ns.substring(with: match.range(at: 1)))
            else { continue }
            let alias: String
            if match.range(at: 2).location != NSNotFound {
                let frac = ns.substring(with: match.range(at: 2))
                let intWords = cardinal(intVal)
                let fracWords = frac.compactMap { Int(String($0)) }.map { cardinal($0) }.joined(separator: " ")
                alias = "\(intWords) point \(fracWords) percent"
            } else {
                alias = "\(cardinal(intVal)) percent"
            }
            let source = String(out[r])
            out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(source)</sub>"#)
        }
        return out
    }

    // MARK: - Temperatures

    /// `98°F` → "ninety eight degrees Fahrenheit", `22.5°C` → decimal form.
    /// Both `°` (U+00B0) and `º` (U+00BA ordinal-indicator) are accepted.
    private static func wrapTemperatures(_ text: String) -> String {
        let pattern = #"(\d+)(?:\.(\d+))?[°º]([FCK])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            guard let r = Range(match.range, in: out),
                let intVal = Int(ns.substring(with: match.range(at: 1)))
            else { continue }
            let unit = ns.substring(with: match.range(at: 3))
            let unitName: String = {
                switch unit {
                case "F": return "Fahrenheit"
                case "C": return "Celsius"
                case "K": return "Kelvin"
                default: return unit
                }
            }()
            let number: String
            if match.range(at: 2).location != NSNotFound {
                let frac = ns.substring(with: match.range(at: 2))
                let fracWords = frac.compactMap { Int(String($0)) }.map { cardinal($0) }.joined(separator: " ")
                number = "\(cardinal(intVal)) point \(fracWords)"
            } else {
                number = cardinal(intVal)
            }
            let alias = "\(number) degrees \(unitName)"
            let source = String(out[r])
            out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(source)</sub>"#)
        }
        return out
    }

    // MARK: - Unit abbreviations

    /// Short unit abbreviations after a digit. Digit AND unit expand into one
    /// span; the alias carries the digit as a word so FluidAudio's number
    /// expander finds nothing to do. Adjacency rule: the unit must follow a
    /// digit (optionally with one space), and must not be followed by a
    /// letter (so `mg` doesn't match the start of `magnesium`).
    ///
    /// Invariable units (Hz-family) are not pluralized.
    private static let unitAliases: [(abbreviation: String, singular: String, plural: String)] = [
        // Frequency (invariable).
        ("GHz", "gigahertz", "gigahertz"),
        ("MHz", "megahertz", "megahertz"),
        ("kHz", "kilohertz", "kilohertz"),
        ("Hz", "hertz", "hertz"),
        // Time.
        ("ms", "millisecond", "milliseconds"),
        // Mass.
        ("mg", "milligram", "milligrams"),
        ("kg", "kilogram", "kilograms"),
        ("lbs", "pounds", "pounds"),
        ("lb", "pound", "pounds"),
        ("oz", "ounce", "ounces"),
        // Volume / length.
        ("ml", "milliliter", "milliliters"),
        ("cm", "centimeter", "centimeters"),
        ("mm", "millimeter", "millimeters"),
        ("km", "kilometer", "kilometers"),
        // Compound phrases (invariable).
        ("mph", "miles per hour", "miles per hour"),
    ]

    private static func wrapUnits(_ text: String) -> String {
        var out = text
        for (abbrev, singular, plural) in unitAliases {
            let escaped = NSRegularExpression.escapedPattern(for: abbrev)
            // `<digits>` + optional single space + unit. The unit must not
            // be followed by an alphanumeric (so we don't grab `Hz` out of
            // `HzX`), and the digit run must not be preceded by another
            // digit (so `12mg` matches but `.12mg` doesn't re-claim the
            // tail of a decimal that money/currency handlers already took).
            let pattern = #"(?<![0-9A-Za-z<>])(\d+(?:,\d{3})*)(?:\.(\d+))?(\s?)"# + escaped + #"(?![A-Za-z0-9])"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = out as NSString
            let matches = re.matches(in: out, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                if insideExistingSub(match.range, in: out) { continue }
                guard let r = Range(match.range, in: out) else { continue }
                let intPart = ns.substring(with: match.range(at: 1))
                let intWords = cardinalFromGrouped(intPart) ?? intPart
                let intVal = Int(intPart.replacingOccurrences(of: ",", with: "")) ?? 0
                let numberWords: String
                let isPlural: Bool
                if match.range(at: 2).location != NSNotFound {
                    let fracPart = ns.substring(with: match.range(at: 2))
                    let fracWords = fracPart.compactMap { Int(String($0)) }.map { cardinal($0) }.joined(separator: " ")
                    numberWords = "\(intWords) point \(fracWords)"
                    isPlural = true  // any decimal is non-unit
                } else {
                    numberWords = intWords
                    isPlural = intVal != 1
                }
                // Attributive (singular) vs nominal (plural): "a 200 mg tube"
                // modifies a following noun, so English reads the unit
                // singular. "200 mg of liquid" / "200 mg per pill" / "200 mg."
                // stay nominal → plural. Rule: if the unit is followed by a
                // word that isn't `of`/`per`, treat it as attributive.
                let tailStart = match.range.location + match.range.length
                let attributive: Bool
                if tailStart < ns.length {
                    let tail = ns.substring(from: tailStart)
                    if let tailRe = try? NSRegularExpression(pattern: #"^\s+([A-Za-z]+)"#),
                       let tailMatch = tailRe.firstMatch(in: tail, range: NSRange(location: 0, length: (tail as NSString).length)) {
                        let nextWord = (tail as NSString).substring(with: tailMatch.range(at: 1)).lowercased()
                        attributive = (nextWord != "of" && nextWord != "per")
                    } else {
                        attributive = false
                    }
                } else {
                    attributive = false
                }
                let effectivePlural = isPlural && !attributive
                let unitWord = effectivePlural ? plural : singular
                let alias = "\(numberWords) \(unitWord)"
                let source = String(out[r])
                out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(source)</sub>"#)
            }
        }
        return out
    }

    // MARK: - Ratios

    /// Bare integer ratios (after `wrapTimes` has claimed HH:MM). Rewrites
    /// `2:1` → "two to one".
    private static func wrapRatios(_ text: String) -> String {
        let pattern = #"(?<![0-9A-Za-z:<>])(\d+):(\d+)(?![0-9:])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            if insideExistingSub(match.range, in: out) { continue }
            guard let r = Range(match.range, in: out),
                let left = Int(ns.substring(with: match.range(at: 1))),
                let right = Int(ns.substring(with: match.range(at: 2)))
            else { continue }
            let alias = "\(cardinal(left)) to \(cardinal(right))"
            let source = String(out[r])
            out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(source)</sub>"#)
        }
        return out
    }

    // MARK: - Claimed-span guard

    /// True if `range.location` falls between an unmatched `<sub`
    /// opener and its `</sub>` closer — i.e. the candidate digits
    /// are inside a span already claimed by an earlier wrapper.
    /// Prevents wrapUnits / wrapFractions / wrapRatios / wrapOrdinals
    /// from double-wrapping something wrapRanges or wrapYears already
    /// consumed.
    private static func insideExistingSub(_ range: NSRange, in text: String) -> Bool {
        guard range.location > 0, range.location <= (text as NSString).length else { return false }
        let head = (text as NSString).substring(with: NSRange(location: 0, length: range.location))
        let opens = head.components(separatedBy: "<sub").count - 1
        let closes = head.components(separatedBy: "</sub>").count - 1
        return opens > closes
    }

    // MARK: - Years

    /// Cue-word list that marks a following 4-digit integer as a year.
    /// Closed list — a linguistic class of date/time prepositions and
    /// copula phrasings. Any non-listed context keeps the integer out
    /// of the year handler, so bare `1999` in prose passes through and
    /// is read by whatever downstream handler later claims it.
    private static let yearCues: String =
        "in|since|by|before|after|around|circa|during|through|" +
        "until|till|year|of|from|between|until"

    private static let monthNames: String =
        "January|February|March|April|May|June|July|August|" +
        "September|October|November|December"

    /// Wrap 4-digit years when flanked by a date/time cue word or a
    /// month name. Only 1100–2099 are treated as year-formatted;
    /// anything outside that range falls through to plain cardinal.
    /// Decade form `1990s` → "nineteen nineties" is handled separately.
    private static func wrapYears(_ text: String) -> String {
        var out = text
        // Decade form first so "the 1990s" doesn't get eaten by cuedPattern.
        let decadePattern = #"\b((?:1[0-9]|20)\d{2})s\b"#
        out = applyYearPattern(out, pattern: decadePattern, isDecade: true)
        // Cue-word + year.
        let cuedPattern = #"\b(?:"# + yearCues + #")\s+((?:1[0-9]|20)\d{2})\b"#
        out = applyYearPattern(out, pattern: cuedPattern, isDecade: false)
        // Month name + year.
        let monthYearPattern = #"\b(?:"# + monthNames + #")\s+((?:1[0-9]|20)\d{2})\b"#
        out = applyYearPattern(out, pattern: monthYearPattern, isDecade: false)
        return out
    }

    private static func applyYearPattern(
        _ text: String, pattern: String, isDecade: Bool
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let yearRange = match.range(at: 1)
            guard let n = Int(ns.substring(with: yearRange)) else { continue }
            let alias: String
            let replaceRange: NSRange
            if isDecade {
                alias = pluralizeDecade(year(n))
                replaceRange = match.range
            } else {
                alias = year(n)
                replaceRange = yearRange
            }
            guard let r = Range(replaceRange, in: out) else { continue }
            let source = String(out[r])
            out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(source)</sub>"#)
        }
        return out
    }

    /// "nineteen ninety" → "nineteen nineties", "nineteen hundred" →
    /// "nineteen hundreds", "two thousand" → "two thousands". Applies
    /// English pluralization to the last word of a year reading.
    private static func pluralizeDecade(_ yearWords: String) -> String {
        let parts = yearWords.split(separator: " ").map(String.init)
        guard let last = parts.last else { return yearWords }
        let plural: String
        if last.hasSuffix("y") {
            plural = String(last.dropLast()) + "ies"
        } else {
            plural = last + "s"
        }
        return (parts.dropLast() + [plural]).joined(separator: " ")
    }

    // MARK: - Dimensions (AxB / A×B)

    /// `8.5×11` / `8.5x11` → "eight point five by eleven". Accepts
    /// both the multiplication sign `×` (U+00D7) and ASCII `x`, with
    /// optional surrounding whitespace. Restricted to digit-only or
    /// decimal operands so bare `x` inside a word isn't grabbed.
    private static func wrapDimensions(_ text: String) -> String {
        let pattern = #"(?<![0-9A-Za-z<>])(\d+(?:\.\d+)?)\s*[x×]\s*(\d+(?:\.\d+)?)(?![0-9A-Za-z])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let left = ns.substring(with: match.range(at: 1))
            let right = ns.substring(with: match.range(at: 2))
            let leftWords = left.contains(".") ? decimal(left) : (Int(left).map(cardinal) ?? left)
            let rightWords = right.contains(".") ? decimal(right) : (Int(right).map(cardinal) ?? right)
            let alias = "\(leftWords) by \(rightWords)"
            guard let r = Range(match.range, in: out) else { continue }
            let source = String(out[r])
            out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(source)</sub>"#)
        }
        return out
    }

    // MARK: - Ranges

    /// Number ranges with en-dash or em-dash: `250–500 ms` →
    /// "two hundred fifty to five hundred milliseconds"; `1–10 scale`
    /// → "one to ten". If both operands are plausible years
    /// (1100–2099), render as year pairs so "1990–1999" reads as
    /// "nineteen ninety to nineteen ninety nine". A trailing unit
    /// abbreviation (Hz / mg / ms / kg / ...) is absorbed into the
    /// range so FluidAudio doesn't later spell the unit out letter-by-
    /// letter.
    private static func wrapRanges(_ text: String) -> String {
        let unitAlt = unitAliases.map { NSRegularExpression.escapedPattern(for: $0.abbreviation) }.joined(separator: "|")
        let pattern = #"(?<![0-9A-Za-z<>])(\d+(?:\.\d+)?)\s*[–—]\s*(\d+(?:\.\d+)?)(?:(\s?)("# + unitAlt + #"))?(?![0-9A-Za-z])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let left = ns.substring(with: match.range(at: 1))
            let right = ns.substring(with: match.range(at: 2))
            let leftWords = rangeEndpointReading(left)
            let rightWords = rangeEndpointReading(right)
            var alias = "\(leftWords) to \(rightWords)"
            let unitMatch = match.range(at: 4)
            if unitMatch.location != NSNotFound {
                let abbrev = ns.substring(with: unitMatch)
                if let unit = unitAliases.first(where: { $0.abbreviation == abbrev }) {
                    alias += " \(unit.plural)"
                }
            }
            guard let r = Range(match.range, in: out) else { continue }
            let source = String(out[r])
            out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(source)</sub>"#)
        }
        return out
    }

    private static func rangeEndpointReading(_ s: String) -> String {
        if s.contains(".") { return decimal(s) }
        guard let n = Int(s) else { return s }
        if n >= 1100 && n <= 2099 { return year(n) }
        return cardinal(n)
    }

    // MARK: - Fractions / scores (N/M)

    /// Bare `N/M` between digits, e.g. `8/10` → "eight out of ten",
    /// `3/4` → "three out of four". Skips dates like `4/20/2025`
    /// (fused three-group form stays out because the (?!/) guard
    /// requires the next char not be another slash-digit).
    private static func wrapFractions(_ text: String) -> String {
        let pattern = #"(?<![0-9A-Za-z<>/])(\d{1,3})/(\d{1,3})(?![0-9/])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            if insideExistingSub(match.range, in: out) { continue }
            guard let num = Int(ns.substring(with: match.range(at: 1))),
                  let den = Int(ns.substring(with: match.range(at: 2)))
            else { continue }
            let alias = "\(cardinal(num)) out of \(cardinal(den))"
            guard let r = Range(match.range, in: out) else { continue }
            let source = String(out[r])
            out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(source)</sub>"#)
        }
        return out
    }

    // MARK: - Roman numerals

    /// Noun cues that gate Roman-numeral conversion. Without a cue the
    /// standalone letter "V" or "I" in prose is not a numeral. Kept
    /// intentionally small; expand only when a new linguistic class
    /// (not a fixture) justifies a new cue.
    private static let romanNumeralCues = [
        "Chapter", "Chapters", "Volume", "Volumes", "Vol", "Part", "Parts",
        "Act", "Acts", "Book", "Books", "Scene", "Scenes", "Article",
        "Articles", "Appendix", "Section", "Sections", "Figure", "Figures",
        "Table", "Tables", "Episode", "Episodes", "Stage", "Stages",
    ]

    private static func romanToInt(_ s: String) -> Int? {
        let values: [Character: Int] = [
            "I": 1, "V": 5, "X": 10, "L": 50,
            "C": 100, "D": 500, "M": 1000,
        ]
        var total = 0
        var prev = 0
        for ch in s.reversed() {
            guard let v = values[ch] else { return nil }
            if v < prev { total -= v } else { total += v }
            prev = v
        }
        // Reject zero/negative or overflow garbage patterns like `IIII`
        // which parse to 4 but violate canonical form. We don't enforce
        // canonicalness — IIII = 4, IIIIII = 6 — just require positive.
        return total > 0 ? total : nil
    }

    private static func wrapRomanNumerals(_ text: String) -> String {
        let cueAlt = romanNumeralCues.joined(separator: "|")
        let pattern = #"\b(\#(cueAlt))\s+([IVXLCDM]{1,6})\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            if insideExistingSub(match.range, in: out) { continue }
            let numeral = ns.substring(with: match.range(at: 2))
            guard let n = romanToInt(numeral), n <= 3999 else { continue }
            guard let r = Range(match.range(at: 2), in: out) else { continue }
            let alias = cardinal(n)
            out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(numeral)</sub>"#)
        }
        return out
    }

    // MARK: - Course codes

    /// `<Subject> <3-digit>` (e.g. `Reflexology 101`, `BIO 250`) read as
    /// digit-by-digit with the middle zero spoken as "oh" — the standard
    /// university-course convention. Gated on a capitalized-word cue so
    /// arbitrary `<word> 200` in prose doesn't collapse into a code.
    private static func wrapCourseCodes(_ text: String) -> String {
        // Cue: capitalized word of 3+ letters. Excludes month names via
        // lookbehind so `September 2026` can't accidentally match (the
        // 3-digit guard already rules out 4-digit years).
        let pattern = #"(?<![A-Za-z])([A-Z][A-Za-z]{2,})\s+(\d{3})(?![0-9A-Za-z])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            if insideExistingSub(match.range, in: out) { continue }
            let digits = ns.substring(with: match.range(at: 2))
            guard digits.count == 3,
                  let r = Range(match.range(at: 2), in: out) else { continue }
            let d = Array(digits)
            let d1 = cardinal(Int(String(d[0])) ?? 0)
            let d2Raw = Int(String(d[1])) ?? 0
            let d2 = d2Raw == 0 ? "oh" : cardinal(d2Raw)
            let d3Raw = Int(String(d[2])) ?? 0
            let d3 = d3Raw == 0 ? "oh" : cardinal(d3Raw)
            let alias = "\(d1) \(d2) \(d3)"
            out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(digits)</sub>"#)
        }
        return out
    }

    // MARK: - Ordinals

    /// `\d+(st|nd|rd|th)` → `<sub alias="<ordinal words>">\d+<suffix></sub>`.
    /// Pre-expand so FluidAudio's preprocessor doesn't re-ordinalize.
    private static func wrapOrdinals(_ text: String) -> String {
        let pattern = #"(?<![A-Za-z0-9<>])(\d+)(st|nd|rd|th)(?![A-Za-z0-9])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            if insideExistingSub(match.range, in: out) { continue }
            guard let r = Range(match.range, in: out),
                let n = Int(ns.substring(with: match.range(at: 1)))
            else { continue }
            let alias = ordinal(n)
            let source = String(out[r])
            out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(source)</sub>"#)
        }
        return out
    }
}
