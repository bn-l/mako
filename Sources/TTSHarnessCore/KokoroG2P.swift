import Foundation

/// Phase 7 G2P orchestrator — Swift port of `kokorog2p/en/g2p.py` that
/// owns the decision-making layer of the Kokoro pipeline, independent
/// of SSML emission (layer 1 compensators stay in
/// `KokoroSSMLNormalizer`) and independent of the runner (Phase 8).
///
/// The resolver is a pure analysis: it produces a plan in the shape
/// `G2PResult(tokens, overrides, structuralSpans)` that a downstream
/// emitter can turn into markdown IPA / `<sub>` / `TtsCustomLexicon`
/// entries. It does not itself touch the source text beyond running
/// `KokoroPunctuation.normalize`, and it does not call into FluidAudio.
///
/// Pipeline (plan checkpoint):
///
///   1. `KokoroPunctuation.normalize`
///   2. `KokoroTokenizer.tokenize` (POS tags via `NLTagger.lexicalClass`)
///   3. Proper-name chain (checkpoint D):
///      a. Full-name plain lookup in the merged lexicon
///      b. Compositional O'/Mc/Mac prefix + stem lookup
///      c. Stem respelling map (`Brien`→`Bryan`)
///      d. Sub-alias fallback (`Mackallister`, `Oh Brien`)
///   4. Penn-context overlay (`read`/`reread` VBD/VBN, `used to`,
///      `wound` active/passive) — regex-cued IPA from the dict's
///      Penn-keyed variants. Runs before the NLTagger homograph pass
///      so a Penn resolution wins over the coarser universal POS.
///   5. POS-aware lexicon lookup for every remaining word token, with
///      copula-veto applied to verb decisions (plan rule G safety net)
///      and a hand-tuned overlay for the five words whose dict layout
///      doesn't line up cleanly with what BART would otherwise produce.
///   6. OOV policy (checkpoint E): default is "emit nothing" so BART
///      handles the token.
///
/// Layer routing (checkpoint A):
///
///   - Single-variant plain hit → token carries `phonemes`. Phase 8 uses
///     this to populate `TtsCustomLexicon` (word-keyed, layer 3).
///   - Homograph / proper-name / Penn-context IPA → entry in
///     `overrides`. Phase 8 emits markdown `[word](/ipa/)`
///     (occurrence-keyed, layer 2).
///   - Proper-name sub-alias fallback → entry in `structuralSpans`.
///     Phase 8 emits `<sub alias="…">source</sub>` (layer 1, overlap
///     with `KokoroSSMLNormalizer`'s compensator work).
///   - Miss → no override anywhere (layer 4, implicit BART).
public enum KokoroG2P {

    // MARK: - Result types

    public struct G2PResult: Sendable {
        public let originalText: String
        /// Output of `KokoroPunctuation.normalize(originalText)`.
        /// All subsequent ranges are into this string.
        public let normalizedText: String
        /// Every token (words, punctuation) in normalizedText order.
        /// `phonemes` is populated only for plain single-variant
        /// lexicon hits — those are the custom-lexicon candidates.
        /// Tokens covered by an override or structural span leave
        /// `phonemes` at `nil` so Phase 8 doesn't double-emit.
        public let tokens: [GToken]
        public let overrides: [PhoneticOverride]
        public let structuralSpans: [StructuralSpan]
    }

    /// Occurrence-keyed IPA override. Fires for POS-ambiguous words
    /// (homographs) and for Celtic surnames whose IPA we compose from
    /// a prefix + stem lookup — in both cases the resolution is
    /// contextual, so the custom lexicon (word-keyed) is the wrong
    /// channel.
    public struct PhoneticOverride: Sendable {
        public let sourceRange: NSRange
        /// Surface text for the markdown `[word]` slot. Includes the
        /// possessive suffix when the proper-name chain captured `'s`.
        public let word: String
        public let ipa: String
        public let reason: OverrideReason
        public let provenance: Provenance
    }

    public enum OverrideReason: String, Sendable {
        case homograph
        case properName
        case pennContext
    }

    public struct StructuralSpan: Sendable {
        public let sourceRange: NSRange
        public let sourceText: String
        public let alias: String
        public let reason: SpanReason
    }

    public enum SpanReason: String, Sendable {
        case properNameFallback
    }

    /// Which decision path produced the resolved IPA. Consumed by
    /// Phase 9's `LexiconProvenanceTests` and `KOKORO_G2P_TRACE`.
    public enum Provenance: Sendable, Equatable {
        case lexicon(tier: KokoroLexicon.LexiconTier, variant: String)
        case celticCompose(tier: KokoroLexicon.LexiconTier)
        case celticRespelling(tier: KokoroLexicon.LexiconTier)
        case handTunedOverlay
    }

    /// Phase 8 emission bundle: text with G2P overrides + structural
    /// spans already spliced in, plus the `TtsCustomLexicon`-ready
    /// entry map collected from plain-lookup token phonemes.
    public struct EmittedPlan: Sendable {
        public let annotatedText: String
        public let lexiconEntries: [String: [String]]
    }

    // MARK: - Public API

    public static func resolve(_ text: String) -> G2PResult {
        let normalized = KokoroPunctuation.normalize(text)
        var tokens = KokoroTokenizer.tokenize(normalized, posTag: true)
        var overrides: [PhoneticOverride] = []
        var spans: [StructuralSpan] = []

        // Pre-pass 1: proper-name chain claims multi-token spans.
        var claimed: [NSRange] = []
        for match in KokoroSSMLNormalizer.findCelticNames(in: normalized) {
            if let (ipa, provenance) = celticResolution(for: match) {
                overrides.append(PhoneticOverride(
                    sourceRange: match.range,
                    word: match.fullText,
                    ipa: ipa,
                    reason: .properName,
                    provenance: provenance
                ))
            } else {
                let alias: String
                switch match.kind {
                case .oApostrophe: alias = "Oh \(match.stem)"
                case .mc, .mac:    alias = "Mack\(match.stem.lowercased())"
                }
                spans.append(StructuralSpan(
                    sourceRange: match.range,
                    sourceText: match.fullText,
                    alias: alias + (match.possessive ?? ""),
                    reason: .properNameFallback
                ))
            }
            claimed.append(match.range)
        }

        // Pre-pass 2: Penn-context overlay. Claims single-token spans
        // around `read`/`used`/`wound` when the regex cues fire, using
        // the Penn-keyed variant's IPA from the dict.
        overrides.append(contentsOf: pennContextOverrides(in: normalized, claimed: &claimed))

        // Per-token walk: homograph resolution for uncovered word
        // tokens, then DEFAULT lookup for the remainder. We do NOT use
        // `lookupPlainTokens` here — it explicitly returns nil for any
        // POS-keyed entry, which would drop the safe DEFAULT for words
        // whose only alternates are Penn-only (`used` VBD, `wound` VBD/
        // VBN), `None`-keyed stressed variants (`there`, `here`), or
        // bare `DT` (`that`). Plan rule G calls those cases out:
        // "emit the DEFAULT IPA (or no override at all) — do not guess."
        // `KokoroLexicon.lookup(word)` with no POS hint resolves DEFAULT
        // for POS-keyed entries and returns the plain tokens for plain
        // entries, which is exactly the safe path.
        for i in tokens.indices {
            let token = tokens[i]
            guard token.isWord else { continue }
            if rangeOverlaps(token.sourceRange, any: claimed) { continue }

            if let override = resolveHomograph(tokens: tokens, at: i) {
                overrides.append(override)
                continue
            }
            // If the word IS a live homograph and `resolveHomograph`
            // returned nil, the rule deliberately has no safe DEFAULT
            // (plan: "never substitute an unrelated variant"). Skip —
            // reading DEFAULT here would re-materialise the null we
            // already rejected.
            if homographRules[token.text.lowercased()] != nil { continue }

            // Interjection overlay — the upstream misaki/kokorog2p dicts
            // ship `hm`/`hmm`/… with phoneme strings that are literally
            // the orthography (no vowel), which Kokoro renders as a
            // clipped consonant cluster. Any `hm+` spelling collapses to
            // a single stressed long-nasal IPA so no matter how many m's
            // the user types, it reads as a closed-mouth hum rather than
            // a vowel-based "hum".
            if isHmInterjection(token.text) {
                tokens[i].phonemes = hmInterjectionIPA
                tokens[i].rating = 4
                continue
            }

            if let hit = KokoroLexicon.lookup(token.text) {
                tokens[i].phonemes = hit.ipa
                tokens[i].rating = 4
            }
            // OOV — default policy: no override; BART handles it.
        }

        return G2PResult(
            originalText: text,
            normalizedText: normalized,
            tokens: tokens,
            overrides: overrides,
            structuralSpans: spans
        )
    }

    /// Phase 8 emission glue. Splice the plan's overrides (as markdown
    /// `[word](/ipa/)`) and structural spans (as `<sub alias="…">source</sub>`)
    /// back into `normalizedText` at their `sourceRange`s, and expose the
    /// plain-lookup phonemes as a ready-to-hand `[word: [tokens]]` map
    /// for `TtsCustomLexicon`.
    ///
    /// By construction in `resolve`, overrides and spans never overlap
    /// (proper-name and Penn-context pre-passes both claim ranges before
    /// the homograph walk runs), so a reverse-ordered splice is safe.
    /// Plain-token phonemes are only populated on tokens that weren't
    /// claimed and aren't in the homograph-rules set — so they never
    /// collide with an override/span either. Phase 8 consumers can feed
    /// `annotatedText` to `KokoroSSMLNormalizer.compensatorsOnly` and
    /// the lexicon map directly to `TtsCustomLexicon(entries:)`.
    public static func emit(_ result: G2PResult) -> EmittedPlan {
        struct Edit { let range: NSRange; let replacement: String }
        var edits: [Edit] = []
        for override in result.overrides {
            let tokens = override.ipa.unicodeScalars.map { String($0) }.joined(separator: " ")
            edits.append(Edit(
                range: override.sourceRange,
                replacement: "[\(override.word)](/\(tokens)/)"
            ))
        }
        for span in result.structuralSpans {
            edits.append(Edit(
                range: span.sourceRange,
                replacement: #"<sub alias="\#(span.alias)">\#(span.sourceText)</sub>"#
            ))
        }
        edits.sort { $0.range.location > $1.range.location }
        var out = result.normalizedText
        for edit in edits {
            guard let r = Range(edit.range, in: out) else { continue }
            out.replaceSubrange(r, with: edit.replacement)
        }

        var lexicon: [String: [String]] = [:]
        for token in result.tokens {
            guard let phonemes = token.phonemes else { continue }
            lexicon[token.text] = phonemes.unicodeScalars.map { String($0) }
        }
        return EmittedPlan(annotatedText: out, lexiconEntries: lexicon)
    }

    // MARK: - Proper-name chain

    private static func celticResolution(
        for match: KokoroSSMLNormalizer.CelticNameMatch
    ) -> (ipa: String, provenance: Provenance)? {
        let suffix = match.possessive != nil ? "z" : ""

        if let plain = KokoroLexicon.lookupPlainTokens(match.bareName) {
            return (plain.tokens.joined() + suffix,
                    .lexicon(tier: plain.tier, variant: "-"))
        }

        if let hit = KokoroLexicon.lookup(match.stem) {
            return (celticPrefixIPA(for: match.kind) + hit.ipa + suffix,
                    .celticCompose(tier: hit.tier))
        }

        if let respell = celticStemRespelling[match.stem],
            let hit = KokoroLexicon.lookup(respell)
        {
            return (celticPrefixIPA(for: match.kind) + hit.ipa + suffix,
                    .celticRespelling(tier: hit.tier))
        }

        return nil
    }

    private static func celticPrefixIPA(for kind: KokoroSSMLNormalizer.CelticKind) -> String {
        switch kind {
        case .oApostrophe: return "O"
        case .mc:          return "mˈɪk"
        case .mac:         return "mˈæk"
        }
    }

    private static let celticStemRespelling: [String: String] = [
        "Brien": "Bryan",
        "Reilly": "Riley",
        "Neil":  "Kneel",
    ]

    // MARK: - Penn-context overlay

    /// `(word, POS key, prefix regex?, suffix regex?)`. Mirrors
    /// `KokoroSSMLNormalizer.pennContextRules` verbatim — identical
    /// cues, identical POS keys. The overlay exists because NLTagger's
    /// `.verb` is tense-agnostic, so we can't distinguish VBD from VBP
    /// from POS alone.
    private struct PennContextRule: Sendable {
        let word: String
        let pos: KokoroLexicon.POSKey
        let prefixPattern: String?
        let suffixPattern: String?
    }

    private static let pastPerfectPrefix =
        #"(?:had|have|has|having|been|was|were|be|being|is|are|never|ever|already|just)\s+(?:\w+\s+){0,2}"#
    private static let pastTimeSuffix =
        #"(?=[^.!?;\n]{0,80}?\b(?:yesterday|last\s+(?:night|week|month|year|summer|time)|\w+\s+ago|earlier|this\s+morning)\b)"#
    /// Narrative-past prefix — widens `read` / `reread` VBD coverage
    /// beyond the temporal-adverb cue. Requires an earlier finite
    /// past-tense verb in the same sentence: either a common
    /// irregular (was/were/had/did/said/went/paid/…), or a word
    /// ending in `-ed` with at least 3 chars before the suffix
    /// (filters adjectives like "red", "bed", "sled" while keeping
    /// past-tense verbs like "walked", "handed", "graded", "asked").
    /// The sentence-boundary class intentionally excludes `.` —
    /// money decimals (`$450.00`) and dotted abbreviations (`Mr.`)
    /// otherwise fragment the scan and hide a legitimate past
    /// verb behind them. `{0,300}?` caps scan distance to stay
    /// away from cross-paragraph backtracking.
    private static let narrativePastVerbs =
        #"was|were|had|did|said|went|came|took|gave|told|paid|saw|made|found|kept|left|felt|thought|knew|held|brought|taught|caught|bought|heard|ran|sat|stood|understood|became|began|spoke|wrote|sent|lost|got|put|set|cut|hit|\w{3,}ed"#
    private static let narrativePastPrefix =
        #"(?:[^!?;\n]{0,300}?\b(?:"# + narrativePastVerbs + #")\b[^!?;\n]*?)"#
    /// Narrative-past suffix — mirror of the prefix for cases where
    /// the past-tense cue follows `read` ("Maya read the note aloud
    /// while the rest of us squirmed"). Lookahead only — doesn't
    /// extend the match range.
    private static let narrativePastSuffix =
        #"(?=[^!?;\n]{0,300}?\b(?:"# + narrativePastVerbs + #")\b)"#

    /// Subject-prefix for the narrative-past suffix rule. Required
    /// to block sentence-initial imperative "Read everything clearly"
    /// from getting rewritten as VBD just because a past-tense verb
    /// sits in a following clause ("…, she told the team"). A VBD
    /// "read" always has an explicit subject immediately before it;
    /// an imperative does not. The subject class is: personal pronoun,
    /// WH-relative, or a capitalised proper-noun token.
    private static let narrativePastSubjectPrefix =
        #"(?:she|he|they|we|I|you|it|who|which|that|[A-Z][a-z]+)\s+"#

    private static let pennContextRules: [PennContextRule] = [
        PennContextRule(word: "read", pos: .verbPastParticiple,
            prefixPattern: pastPerfectPrefix, suffixPattern: nil),
        PennContextRule(word: "read", pos: .verbPastTense,
            prefixPattern: nil, suffixPattern: pastTimeSuffix),
        PennContextRule(word: "read", pos: .verbPastTense,
            prefixPattern: narrativePastPrefix, suffixPattern: nil),
        PennContextRule(word: "read", pos: .verbPastTense,
            prefixPattern: narrativePastSubjectPrefix, suffixPattern: narrativePastSuffix),
        PennContextRule(word: "reread", pos: .verbPastParticiple,
            prefixPattern: pastPerfectPrefix, suffixPattern: nil),
        PennContextRule(word: "reread", pos: .verbPastTense,
            prefixPattern: nil, suffixPattern: pastTimeSuffix),
        PennContextRule(word: "reread", pos: .verbPastTense,
            prefixPattern: narrativePastPrefix, suffixPattern: nil),
        PennContextRule(word: "reread", pos: .verbPastTense,
            prefixPattern: narrativePastSubjectPrefix, suffixPattern: narrativePastSuffix),
        PennContextRule(word: "used", pos: .verbPastTense,
            prefixPattern: nil, suffixPattern: #"\s+to\b"#),
        PennContextRule(word: "wound", pos: .verbPastTense,
            prefixPattern: #"(?:she|he|they|we|I|you|it|who|which|that)\s+"#,
            suffixPattern: nil),
        PennContextRule(word: "wound", pos: .verbPastParticiple,
            prefixPattern: #"(?:was|were|been|being|is|are|be|had|have|has|having)\s+"#,
            suffixPattern: nil),
    ]

    private static func pennContextOverrides(
        in text: String, claimed: inout [NSRange]
    ) -> [PhoneticOverride] {
        var results: [PhoneticOverride] = []
        let ns = text as NSString
        for rule in pennContextRules {
            guard let hit = KokoroLexicon.lookup(rule.word, pos: rule.pos) else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: rule.word)
            let pattern = "\\b\(rule.prefixPattern ?? "")\\b(\(escaped))\\b\(rule.suffixPattern ?? "")"
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                let wordRange = match.range(at: 1)
                if rangeOverlaps(wordRange, any: claimed) { continue }
                let surface = ns.substring(with: wordRange)
                results.append(PhoneticOverride(
                    sourceRange: wordRange,
                    word: surface,
                    ipa: hit.ipa,
                    reason: .pennContext,
                    provenance: .lexicon(tier: hit.tier, variant: rule.pos.rawValue)
                ))
                claimed.append(wordRange)
            }
        }
        return results
    }

    // MARK: - Homograph rules (NLTagger universal-POS path)

    /// Per-word rule pulled from the dict's POS-keyed variants (VERB /
    /// NOUN / ADJ / ADV — universal only, Penn keys handled by the
    /// overlay above). A word is ONLY registered here when at least one
    /// universal-POS variant exists — otherwise `lookup(word, pos:
    /// .defaultVariant)` is just the plain-hit path and belongs on the
    /// custom lexicon.
    private struct HomographRule: Sendable {
        let byTag: [String: String]        // NLTag raw value → IPA
        let defaultIPA: String?
        let defaultTier: KokoroLexicon.LexiconTier?
        let variantTiers: [String: KokoroLexicon.LexiconTier]
        let handTuned: Bool
    }

    private static let homographRules: [String: HomographRule] = {
        var rules: [String: HomographRule] = [:]
        for (word, variants) in KokoroLexicon.allHomographs() {
            var byTag: [String: String] = [:]
            var variantTiers: [String: KokoroLexicon.LexiconTier] = [:]
            for (universal, tag) in [("VERB", "Verb"), ("NOUN", "Noun"),
                                     ("ADJ", "Adjective"), ("ADV", "Adverb")] {
                if let ipa = variants[universal] {
                    byTag[tag] = ipa
                    if let tier = tierForLookup(word: word, pos: universal) {
                        variantTiers[tag] = tier
                    }
                }
            }
            guard !byTag.isEmpty else { continue }
            let defaultIPA = variants["DEFAULT"]
            let defaultTier = defaultIPA.flatMap { _ in tierForLookup(word: word, pos: "DEFAULT") }
            rules[word.lowercased()] = HomographRule(
                byTag: byTag, defaultIPA: defaultIPA,
                defaultTier: defaultTier, variantTiers: variantTiers,
                handTuned: false
            )
        }
        // Hand-tuned overlay (plan Phase 2). Same entries the SSML
        // normalizer has today — they compensate for dict-layout vs
        // BART-output mismatches that auto-discovery can't capture.
        let handTuned: [String: (byTag: [String: String], defaultIPA: String?)] = [
            "live": (["Verb": "lˈɪv"], "lˈIv"),
            "lead": (["Verb": "lˈid"], "lˈɛd"),
            "wind": (["Verb": "wˈInd"], "wˈɪnd"),
            "tear": (["Verb": "tˈɛɹ"], "tˈɪɹ"),
            "bass": ([:],              "bˈAs"),
        ]
        for (word, data) in handTuned {
            rules[word] = HomographRule(
                byTag: data.byTag, defaultIPA: data.defaultIPA,
                defaultTier: nil, variantTiers: [:], handTuned: true
            )
        }
        return rules
    }()

    /// Resolve which tier holds a given `word`/`pos` entry. Used only
    /// at homograph-rule construction time for provenance.
    private static func tierForLookup(word: String, pos: String) -> KokoroLexicon.LexiconTier? {
        guard let posKey = KokoroLexicon.POSKey(rawValue: pos) else { return nil }
        return KokoroLexicon.lookup(word, pos: posKey)?.tier
    }

    private static func resolveHomograph(
        tokens: [GToken], at index: Int
    ) -> PhoneticOverride? {
        let token = tokens[index]
        let lower = token.text.lowercased()
        guard let rule = homographRules[lower] else { return nil }

        var tagKey: String? = token.tag
        if tagKey == "Verb" {
            let prev = index > 0 ? tokens[index - 1].text.lowercased() : ""
            if copulaVeto.contains(prev) { tagKey = nil }
        }
        // Verb-frame promotion (plan rule G follow-up). NLTagger.lexicalClass
        // systematically mis-tags finite verbs in clauses headed by a bare
        // plural/pronoun subject — `Children present awards` lands as
        // Adjective, `Models project sales` as Noun. We override only
        // when a clause-local resolver finds positive verb-frame evidence;
        // otherwise we leave the tag alone and fall through to DEFAULT.
        // Both Noun and Adjective are entry points because NLTagger picks
        // either label on different homographs (`present` → Adjective,
        // `project` → Noun).
        if (tagKey == "Noun" || tagKey == "Adjective"),
           rule.byTag["Verb"] != nil,
           shouldPromoteToVerb(tokens: tokens, at: index) {
            tagKey = "Verb"
        }
        let ipa: String?
        let provenance: Provenance
        if let key = tagKey, let hit = rule.byTag[key] {
            ipa = hit
            provenance = rule.handTuned
                ? .handTunedOverlay
                : .lexicon(tier: rule.variantTiers[key] ?? .kokorog2pGold,
                           variant: universalKey(for: key) ?? "-")
        } else {
            ipa = rule.defaultIPA
            provenance = rule.handTuned
                ? .handTunedOverlay
                : .lexicon(tier: rule.defaultTier ?? .kokorog2pGold,
                           variant: "DEFAULT")
        }
        guard let resolved = ipa else { return nil }

        return PhoneticOverride(
            sourceRange: token.sourceRange,
            word: token.text,
            ipa: resolved,
            reason: .homograph,
            provenance: provenance
        )
    }

    /// Clause-local resolver for verb-frame evidence around a homograph
    /// NLTagger didn't already tag Verb. Walks backward from `index`
    /// through adjacent tokens and aborts with "don't promote" on any
    /// evidence that H is NOT the main clause verb:
    ///
    ///   (a) A Determiner appears before H at the current clause level:
    ///       H sits inside a Det-headed NP ("The analysts project
    ///       manager resigned" — `project` is a noun-compound modifier
    ///       inside "The analysts project manager", not a verb).
    ///   (b) A Verb-tagged token appears before H inside the clause:
    ///       the predicate slot is already claimed, so H is likely an
    ///       object noun ("He signed the contract in blue ink").
    ///   (c) A copulaVeto word precedes H at the clause level:
    ///       belt-and-braces against NLTagger mis-tagging "is/are/was"
    ///       when they appear as non-Verb (contractions etc.).
    ///
    /// Walk terminates at a clause boundary: strong sentence-end
    /// punctuation (`.!?;:`), a comma (weak clause boundary — enough
    /// to separate a leading adverbial from the main clause), a
    /// Conjunction-tagged token, or a closed list of subordinators
    /// NLTagger frequently mis-classifies (`when`/`while`/`because`/
    /// …). Those are an English-linguistic class, not a fixture list.
    ///
    /// Forward guard: if the word immediately after H is Verb-tagged,
    /// H is almost certainly the subject, not the verb ("The parking
    /// permit is on…") — don't promote even if the backward walk
    /// would have.
    ///
    /// Positive subject evidence (collected during the walk) is
    /// required to promote: a Pronoun, or a Noun that is plural
    /// (regular -s morphology on a Noun-tagged token, or one of the
    /// closed set of English irregular plurals). NLTagger's own
    /// Pronoun/Noun classifications are the primary signal; the
    /// irregular-plural list exists only because surface morphology
    /// can't identify them as plural on its own.
    ///
    /// Unknown cases (no clear subject, ambiguous frame) stay on
    /// DEFAULT — plan rule G: "never invent a variant".
    private static func shouldPromoteToVerb(
        tokens: [GToken], at index: Int
    ) -> Bool {
        // Forward guard: H directly followed by a Verb-tagged word.
        if let nextIdx = nextWordTokenIndex(tokens: tokens, after: index),
           tokens[nextIdx].tag == "Verb" {
            return false
        }

        var sawSubject = false
        var i = index - 1
        while i >= 0 {
            let t = tokens[i]
            if t.isPunctuation {
                if clauseBreakMarks.contains(t.text) { break }
                i -= 1
                continue
            }
            guard t.isWord else { i -= 1; continue }

            // NP-dominance: Det before H at the same clause level
            // means H is head-or-modifier of a Det-headed NP.
            if t.tag == "Determiner" { return false }

            // Predicate already consumed by a prior finite verb.
            if t.tag == "Verb" { return false }

            let lower = t.text.lowercased()
            // Copula/be-verb words (NLTagger sometimes tags "'s"
            // inside contractions as Pronoun/OtherWord).
            if copulaVeto.contains(lower) { return false }

            // Clause boundary from a conjunction or subordinator.
            if t.tag == "Conjunction" { break }
            if subordinatorBoundaries.contains(lower) { break }

            // Positive subject evidence.
            if t.tag == "Pronoun" {
                sawSubject = true
            } else if t.tag == "Noun", isPluralNounSurface(t.text) {
                sawSubject = true
            }

            i -= 1
        }
        return sawSubject
    }

    /// Punctuation that closes a clause for the purposes of the
    /// backward verb-frame walk. Commas are included because a
    /// leading adverbial PP ("After the meeting, employees record
    /// their hours") is a clause boundary — the walk should reach
    /// the subject without crossing into the adverbial.
    private static let clauseBreakMarks: Set<String> = [
        ".", "!", "?", ";", ":", ",",
    ]

    /// English subordinating / coordinating conjunctions NLTagger
    /// routinely mis-tags as Pronoun / Preposition / OtherWord.
    /// A closed linguistic class — backs the clause-boundary scan,
    /// not any per-word IPA decision.
    private static let subordinatorBoundaries: Set<String> = [
        "and", "or", "but", "nor", "yet", "so",
        "because", "since", "although", "though", "while",
        "when", "where", "if", "unless", "until",
        "after", "before", "whenever", "wherever", "whereas",
        "that", "which", "who", "whom", "whose",
    ]

    /// English irregular plurals. Backs the subject-number signal —
    /// NLTagger tags these as Noun but surface morphology can't
    /// see their number. Intentionally a closed linguistic class,
    /// not a fixture word list.
    private static let irregularPlurals: Set<String> = [
        "men", "women", "children", "people",
        "feet", "teeth", "mice", "geese", "oxen", "lice",
        "analyses", "crises", "theses",
        "phenomena", "criteria", "strata", "bacteria",
        "data", "media", "alumni",
    ]

    /// True iff the surface text plausibly represents a plural noun.
    /// Combines the irregular-plural list with a regular-plural
    /// suffix check (words of length ≥ 3 ending in `-s` but not the
    /// obvious singular endings `-ss`/`-ous`/`-us`/`-is`).
    private static func isPluralNounSurface(_ text: String) -> Bool {
        let lower = text.lowercased()
        if irregularPlurals.contains(lower) { return true }
        guard text.count >= 3, lower.hasSuffix("s") else { return false }
        if lower.hasSuffix("ss") { return false }
        if lower.hasSuffix("ous") { return false }
        if lower.hasSuffix("us") { return false }
        if lower.hasSuffix("is") { return false }
        return true
    }

    /// First word-carrying token after `index`, stopping the scan
    /// at strong clause enders so we don't reach across a sentence
    /// boundary when H is clause-final.
    private static func nextWordTokenIndex(
        tokens: [GToken], after index: Int
    ) -> Int? {
        var i = index + 1
        while i < tokens.count {
            let t = tokens[i]
            if t.isPunctuation {
                if clauseBreakMarks.contains(t.text) { return nil }
                i += 1
                continue
            }
            if t.isWord { return i }
            i += 1
        }
        return nil
    }

    /// Reverse of the tag-seed mapping in the rules table.
    private static func universalKey(for tag: String) -> String? {
        switch tag {
        case "Verb":      return "VERB"
        case "Noun":      return "NOUN"
        case "Adjective": return "ADJ"
        case "Adverb":    return "ADV"
        default:          return nil
        }
    }

    /// Canonical IPA for any `hm+` thinking-hum interjection. No vowel
    /// (a `hˈʌm`-shape reads as the word "hum", which isn't what a
    /// thinking pause sounds like); just a stressed long nasal so the
    /// mouth-closed humming quality carries. Repeated m's in the input
    /// spelling are flattened to this single form — the user's intent
    /// is the same whether they type `Hm`, `Hmm`, or `Hmmmm`.
    private static let hmInterjectionIPA = "hˈmː"

    /// True iff `text` is an `hm+` interjection (case-insensitive): a
    /// leading `h` followed by one or more `m`s and nothing else.
    private static func isHmInterjection(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.count >= 2, lower.first == "h" else { return false }
        return lower.dropFirst().allSatisfy { $0 == "m" }
    }

    /// Copula / intensifier words that force DEFAULT when they
    /// immediately precede a homograph. Duplicated from
    /// `KokoroSSMLNormalizer` — Phase 8 integration may unify them.
    private static let copulaVeto: Set<String> = [
        "is", "are", "was", "were", "be", "been", "being", "am",
        "'s", "'re", "still", "very", "quite", "so", "really", "truly",
    ]

    // MARK: - Range helpers

    private static func rangeOverlaps(_ range: NSRange, any claimed: [NSRange]) -> Bool {
        for c in claimed where NSIntersectionRange(range, c).length > 0 {
            return true
        }
        return false
    }
}
