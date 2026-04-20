import Foundation

/// Two-stage word-level normalisation for the Kitten mini acoustic model,
/// which mis-renders certain phoneme sequences even when the IPA is correct.
///
/// 1. **Text substitutions** (run before phonemisation): expand contractions
///    and split compounds that the model garbles. Strict word-boundary
///    matching, case-preserving.
/// 2. **IPA substitutions** (run on each phonemized segment): direct patch
///    of problem phoneme sequences, for words where text-level changes
///    can't help.
///
/// Both maps are deliberately conservative — start with the handful of
/// documented failures; extend as new ones surface.
public enum KittenWordNormalizer {

    // MARK: - Text-level substitutions

    /// Whole-word text replacements, matched case-insensitively with word
    /// boundaries. Values are lowercase; casing of the original match is
    /// preserved on the first character only (simple heuristic).
    private static let textReplacements: [(pattern: String, replacement: String)] = [
        // Contraction expansion — apostrophes confuse the Kitten mini model;
        // the non-contracted form renders cleanly.
        (#"\bwe'll\b"#, "we will"),
        (#"\byou'll\b"#, "you will"),
        (#"\bthey'll\b"#, "they will"),
        (#"\bhe'll\b"#, "he will"),
        (#"\bshe'll\b"#, "she will"),
        (#"\bit'll\b"#, "it will"),
        (#"\bI'll\b"#, "I will"),
        (#"\bdon't\b"#, "do not"),
        (#"\bdoesn't\b"#, "does not"),
        (#"\bdidn't\b"#, "did not"),
        (#"\bisn't\b"#, "is not"),
        (#"\baren't\b"#, "are not"),
        (#"\bwasn't\b"#, "was not"),
        (#"\bweren't\b"#, "were not"),
        (#"\bcan't\b"#, "cannot"),
        (#"\bwon't\b"#, "will not"),
        (#"\bwouldn't\b"#, "would not"),
        (#"\bshouldn't\b"#, "should not"),
        (#"\bcouldn't\b"#, "could not"),
        (#"\bhasn't\b"#, "has not"),
        (#"\bhaven't\b"#, "have not"),
        (#"\bhadn't\b"#, "had not"),
        (#"\bI'm\b"#, "I am"),
        (#"\bI've\b"#, "I have"),
        (#"\bwe've\b"#, "we have"),
        (#"\byou've\b"#, "you have"),
        (#"\bthey've\b"#, "they have"),

        // Compound words the model mis-renders; a space forces the
        // phonemiser to treat them as two words with clearer boundaries.
        // Rationale: the user's listening caught `outside` rendering
        // correctly (because already split here) but `website` breaking
        // as "webseeet" — same /aɪ/ diphthong mangled in compound-word
        // context. Targeted extension to compounds where /aɪ/ falls in a
        // non-initial syllable (site, line, time, light, rise).
        (#"\bOutside\b"#, "Out side"),
        (#"\boutside\b"#, "out side"),
        (#"\bInside\b"#, "In side"),
        (#"\binside\b"#, "in side"),
        (#"\bwebsite\b"#, "web site"),
        (#"\bwebsites\b"#, "web sites"),
        (#"\bonline\b"#, "on line"),
        (#"\banytime\b"#, "any time"),
        (#"\bbedtime\b"#, "bed time"),
        (#"\bsometime\b"#, "some time"),
        (#"\bsometimes\b"#, "some times"),
        (#"\blifetime\b"#, "life time"),
        (#"\bdaylight\b"#, "day light"),
        (#"\bmoonlight\b"#, "moon light"),
        (#"\bsunrise\b"#, "sun rise"),
        (#"\bsunrises\b"#, "sun rises"),
        (#"\bspotlight\b"#, "spot light"),
        (#"\bhighlight\b"#, "high light"),
        (#"\bhighlights\b"#, "high lights"),

        // "read" after a report-verb noun is past tense ("red"), not
        // present ("reed"). The phonemiser defaults to the present form
        // and produces a drawn-out "reeed". Substitute the homograph
        // that the phonemiser gets right.
        (#"\b(note|letter|sign|message|card|label|headline|caption)\s+read\b"#, "$1 red"),
    ]

    public static func normalizeText(_ text: String) -> String {
        var out = expandSlashLetters(text)
        out = dotifyCapsAcronyms(out)
        out = separateAdjacentLetterSequences(out)
        out = spellStandaloneLettersAfterDigits(out)
        out = stripAbbreviationDots(out)
        for (pattern, replacement) in textReplacements {
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            let ns = out as NSString
            let range = NSRange(location: 0, length: ns.length)
            // Preserve leading-char casing of each match.
            out = re.stringByReplacingMatches(
                in: out,
                options: [],
                range: range,
                withTemplate: replacement
            )
            // Re-case the first letter of the replacement if the original was capitalised.
            // Simple approach: re-run through the original text positions, match-by-match.
            // For our small dict the replacements are lowercase; we accept that leading
            // "I" forms stay correct because the pattern already matches uppercase.
        }
        return out
    }

    /// English letter names. Bare single letters are ambiguous to the
    /// phonemiser — "a" phonemises as the article /ɐ/, "i" as the pronoun
    /// /aɪ/, etc. Spelling them (a → "ay", p → "pee") forces the phonemiser
    /// to emit the letter-name pronunciation every time.
    private static let letterNames: [Character: String] = [
        // "eigh" phonemises cleanly as /eɪ/. "ay" and "aye" both phonemise
        // as /aɪ/ (the "aye" agreement word), so a.m. comes out "eye-em".
        "a": "eigh",  "b": "bee",  "c": "see",  "d": "dee",  "e": "ee",
        "f": "eff",   "g": "gee",  "h": "aitch","i": "eye",  "j": "jay",
        "k": "kay",   "l": "el",   "m": "em",   "n": "en",   "o": "oh",
        "p": "pee",   "q": "cue",  "r": "ar",   "s": "ess",  "t": "tee",
        "u": "you",   "v": "vee",  "w": "double you",
        "x": "ex",    "y": "why",  "z": "zee",
    ]

    /// Expand any dotted single-letter acronym ("a.m.", "p.m.", "e.g.",
    /// "U.S.A.", "F.B.I.") into space-separated spelled letter names.
    /// General rule — subsumes the old per-abbreviation entries.
    /// Two-letter-before-dot forms (Ph.D., Mr., Dr.) are handled by
    /// `stripAbbreviationDots` instead, since the phonemiser's dictionary
    /// usually renders them correctly once the dots are gone.
    /// Expand "A/B" → "eigh slash bee". The phonemiser otherwise treats
    /// "A/B" as one word and renders it as a schwa-then-letter ("uh-bee").
    /// Also covers "N/A", "A/C", "I/O", etc.
    private static func expandSlashLetters(_ text: String) -> String {
        let pattern = #"\b([A-Za-z])\s*/\s*([A-Za-z])\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = text
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let a = ns.substring(with: match.range(at: 1)).lowercased().first!
            let b = ns.substring(with: match.range(at: 2)).lowercased().first!
            let an = letterNames[a, default: String(a)]
            let bn = letterNames[b, default: String(b)]
            guard let r = Range(match.range, in: out) else { continue }
            out.replaceSubrange(r, with: "\(an) slash \(bn)")
        }
        return out
    }

    /// Acronyms pronounced as single words (anacronyms) — skip dot-ifying.
    /// Letter-by-letter is the safer default; this list opts specific
    /// terms out so they pass through to espeak as one-word tokens.
    /// Curated from common-usage lists; extend as real-world text surfaces
    /// cases where dot-ifying produces the wrong pronunciation.
    private static let wordAcronyms: Set<String> = [
        // Agencies & organizations
        "NASA", "NATO", "UNICEF", "UNESCO", "OPEC", "DARPA", "FEMA", "FIFA",
        "IKEA", "INTERPOL",
        // Tech pronounced-as-words
        "SCUBA", "LASER", "RADAR", "SONAR", "MODEM", "TASER",
        "GIF", "JPEG", "MPEG",
        // Military / security
        "SWAT", "SEAL",
        // Health
        "AIDS", "SARS", "COVID", "EBOLA",
        // Colloquial
        "ASAP", "AWOL", "SNAFU", "FUBAR", "NIMBY", "WASP", "YOLO", "YAML",
    ]

    /// Turn all-caps runs of bare letters into a phonemiser-friendly form.
    /// 3+ letter runs dot-ify ("RSVP" → "R.S.V.P.") so espeak letter-spells
    /// them natively via `.`-separated IPA (`ˈɑːɹ.ˈɛs.vˈiː.pˈiː.`).
    /// 2-letter runs use space-expanded letter names ("AI" → "eigh eye")
    /// because the dot-form on adjacent diphthong-starting letters
    /// ("A.I." → `ˈeɪ . ˈaɪ .`) trips a pitch/stretch artefact in the
    /// mini model; space-expansion lets word-boundary spacing handle it.
    /// Already-dotted inputs ("p.m.", "A.I.") don't match `[A-Z]{2,}` so
    /// they pass through untouched and espeak handles them natively.
    /// Exceptions in `wordAcronyms` (NASA, NATO, SCUBA, …) pass through
    /// so espeak pronounces them as single words.
    private static func dotifyCapsAcronyms(_ text: String) -> String {
        let pattern = #"\b[A-Z]{2,}\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = text
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let matched = ns.substring(with: match.range)
            if wordAcronyms.contains(matched) { continue }
            guard let r = Range(match.range, in: out) else { continue }
            let replacement: String
            if matched.count == 2 {
                let names = matched.map { letterNames[Character($0.lowercased()), default: String($0)] }
                replacement = names.joined(separator: " ")
            } else {
                replacement = matched.map { "\($0)." }.joined()
            }
            out.replaceSubrange(r, with: replacement)
        }
        return out
    }

    /// Spell a standalone single capital letter that sits adjacent to a
    /// digit token, like the "B" in "Lab 3 B" or the "C" in "Apt 12 C"
    /// after `splitLetterDigit` runs. The phonemiser otherwise produces
    /// the schwa-article for bare "A" and quietly drops some others. We
    /// only target digit-adjacent capitals so real sentence-initial
    /// letters ("A fine day…") aren't rewritten.
    private static func spellStandaloneLettersAfterDigits(_ text: String) -> String {
        // "3 B" / "12 C" / "22 A" etc. — a digit word immediately before
        // a single capital letter word. Also the reverse: "C 14".
        let patterns = [
            (#"\b(\d+)\s+([A-Z])\b"#, "before"),
            (#"\b([A-Z])\s+(\d+)\b"#, "after"),
        ]
        var out = text
        for (pattern, direction) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = out as NSString
            var next = out
            for match in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let letterRange = direction == "before" ? match.range(at: 2) : match.range(at: 1)
                let digitRange = direction == "before" ? match.range(at: 1) : match.range(at: 2)
                let letter = ns.substring(with: letterRange).lowercased().first!
                let digits = ns.substring(with: digitRange)
                guard let name = letterNames[letter] else { continue }
                let replacement = direction == "before"
                    ? "\(digits) \(name)"
                    : "\(name) \(digits)"
                guard let r = Range(match.range, in: next) else { continue }
                next.replaceSubrange(r, with: replacement)
            }
            out = next
        }
        return out
    }

    /// When two letter-spelled sequences sit next to each other ("a.m. FYI"
    /// → after dotify: "a.m. F.Y.I."), the model can mash across the word
    /// boundary — "em eff" runs together as "emeff". Both words present the
    /// same letter-dot-letter-dot pattern so the plain space between them
    /// doesn't carry enough weight. Swap the left sequence's trailing period
    /// for a comma (stacking period+comma stretches the preceding letter
    /// into "emmee"): "a.m. F.Y.I." → "a.m, F.Y.I.". Only triggers when one
    /// letter-dot run is immediately followed by another, so normal prose
    /// ("p.m. by the station") is untouched — the trailing period stays.
    private static func separateAdjacentLetterSequences(_ text: String) -> String {
        let pattern = #"(\b[A-Za-z])\.\s+(?=\b[A-Za-z]\.)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1, ")
    }

    /// Strip periods from multi-letter abbreviations (titles, suffixes)
    /// so they don't get emitted as pause tokens during IPA tokenisation.
    /// Single-letter dotted acronyms (a.m., p.m., A.I., R.S.V.P., …) are
    /// left alone — espeak letter-spells them natively from the dotted
    /// form, which is the canonical pipeline for every acronym now.
    private static let abbreviationPatterns: [(pattern: String, replacement: String)] = [
        (#"\bDr\."#, "Dr"),
        (#"\bMr\."#, "Mr"),
        (#"\bMrs\."#, "Mrs"),
        (#"\bMs\."#, "Ms"),
        (#"\bJr\."#, "Jr"),
        (#"\bSr\."#, "Sr"),
        (#"\bSt\."#, "St"),
        (#"\betc\."#, "etc"),
        (#"\bvs\."#, "vs"),
    ]

    private static func stripAbbreviationDots(_ text: String) -> String {
        var out = text
        for (pattern, replacement) in abbreviationPatterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: (out as NSString).length)
            out = re.stringByReplacingMatches(
                in: out, options: [], range: range, withTemplate: replacement
            )
        }
        return out
    }

    // MARK: - IPA-level substitutions

    /// IPA string patches, applied AFTER phonemisation. Keys are phoneme
    /// substrings that reliably indicate the mis-rendered word in context;
    /// values are replacements. Empty by default — populate as specific
    /// model failures are diagnosed.
    private static let ipaReplacements: [(String, String)] = [
        // "hundred" — the phonemiser emits hˈʌndɹɪd / hˈʌndɹəd and the
        // model truncates it to "hoh". Marking a secondary stress on the
        // final -red with an ɛ nucleus forces a clear two-syllable render.
        ("hˈʌndɹɪd", "hˈʌndɹˌɛd"),
        ("hˈʌndɹəd", "hˈʌndɹˌɛd"),
    ]

    public static func patchIPA(_ ipa: String) -> String {
        var out = ipa
        for (src, dst) in ipaReplacements {
            out = out.replacingOccurrences(of: src, with: dst)
        }
        return out
    }
}
