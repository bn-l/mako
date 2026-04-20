import Foundation
import NaturalLanguage

/// SSML emitter for the FluidAudio `KokoroTtsManager`, which parses a
/// subset of SSML inside its `synthesize(text:)` entry point:
/// `<sub alias="...">…</sub>`, `<phoneme alphabet="ipa" ph="…">…</phoneme>`,
/// and `<say-as interpret-as="characters|cardinal|ordinal|digits|date|time|telephone|fraction">…</say-as>`.
///
/// Unlike the Kitten normalizer (which rewrites the source text so espeak's
/// G2P behaves), this one **wraps** problem tokens in SSML so Kokoro's own
/// CoreML G2P is bypassed for the wrapped span. Untouched text still goes
/// through the default G2P path.
public enum KokoroSSMLNormalizer {

    public static func normalize(_ text: String) -> String {
        var out = text
        // Email/URL must run before any handler that might touch their punctuation.
        out = wrapEmails(out)
        out = wrapURLs(out)
        out = wrapPhoneNumbers(out)
        // Hyphenated compounds with 3+ segments (state-of-the-art, mother-in-law,
        // pressure-to-release) get hyphens replaced with spaces so the chunker
        // doesn't fragment the phrase. Runs AFTER email/URL protection.
        out = applyHyphenatedCompounds(out)
        // When KOKORO_CUSTOM_LEXICON=1, the runner installs a TtsCustomLexicon
        // that handles per-word IPA overrides directly in FluidAudio's G2P chain.
        // Celtic handling is always called (path-invariant): the IPA branch is
        // skipped under custom-lexicon to avoid stacking, but the `<sub alias>`
        // fallback MUST still run — the lexicon only gets entries for gold-hit
        // names (e.g. O'Brien), so gold-miss names (e.g. McAllister) would
        // otherwise fall through to BART and read as two words.
        let env = ProcessInfo.processInfo.environment
        let useCustomLexicon = env["KOKORO_CUSTOM_LEXICON"] != nil
            || env["KOKORO_CUSTOM_LEXICON_AUTO"] != nil
        out = applyCelticNames(out, customLexiconActive: useCustomLexicon)
        out = applyTechnicalAliases(out)
        // Time+meridiem (5:30 a.m.) must run BEFORE wrapDottedAbbreviations +
        // wrapTimes so it claims the whole span as one unit. Avoids the "ammy"
        // adjacency where "a.m. My" runs together.
        out = wrapTimeMeridiem(out)
        // Abbreviation expansion (Phase 3 port of kokorog2p). Replaces
        // the prior `wrapDottedAbbreviations` + `wrapTitles` pair.
        out = KokoroAbbreviations.expand(out)
        out = wrapIsoDates(out)
        out = wrapTimes(out)
        out = wrapIPv4Address(out)
        // Number expansion (Phase 4 port of kokorog2p/en/numbers.py).
        // Replaces the prior `wrapMoney` / `wrapCurrency` / `wrapPercentages`
        // / `wrapTemperatures` / `wrapUnits` / `wrapRatios` / `wrapOrdinals`
        // set. Every digit we claim is pre-expanded into English words so
        // FluidAudio's second preprocessing pass sees no bare digits.
        out = KokoroNumbers.expand(out)
        out = wrapRoomCodes(out)
        out = wrapAlphaNumericCodes(out)
        out = wrapInitialisms(out)
        out = wrapAlphaSlash(out)
        out = applyPennContextOverrides(out)
        if !useCustomLexicon {
            out = applyGoldLexiconOverrides(out)
        }
        out = applyHomographOverrides(out)
        return out
    }

    /// Phase 8 entry point. Runs only the structural compensators —
    /// the stages that compensate for FluidAudio's second preprocessing
    /// pass (checkpoint A layer 1) — and skips every phonetic-override
    /// layer that `KokoroG2P.resolve` + `KokoroG2P.emit` have already
    /// handled: Celtic names, Penn-context, gold-lexicon, homograph.
    ///
    /// Callers hand this the post-`emit` annotated text; the compensator
    /// regexes' `<>` / `[]` guards keep them from re-matching inside
    /// spliced `<sub>` or `[word](/ipa/)` spans. Order matches `normalize`
    /// so any ordering invariants between stages hold.
    public static func compensatorsOnly(_ text: String) -> String {
        var out = text
        out = wrapEmails(out)
        out = wrapURLs(out)
        out = wrapPhoneNumbers(out)
        out = applyHyphenatedCompounds(out)
        out = applyTechnicalAliases(out)
        out = wrapTimeMeridiem(out)
        out = KokoroAbbreviations.expand(out)
        out = wrapIsoDates(out)
        out = wrapTimes(out)
        out = wrapIPv4Address(out)
        out = KokoroNumbers.expand(out)
        out = wrapRoomCodes(out)
        out = wrapAlphaNumericCodes(out)
        out = wrapInitialisms(out)
        out = wrapAlphaSlash(out)
        return out
    }

    // MARK: - POS-aware homograph disambiguation (NLTagger)

    /// One homograph word's POS → IPA map, assembled from the lexicon's
    /// `byPOS` variants via the universal-POS-first contract (plan
    /// Phase 2). Penn keys are collapsed via `POSKey.parent`; `None`
    /// (stressed function-word variants) and bare `DT` are deliberately
    /// NOT auto-fired from NLTagger output.
    fileprivate struct HomographRule: Sendable {
        /// NLTag.rawValue → IPA (only for `.noun`/`.verb`/`.adjective`/`.adverb`).
        let byTag: [String: String]
        /// DEFAULT variant. Nil when the dict explicitly stores null for
        /// DEFAULT — in that case the word has no safe fallback and we
        /// emit no override (plan: "never substitute an unrelated variant").
        let defaultIPA: String?
    }

    /// Every POS-keyed homograph in the merged dict, rebuilt at static
    /// init time. The "hand-tuned overlay" below wins on conflict for
    /// the five words today's code specialises.
    private static let homographRules: [String: HomographRule] = {
        var rules: [String: HomographRule] = [:]
        for (word, variants) in KokoroLexicon.allHomographs() {
            var byTag: [String: String] = [:]
            // Universal POS first (the dominant key format in kokorog2p).
            if let v = variants["VERB"] { byTag["Verb"] = v }
            if let v = variants["NOUN"] { byTag["Noun"] = v }
            if let v = variants["ADJ"] { byTag["Adjective"] = v }
            if let v = variants["ADV"] { byTag["Adverb"] = v }
            // Penn variants (VBD/VBN/VBP/DT) are deliberately NOT seeded
            // into NLTagger tags. NLTagger's `.verb` is tense-agnostic, so
            // mapping `.verb`→VBD would promote past-tense IPA to every
            // verb use (e.g. present-tense `read` → /ɹɛd/). Words whose
            // sense depends on Penn-level tense are handled by
            // `pennContextRules` with explicit lexical cues instead.
            // `None` (stressed function words) is likewise never auto-fired.
            let defaultIPA = variants["DEFAULT"]
            // Only register a rule if NLTagger can actually help (non-empty
            // byTag), otherwise we'd just emit DEFAULT unconditionally and
            // step on whatever BART would have produced for ambiguous context.
            guard !byTag.isEmpty else { continue }
            rules[word] = HomographRule(byTag: byTag, defaultIPA: defaultIPA)
        }
        // Hand-tuned overlay (plan Phase 2 step 4 — POST-lookup safety).
        // Overrides the auto-discovered rule for the handful of words
        // where the dict's variant layout and BART's likely rendering
        // don't line up with the effect we want.
        let handTuned: [String: HomographRule] = [
            "live": HomographRule(byTag: ["Verb": "lˈɪv"], defaultIPA: "lˈIv"),
            "lead": HomographRule(byTag: ["Verb": "lˈid"], defaultIPA: "lˈɛd"),
            "wind": HomographRule(byTag: ["Verb": "wˈInd"], defaultIPA: "wˈɪnd"),
            "tear": HomographRule(byTag: ["Verb": "tˈɛɹ"], defaultIPA: "tˈɪɹ"),
            "bass": HomographRule(byTag: [:], defaultIPA: "bˈAs"),
        ]
        for (word, rule) in handTuned {
            rules[word] = rule
        }
        return rules
    }()

    /// Words that, when preceding a homograph, strongly suggest it's
    /// NOT a verb (copular `be` forms, progressive adverbs). Used to
    /// veto NLTagger's VERB tag — retained as a POST-lookup safety
    /// layer per plan Phase 2.
    private static let copulaVeto: Set<String> = [
        "is", "are", "was", "were", "be", "been", "being", "am", "'s", "'re",
        "still", "very", "quite", "so", "really", "truly",
    ]

    private static func applyHomographOverrides(_ text: String) -> String {
        guard !homographRules.isEmpty else { return text }
        // Only tag if at least one homograph word appears (avoids NLTagger setup cost otherwise).
        let lowered = text.lowercased()
        let relevant = homographRules.keys.contains(where: { lowered.range(of: $0) != nil })
        guard relevant else { return text }

        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text

        var decisions: [(NSRange, String, String)] = []
        let nsText = text as NSString

        var priorWord: String? = nil
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, range in
            let word = String(text[range])
            let key = word.lowercased()
            defer { priorWord = key }
            guard let rule = homographRules[key] else { return true }
            var tagKey: String? = tag?.rawValue
            if tagKey == "Verb", let prior = priorWord, copulaVeto.contains(prior) {
                tagKey = nil  // force DEFAULT (adjective/noun sense)
            }
            let resolved = tagKey.flatMap { rule.byTag[$0] } ?? rule.defaultIPA
            guard let ipa = resolved else { return true }  // null DEFAULT — skip
            let nsRange = NSRange(range, in: text)
            if isInsideMarkupTag(at: nsRange.location, in: nsText) { return true }
            decisions.append((nsRange, word, ipa))
            return true
        }

        var out = text
        for (nsRange, word, ipa) in decisions.reversed() {
            guard let r = Range(nsRange, in: out) else { continue }
            out.replaceSubrange(r, with: emitIPAOverride(word: word, ipa: ipa))
        }
        return out
    }

    private static func isInsideMarkupTag(at location: Int, in ns: NSString) -> Bool {
        // Heuristic: scan backwards from `location` — if we hit `[` or `<` before `]`/`>` or the start, we're inside a tag.
        var i = location - 1
        while i >= 0 {
            let c = ns.character(at: i)
            if c == 0x5D /* ] */ || c == 0x3E /* > */ { return false }
            if c == 0x5B /* [ */ || c == 0x3C /* < */ { return true }
            i -= 1
        }
        return false
    }

    // MARK: - Markdown IPA overrides (FluidAudio's `[word](/ipa/)` surface)

    /// Emit a FluidAudio markdown phonetic override — `[word](/<space-separated IPA>/)`.
    /// The parser splits on whitespace into per-token phoneme strings, which is what
    /// FluidAudio's PhonemeMapper expects (one IPA phoneme per token).
    private static func emitIPAOverride(word: String, ipa: String) -> String {
        let tokens = ipa.unicodeScalars.map { String($0) }.joined(separator: " ")
        return "[\(word)](/\(tokens)/)"
    }

    /// Words we know (or suspect) Kokoro's built-in G2P mispronounces, fixed
    /// via gold-lexicon IPA. Runs late so structural transforms (SSML, money,
    /// dates…) go first. Conservative list by default — aggressive coverage
    /// is gated behind the `KOKORO_GOLD_AGGRESSIVE` env var.
    private static let goldOverrideWords: [String] = [
        "Maya", "Worcestershire", "colonel", "Colonel",
        "kettle", "choir", "iron", "rural", "squirrel", "February",
        "boil",
    ]

    /// Extra words to override when `KOKORO_GOLD_AGGRESSIVE=1`. These are
    /// compound `/aɪ/`-bearing words and other terms Kokoro's CoreML G2P has
    /// historically struggled with (see completed task #49).
    private static let goldOverrideWordsAggressive: [String] = [
        "midnight", "moonlight", "spotlight", "sunrise", "sideline",
        "online", "offline", "outside", "website", "deadline",
        "portrait", "email", "rolling",
        "review", "research", "approved", "defense", "began",
    ]

    private static func applyGoldLexiconOverrides(_ text: String) -> String {
        var out = text
        let aggressive = ProcessInfo.processInfo.environment["KOKORO_GOLD_AGGRESSIVE"] != nil
        let words = aggressive ? goldOverrideWords + goldOverrideWordsAggressive : goldOverrideWords
        for word in words {
            guard let ipa = KokoroLexicon.lookupIPA(word) else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: word)
            // Skip matches already inside another override or an SSML tag.
            let pattern = #"(?<![A-Za-z\[<>/])"# + escaped + #"(?![A-Za-z\]<>/])"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = out as NSString
            let matches = re.matches(in: out, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard let r = Range(match.range, in: out) else { continue }
                let source = String(out[r])
                out.replaceSubrange(r, with: emitIPAOverride(word: source, ipa: ipa))
            }
        }
        return out
    }

    // NOTE on SSML surface: FluidAudio's `SSMLProcessor` has a word-indexing
    // bug in `<phoneme>` handling — `countWordsBeforeIndex` is called on the
    // text with OTHER tags still in place, so the literal characters of
    // `<sub alias="…">`, `<say-as …>`, etc. (like "sub", "alias", "say",
    // "as", "interpret") are counted as words. Any `<phoneme>` override
    // therefore lands at a garbage word index, corrupting downstream
    // synthesis. `<sub>` and `<say-as>` don't create phonetic overrides, so
    // they're safe. We only emit those two tag kinds here.

    // MARK: - Technical aliases (mixed-case tokens that the initialism regex misses)

    /// Mixed-case technical terms that Kokoro's G2P can't handle. Applied
    /// before the all-caps initialism wrapper so they don't get partially
    /// letter-split (e.g. `IPv4` → `<say-as>IP</say-as>v4` reads "ipver").
    private static let technicalAliases: [(source: String, alias: String)] = [
        ("IPv4", "I P version four"),
        ("IPv6", "I P version six"),
    ]

    private static func applyTechnicalAliases(_ text: String) -> String {
        var out = text
        for (source, alias) in technicalAliases {
            let escaped = NSRegularExpression.escapedPattern(for: source)
            let pattern = "(?<![A-Za-z0-9])" + escaped + "(?![A-Za-z0-9])"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: (out as NSString).length)
            let replacement = #"<sub alias="\#(alias)">\#(source)</sub>"#
            out = re.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: escapeTemplate(replacement))
        }
        return out
    }

    // MARK: - Celtic surname prefixes (O'/Mc/Mac)

    /// Programmatic rule: for `O'X`, `McX`, `MacX` proper nouns, compose IPA
    /// from a fixed prefix IPA + gold-lexicon lookup of the stem. Replaces the
    /// prior hand-written per-surname IPA table — this scales to any stem
    /// covered by the gold lexicon (~90k words). For stems absent from gold,
    /// falls back to `<sub alias="...">` with a phonetic respelling.
    ///
    /// Kokoro phoneme-inventory prefixes (capital `O` = /oʊ/ diphthong):
    ///   - `O'`  → `O`       ("oh")
    ///   - `Mc`  → `mˈɪk`    ("mick")
    ///   - `Mac` → `mˈæk`    ("mack")
    public struct CelticNameMatch {
        public let range: NSRange      // full matched span (includes possessive if captured)
        public let fullText: String    // e.g. "O'Brien's"
        public let bareName: String    // e.g. "O'Brien"
        public let kind: CelticKind    // O / Mc / Mac
        public let stem: String        // e.g. "Brien"
        public let possessive: String? // e.g. "'s" or nil
    }

    public enum CelticKind: String { case oApostrophe = "O'", mc = "Mc", mac = "Mac" }

    private static let celticPattern = #"(?<![A-Za-z])(O'|Mc|Mac)([A-Z][a-z]+)(['’]s)?(?![A-Za-z])"#

    /// Scan `text` for Celtic-name tokens. Exposed for the runner's custom
    /// lexicon builder.
    public static func findCelticNames(in text: String) -> [CelticNameMatch] {
        guard let re = try? NSRegularExpression(pattern: celticPattern) else { return [] }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { m in
            guard let kind = CelticKind(rawValue: ns.substring(with: m.range(at: 1))) else { return nil }
            let stem = ns.substring(with: m.range(at: 2))
            let possessive: String? = m.range(at: 3).location != NSNotFound
                ? ns.substring(with: m.range(at: 3))
                : nil
            let fullText = ns.substring(with: m.range)
            let bareName = "\(kind.rawValue)\(stem)"
            return CelticNameMatch(
                range: m.range,
                fullText: fullText,
                bareName: bareName,
                kind: kind,
                stem: stem,
                possessive: possessive
            )
        }
    }

    private static func celticPrefixIPA(for kind: CelticKind) -> String {
        switch kind {
        case .oApostrophe: return "O"         // /oʊ/ per Kokoro inventory
        case .mc: return "mˈɪk"
        case .mac: return "mˈæk"
        }
    }

    /// Minimal stem-respelling map: proper-noun stems that gold doesn't carry
    /// directly, but which rhyme with (or are homophonous with) a word that
    /// IS in gold. BART G2P mispronounces the raw stem (e.g. "Brien" → "breen")
    /// so we substitute the respelling before the gold lookup. Each entry must
    /// be a word that exists in `us_gold.json`.
    private static let celticStemRespelling: [String: String] = [
        "Brien": "Bryan",   // → bɹˈIən
        "Reilly": "Riley",  // → ɹˈIli
        "Neil": "Kneel",    // → nˈil
    ]

    /// Build IPA for a Celtic match. Strategy (matches plan checkpoint D):
    ///   1. **Full-name plain lookup.** If the merged dict carries a
    ///      direct pronunciation (`McCarthy`, `MacGyver`, `McCoy`, …),
    ///      use it verbatim. Prefix composition only runs when the
    ///      dict has nothing.
    ///   2. Prefix IPA + direct stem lookup.
    ///   3. Prefix IPA + respell via `celticStemRespelling` → gold lookup.
    ///   4. Return nil → caller emits a `<sub alias="Oh X">` fallback.
    ///
    /// `includePossessive` = append `z` (/z/) when the match captured `'s`.
    /// Keep off for the custom-lexicon path (keys must be bare words).
    public static func celticIPA(for match: CelticNameMatch, includePossessive: Bool) -> String? {
        let suffix = (includePossessive && match.possessive != nil) ? "z" : ""
        if let ipa = KokoroLexicon.lookupPlainTokens(match.bareName) {
            return ipa.tokens.joined() + suffix
        }
        let stemIPA: String
        if let ipa = KokoroLexicon.lookupIPA(match.stem) {
            stemIPA = ipa
        } else if let respell = celticStemRespelling[match.stem],
            let ipa = KokoroLexicon.lookupIPA(respell)
        {
            stemIPA = ipa
        } else {
            return nil
        }
        let prefix = celticPrefixIPA(for: match.kind)
        return prefix + stemIPA + suffix
    }

    /// Run Celtic-name handling. Always safe to call.
    ///
    /// - `customLexiconActive=true`: IPA-hit names are left alone (the custom
    ///   lexicon will handle them via FluidAudio's G2P chain — emitting
    ///   markdown IPA here would stack two overrides on the same word).
    ///   Gold-miss names STILL get their `<sub alias>` fallback emitted; the
    ///   custom-lexicon builder skips them, so without this pass `McAllister`
    ///   would fall through to BART and read as two words.
    /// - `customLexiconActive=false`: emits markdown IPA for hits, sub-alias for misses.
    private static func applyCelticNames(_ text: String, customLexiconActive: Bool) -> String {
        let matches = findCelticNames(in: text)
        guard !matches.isEmpty else { return text }
        var out = text
        for match in matches.reversed() {
            guard let r = Range(match.range, in: out) else { continue }
            if let ipa = celticIPA(for: match, includePossessive: true) {
                if customLexiconActive { continue }  // custom lexicon handles bare name
                out.replaceSubrange(r, with: emitIPAOverride(word: match.fullText, ipa: ipa))
            } else {
                // Gold miss → sub-alias respelling.
                //   O'X → "Oh X" (space OK; O and stem are separable)
                //   McX / MacX → "Mack<stem>" (NO space; the prefix glues to
                //   the stem in natural speech — "Mack Allister" reads as two
                //   words which is wrong for a surname).
                let alias: String
                switch match.kind {
                case .oApostrophe:
                    alias = "Oh \(match.stem)"
                case .mc, .mac:
                    alias = "Mack\(match.stem.lowercased())"
                }
                let wrap = #"<sub alias="\#(alias)">\#(match.bareName)</sub>"#
                let tail = match.possessive ?? ""
                out.replaceSubrange(r, with: wrap + tail)
            }
        }
        return out
    }

    // MARK: - Hyphenated compounds (state-of-the-art, mother-in-law, …)

    /// Alphabetic hyphen-chain with 3+ segments. Replaces internal hyphens
    /// with spaces via a `<sub>` alias so the TTS chunker doesn't fragment
    /// the phrase into choppy fragments. Two-segment compounds (long-term,
    /// well-known) are left alone — they usually read fine as single units.
    /// Runs after URL/email protection so domain/path hyphens aren't touched.
    private static func applyHyphenatedCompounds(_ text: String) -> String {
        // Lookbehind/lookahead reject `>`/`<` so we don't touch hyphenated
        // sequences inside an already-emitted `<sub>` source (e.g. a URL
        // like `foo-bar-baz.com` wrapped by wrapURLs).
        let pattern = #"(?<![A-Za-z0-9>])([A-Za-z]+(?:-[A-Za-z]+){2,})(?![A-Za-z0-9<])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let source = ns.substring(with: match.range)
            let alias = source.replacingOccurrences(of: "-", with: " ")
            guard let r = Range(match.range, in: out) else { continue }
            out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(source)</sub>"#)
        }
        return out
    }

    // MARK: - Time + meridiem (5:30 a.m., 6:47 p.m., …)

    /// `H:MM a.m./p.m.` → single `<sub>` span so the time and meridiem are
    /// pronounced as one prosodic unit. Mid-sentence: alias is "H MM A M".
    /// Sentence-boundary (followed by whitespace + capital): alias becomes
    /// "H MM in the morning." / "in the evening." so the meridiem doesn't
    /// end in `M` — which would collide with a following `M`-initial word
    /// ("a.m. My" → "ammy").
    private static func wrapTimeMeridiem(_ text: String) -> String {
        let pattern = #"(?<![A-Za-z0-9])(\d{1,2}):(\d{2})(\s+)([aApP])\.([mM])\.(?![A-Za-z0-9])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            guard let r = Range(match.range, in: out) else { continue }
            let hours = ns.substring(with: match.range(at: 1))
            let mins = ns.substring(with: match.range(at: 2))
            let meridiemLetter = ns.substring(with: match.range(at: 4)).lowercased()
            let isAM = meridiemLetter == "a"
            let source = String(out[r])
            let tailStart = match.range.location + match.range.length
            let followsSentenceStart: Bool = {
                guard tailStart + 1 < ns.length else { return false }
                let after = ns.substring(
                    with: NSRange(location: tailStart, length: min(3, ns.length - tailStart))
                )
                return after.range(of: #"^\s+[A-Z]"#, options: .regularExpression) != nil
            }()
            let meridiem = isAM ? "A M" : "P M"
            let alias: String
            if followsSentenceStart {
                // Ellipsis forces a hard pause so the trailing `M` of
                // the meridiem doesn't fuse with the next sentence's
                // first word (avoids the "A M. My" → "ammy" collision).
                // Previously used "in the morning/evening" here, which
                // caused FluidAudio's downstream preprocessor to rewrite
                // "30 in" as "30 inches" — see plan checkpoint B.
                alias = "\(hours) \(mins) \(meridiem). …"
            } else {
                alias = "\(hours) \(mins) \(meridiem)"
            }
            out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(source)</sub>"#)
        }
        return out
    }

    /// Spoken letter names (BART pronounces most capitals well, but under
    /// unit-normalization `C`/`F` get reinterpreted as Celsius/Fahrenheit and
    /// `M` can collide with adjacent `M`-initial words). Used by wrapRoomCodes.
    private static let letterSpelling: [Character: String] = [
        "A": "ay", "B": "bee", "C": "see", "D": "dee", "E": "ee",
        "F": "eff", "G": "gee", "H": "aitch", "I": "eye", "J": "jay",
        "K": "kay", "L": "ell", "M": "em", "N": "en", "O": "oh",
        "P": "pee", "Q": "cue", "R": "are", "S": "ess", "T": "tee",
        "U": "you", "V": "vee", "W": "double you", "X": "ex", "Y": "why", "Z": "zee",
    ]

    // MARK: - Email / URL / phone (ported from Kokoro-FastAPI normalizer.py)

    /// RFC-ish email → `<sub alias="user at host dot tld">…</sub>`.
    private static func wrapEmails(_ text: String) -> String {
        let pattern = #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let source = ns.substring(with: match.range)
            let parts = source.split(separator: "@", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let user = parts[0].replacingOccurrences(of: ".", with: " dot ")
                .replacingOccurrences(of: "-", with: " dash ")
                .replacingOccurrences(of: "_", with: " underscore ")
            let host = parts[1].replacingOccurrences(of: ".", with: " dot ")
                .replacingOccurrences(of: "-", with: " dash ")
            let alias = "\(user) at \(host)"
            guard let r = Range(match.range, in: out) else { continue }
            out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(source)</sub>"#)
        }
        return out
    }

    /// HTTP(S) / `www.` / bare TLD URLs (non-IP) → spelled-out form.
    /// Mirrors the remsky/Kokoro-FastAPI URL handler: dots in domain become
    /// " dot ", path slashes become " slash ", dashes/underscores spelled out,
    /// port numbers prefixed with " colon ".
    private static let validTLDs: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "int", "biz", "info", "io",
        "co", "us", "uk", "eu", "de", "fr", "jp", "cn", "ca", "au", "nz",
        "ru", "br", "mx", "es", "it", "nl", "ai", "dev", "app", "xyz",
    ]

    private static func wrapURLs(_ text: String) -> String {
        // Sort by length descending so `com` wins over `co` in alternation
        // (regex alternation picks first match at a position, not longest).
        let tldAlt = validTLDs.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .joined(separator: "|")
        // protocol? (www.)? host (:port)? (/path)?  — host must end in a known TLD
        // followed by a word boundary. Lookbehind `(?<![@A-Za-z0-9])` prevents
        // matching inside an email's source text or inside a longer identifier.
        // Path excludes whitespace AND quote/angle-bracket characters so a
        // quoted URL (`"www.site.io/x".`) doesn't swallow the closing quote.
        // Trailing sentence punctuation that sneaks in is stripped below.
        let pattern = #"(?i)(?<![@A-Za-z0-9])(https?://|www\.)?([A-Za-z0-9][A-Za-z0-9.-]*\.(?:\#(tldAlt)))\b(:\d+)?(/[^\s"'<>]*)?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            // Strip trailing sentence-terminal punctuation from the captured
            // URL. `[^\s"'<>]*` already rejects quotes, but `,`, `.`, `;`,
            // `:`, `!`, `?`, and closing brackets/parens are valid URL chars
            // that usually mean sentence punctuation in prose. Stripping
            // also makes the `<sub>` span leave the period outside, so
            // FluidAudio's sentence segmenter still sees the full stop.
            var effective = match.range
            while effective.length > 0 {
                let tail = ns.character(at: effective.location + effective.length - 1)
                // .,;:!?)]}  (no ASCII double-quote — path class already excludes it)
                let punct: Set<unichar> = [0x2E, 0x2C, 0x3B, 0x3A, 0x21, 0x3F, 0x29, 0x5D, 0x7D]
                if punct.contains(tail) {
                    effective.length -= 1
                } else {
                    break
                }
            }
            guard effective.length > 0, let r = Range(effective, in: out) else { continue }
            let source = ns.substring(with: effective)
            let alias = speakableURL(source)
            out.replaceSubrange(r, with: #"<sub alias="\#(escapeAttribute(alias))">\#(source)</sub>"#)
        }
        return out
    }

    private static func speakableURL(_ url: String) -> String {
        var s = url
        s = s.replacingOccurrences(of: "https://", with: "https ", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "http://", with: "http ", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "www.", with: "www ", options: .caseInsensitive)
        // Port ": 1234" → " colon 1234 " — do before replacing bare colons.
        if let portRe = try? NSRegularExpression(pattern: #":(\d+)"#) {
            let ns = s as NSString
            s = portRe.stringByReplacingMatches(
                in: s, options: [], range: NSRange(location: 0, length: ns.length),
                withTemplate: " colon $1"
            )
        }
        // Split domain/path at the first unescaped slash.
        if let slash = s.firstIndex(of: "/") {
            let domain = String(s[..<slash])
            let path = String(s[s.index(after: slash)...])
            s = domain.replacingOccurrences(of: ".", with: " dot ") + " slash " + path
        } else {
            s = s.replacingOccurrences(of: ".", with: " dot ")
        }
        s = s.replacingOccurrences(of: "-", with: " dash ")
        s = s.replacingOccurrences(of: "_", with: " underscore ")
        s = s.replacingOccurrences(of: "?", with: " question mark ")
        s = s.replacingOccurrences(of: "=", with: " equals ")
        s = s.replacingOccurrences(of: "&", with: " and ")
        s = s.replacingOccurrences(of: "%", with: " percent ")
        s = s.replacingOccurrences(of: "/", with: " slash ")
        // Digit runs → spelled-out digits ("101" → "one oh one"); prevents
        // FluidAudio from reading `reflex101.edu` as "reflex one hundred
        // one dot edu".
        if let digitRe = try? NSRegularExpression(pattern: #"\d+"#) {
            let ns = s as NSString
            let digitMatches = digitRe.matches(in: s, range: NSRange(location: 0, length: ns.length))
            for match in digitMatches.reversed() {
                let run = ns.substring(with: match.range)
                let words = run.map { ch -> String in
                    let d = Int(String(ch)) ?? 0
                    return d == 0 ? "oh" : KokoroNumbers.cardinal(d)
                }.joined(separator: " ")
                guard let r = Range(match.range, in: s) else { continue }
                // Pad with spaces so `reflex101` splits into "reflex one
                // oh one" — final whitespace collapser trims the excess.
                s.replaceSubrange(r, with: " \(words) ")
            }
        }
        // Collapse whitespace.
        if let wsRe = try? NSRegularExpression(pattern: #"\s+"#) {
            let ns = s as NSString
            s = wsRe.stringByReplacingMatches(
                in: s, options: [], range: NSRange(location: 0, length: ns.length),
                withTemplate: " "
            )
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// US-style phone numbers in several formats → digit-by-digit alias.
    /// `(555) 123-4567`, `555-123-4567`, `555.123.4567`, `+1 555 123 4567`.
    private static func wrapPhoneNumbers(_ text: String) -> String {
        let pattern = #"(\+?\d{1,2})?[ .-]?\(?(\d{3})\)?[ .-](\d{3})[ .-](\d{4})\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let source = ns.substring(with: match.range)
            let country: String = match.range(at: 1).location != NSNotFound
                ? ns.substring(with: match.range(at: 1)).replacingOccurrences(of: "+", with: "")
                : ""
            let area = ns.substring(with: match.range(at: 2))
            let prefix = ns.substring(with: match.range(at: 3))
            let line = ns.substring(with: match.range(at: 4))
            var parts: [String] = []
            if !country.isEmpty { parts.append(country.map { String($0) }.joined(separator: " ")) }
            parts.append(area.map { String($0) }.joined(separator: " "))
            parts.append(prefix.map { String($0) }.joined(separator: " "))
            parts.append(line.map { String($0) }.joined(separator: " "))
            let alias = parts.joined(separator: ", ")
            guard let r = Range(match.range, in: out) else { continue }
            out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(source)</sub>"#)
        }
        return out
    }

    // MARK: - Date / time / IPv4 (number expansion lives in KokoroNumbers)

    /// ISO-style `YYYY-MM-DD` → `<say-as interpret-as="date" format="ymd">`.
    private static func wrapIsoDates(_ text: String) -> String {
        let pattern = #"(?<![0-9])(\d{4}-\d{2}-\d{2})(?![0-9])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return re.stringByReplacingMatches(
            in: text, options: [], range: range,
            withTemplate: #"<say-as interpret-as="date" format="ymd">$1</say-as>"#
        )
    }

    /// Clock times `H:MM` or `HH:MM(:SS)?` → `<say-as interpret-as="time">`.
    /// Explicitly avoids matching ratio-like `1:1` to reduce false positives.
    private static func wrapTimes(_ text: String) -> String {
        // `<>` in the exclusions prevents matching inside a `<sub>` source
        // that wrapTimeMeridiem (or any earlier handler) has already wrapped.
        let pattern = #"(?<![0-9<>])(\d{1,2}:\d{2}(?::\d{2})?)(?![0-9<>])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return re.stringByReplacingMatches(
            in: text, options: [], range: range,
            withTemplate: #"<say-as interpret-as="time">$1</say-as>"#
        )
    }

    /// IPv4 addresses → digit-by-digit octets separated by the word "dot".
    /// `192.168.1.1` → alias "1 9 2 dot 1 6 8 dot 1 dot 1", which Kokoro's
    /// spell-out pass renders as "one nine two dot one six eight dot one dot one".
    private static func wrapIPv4Address(_ text: String) -> String {
        let pattern = #"(?<![0-9.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![0-9.])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let octets = (1...4).map { ns.substring(with: match.range(at: $0)) }
            let spaced = octets.map { $0.map { String($0) }.joined(separator: " ") }
            let alias = spaced.joined(separator: " dot ")
            let source = octets.joined(separator: ".")
            guard let r = Range(match.range, in: out) else { continue }
            out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(source)</sub>"#)
        }
        return out
    }

    // MARK: - Room / apartment codes (4B, 12C, …)

    /// Place-noun preludes that license the room-code rewrite. Without one
    /// of these preceding the token, a bare `digits + capital` could just
    /// as easily be a temperature (`98F`), a grade, or a model number, so
    /// we leave it for FluidAudio rather than forcing a spell-out. Kept as
    /// a lowercased set; matching is case-insensitive.
    private static let roomCodePreludes: Set<String> = [
        "apartment", "apt", "room", "rm", "gate", "exit", "building", "bldg",
        "suite", "ste", "flat", "unit", "floor", "fl", "lab", "block", "bay",
        "office", "studio", "box", "door", "zone",
    ]

    /// Short `digits + single uppercase letter` tokens used for apartment,
    /// room, gate, or suite numbers. Emitted as a `<sub>` with the letter
    /// pre-spelled in the alias ("12 see", "4 bee") so downstream
    /// preprocessing can't reinterpret a bare `C`/`F` as Celsius/Fahrenheit.
    private static func wrapRoomCodes(_ text: String) -> String {
        // Must NOT be preceded by `$`, `°`, or another digit — those belong to
        // money / temperature handlers. Followed by a non-alnum so we don't
        // catch prefixes of longer tokens. `<say-as characters>` was tried in
        // v19 but FluidAudio's own text preprocessing still saw bare "C" after
        // the SSML pass and applied the temperature-unit rule. Aliasing to a
        // full word ("see") eliminates the ambiguity in the downstream text.
        let pattern = #"(?<![A-Za-z0-9$°<>])(\d+)([A-Z])(?![A-Za-z0-9])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            // Require a place-noun prelude within the preceding word. Without
            // one, a bare `98F` or `12C` in prose is almost certainly NOT a
            // room code (it's a temperature, a grade, a model, or similar),
            // so we leave it for FluidAudio rather than forcing "98 eff".
            guard hasRoomCodePrelude(before: match.range.location, in: ns) else { continue }
            let digits = ns.substring(with: match.range(at: 1))
            let letter = ns.substring(with: match.range(at: 2))
            guard let letterChar = letter.first,
                let letterWord = letterSpelling[letterChar]
            else { continue }
            guard let r = Range(match.range, in: out) else { continue }
            let source = digits + letter
            let alias = "\(digits) \(letterWord)"
            out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(source)</sub>"#)
        }
        return out
    }

    /// Walk backwards from `location` over whitespace, then over an
    /// immediately-preceding alphabetic token, and return true when that
    /// token (lowercased, with a possible trailing `.` stripped) is one
    /// of `roomCodePreludes`.
    private static func hasRoomCodePrelude(before location: Int, in ns: NSString) -> Bool {
        var i = location - 1
        while i >= 0 {
            let c = ns.character(at: i)
            if c == 0x20 || c == 0x09 { i -= 1 } else { break }
        }
        let tokenEnd = i
        while i >= 0 {
            let c = ns.character(at: i)
            if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2E {
                i -= 1
            } else {
                break
            }
        }
        let tokenStart = i + 1
        guard tokenStart <= tokenEnd else { return false }
        let raw = ns.substring(with: NSRange(location: tokenStart, length: tokenEnd - tokenStart + 1))
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return roomCodePreludes.contains(trimmed)
    }

    // MARK: - Alphanumeric codes (flight codes, gate numbers, etc.)

    /// Patterns like `QF12` that the bare initialism regex grabs the letters
    /// of and leaves trailing digits behind (producing "Q F12" which Kokoro
    /// mangles). Grab the whole `[A-Z]{2,}\d+` run and spell it out.
    private static func wrapAlphaNumericCodes(_ text: String) -> String {
        let pattern = #"(?<![A-Za-z0-9<])([A-Z]{2,})(\d+)(?![A-Za-z0-9>])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let letters = ns.substring(with: match.range(at: 1))
            let digits = ns.substring(with: match.range(at: 2))
            let alias = letters.map { String($0) }.joined(separator: " ")
                + " " + digits.map { String($0) }.joined(separator: " ")
            let source = letters + digits
            guard let r = Range(match.range, in: out) else { continue }
            out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(source)</sub>"#)
        }
        return out
    }

    // MARK: - Initialisms (all-caps runs)

    /// All-caps initialisms that must be letter-spelled. Excludes
    /// `wordAcronyms` which Kokoro tends to render correctly as single
    /// words (NASA, NATO, SCUBA, ASAP, AIDS, …).
    private static let wordAcronyms: Set<String> = [
        "NASA", "NATO", "UNICEF", "UNESCO", "OPEC", "DARPA", "FEMA", "FIFA",
        "IKEA", "INTERPOL",
        "SCUBA", "LASER", "RADAR", "SONAR", "MODEM", "TASER",
        "GIF", "JPEG", "MPEG", "JSON",
        "SWAT", "SEAL",
        "AIDS", "SARS", "COVID", "EBOLA",
        "ASAP", "AWOL", "SNAFU", "FUBAR", "NIMBY", "WASP", "YOLO", "YAML",
    ]

    /// Wrap bare all-caps runs of 2+ letters in `<say-as interpret-as="characters">`.
    /// Single-capital words are left alone (sentence-initial common words).
    /// Two-letter runs (AI, TV) get the same treatment — apostrophe-free
    /// bare letter pairs are typically initialisms. Digits immediately on
    /// either side of the cap run disqualify the match (those go to
    /// `wrapAlphaNumericCodes` instead), as do adjacent `<`/`>` which mean
    /// the caps are already inside an SSML tag.
    private static func wrapInitialisms(_ text: String) -> String {
        let pattern = #"(?<![A-Za-z0-9<>])[A-Z]{2,}(?![A-Za-z0-9<>])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let matched = ns.substring(with: match.range)
            if wordAcronyms.contains(matched) { continue }
            guard let r = Range(match.range, in: out) else { continue }
            out.replaceSubrange(r, with: #"<say-as interpret-as="characters">\#(matched)</say-as>"#)
        }
        return out
    }

    /// `A/B` slash between two single capital letters reads as "A or B" —
    /// the standard way to disambiguate short option-label notation.
    /// Bounded by non-alphanumeric on both sides so `I/O` → "I or O" but
    /// `TCP/IP` (multi-letter) flows through untouched.
    private static func wrapAlphaSlash(_ text: String) -> String {
        let pattern = #"(?<![A-Za-z0-9/])([A-Z])/([A-Z])(?![A-Za-z0-9/])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            guard let r = Range(match.range, in: out) else { continue }
            let left = ns.substring(with: match.range(at: 1))
            let right = ns.substring(with: match.range(at: 2))
            let source = ns.substring(with: match.range)
            let alias = "\(left) or \(right)"
            out.replaceSubrange(r, with: #"<sub alias="\#(alias)">\#(source)</sub>"#)
        }
        return out
    }

    // MARK: - "read" past-tense disambiguation

    /// "Read" is a homograph. Kokoro's G2P defaults to the present-tense /ɹiːd/.
    /// When context makes past tense clearly correct, emit a markdown IPA
    /// The Penn-tag overlay (plan Phase 2). kokorog2p's merged dict
    /// stores Penn-keyed variants (VBD/VBP/VBN/DT) for a hand-finite
    /// set of words that NLTagger's coarse `.verb` / `.determiner` tag
    /// cannot disambiguate by POS alone — the sense depends on local
    /// syntactic context. Each rule here runs a regex against the
    /// surrounding tokens and, on match, emits a markdown IPA override
    /// pulled directly from the lexicon so dict changes flow through
    /// automatically.
    private struct PennContextRule: Sendable {
        /// Word as stored in the dict (lowercase, since we case-fold).
        let word: String
        /// POS key whose IPA we want on match.
        let pos: KokoroLexicon.POSKey
        /// `(prefix, suffix)` regex patterns bracketing the target word.
        /// Both are required to match.
        let prefixPattern: String?
        let suffixPattern: String?
    }

    /// Strong past-tense cues only — subject pronouns alone are NOT a
    /// cue, because "I read the newspaper every morning" is present
    /// tense. Two disjoint cue families: perfect/passive prefix
    /// (`had/have/has/been/was/...`) → VBN, and past-time-marker suffix
    /// (`yesterday`, `last week`, `... ago`) → VBD. Words without either
    /// cue flow through unchanged and let the dict default (present
    /// tense) reach BART.
    private static let pastPerfectPrefix =
        #"(?:had|have|has|having|been|was|were|be|being|is|are|never|ever|already|just)\s+(?:\w+\s+){0,2}"#
    private static let pastTimeSuffix =
        #"(?=[^.!?;\n]{0,80}?\b(?:yesterday|last\s+(?:night|week|month|year|summer|time)|\w+\s+ago|earlier|this\s+morning)\b)"#

    private static let pennContextRules: [PennContextRule] = [
        // "read" past participle (VBN): perfect / passive constructions.
        PennContextRule(word: "read", pos: .verbPastParticiple,
            prefixPattern: pastPerfectPrefix, suffixPattern: nil),
        // "read" past tense (VBD): followed by a past-time marker.
        PennContextRule(word: "read", pos: .verbPastTense,
            prefixPattern: nil, suffixPattern: pastTimeSuffix),
        // "reread": same cue families.
        PennContextRule(word: "reread", pos: .verbPastParticiple,
            prefixPattern: pastPerfectPrefix, suffixPattern: nil),
        PennContextRule(word: "reread", pos: .verbPastTense,
            prefixPattern: nil, suffixPattern: pastTimeSuffix),
        // "used to" (habitual construction) → VBD (/juːst/). The dict's
        // VBD convention: "used" as part of "used to …" habitual, not
        // literal past tense of "use".
        PennContextRule(word: "used", pos: .verbPastTense,
            prefixPattern: nil, suffixPattern: #"\s+to\b"#),
        // "wound" active past (VBD): "{subject} wound {object}".
        PennContextRule(word: "wound", pos: .verbPastTense,
            prefixPattern: #"(?:she|he|they|we|I|you|it|who|which|that)\s+"#,
            suffixPattern: nil),
        // "wound" passive/perfect (VBN): "(was/were/been/has/had/...) wound".
        PennContextRule(word: "wound", pos: .verbPastParticiple,
            prefixPattern: #"(?:was|were|been|being|is|are|be|had|have|has|having)\s+"#,
            suffixPattern: nil),
    ]

    private static func applyPennContextOverrides(_ text: String) -> String {
        var out = text
        for rule in pennContextRules {
            guard let ipa = KokoroLexicon.lookupIPA(rule.word, pos: rule.pos) else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: rule.word)
            let pattern = "\\b\(rule.prefixPattern ?? "")(\(escaped))\(rule.suffixPattern ?? "")\\b"
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            // Each rule sees the current `out`, which may already contain
            // markdown IPA emitted by earlier rules. Recompute the NSString
            // view per iteration so `ns.length` tracks those insertions.
            let ns = out as NSString
            let matches = re.matches(in: out, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                let wordRange = match.range(at: 1)
                guard let r = Range(wordRange, in: out) else { continue }
                let original = String(out[r])
                if isInsideMarkupTag(at: wordRange.location, in: ns) { continue }
                out.replaceSubrange(r, with: emitIPAOverride(word: original, ipa: ipa))
            }
        }
        return out
    }

    // MARK: - Helpers

    /// Escape `$` and `\` in a literal template string so NSRegularExpression
    /// doesn't treat them as back-references.
    private static func escapeTemplate(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "$", with: "\\$")
    }

    /// Escape characters that break an XML/SSML attribute value. Used for
    /// `alias="…"` content whenever the alias text is derived from source
    /// input (URLs, email addresses) rather than strings we synthesize
    /// ourselves. Alias text we construct from cardinal/ordinal tables
    /// never contains these characters.
    private static func escapeAttribute(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
