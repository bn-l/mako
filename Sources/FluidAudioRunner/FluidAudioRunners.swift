import Foundation
import FluidAudio
import TTSHarnessCore

public struct KokoroFluidAudioRunner: Runner {
    public let modelID = "kokoro-fluidaudio"
    public let sampleRate = 24_000
    public let voice: String

    public init(voice: String = "af_heart") {
        self.voice = voice
    }

    public func synthesize(text: String, to outputURL: URL) async throws {
        let env = ProcessInfo.processInfo.environment
        let rawPassthrough = env["KOKORO_RAW_TEXT"] != nil
        // Phase 9b closeout: ported is the default; `KOKORO_G2P=classic`
        // is the escape hatch back to the legacy
        // `KokoroSSMLNormalizer.normalize` + `buildCustomLexiconIfEnabled`
        // path. `KOKORO_RAW_TEXT` still short-circuits both.
        let portedG2P = env["KOKORO_G2P"] != "classic"
        let lexicon: TtsCustomLexicon?
        let normalized: String
        if rawPassthrough {
            lexicon = nil
            normalized = text
        } else if portedG2P {
            let plan = KokoroG2P.resolve(text)
            let emitted = KokoroG2P.emit(plan)
            lexicon = emitted.lexiconEntries.isEmpty
                ? nil
                : TtsCustomLexicon(entries: emitted.lexiconEntries)
            normalized = KokoroSSMLNormalizer.compensatorsOnly(emitted.annotatedText)
            if env["KOKORO_G2P_TRACE"] != nil {
                Self.emitPortedPlanProvenance(plan: plan, lexiconSize: emitted.lexiconEntries.count)
            }
        } else {
            lexicon = Self.buildCustomLexiconIfEnabled(for: text)
            normalized = KokoroSSMLNormalizer.normalize(text)
        }
        let manager = KokoroTtsManager(defaultVoice: voice, customLexicon: lexicon)
        try await manager.initialize()
        if env["KOKORO_PREVIEW_SSML"] != nil {
            FileHandle.standardError.write(Data("--- Kokoro SSML preview ---\n\(normalized)\n--- end preview ---\n".utf8))
        }
        if env["KOKORO_G2P_TRACE"] != nil {
            try await Self.synthesizeWithTrace(
                manager: manager,
                sourceText: text,
                normalizedSSML: normalized,
                outputURL: outputURL,
                voice: voice
            )
            return
        }
        let voiceSpeed = Float(env["KOKORO_SPEED"] ?? "") ?? 1.0
        try await manager.synthesizeToFile(
            text: normalized, outputURL: outputURL, voice: voice, voiceSpeed: voiceSpeed)
    }

    /// Emits a three-stage trace to stderr, then writes the audio to `outputURL`.
    /// Stages dumped:
    ///   1. raw source text
    ///   2. our normalized SSML (what we hand to FluidAudio)
    ///   3. per-chunk view from `synthesizeDetailed` — text/words/atoms/tokenCount
    ///      are the only fields FluidAudio's `ChunkInfo` exposes publicly today.
    ///      Post-`SSMLProcessor` and post-`TtsTextPreprocessor` text and final
    ///      phoneme output are not reachable without an upstream hook — see
    ///      PLAN_port_kokorog2p.md checkpoint J.
    private static func synthesizeWithTrace(
        manager: KokoroTtsManager,
        sourceText: String,
        normalizedSSML: String,
        outputURL: URL,
        voice: String
    ) async throws {
        let stderr = FileHandle.standardError
        func emit(_ s: String) { stderr.write(Data(s.utf8)) }
        emit("=== KOKORO_G2P_TRACE ===\n")
        emit("--- source ---\n\(sourceText)\n")
        emit("--- normalized SSML ---\n\(normalizedSSML)\n")
        let result = try await manager.synthesizeDetailed(text: normalizedSSML, voice: voice)
        emit("--- chunks (\(result.chunks.count)) ---\n")
        for chunk in result.chunks {
            emit("[chunk \(chunk.index)] variant=\(chunk.variant) tokens=\(chunk.tokenCount) words=\(chunk.wordCount)\n")
            emit("  text: \(chunk.text)\n")
            emit("  words: \(chunk.words.joined(separator: " | "))\n")
            emit("  atoms: \(chunk.atoms.joined(separator: " "))\n")
        }
        if let diag = result.diagnostics {
            emit("--- diagnostics ---\n")
            emit("  lexiconEntryCount=\(diag.lexiconEntryCount) lexiconBytes=\(diag.lexiconEstimatedBytes) outputWavBytes=\(diag.outputWavBytes)\n")
        }
        emit("=== end KOKORO_G2P_TRACE ===\n")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try result.audio.write(to: outputURL)
    }

    /// When `KOKORO_CUSTOM_LEXICON=1` (curated) or `KOKORO_CUSTOM_LEXICON_AUTO=1`
    /// (auto-scan), build a `TtsCustomLexicon` from `us_gold.json` for words
    /// appearing in the input. This is an alternative path to the normalizer's
    /// markdown `[word](/ipa/)` overrides — the lexicon feeds into FluidAudio's
    /// G2P chain directly (case-sensitive then lowercase lookup, before BART).
    ///
    /// - `_AUTO`: scans the input text, includes every word that has a
    ///   single-variant entry in gold (skipping homographs with POS dicts,
    ///   which need context to disambiguate).
    /// - Otherwise: curated list + hand-written Irish surnames.
    private static func buildCustomLexiconIfEnabled(for text: String) -> TtsCustomLexicon? {
        let env = ProcessInfo.processInfo.environment
        let isAuto = env["KOKORO_CUSTOM_LEXICON_AUTO"] != nil
        let isCurated = env["KOKORO_CUSTOM_LEXICON"] != nil
        guard isAuto || isCurated else { return nil }

        if isAuto {
            var entries: [String: [String]] = [:]
            var seen = Set<String>()
            var current = ""
            var tierCounts: [KokoroLexicon.LexiconTier: Int] = [:]
            var skippedHomographs = 0
            let consume = { (word: String) in
                guard seen.insert(word).inserted else { return }
                if let hit = KokoroLexicon.lookupPlainTokens(word) {
                    entries[word] = hit.tokens
                    tierCounts[hit.tier, default: 0] += 1
                } else if KokoroLexicon.isHomograph(word) {
                    skippedHomographs += 1
                }
            }
            for ch in text {
                if ch.isLetter || ch == "'" {
                    current.append(ch)
                } else if !current.isEmpty {
                    consume(current)
                    current = ""
                }
            }
            if !current.isEmpty { consume(current) }
            // Programmatic Celtic-name rule: full-name plain lookup first
            // (checkpoint D step 1); O'/Mc/Mac prefix IPA + stem only when
            // the dict has nothing direct. If the main word scan above
            // already resolved the name, skip — we must never overwrite a
            // direct lexicon hit with a composed approximation.
            var celticCount = 0
            for match in KokoroSSMLNormalizer.findCelticNames(in: text) {
                if entries[match.bareName] != nil { continue }
                guard let ipa = KokoroSSMLNormalizer.celticIPA(for: match, includePossessive: false)
                else { continue }
                entries[match.bareName] = ipa.unicodeScalars.map { String($0) }
                celticCount += 1
            }
            emitLexiconProvenanceIfTracing(
                tierCounts: tierCounts,
                skippedHomographs: skippedHomographs,
                celticCount: celticCount,
                totalEntries: entries.count
            )
            return entries.isEmpty ? nil : TtsCustomLexicon(entries: entries)
        }

        let goldWords = [
            "Maya", "Worcestershire", "colonel", "Colonel",
            "kettle", "choir", "iron", "rural", "squirrel", "February", "boil",
            "midnight", "moonlight", "spotlight", "sunrise", "sideline",
            "online", "offline", "outside", "website", "deadline",
            "portrait", "email", "rolling",
            "review", "research", "approved", "defense", "began",
        ]
        var entries: [String: [String]] = [:]
        for word in goldWords {
            if let hit = KokoroLexicon.lookupPlainTokens(word) {
                entries[word] = hit.tokens
            } else if let tokens = KokoroLexicon.lookupTokens(word) {
                // Curated words may legitimately be homographs — the user
                // asked for them explicitly, so unlike auto we take the
                // DEFAULT variant.
                entries[word] = tokens
            }
        }
        // Programmatic Celtic-name rule — gold-lookup the stem, prepend the
        // Kokoro-inventory prefix IPA (/oʊ/ for O', /mɪk/ for Mc, /mæk/ for Mac).
        for match in KokoroSSMLNormalizer.findCelticNames(in: text) {
            guard let ipa = KokoroSSMLNormalizer.celticIPA(for: match, includePossessive: false)
            else { continue }
            entries[match.bareName] = ipa.unicodeScalars.map { String($0) }
        }
        return entries.isEmpty ? nil : TtsCustomLexicon(entries: entries)
    }

    /// Provenance summary for the ported pipeline (Phase 8). Counts
    /// overrides by reason + per-tier distribution, structural spans,
    /// and the resulting custom-lexicon size — the legacy tracer's
    /// shape adapted for the G2P result type.
    private static func emitPortedPlanProvenance(
        plan: KokoroG2P.G2PResult, lexiconSize: Int
    ) {
        var reasonCounts: [String: Int] = [:]
        var tierCounts: [KokoroLexicon.LexiconTier: Int] = [:]
        var handTuned = 0
        for o in plan.overrides {
            reasonCounts[o.reason.rawValue, default: 0] += 1
            switch o.provenance {
            case let .lexicon(tier, _): tierCounts[tier, default: 0] += 1
            case let .celticCompose(tier): tierCounts[tier, default: 0] += 1
            case let .celticRespelling(tier): tierCounts[tier, default: 0] += 1
            case .handTunedOverlay: handTuned += 1
            }
        }
        var lines = "--- KOKORO_G2P=ported plan ---\n"
        lines += "  overrides: \(plan.overrides.count) (hand-tuned: \(handTuned))\n"
        for (reason, n) in reasonCounts.sorted(by: { $0.key < $1.key }) {
            lines += "    \(reason): \(n)\n"
        }
        lines += "  structural spans: \(plan.structuralSpans.count)\n"
        lines += "  custom lexicon: \(lexiconSize)\n"
        for tier in KokoroLexicon.LexiconTier.allCases {
            let n = tierCounts[tier] ?? 0
            guard n > 0 else { continue }
            lines += "  \(tier.rawValue): \(n)\n"
        }
        FileHandle.standardError.write(Data(lines.utf8))
    }

    /// When `KOKORO_G2P_TRACE=1`, emit a provenance summary of the
    /// auto-scanned lexicon: per-tier hit count, homographs skipped,
    /// and Celtic-name additions. Gives us a running view of the
    /// compatibility tier usage so we can watch it shrink as
    /// kokorog2p-gold covers more of the corpus.
    private static func emitLexiconProvenanceIfTracing(
        tierCounts: [KokoroLexicon.LexiconTier: Int],
        skippedHomographs: Int,
        celticCount: Int,
        totalEntries: Int
    ) {
        guard ProcessInfo.processInfo.environment["KOKORO_G2P_TRACE"] != nil else { return }
        var lines = "--- custom-lexicon auto-scan ---\n"
        lines += "  entries: \(totalEntries) (celtic: \(celticCount), skipped homographs: \(skippedHomographs))\n"
        for tier in KokoroLexicon.LexiconTier.allCases {
            let hits = tierCounts[tier] ?? 0
            guard hits > 0 else { continue }
            lines += "  \(tier.rawValue): \(hits)\n"
        }
        FileHandle.standardError.write(Data(lines.utf8))
    }
}

public struct PocketFluidAudioRunner: Runner {
    public let modelID = "pocket-tts-fluidaudio"
    public let sampleRate = 24_000
    public let voice: String

    public init(voice: String = "alba") {
        self.voice = voice
    }

    public func synthesize(text: String, to outputURL: URL) async throws {
        let manager = PocketTtsManager(defaultVoice: voice)
        try await manager.initialize()
        let normalized = KittenWordNormalizer.normalizeText(text)
        try await manager.synthesizeToFile(text: normalized, outputURL: outputURL, voice: voice)
    }
}
