import Foundation

/// Swift port of `kokorog2p/pipeline/abbreviations.py` +
/// `kokorog2p/en/abbreviations.py`.
///
/// The expander walks an ordered table of `AbbreviationEntry` rows and
/// rewrites each match as a `<sub alias="...">source</sub>` structural
/// span — the alias is the spoken form, the source is left inside the
/// tag so downstream tools can still see the original surface.
///
/// Context-aware entries (`St.` → Street|Saint, `Dr.` → Doctor|Drive)
/// run through `ContextDetector` which mirrors kokorog2p's multi-signal
/// logic: Saint/city name wins first, then a close-proximity house
/// number, then the default.
///
/// Replaces the prior `wrapDottedAbbreviations` + `wrapTitles` pair.
/// `applyTechnicalAliases` stays separate — it's a FluidAudio
/// preprocessor compensator, not a linguistic abbreviation.
public enum AbbreviationContext: Sendable, Hashable {
    case defaultCtx
    case title
    case place
    case time
    case academic
    case religious
}

public struct AbbreviationEntry: Sendable {
    public let abbreviation: String
    public let expansion: String
    public let contextExpansions: [AbbreviationContext: String]
    public let caseSensitive: Bool
    /// Regex that must match the (short) text slice ending immediately
    /// before the abbreviation — e.g. `"30 in."` only expands when a
    /// digit precedes, avoiding "Wizard of Oz." → "Wizard of Oince".
    public let onlyIfPrecededBy: String?
    /// Regex that must match starting at the character immediately
    /// after the abbreviation — e.g. `"No. 244"` only expands when
    /// followed by digits.
    public let onlyIfFollowedBy: String?

    public init(
        _ abbreviation: String,
        _ expansion: String,
        contextExpansions: [AbbreviationContext: String] = [:],
        caseSensitive: Bool = false,
        onlyIfPrecededBy: String? = nil,
        onlyIfFollowedBy: String? = nil
    ) {
        self.abbreviation = abbreviation
        self.expansion = expansion
        self.contextExpansions = contextExpansions
        self.caseSensitive = caseSensitive
        self.onlyIfPrecededBy = onlyIfPrecededBy
        self.onlyIfFollowedBy = onlyIfFollowedBy
    }

    public func expansion(for context: AbbreviationContext?) -> String {
        if let context, let override = contextExpansions[context] { return override }
        return expansion
    }
}

/// Mirrors `kokorog2p.pipeline.abbreviations.ContextDetector`.
enum ContextDetector {
    static let saintNames: Set<String> = [
        "peter", "paul", "john", "mary", "patrick", "francis",
        "joseph", "michael", "george", "luke", "mark", "matthew",
        "thomas", "james", "anthony", "andrew",
    ]

    static let cityNames: Set<String> = [
        "louis", "paul", "petersburg", "augustine", "helena",
        "cloud", "albans", "andrews",
    ]

    /// Address pattern: `<number> [<direction>] <word>` ending at the
    /// cursor. Matches "123 Main", "456 N. Oak", "10 Park Avenue".
    static let placeIndicators = try! NSRegularExpression(
        pattern: #"\b\d+\s+(?:[A-Z]\.\s+)?\w+(?:\s+\w+)*$"#,
        options: [.caseInsensitive]
    )

    /// After-text begins with a capitalised word — indicates a title
    /// like "Dr. Smith" / "Prof. Johnson".
    static let titleIndicators = try! NSRegularExpression(
        pattern: #"^(?:\w+\s+)*[A-Z][a-z]+"#
    )

    /// Time pattern ending at cursor: `3`, `3:00`, `11:59`.
    static let timeIndicators = try! NSRegularExpression(
        pattern: #"\b\d{1,2}(?::\d{2})?\s*$"#,
        options: [.caseInsensitive]
    )

    /// Ordinal directly before `St.` — "5th St.", "42nd St.".
    static let ordinalStreetPattern = try! NSRegularExpression(
        pattern: #"\d+(?:st|nd|rd|th)\s*$"#,
        options: [.caseInsensitive]
    )

    /// Close-proximity house number pattern — "123 Main", "456 N. Oak".
    static let houseNumberPattern = try! NSRegularExpression(
        pattern: #"\d+\s+(?:[NSEW]\.?\s+)?[A-Z]\w*\s*$"#,
        options: [.caseInsensitive]
    )

    /// Bare capitalised word at end of `before` — matches street-name
    /// contexts without a preceding house number ("Main St.", "Elm Dr.",
    /// "Oak Ave."). Intentionally excludes sentence-start capitals:
    /// the word must have at least one lowercase letter so "The St." at
    /// the start of a sentence doesn't match.
    static let bareStreetNamePattern = try! NSRegularExpression(
        pattern: #"[A-Z][a-z]+\s*$"#
    )

    /// Abbreviations that canonically act as street-type suffixes.
    /// Used to promote bare-capitalised-name contexts to `.place`
    /// without requiring a number in `before`.
    static let streetSuffixAbbreviations: Set<String> = [
        "st.", "rd.", "ave.", "blvd.", "ln.", "ct.", "pl.", "pkwy.",
        "cir.", "sq.", "dr.",
    ]

    static func detect(abbreviation: String, before: String, after: String) -> AbbreviationContext {
        if matches(timeIndicators, before) {
            return .time
        }

        let key = abbreviation.lowercased()

        // St. — multi-signal Saint vs Street disambiguation.
        if key == "st." || key == "st" {
            let trimmedAfter = after.trimmingCharacters(in: .whitespaces)
            if !trimmedAfter.isEmpty {
                let firstWord = trimmedAfter
                    .split(whereSeparator: { $0.isWhitespace })
                    .first.map(String.init) ?? ""
                let cleaned = firstWord
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'s.,;:!?"))
                    .lowercased()
                if saintNames.contains(cleaned) || cityNames.contains(cleaned) {
                    return .religious
                }
            }
            let recent = String(before.suffix(30))
            if matches(ordinalStreetPattern, recent) { return .place }
            if matches(houseNumberPattern, recent) { return .place }
            // Bare street-name — "Main St.", "Elm St.". Saint/city
            // check already won above if applicable.
            if matches(bareStreetNamePattern, before) { return .place }
            return .religious
        }

        // Full house-number address pattern (for any place-sensitive
        // abbreviation).
        if matches(placeIndicators, before) {
            return .place
        }

        // Bare street-name promotion for other street-suffix abbrevs.
        // `Dr.` (Drive) is the main beneficiary — "Elm Dr.",
        // "Oak Dr." — since its default expansion is `Doctor`.
        if streetSuffixAbbreviations.contains(key),
            matches(bareStreetNamePattern, before) {
            return .place
        }

        // Title context (Dr. Smith, Prof. Johnson).
        if !after.isEmpty, matchesAnchored(titleIndicators, after) {
            return .title
        }

        return .defaultCtx
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        let ns = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func matchesAnchored(_ regex: NSRegularExpression, _ text: String) -> Bool {
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        else { return false }
        return match.range.location == 0
    }
}

public enum KokoroAbbreviations {
    /// Ordered table of entries. Order matters: `expand` sorts by length
    /// descending so longer abbreviations win — `Ph.D.` is matched before
    /// `D.`, `U.S.A.` before `U.S.`.
    static let entries: [AbbreviationEntry] = [
        // MARK: Titles / honorifics
        AbbreviationEntry("Mr.", "Mister"),
        AbbreviationEntry("Mrs.", "Missus"),
        AbbreviationEntry("Ms.", "Miss"),
        AbbreviationEntry(
            "Dr.", "Doctor",
            contextExpansions: [.place: "Drive", .title: "Doctor"]
        ),
        AbbreviationEntry("Prof.", "Professor"),
        AbbreviationEntry("Rev.", "Reverend"),
        AbbreviationEntry("Hon.", "Honorable"),
        AbbreviationEntry("Mx.", "Mix"),
        AbbreviationEntry("Esq.", "Esquire"),

        // MARK: Military ranks
        AbbreviationEntry("Lt.", "Lieutenant"),
        AbbreviationEntry("Gen.", "General"),
        AbbreviationEntry("Col.", "Colonel"),
        AbbreviationEntry("Maj.", "Major"),
        AbbreviationEntry("Capt.", "Captain"),
        AbbreviationEntry("Sgt.", "Sergeant"),
        AbbreviationEntry("Cpl.", "Corporal"),

        // MARK: Days of the week
        AbbreviationEntry("Mon.", "Monday"),
        AbbreviationEntry("Tue.", "Tuesday"),
        AbbreviationEntry("Tues.", "Tuesday"),
        AbbreviationEntry("Wed.", "Wednesday"),
        AbbreviationEntry("Thu.", "Thursday"),
        AbbreviationEntry("Thur.", "Thursday"),
        AbbreviationEntry("Thurs.", "Thursday"),
        AbbreviationEntry("Fri.", "Friday"),
        AbbreviationEntry("Sat.", "Saturday"),
        AbbreviationEntry("Sun.", "Sunday"),

        // MARK: Months
        AbbreviationEntry("Jan.", "January"),
        AbbreviationEntry("Feb.", "February"),
        AbbreviationEntry("Mar.", "March"),
        AbbreviationEntry("Apr.", "April"),
        AbbreviationEntry("Jun.", "June"),
        AbbreviationEntry("Jul.", "July"),
        AbbreviationEntry("Aug.", "August"),
        AbbreviationEntry("Sep.", "September"),
        AbbreviationEntry("Sept.", "September"),
        AbbreviationEntry("Oct.", "October"),
        AbbreviationEntry("Nov.", "November"),
        AbbreviationEntry("Dec.", "December"),

        // MARK: Streets / places
        AbbreviationEntry(
            "St.", "Saint",
            contextExpansions: [.place: "Street", .religious: "Saint"]
        ),
        AbbreviationEntry("Ave.", "Avenue"),
        AbbreviationEntry("Rd.", "Road"),
        AbbreviationEntry("Blvd.", "Boulevard"),
        AbbreviationEntry("Ln.", "Lane"),
        AbbreviationEntry("Ct.", "Court"),
        AbbreviationEntry("Pl.", "Place"),
        AbbreviationEntry("Pkwy.", "Parkway"),
        AbbreviationEntry("Apt.", "Apartment"),
        AbbreviationEntry("Ste.", "Suite"),
        AbbreviationEntry("Fl.", "Floor"),
        AbbreviationEntry("N.Y.", "New York"),
        AbbreviationEntry("L.A.", "Los Angeles"),
        AbbreviationEntry("D.C.", "District of Columbia"),

        // MARK: AP-style US state abbreviations. Case-sensitive so
        // short ones (`Pa.`, `La.`, `Mo.`, `Ga.`) don't collide with
        // lowercase words. Only states whose AP abbreviation differs
        // from the USPS two-letter code; full-name-only states (Ohio,
        // Iowa, Idaho, Utah, Maine, Texas, Alaska, Hawaii) are omitted.
        AbbreviationEntry("Ala.", "Alabama", caseSensitive: true),
        AbbreviationEntry("Ariz.", "Arizona", caseSensitive: true),
        AbbreviationEntry("Ark.", "Arkansas", caseSensitive: true),
        AbbreviationEntry("Calif.", "California", caseSensitive: true),
        AbbreviationEntry("Colo.", "Colorado", caseSensitive: true),
        AbbreviationEntry("Conn.", "Connecticut", caseSensitive: true),
        AbbreviationEntry("Del.", "Delaware", caseSensitive: true),
        AbbreviationEntry("Fla.", "Florida", caseSensitive: true),
        AbbreviationEntry("Ga.", "Georgia", caseSensitive: true),
        AbbreviationEntry("Ill.", "Illinois", caseSensitive: true),
        AbbreviationEntry("Ind.", "Indiana", caseSensitive: true),
        AbbreviationEntry("Kan.", "Kansas", caseSensitive: true),
        AbbreviationEntry("Ky.", "Kentucky", caseSensitive: true),
        AbbreviationEntry("La.", "Louisiana", caseSensitive: true),
        AbbreviationEntry("Md.", "Maryland", caseSensitive: true),
        AbbreviationEntry("Mass.", "Massachusetts", caseSensitive: true),
        AbbreviationEntry("Mich.", "Michigan", caseSensitive: true),
        AbbreviationEntry("Minn.", "Minnesota", caseSensitive: true),
        AbbreviationEntry("Miss.", "Mississippi", caseSensitive: true),
        AbbreviationEntry("Mo.", "Missouri", caseSensitive: true),
        AbbreviationEntry("Mont.", "Montana", caseSensitive: true),
        AbbreviationEntry("Neb.", "Nebraska", caseSensitive: true),
        AbbreviationEntry("Nev.", "Nevada", caseSensitive: true),
        AbbreviationEntry("Okla.", "Oklahoma", caseSensitive: true),
        AbbreviationEntry("Ore.", "Oregon", caseSensitive: true),
        AbbreviationEntry("Pa.", "Pennsylvania", caseSensitive: true),
        AbbreviationEntry("Tenn.", "Tennessee", caseSensitive: true),
        AbbreviationEntry("Tex.", "Texas", caseSensitive: true),
        AbbreviationEntry("Va.", "Virginia", caseSensitive: true),
        AbbreviationEntry("Vt.", "Vermont", caseSensitive: true),
        AbbreviationEntry("Wash.", "Washington", caseSensitive: true),
        AbbreviationEntry("Wis.", "Wisconsin", caseSensitive: true),
        AbbreviationEntry("Wyo.", "Wyoming", caseSensitive: true),
        AbbreviationEntry("N.H.", "New Hampshire", caseSensitive: true),
        AbbreviationEntry("N.J.", "New Jersey", caseSensitive: true),
        AbbreviationEntry("N.M.", "New Mexico", caseSensitive: true),
        AbbreviationEntry("N.C.", "North Carolina", caseSensitive: true),
        AbbreviationEntry("N.D.", "North Dakota", caseSensitive: true),
        AbbreviationEntry("R.I.", "Rhode Island", caseSensitive: true),
        AbbreviationEntry("S.C.", "South Carolina", caseSensitive: true),
        AbbreviationEntry("S.D.", "South Dakota", caseSensitive: true),
        AbbreviationEntry("W.Va.", "West Virginia", caseSensitive: true),

        // MARK: Time
        AbbreviationEntry("A.M.", "A M"),
        AbbreviationEntry("P.M.", "P M"),
        AbbreviationEntry("a.m.", "A M"),
        AbbreviationEntry("p.m.", "P M"),
        AbbreviationEntry("A.D.", "A D"),
        AbbreviationEntry("B.C.", "B C"),

        // MARK: Academic degrees
        AbbreviationEntry("Ph.D.", "P H D"),
        AbbreviationEntry("Ph.d.", "P H D"),
        AbbreviationEntry("M.D.", "M D"),
        AbbreviationEntry("B.A.", "B A"),
        AbbreviationEntry("M.A.", "M A"),
        AbbreviationEntry("B.S.", "B S"),
        AbbreviationEntry("M.S.", "M S"),
        AbbreviationEntry("Jr.", "Junior"),
        AbbreviationEntry("Sr.", "Senior"),
        AbbreviationEntry("M.B.A.", "M B A"),
        AbbreviationEntry("D.D.S.", "D D S"),
        AbbreviationEntry("D.V.M.", "D V M"),
        AbbreviationEntry("R.N.", "R N"),
        AbbreviationEntry("L.P.N.", "L P N"),

        // MARK: Common abbreviations
        AbbreviationEntry("etc.", "et cetera"),
        AbbreviationEntry("vs.", "versus"),
        AbbreviationEntry("v.", "versus"),
        AbbreviationEntry("e.g.", "for example"),
        AbbreviationEntry("i.e.", "that is"),
        AbbreviationEntry("dept.", "department"),
        AbbreviationEntry("govt.", "government"),
        AbbreviationEntry("approx.", "approximately"),
        AbbreviationEntry("est.", "estimated"),
        AbbreviationEntry("inc.", "incorporated"),
        AbbreviationEntry("corp.", "corporation"),
        AbbreviationEntry("ltd.", "limited"),
        AbbreviationEntry("co.", "company"),
        AbbreviationEntry("No.", "number", onlyIfFollowedBy: #"\s*\d"#),
        AbbreviationEntry("no.", "number", onlyIfFollowedBy: #"\s*\d"#),
        AbbreviationEntry("vol.", "volume", onlyIfFollowedBy: #"\s*\d"#),
        AbbreviationEntry("pg.", "page", onlyIfFollowedBy: #"\s*\d"#),
        AbbreviationEntry("pp.", "pages", onlyIfFollowedBy: #"\s*\d"#),
        AbbreviationEntry("ch.", "chapter", onlyIfFollowedBy: #"\s*\d"#),
        AbbreviationEntry("fig.", "figure", onlyIfFollowedBy: #"\s*\d"#),
        AbbreviationEntry("max.", "maximum"),
        AbbreviationEntry("min.", "minimum"),
        AbbreviationEntry("misc.", "miscellaneous"),
        AbbreviationEntry("assn.", "association"),
        AbbreviationEntry("assoc.", "association"),

        // MARK: Countries / regions
        AbbreviationEntry("U.S.A.", "U S A"),
        AbbreviationEntry("U.S.", "U S"),
        AbbreviationEntry("U.K.", "U K"),
        AbbreviationEntry("U.N.", "U N"),
        AbbreviationEntry("E.U.", "E U"),

        // MARK: Geographic features
        AbbreviationEntry("Mt.", "Mount"),
        AbbreviationEntry("Mtn.", "Mountain"),
        AbbreviationEntry("Pk.", "Park"),
        AbbreviationEntry("Cir.", "Circle"),
        AbbreviationEntry("Sq.", "Square"),
        AbbreviationEntry("Bldg.", "Building"),
        AbbreviationEntry("Cyn.", "Canyon"),

        // MARK: Latin
        AbbreviationEntry("viz.", "namely"),
        AbbreviationEntry("cf.", "compare"),
        AbbreviationEntry("ibid.", "ibidem"),
        AbbreviationEntry("ca.", "circa"),

        // MARK: Dotted initialisms (bare forms handled by wrapInitialisms)
        AbbreviationEntry("F.Y.I.", "F Y I"),
        AbbreviationEntry("R.S.V.P.", "R S V P"),
        AbbreviationEntry("E.T.A.", "E T A"),
        AbbreviationEntry("A.I.", "A I"),

        // MARK: Measurement units — only after a number. Prevents
        // "Wizard of Oz." → "Wizard of Ounce" and friends.
        AbbreviationEntry("in.", "inch",
            onlyIfPrecededBy: #"(?:^|[^\w.])\d[\d,]*(?:\.\d+)?\s*$"#),
        AbbreviationEntry("ft.", "foot",
            onlyIfPrecededBy: #"\d[\d,]*(?:\.\d+)?\s*$"#),
        AbbreviationEntry("yd.", "yard",
            onlyIfPrecededBy: #"\d[\d,]*(?:\.\d+)?\s*$"#),
        AbbreviationEntry("mi.", "mile",
            onlyIfPrecededBy: #"\d[\d,]*(?:\.\d+)?\s*$"#),
        AbbreviationEntry("oz.", "ounce",
            onlyIfPrecededBy: #"\d[\d,]*(?:\.\d+)?\s*$"#),
        AbbreviationEntry("lb.", "pound",
            onlyIfPrecededBy: #"\d[\d,]*(?:\.\d+)?\s*$"#),
        AbbreviationEntry("lbs.", "pounds",
            onlyIfPrecededBy: #"\d[\d,]*(?:\.\d+)?\s*$"#),
        AbbreviationEntry("gal.", "gallon",
            onlyIfPrecededBy: #"\d[\d,]*(?:\.\d+)?\s*$"#),
        AbbreviationEntry("qt.", "quart",
            onlyIfPrecededBy: #"\d[\d,]*(?:\.\d+)?\s*$"#),
        AbbreviationEntry("pt.", "pint",
            onlyIfPrecededBy: #"\d[\d,]*(?:\.\d+)?\s*$"#),
        AbbreviationEntry("tsp.", "teaspoon",
            onlyIfPrecededBy: #"\d[\d,]*(?:\.\d+)?\s*$"#),
        AbbreviationEntry("tbsp.", "tablespoon",
            onlyIfPrecededBy: #"\d[\d,]*(?:\.\d+)?\s*$"#),
        AbbreviationEntry("hr.", "hour",
            onlyIfPrecededBy: #"\d[\d,]*(?:\.\d+)?\s*$"#),
        AbbreviationEntry("hrs.", "hours",
            onlyIfPrecededBy: #"\d[\d,]*(?:\.\d+)?\s*$"#),
        AbbreviationEntry("sec.", "second",
            onlyIfPrecededBy: #"\d[\d,]*(?:\.\d+)?\s*$"#),

        // MARK: Email/business
        AbbreviationEntry("attn.", "attention"),
        AbbreviationEntry("ref.", "reference"),
    ]

    /// Surface forms of every abbreviation in the table, exposed for
    /// the tokenizer's abbreviation-aware merge pass (Phase 5). Returned
    /// as `(surface, caseSensitive)` pairs so consumers can build
    /// case-folded match sets without recomputing the flag.
    public static var surfaceForms: [(surface: String, caseSensitive: Bool)] {
        entries.map { ($0.abbreviation, $0.caseSensitive) }
    }

    /// Rewrites every matching abbreviation as a structural `<sub>`
    /// span. Processing is longest-first so overlapping prefixes (e.g.
    /// `U.S.A.` vs `U.S.`) resolve correctly.
    public static func expand(_ text: String) -> String {
        let sorted = entries.sorted { $0.abbreviation.count > $1.abbreviation.count }
        var out = text
        for entry in sorted {
            out = expandOne(out, entry: entry)
        }
        return out
    }

    private static func expandOne(_ text: String, entry: AbbreviationEntry) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: entry.abbreviation)
        let pattern: String
        if entry.abbreviation.hasSuffix(".") {
            pattern = #"(?<![A-Za-z0-9<>])"# + escaped + #"(?=\s|[,;:!?<]|$)"#
        } else {
            pattern = #"(?<![A-Za-z0-9<>])"# + escaped + #"(?![A-Za-z0-9<>])"#
        }
        var options: NSRegularExpression.Options = []
        if !entry.caseSensitive { options.insert(.caseInsensitive) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options)
        else { return text }
        let protectedRanges = ssmlSpanRanges(in: text)

        // Ellipsis at sentence boundary is only safe for multi-period
        // dotted acronyms (`a.m.`, `Ph.D.`, `U.S.`). Single-dot
        // abbreviations (`Dr.`, `Mr.`, `Jr.`) are honorifics that flow
        // into the following word — emitting `. …` there would insert
        // an unwanted pause between title and name.
        let ellipsisEligible = entry.abbreviation.filter { $0 == "." }.count > 1

        var out = text
        let ns = out as NSString
        let matches = re.matches(in: out, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let r = match.range
            let start = r.location
            let end = r.location + r.length
            let outNs = out as NSString

            if protectedRanges.contains(where: { NSLocationInRange(start, $0) }) { continue }
            if isInsideMarkupTag(at: start, in: outNs) { continue }

            if let precedePattern = entry.onlyIfPrecededBy {
                let windowStart = max(0, start - 80)
                let before = outNs.substring(with: NSRange(location: windowStart, length: start - windowStart))
                guard let preRe = try? NSRegularExpression(pattern: precedePattern)
                else { continue }
                let beforeNs = before as NSString
                if preRe.firstMatch(in: before, range: NSRange(location: 0, length: beforeNs.length)) == nil {
                    continue
                }
            }
            if let followPattern = entry.onlyIfFollowedBy {
                let after = outNs.substring(from: end)
                guard let postRe = try? NSRegularExpression(pattern: followPattern)
                else { continue }
                let afterNs = after as NSString
                let m = postRe.firstMatch(in: after, range: NSRange(location: 0, length: afterNs.length))
                if m == nil || m?.range.location != 0 { continue }
            }

            let before = start > 0 ? outNs.substring(with: NSRange(location: 0, length: start)) : ""
            let after = end < outNs.length
                ? outNs.substring(with: NSRange(location: end, length: outNs.length - end))
                : ""

            let ctx = ContextDetector.detect(
                abbreviation: entry.abbreviation,
                before: before.trimmingCharacters(in: .whitespaces),
                after: after.trimmingCharacters(in: .whitespaces)
            )
            var alias = entry.expansion(for: ctx)

            // Post-hoc emitter detail: multi-dot dotted acronyms at
            // sentence boundary get `. …` appended so the downstream
            // prosody layer sees a hard pause and the acronym's final
            // letter doesn't fuse with the next sentence's first word.
            if ellipsisEligible {
                let tail = outNs.substring(
                    with: NSRange(location: end, length: min(3, outNs.length - end))
                )
                if tail.range(of: #"^\s+[A-Z]"#, options: .regularExpression) != nil {
                    alias = "\(alias). …"
                }
            }

            guard let rr = Range(r, in: out) else { continue }
            let source = String(out[rr])
            let replacement = #"<sub alias="\#(alias)">\#(source)</sub>"#
            out.replaceSubrange(rr, with: replacement)
        }
        return out
    }

    /// Returns true when `location` sits inside a `<...>` opening or
    /// closing tag (i.e. between `<` and the next `>`). Covers cases
    /// where a partial match of an abbreviation falls inside tag
    /// attribute text.
    private static func isInsideMarkupTag(at location: Int, in ns: NSString) -> Bool {
        var i = location - 1
        while i >= 0 {
            let c = ns.character(at: i)
            if c == 0x3E /* > */ { return false }
            if c == 0x3C /* < */ { return true }
            i -= 1
        }
        return false
    }

    /// Ranges of the *contents* of already-emitted structural spans
    /// (`<sub>...</sub>`, `<say-as>...</say-as>`). Matches inside these
    /// ranges are skipped so we don't double-wrap an inner abbreviation
    /// that an earlier handler already claimed (e.g. `p.m.` inside
    /// `wrapTimeMeridiem`'s `<sub alias="...">5:30 p.m.</sub>`).
    private static func ssmlSpanRanges(in text: String) -> [NSRange] {
        let pattern = #"<(sub|say-as)\b[^>]*>[\s\S]*?</\1>"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
    }
}
