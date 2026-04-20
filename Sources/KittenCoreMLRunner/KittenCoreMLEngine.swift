import Foundation
import CoreML
import NaturalLanguage
import KittenTTS
import TTSHarnessCore

public enum KittenCoreMLVariant: Sendable {
    case nano   // needs random_phases + source_noise; single 256-dim style vector
    case mini   // needs speed; style is a row of a (400, 256) matrix, row = min(len(chunk_text), 399)
}

private func envInt(_ name: String, default def: Int) -> Int {
    if let v = ProcessInfo.processInfo.environment[name], let i = Int(v) {
        return i
    }
    return def
}

private func envStr(_ name: String, default def: String) -> String {
    ProcessInfo.processInfo.environment[name] ?? def
}

public enum KittenCoreMLError: Error, CustomStringConvertible {
    case modelsDirectoryMissing(URL)
    case modelFileMissing(URL)
    case voiceFileMissing(String, URL)
    case unknownVoice(String)
    case inferenceFailed(String)
    case chunkTooLong(chunkTextLen: Int, tokenCount: Int)

    public var description: String {
        switch self {
        case .modelsDirectoryMissing(let url): return "kittentts-coreml models dir missing: \(url.path)"
        case .modelFileMissing(let url):       return ".mlmodelc missing: \(url.path)"
        case .voiceFileMissing(let n, let u):  return "voice '\(n)' missing at \(u.path)"
        case .unknownVoice(let n):             return "unknown voice: \(n)"
        case .inferenceFailed(let m):          return "CoreML inference failed: \(m)"
        case .chunkTooLong(let c, let t):      return "chunk too long after phonemisation: \(c) chars → \(t) tokens (> 140)"
        }
    }
}

public actor KittenCoreMLEngine {
    private let model: MLModel
    private let variant: KittenCoreMLVariant
    private let voices: [String: [Float]]
    private let phonemizer: any KittenPhonemizerProtocol

    private static let maxTokens = 140
    private static let maxSamples = 240_000
    private static let sampleRate = 24_000
    /// The CoreML port emits `audio_length_samples`, but empirically the last
    /// ~5000 samples of that valid region still contain vocoder wind-down
    /// artefacts that click audibly at chunk boundaries. Upstream ONNX Python
    /// also does `audio[:-5000]`. Keep the trim; rely on a longer microfade
    /// or an equal-power crossfade to mask the discontinuity.
    /// Override at runtime via env var `KITTEN_CHUNK_TAIL_TRIM`.
    /// Fixed trim off the end of saturated chunks (ones that fill the 10 s
    /// output cap). Empirically 9000 samples of vocoder tail artefact at the
    /// cap; less on under-filled chunks. Override via `KITTEN_CHUNK_TAIL_TRIM`.
    private static let chunkTailTrim = envInt("KITTEN_CHUNK_TAIL_TRIM", default: 9_000)
    /// Fixed trim for short / under-filled chunks where the model actually
    /// stops before the cap. Must be small enough not to clip the last
    /// phoneme on utterances like "Nobody laughed, but a few people
    /// whispered." Override via `KITTEN_SHORT_TAIL_TRIM`.
    private static let shortChunkTailTrim = envInt("KITTEN_SHORT_TAIL_TRIM", default: 3_000)
    /// Per-chunk symmetric fade-in/out in ms. Only used when xfadeMs == 0.
    /// Override via `KITTEN_FADE_MS`.
    private static let fadeMs = envInt("KITTEN_FADE_MS", default: 0)
    /// Equal-power crossfade between adjacent chunks, in ms. When > 0 this
    /// replaces the simple microfade. Suppressed at sentence boundaries —
    /// `sentenceGapMs` silence is inserted there instead.
    /// Override via `KITTEN_XFADE_MS`.
    private static let xfadeMs = envInt("KITTEN_XFADE_MS", default: 100)
    /// Silence inserted between chunks that end a sentence (`.` `!` `?`) and
    /// the next chunk. Replaces the crossfade there so the final consonant
    /// isn't blended into the next word, and the ear hears a real pause.
    /// Override via `KITTEN_SENTENCE_GAP_MS`.
    private static let sentenceGapMs = envInt("KITTEN_SENTENCE_GAP_MS", default: 220)
    /// Linear fade applied on both sides of the sentence-boundary silence.
    /// Without it, the transition between a non-zero sample and silence
    /// clicks audibly at every sentence boundary.
    /// Override via `KITTEN_BOUNDARY_FADE_MS`.
    private static let boundaryFadeMs = envInt("KITTEN_BOUNDARY_FADE_MS", default: 12)
    /// When > 0, after the fixed `chunkTailTrim` we also scan backward from the
    /// new boundary looking for the nearest low-energy frame within this window
    /// (in ms) and trim there instead. Makes the crossfade region always land in
    /// a natural silence → no click. Override via `KITTEN_ADAPTIVE_TRIM_MS`.
    private static let adaptiveTrimMs = envInt("KITTEN_ADAPTIVE_TRIM_MS", default: 0)
    /// When > 0, snap crossfade endpoints to nearest zero-crossing within this
    /// window (in samples). Override via `KITTEN_ZC_SNAP_SAMPLES`.
    private static let zcSnapSamples = envInt("KITTEN_ZC_SNAP_SAMPLES", default: 0)
    /// Apply DC-block (simple IIR high-pass at ~20 Hz) to each raw chunk before
    /// crossfade. 0 = off, 1 = on. Override via `KITTEN_DC_BLOCK`.
    private static let dcBlockEnabled = envInt("KITTEN_DC_BLOCK", default: 0) != 0
    /// If >= 0, force every chunk (mini variant only) to use this row of the
    /// 400×256 style matrix instead of `min(chunkTextLen, 399)`. Keeps style
    /// constant across chunks → no prosody jump at boundaries.
    /// -1 = use upstream per-chunk indexing (default).
    private static let styleRowOverride = envInt("KITTEN_STYLE_ROW", default: -1)
    /// Which per-chunk length feeds the style-row index when no override is
    /// set. Kitten implementations disagree: Python uses raw text chunk
    /// length, the Swift SDK uses phoneme length, the Rust port uses token
    /// count. Experiment-grade knob; default matches the Python reference.
    ///   "text"     — `min(chunkTextLen, 399)`  (default, matches upstream)
    ///   "phonemes" — `min(phonemeLen, 399)`
    ///   "tokens"   — `min(tokenCount, 399)`
    private static let styleRowPolicy = envStr("KITTEN_STYLE_ROW_POLICY", default: "text")
    /// Which strategy to use when deciding where to cut off a sentence-final
    /// chunk's tail. Each mode trades off between OVERTRIM (clipping the
    /// final word) and UNDERTRIM (leaving the vocoder wind-down burst in the
    /// output). Set via `KITTEN_TRIM_MODE`.
    ///   "v26"           — original: backward scan, -10 dB sustained 30 ms, return rawLen if no hit
    ///   "bounded-back"  — v26 but capped at `KITTEN_LOOKBACK_MS`; fall back to `rawLen - KITTEN_TRIM_FALLBACK_MS` when no hit
    ///   "fwd-last-loud" — forward scan over last `KITTEN_LOOKBACK_MS`; last loud frame + `KITTEN_FWD_MARGIN_MS`
    ///   "fwd-extend"    — fwd-last-loud, then extend through quiet-but-non-silent frames (ZCR-gated to skip the burst)
    ///   "burst-scan"    — classify frames by RMS + ZCR; trim just before the earliest burst-signature run
    ///   "aggressive"    — just `rawLen - KITTEN_AGGRESSIVE_TRIM` samples, no scan
    ///   "dur-aligned"   — use `pred_dur`: cut just after the predicted end of
    ///                      the last content (letter/IPA) token, + small margin
    private static let trimMode = envStr("KITTEN_TRIM_MODE", default: "v26")
    private static let trimLookbackMs = envInt("KITTEN_LOOKBACK_MS", default: 500)
    private static let trimFallbackMs = envInt("KITTEN_TRIM_FALLBACK_MS", default: 80)
    private static let fwdMarginMs = envInt("KITTEN_FWD_MARGIN_MS", default: 100)
    private static let aggressiveTrimSamples = envInt("KITTEN_AGGRESSIVE_TRIM", default: 2_000)
    /// Post-content margin for `dur-aligned` trim, in ms. Added after the
    /// predicted end of the last content token so short unvoiced finals
    /// (/t/, /s/, /d/) aren't clipped by a tight cut at the token boundary.
    private static let durMarginMs = envInt("KITTEN_DUR_MARGIN_MS", default: 20)
    /// Upstream uses max_len=400 chars; their ONNX has no hard token cap.
    /// Our CoreML 10s model caps output at 240_000 samples (10.0 s). Even well
    /// under the 140-token input cap, a dense chunk can produce >10 s of speech
    /// and be audibly truncated mid-word. We start with a conservative char cap
    /// and auto-split chunks that saturate the output.
    /// Upstream Python uses 400 chars. We need a lower cap because the 140-
    /// token model input plus our punctuation-preserving phonemisation (each
    /// `,` and `:` costs a token) eats budget fast. 90 is a balance: under the
    /// token cap in almost every case, few enough mid-phrase splits to avoid
    /// boundary clicks.
    private static let maxCharsPerChunk = envInt("KITTEN_MAX_CHARS", default: 90)
    /// If a chunk's output reaches within this many samples of the cap, we treat
    /// it as truncated and recursively split it in half.
    private static let saturationMargin = 1_500

    // Pre-allocated, reused across chunks.
    private let inputIdsArr: MLMultiArray
    private let attentionMaskArr: MLMultiArray
    private let styleArr: MLMultiArray
    private let speedArr: MLMultiArray?
    private let randomPhasesArr: MLMultiArray?
    private let sourceNoiseArr: MLMultiArray?

    public init(variant: KittenCoreMLVariant, modelURL: URL, voicesDir: URL) async throws {
        self.variant = variant

        let voiceNames = [
            "expr-voice-2-f", "expr-voice-2-m", "expr-voice-3-f", "expr-voice-3-m",
            "expr-voice-4-f", "expr-voice-4-m", "expr-voice-5-f", "expr-voice-5-m",
        ]
        var voices: [String: [Float]] = [:]
        for name in voiceNames {
            let url = voicesDir.appendingPathComponent("\(name).bin")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw KittenCoreMLError.voiceFileMissing(name, url)
            }
            let data = try Data(contentsOf: url)
            let floats = data.withUnsafeBytes { raw -> [Float] in
                Array(raw.bindMemory(to: Float.self))
            }
            voices[name] = floats
        }
        self.voices = voices

        let phon = EPhonemizer()
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KittenCoreMLRunner", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try await phon.downloadIfNeeded(to: cacheDir, progressHandler: nil)
        self.phonemizer = phon

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw KittenCoreMLError.modelFileMissing(modelURL)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        self.model = try MLModel(contentsOf: modelURL, configuration: config)

        self.inputIdsArr = try MLMultiArray(shape: [1, NSNumber(value: Self.maxTokens)], dataType: .int32)
        self.attentionMaskArr = try MLMultiArray(shape: [1, NSNumber(value: Self.maxTokens)], dataType: .int32)
        self.styleArr = try MLMultiArray(shape: [1, 256], dataType: .float32)

        switch variant {
        case .nano:
            self.speedArr = nil
            self.randomPhasesArr = try MLMultiArray(shape: [1, 9], dataType: .float32)
            self.sourceNoiseArr = try MLMultiArray(
                shape: [1, NSNumber(value: Self.maxSamples), 9],
                dataType: .float32
            )
            Self.fillRandN(randomPhasesArr!)
            Self.fillRandN(sourceNoiseArr!)
        case .mini:
            self.speedArr = try MLMultiArray(shape: [1], dataType: .float32)
            self.randomPhasesArr = nil
            self.sourceNoiseArr = nil
        }
    }

    public func generate(text: String, voice: String, speed: Float) throws -> [Float] {
        guard let voiceData = voices[voice] else {
            throw KittenCoreMLError.unknownVoice(voice)
        }
        let normalised = KittenWordNormalizer.normalizeText(
            KittenTextPreprocessor.process(text)
        )
        let textChunks = Self.chunkText(normalised, maxChars: Self.maxCharsPerChunk)

        var all: [Float] = []
        var dropped: Set<Unicode.Scalar> = []
        let fadeSamples = max(1, Self.sampleRate * Self.fadeMs / 1000)
        let xfadeSamples = max(0, Self.sampleRate * Self.xfadeMs / 1000)
        let sentenceGapSamples = max(0, Self.sampleRate * Self.sentenceGapMs / 1000)

        let logBoundaries = ProcessInfo.processInfo.environment["KITTEN_LOG_BOUNDARIES"] == "1"
        var prevSentenceFinal = false
        for (i, chunk) in textChunks.enumerated() {
            let sentenceFinal = Self.isSentenceFinal(chunk)
            var samples = try synthChunkWithAutoSplit(
                chunk: chunk,
                voiceData: voiceData,
                speed: speed,
                droppedSink: &dropped,
                depth: 0,
                isSentenceFinal: sentenceFinal
            )
            let beforeCount = all.count
            if i == 0 {
                all.append(contentsOf: samples)
            } else if prevSentenceFinal {
                // Hard sentence boundary: fade the trailing edge of the
                // previous chunk down to zero, insert silence, fade the
                // next chunk in from zero. Without proper fades, the
                // hard cut from a non-zero sample to silence produces
                // an audible click at every sentence boundary.
                let boundaryFade = max(1, Self.sampleRate * Self.boundaryFadeMs / 1000)
                Self.fadeOutTail(&all, fadeSamples: boundaryFade)
                Self.fadeInHead(&samples, fadeSamples: boundaryFade)
                if sentenceGapSamples > 0 {
                    all.append(contentsOf: [Float](repeating: 0, count: sentenceGapSamples))
                }
                all.append(contentsOf: samples)
            } else if xfadeSamples > 0 {
                Self.appendWithCrossfade(dst: &all, src: samples, xfadeSamples: xfadeSamples)
            } else {
                Self.microfade(&samples, fadeSamples: fadeSamples)
                all.append(contentsOf: samples)
            }
            prevSentenceFinal = sentenceFinal
            if logBoundaries {
                let seamSec = Double(beforeCount) / Double(Self.sampleRate)
                let endSec = Double(all.count) / Double(Self.sampleRate)
                fputs(
                    "chunk \(i) seam@\(String(format: "%.2f", seamSec))s end@\(String(format: "%.2f", endSec))s: “\(chunk.prefix(60))”\n",
                    stderr
                )
            }
        }

        if !dropped.isEmpty {
            let list = dropped
                .sorted { $0.value < $1.value }
                .map { String(format: "U+%04X(%@)", $0.value, String($0)) }
                .joined(separator: " ")
            fputs("⚠︎ kittentts-coreml: phonemes not in symbol table, dropped: \(list)\n", stderr)
        }
        // Final fade so the file doesn't end on a non-zero sample (which
        // clicks in any player that doesn't fade to silence itself).
        let boundaryFade = max(1, Self.sampleRate * Self.boundaryFadeMs / 1000)
        Self.fadeOutTail(&all, fadeSamples: boundaryFade)
        return all
    }

    // MARK: - Chunking
    //
    // Upstream Python `chunk_text` splits on every `.!?` character, which
    // wrecks abbreviations: `a.m.` becomes two single-letter sentences "a"
    // and "m", which then synthesise as their own tiny chunks and produce
    // audible boundary glitches. We use `NLTokenizer(unit: .sentence)`, which
    // handles English abbreviations correctly (`Dr.`, `a.m.`, `e.g.`, etc.),
    // and then apply a min-length merge pass as a safety net for any tiny
    // fragments that still slip through.

    /// Abbreviation-aware sentence-level chunker with min-length merging.
    static func chunkText(_ text: String, maxChars: Int) -> [String] {
        let sentences = splitIntoSentences(text)

        var chunks: [String] = []
        for s in sentences {
            if s.count <= maxChars {
                chunks.append(ensurePunctuation(s))
            } else {
                var cur = ""
                for word in s.split(separator: " ") {
                    let wlen = word.count
                    if cur.isEmpty {
                        cur = String(word)
                    } else if cur.count + wlen + 1 <= maxChars {
                        cur += " " + word
                    } else {
                        chunks.append(ensurePunctuation(cur))
                        cur = String(word)
                    }
                }
                if !cur.isEmpty { chunks.append(ensurePunctuation(cur)) }
            }
        }
        return mergeShortChunks(chunks, minChars: 18, maxChars: maxChars)
    }

    private static func splitIntoSentences(_ text: String) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return [] }
        let tok = NLTokenizer(unit: .sentence)
        tok.string = t
        var out: [String] = []
        tok.enumerateTokens(in: t.startIndex..<t.endIndex) { range, _ in
            let piece = String(t[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { out.append(piece) }
            return true
        }
        return out
    }

    /// Merge short chunks into a neighbour. Isolated short chunks cause the
    /// acoustic model to produce weird prosody — a single word uttered in
    /// its own chunk comes out higher and faster ("clarity" → "pluhree",
    /// "working well" → higher/faster). A short chunk is one below
    /// `minChars`; a slight maxChars overage (up to `minChars - 1` chars)
    /// is allowed on merge because the overage is bounded by the short
    /// chunk's size and stays comfortably under the model's 140-token cap.
    private static func mergeShortChunks(
        _ chunks: [String], minChars: Int, maxChars: Int
    ) -> [String] {
        let softCap = maxChars + minChars
        var out: [String] = []
        for c in chunks {
            if c.count < minChars,
               let last = out.last,
               last.count + 1 + c.count <= softCap {
                out[out.count - 1] = ensurePunctuation(last + " " + c)
            } else {
                out.append(c)
            }
        }
        if out.count >= 2, out[0].count < minChars {
            let joined = ensurePunctuation(out[0] + " " + out[1])
            if joined.count <= softCap {
                out[1] = joined
                out.removeFirst()
            }
        }
        return out
    }

    /// A chunk is "sentence-final" when it ends with sentence terminator
    /// (`.` `!` `?`), ignoring any trailing quotes, whitespace, or trailing
    /// commas added by `ensurePunctuation` after a closing quote. Abbreviation
    /// dots are stripped earlier, so any remaining `.` is a real sentence end.
    static func isSentenceFinal(_ chunk: String) -> Bool {
        let skip: Set<Character> = [" ", "\t", "\n", "\"", "\u{201C}", "\u{201D}", "'", "`", ","]
        for ch in chunk.reversed() {
            if skip.contains(ch) { continue }
            return ".!?".contains(ch)
        }
        return false
    }

    static func ensurePunctuation(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return t }
        if let last = t.last, ".!?,;:".contains(last) { return t }
        return t + ","
    }

    /// `EPhonemizer.phonemize` strips all punctuation from its output, which
    /// makes the model render comma/colon/period-bearing text as a single
    /// unbroken breath ("seven forty-five a em", "will test numbers pause and
    /// clarity" with no pauses). KittenTextCleaner's symbol table *does*
    /// include punctuation tokens — we just need to keep them in the phoneme
    /// stream. Split the chunk on sentence-internal punctuation, phonemize
    /// each text segment, and rejoin with the original punctuation surrounded
    /// by spaces so `basicEnglishTokenizeJoin` later emits the punctuation
    /// chars as their own tokens.
    /// Punctuation characters that should be preserved in the phoneme stream
    /// so the acoustic model produces a natural pause at their position.
    /// Upstream kittentts runs EspeakBackend(preserve_punctuation=True), which
    /// emits every `.!?,:;` in the IPA output. We don't have preserve_punctuation
    /// on our Swift EPhonemizer, so we manually split-and-rejoin here.
    /// `.` is included: `expandDottedAcronyms` has already normalised
    /// single-letter abbreviations (`a.m.`, `e.g.`) away, so the only `.`
    /// chars left are sentence-terminal ones we want the model to see as
    /// period tokens. Quotes remain excluded — they carry no IPA content.
    private static let pausePunctuation: Set<Character> = [
        ",", ".", ":", ";", "!", "?", "—", "…",
    ]

    /// JSON map of `chunk-text → IPA` loaded from
    /// `KITTEN_IPA_CHUNK_OVERRIDE_FILE`. Used to bypass our local EPhonemizer
    /// on matching chunks (exact string match against the post-normalization
    /// chunk text). Populated at first access; empty when no env var is set
    /// or the file can't be decoded. Intended for A/B tests against the
    /// upstream Python phonemizer.
    private static let ipaChunkOverride: [String: String] = {
        guard let path = ProcessInfo.processInfo.environment["KITTEN_IPA_CHUNK_OVERRIDE_FILE"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return obj
    }()

    /// JSON map of `ipa-substring → replacement` loaded from
    /// `KITTEN_IPA_PATCH_FILE`. Applied AFTER `patchIPA`'s built-in map so
    /// the runtime map can both add new patches and override hard-coded ones
    /// (replacement wins since it's applied last). Intended for rapid
    /// variant probing (live: `lˈaɪv` → `lˌaɪv` / `lˈɑɪv` / `ɫˈaɪv` etc.)
    /// without recompiling. Keys/values are raw IPA substrings — bring your
    /// own stress marks, tones, diacritics.
    private static let ipaPatchRuntime: [(String, String)] = {
        guard let path = ProcessInfo.processInfo.environment["KITTEN_IPA_PATCH_FILE"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [] }
        return Array(obj)
    }()

    static func phonemizePreservingPunctuation(
        _ text: String,
        phonemizer: any KittenPhonemizerProtocol
    ) -> String {
        if let override = ipaChunkOverride[text] {
            return KittenWordNormalizer.patchIPA(override)
        }
        var out: [String] = []
        var buf = ""
        for ch in text {
            if pausePunctuation.contains(ch) {
                if !buf.isEmpty {
                    let seg = phonemizer.phonemize(buf).trimmingCharacters(in: .whitespaces)
                    if !seg.isEmpty { out.append(seg) }
                    buf = ""
                }
                out.append(String(ch))
            } else {
                buf.append(ch)
            }
        }
        if !buf.isEmpty {
            let seg = phonemizer.phonemize(buf).trimmingCharacters(in: .whitespaces)
            if !seg.isEmpty { out.append(seg) }
        }
        var ipa = KittenWordNormalizer.patchIPA(out.joined(separator: " "))
        for (src, dst) in ipaPatchRuntime {
            ipa = ipa.replacingOccurrences(of: src, with: dst)
        }
        return ipa
    }

    /// Mirrors upstream `basic_english_tokenize(text); ' '.join(tokens)`:
    /// extract `\w+` runs and isolated `[^\w\s]` chars, then rejoin with single spaces.
    /// This normalises spacing and isolates punctuation with a leading space — the
    /// exact form the model was trained on.
    static func basicEnglishTokenizeJoin(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\w+|[^\w\s]"#) else { return s }
        let ns = s as NSString
        var parts: [String] = []
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            parts.append(ns.substring(with: m.range))
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Chunk synthesis with saturation-based auto-split

    private func synthChunkWithAutoSplit(
        chunk: String,
        voiceData: [Float],
        speed: Float,
        droppedSink: inout Set<Unicode.Scalar>,
        depth: Int,
        isSentenceFinal: Bool = false
    ) throws -> [Float] {
        let ipa = Self.phonemizePreservingPunctuation(chunk, phonemizer: phonemizer)
        let retokenised = Self.basicEnglishTokenizeJoin(ipa)
        let (tokens, miss) = KittenTextCleaner.encodeWithLog(retokenised)
        droppedSink.formUnion(miss)

        if ProcessInfo.processInfo.environment["KITTEN_LOG_PHONEMES"] == "1" {
            fputs("phonemes@depth\(depth): “\(chunk)” → \(ipa)\n", stderr)
        }

        // If token count exceeds the model's fixed 140-slot input, we can't run
        // the chunk at all — split it now.
        if tokens.count > Self.maxTokens {
            return try splitAndSynth(chunk, voiceData: voiceData, speed: speed,
                                     droppedSink: &droppedSink, depth: depth,
                                     isSentenceFinal: isSentenceFinal,
                                     reason: "\(tokens.count) tokens > \(Self.maxTokens)")
        }

        let (samples, audioLen) = try runChunk(
            tokens: tokens, voiceData: voiceData,
            textChunkLen: chunk.count,
            phonemeLen: ipa.count,
            chunkText: chunk,
            ipa: ipa,
            speed: speed,
            isSentenceFinal: isSentenceFinal
        )
        let saturated = audioLen >= (Self.maxSamples - Self.saturationMargin)

        if saturated && depth < 4 && chunk.split(separator: " ").count > 1 {
            fputs("⚠︎ chunk saturated 10s cap at depth \(depth) (\(chunk.count) chars → \(tokens.count) tok → \(audioLen) samples), splitting: “\(chunk.prefix(50))…”\n", stderr)
            return try splitAndSynth(chunk, voiceData: voiceData, speed: speed,
                                     droppedSink: &droppedSink, depth: depth,
                                     isSentenceFinal: isSentenceFinal,
                                     reason: "saturated")
        }

        if saturated {
            fputs("⚠︎ chunk saturated and cannot split further (depth \(depth), words=\(chunk.split(separator: " ").count))\n", stderr)
        }
        return samples
    }

    private func splitAndSynth(
        _ chunk: String,
        voiceData: [Float],
        speed: Float,
        droppedSink: inout Set<Unicode.Scalar>,
        depth: Int,
        isSentenceFinal: Bool,
        reason: String
    ) throws -> [Float] {
        let words = chunk.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 1 else { return [] }
        let mid = words.count / 2
        let left = Self.ensurePunctuation(words[0..<mid].joined(separator: " "))
        let right = Self.ensurePunctuation(words[mid..<words.count].joined(separator: " "))

        let leftSamples = try synthChunkWithAutoSplit(
            chunk: left, voiceData: voiceData, speed: speed,
            droppedSink: &droppedSink, depth: depth + 1,
            isSentenceFinal: false
        )
        let rightSamples = try synthChunkWithAutoSplit(
            chunk: right, voiceData: voiceData, speed: speed,
            droppedSink: &droppedSink, depth: depth + 1,
            isSentenceFinal: isSentenceFinal
        )
        let xfadeSamples = max(0, Self.sampleRate * Self.xfadeMs / 1000)
        var out = leftSamples
        if xfadeSamples > 0 {
            Self.appendWithCrossfade(dst: &out, src: rightSamples, xfadeSamples: xfadeSamples)
        } else {
            let fadeSamples = max(1, Self.sampleRate * Self.fadeMs / 1000)
            Self.microfade(&out, fadeSamples: fadeSamples)
            var r = rightSamples
            Self.microfade(&r, fadeSamples: fadeSamples)
            out.append(contentsOf: r)
        }
        _ = reason
        return out
    }

    // MARK: - Per-chunk inference

    private func runChunk(
        tokens: [Int64],
        voiceData: [Float],
        textChunkLen: Int,
        phonemeLen: Int,
        chunkText: String = "",
        ipa: String = "",
        speed: Float,
        isSentenceFinal: Bool = false
    ) throws -> (samples: [Float], audioLen: Int) {
        let logTokens = ProcessInfo.processInfo.environment["KITTEN_LOG_TOKENS"] == "1"
        let idsPtr = inputIdsArr.dataPointer.bindMemory(to: Int32.self, capacity: Self.maxTokens)
        let maskPtr = attentionMaskArr.dataPointer.bindMemory(to: Int32.self, capacity: Self.maxTokens)
        for i in 0..<Self.maxTokens {
            if i < tokens.count {
                idsPtr[i] = Int32(tokens[i])
                maskPtr[i] = 1
            } else {
                idsPtr[i] = 0
                maskPtr[i] = 0
            }
        }

        if logTokens {
            let scalars = ipa.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            let tokStr = tokens.map { String($0) }.joined(separator: ",")
            let first = tokens.first.map { String($0) } ?? "nil"
            let lastTok = tokens.last.map { String($0) } ?? "nil"
            let penult = tokens.count >= 2 ? String(tokens[tokens.count - 2]) : "nil"
            let contentCount = tokens.filter { $0 > 16 }.count
            let punctCount = tokens.filter { $0 > 0 && $0 <= 16 }.count
            fputs("=== token-trace chunk ===\n", stderr)
            fputs("  text: \"\(chunkText)\"\n", stderr)
            fputs("  ipa: \"\(ipa)\" (chars=\(ipa.count) scalars=\(ipa.unicodeScalars.count))\n", stderr)
            fputs("  scalars: \(scalars)\n", stderr)
            fputs("  tokens(count=\(tokens.count) cap=\(Self.maxTokens)): \(tokStr)\n", stderr)
            fputs("  structure: tokens[0]=\(first) tokens[-2]=\(penult) tokens[-1]=\(lastTok) (expect 0,10,0 = start,end,pad)\n", stderr)
            fputs("  classification: content(>16)=\(contentCount) punct(1..16)=\(punctCount) start/end/pad=\(tokens.count - contentCount - punctCount)\n", stderr)
            fputs("  mask: ones=\(tokens.count) zeros=\(Self.maxTokens - tokens.count) (mask==1 for pad-token at end)\n", stderr)
        }

        let stylePtr = styleArr.dataPointer.bindMemory(to: Float.self, capacity: 256)
        var features: [String: MLFeatureValue] = [
            "input_ids":      MLFeatureValue(multiArray: inputIdsArr),
            "attention_mask": MLFeatureValue(multiArray: attentionMaskArr),
        ]

        switch variant {
        case .nano:
            // Nano: single 256-dim vector (the .bin is 1 KB == 256 floats).
            for i in 0..<256 { stylePtr[i] = voiceData[i] }
            features["ref_s"]         = MLFeatureValue(multiArray: styleArr)
            features["random_phases"] = MLFeatureValue(multiArray: randomPhasesArr!)
            features["source_noise"]  = MLFeatureValue(multiArray: sourceNoiseArr!)

        case .mini:
            // Mini: (400, 256) matrix. Upstream kittentts/onnx_model.py indexes by
            //   ref_id = min(len(text_chunk), voices[voice].shape[0] - 1)
            // Swift SDK indexes by phoneme length, Rust port by token count —
            // the ecosystem disagrees. Default to Python. Policy is a runtime
            // knob so style-row sweeps can hold everything else fixed.
            let policyRow: Int
            switch Self.styleRowPolicy {
            case "phonemes": policyRow = min(phonemeLen, 399)
            case "tokens":   policyRow = min(tokens.count, 399)
            default:         policyRow = min(textChunkLen, 399)
            }
            let rowIdx = Self.styleRowOverride >= 0
                ? min(max(0, Self.styleRowOverride), 399)
                : policyRow
            if ProcessInfo.processInfo.environment["KITTEN_LOG_STYLE_ROW"] == "1" {
                fputs(
                    "style: textLen=\(textChunkLen) phonLen=\(phonemeLen) tokLen=\(tokens.count) policy=\(Self.styleRowPolicy) override=\(Self.styleRowOverride) → row=\(rowIdx)\n",
                    stderr
                )
            }
            let base = rowIdx * 256
            for i in 0..<256 { stylePtr[i] = voiceData[base + i] }
            speedArr![0] = NSNumber(value: speed)
            features["style"] = MLFeatureValue(multiArray: styleArr)
            features["speed"] = MLFeatureValue(multiArray: speedArr!)
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: features)
        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: provider)
        } catch {
            throw KittenCoreMLError.inferenceFailed(String(describing: error))
        }

        guard let audio = output.featureValue(for: "audio")?.multiArrayValue,
              let lenArr = output.featureValue(for: "audio_length_samples")?.multiArrayValue
        else {
            throw KittenCoreMLError.inferenceFailed("missing output features")
        }
        let predDur = output.featureValue(for: "pred_dur")?.multiArrayValue

        let total = audio.count
        let rawLen = max(0, min(lenArr[0].intValue, total))

        if logTokens {
            fputs("  audio_length_samples=\(rawLen) audio_buffer_total=\(total) saturated=\(rawLen >= Self.maxSamples - Self.saturationMargin)\n", stderr)
            if let pd = predDur {
                let n = min(pd.count, tokens.count)
                let pdPtr = pd.dataPointer.bindMemory(to: Float.self, capacity: pd.count)
                var cum: Float = 0
                var tail = ""
                let tailStart = max(0, n - 12)
                for i in 0..<n { cum += pdPtr[i] }
                let total = cum
                let spf = total > 0 ? Float(rawLen) / total : 0
                cum = 0
                for i in 0..<n {
                    cum += pdPtr[i]
                    if i >= tailStart {
                        let endSample = Int(cum * spf)
                        tail += String(format: " tok[%d]=%d dur=%.2f end=%d;", i, tokens[i], pdPtr[i], endSample)
                    }
                }
                fputs("  pred_dur totalFrames=\(String(format: "%.2f", total)) samplesPerFrame=\(String(format: "%.2f", spf))\n", stderr)
                fputs("  pred_dur tail:\(tail)\n", stderr)
            } else {
                fputs("  pred_dur: (absent from output)\n", stderr)
            }
        }

        if ProcessInfo.processInfo.environment["KITTEN_LOG_DURATION"] == "1",
           let pd = predDur {
            let n = min(pd.count, tokens.count)
            let pdPtr = pd.dataPointer.bindMemory(to: Float.self, capacity: pd.count)
            var cum: Float = 0
            var perToken: [(Int, Float, Float)] = []  // (tokenIdx, dur, cumFrames)
            for i in 0..<n {
                let d = pdPtr[i]
                cum += d
                perToken.append((i, d, cum))
            }
            let totalFrames = cum
            let samplesPerFrame = totalFrames > 0 ? Float(rawLen) / totalFrames : 0
            fputs(
                "duration: rawLen=\(rawLen) totalFrames=\(totalFrames) samplesPerFrame=\(String(format: "%.2f", samplesPerFrame))\n",
                stderr
            )
            let tailStart = max(0, perToken.count - 12)
            for (i, d, c) in perToken[tailStart..<perToken.count] {
                let sampleEnd = Int(c * samplesPerFrame)
                fputs(
                    "  tok[\(i)]=\(tokens[i]) dur=\(String(format: "%.2f", d)) cumFrames=\(String(format: "%.2f", c)) endSample=\(sampleEnd)\n",
                    stderr
                )
            }
        }
        let audioPtr = audio.dataPointer.bindMemory(to: Float.self, capacity: total)
        let rawBuf = UnsafeBufferPointer(start: audioPtr, count: max(rawLen, 1))
        // Only use the deep 9000-sample trim on chunks that saturated the
        // 10 s output cap (the model was still generating at the boundary
        // and `audio_length_samples` includes vocoder wind-down). Everything
        // else gets the short 3000-sample trim, which preserves word-final
        // phonemes on sentences like "…people whispered." The earlier
        // content-aware heuristic misfired because natural end-of-sentence
        // silence + an unvoiced final consonant look quiet by RMS but still
        // contain real speech we need to keep.
        let saturated = rawLen >= (Self.maxSamples - Self.saturationMargin)
        // For sentence-final chunks, the tail of the raw buffer typically
        // contains: [speech end] [brief silence] [vocoder noise burst
        // ~40 ms] [long silence]. A fixed trim can't catch the noise
        // burst reliably — `speechEndBoundary` scans backward past any
        // sub-threshold region (noise and silence both) and cuts right
        // after the last voiced frame, eliminating the buzz the user
        // hears before each inter-sentence pause.
        let afterFixedTrim: Int
        if isSentenceFinal {
            if Self.trimMode == "dur-aligned", let pd = predDur {
                afterFixedTrim = Self.durationAlignedEnd(
                    predDur: pd, tokens: tokens, rawLen: rawLen
                )
            } else {
                afterFixedTrim = Self.speechEndBoundary(
                    buf: rawBuf, rawLen: rawLen
                )
            }
        } else {
            let trim = saturated ? Self.chunkTailTrim : Self.shortChunkTailTrim
            afterFixedTrim = max(0, rawLen - trim)
        }
        if ProcessInfo.processInfo.environment["KITTEN_LOG_TRIM"] == "1" {
            let mode = isSentenceFinal ? "speechEnd" : (saturated ? "sat" : "short")
            fputs("trim: rawLen=\(rawLen) mode=\(mode) → \(afterFixedTrim)\n", stderr)
        }
        let adaptiveLen = Self.adaptiveBoundary(buf: rawBuf, initialEnd: afterFixedTrim)
        if logTokens {
            fputs("  crop: afterFixedTrim=\(afterFixedTrim) adaptiveLen=\(adaptiveLen) isSentenceFinal=\(isSentenceFinal) trimMode=\(Self.trimMode)\n", stderr)
            fputs("=== end token-trace ===\n", stderr)
        }
        var samples = Array(UnsafeBufferPointer(start: audioPtr, count: adaptiveLen))
        if Self.dcBlockEnabled {
            Self.dcBlock(&samples)
        }
        return (samples, rawLen)
    }

    // MARK: - DSP

    /// Equal-power crossfade: overlap the last `xfadeSamples` of `dst` with the
    /// first `xfadeSamples` of `src`, then append the remaining tail of `src`.
    /// Curves are sin/cos so summed power is constant. Optionally snaps the
    /// overlap start on each side to the nearest zero-crossing within
    /// `zcSnapSamples` so any residual amplitude offset at the boundary is
    /// eliminated.
    private static func appendWithCrossfade(dst: inout [Float], src: [Float], xfadeSamples: Int) {
        let n = min(xfadeSamples, dst.count, src.count)
        if n <= 0 {
            dst.append(contentsOf: src)
            return
        }
        var dstStart = dst.count - n
        var srcStart = 0

        let snap = Self.zcSnapSamples
        if snap > 0 {
            // Shift dstStart earlier (within ±snap) to nearest zero-crossing.
            dstStart = nearestZeroCrossing(in: dst, around: dstStart, radius: snap)
            srcStart = nearestZeroCrossing(in: src, around: 0, radius: snap)
        }

        let nd = dst.count - dstStart
        let ns = src.count - srcStart
        let m = min(n, nd, ns)
        guard m > 0 else { dst.append(contentsOf: src); return }

        // Overwrite dst[dstStart..dstStart+m) with crossfaded samples, then
        // append the rest of src.
        for i in 0..<m {
            let t = Float(i) / Float(m - 1)
            let fadeOut = cos(t * .pi / 2)
            let fadeIn = sin(t * .pi / 2)
            dst[dstStart + i] = dst[dstStart + i] * fadeOut + src[srcStart + i] * fadeIn
        }
        dst.removeLast(nd - m)  // drop any dst samples past the fade region
        if src.count > srcStart + m {
            dst.append(contentsOf: src[(srcStart + m)..<src.count])
        }
    }

    /// Find the index nearest to `around` (within ±`radius`) where the signal
    /// crosses zero. Returns `around` if none found.
    private static func nearestZeroCrossing(in buf: [Float], around: Int, radius: Int) -> Int {
        let lo = max(1, around - radius)
        let hi = min(buf.count - 1, around + radius)
        if lo >= hi { return around }
        var best = around
        var bestDist = Int.max
        var i = lo
        while i < hi {
            if (buf[i - 1] >= 0 && buf[i] < 0) || (buf[i - 1] <= 0 && buf[i] > 0) {
                let d = abs(i - around)
                if d < bestDist {
                    bestDist = d
                    best = i
                }
            }
            i += 1
        }
        return best
    }

    /// Look at the last ~200 ms of a chunk. If it's already quiet (-20 dB or
    /// more below the chunk peak) we can safely trim the full 9000-sample
    /// vocoder tail; the content ended earlier anyway. If it's loud, the
    /// vocoder was still rendering real phonemes at the end — a deep trim
    /// would clip the last word. Use a conservative short trim instead.
    private static func chooseTailTrim(buf: UnsafeBufferPointer<Float>) -> Int {
        if buf.count < 2 * Self.chunkTailTrim { return Self.shortChunkTailTrim }
        var peak: Float = 1e-6
        for i in 0..<buf.count {
            let a = abs(buf[i])
            if a > peak { peak = a }
        }
        let window = Self.sampleRate * 200 / 1000
        let start = buf.count - window
        var ssq: Float = 0
        for i in start..<buf.count { ssq += buf[i] * buf[i] }
        let rms = (ssq / Float(window)).squareRoot()
        // -20 dB threshold
        return rms < peak * 0.1 ? Self.chunkTailTrim : Self.shortChunkTailTrim
    }

    /// Dispatch to one of the speech-end trim strategies. Behaviour selected
    /// by `KITTEN_TRIM_MODE`. All modes share a common goal: cut the raw
    /// chunk just after the last real speech frame and before the vocoder's
    /// wind-down noise burst, without clipping the final word.
    static func speechEndBoundary(
        buf: UnsafeBufferPointer<Float>, rawLen: Int
    ) -> Int {
        switch trimMode {
        case "bounded-back":  return speechEndBoundedBack(buf: buf, rawLen: rawLen)
        case "fwd-last-loud": return speechEndFwdLastLoud(buf: buf, rawLen: rawLen)
        case "fwd-extend":    return speechEndFwdExtend(buf: buf, rawLen: rawLen)
        case "burst-scan":    return speechEndBurstScan(buf: buf, rawLen: rawLen)
        case "aggressive":    return max(0, rawLen - aggressiveTrimSamples)
        default:              return speechEndV26(buf: buf, rawLen: rawLen)
        }
    }

    /// Compute the sample index just after the last content token's predicted
    /// end, using `pred_dur`. "Content" = id > 16 in KittenTextCleaner's
    /// symbol table (ids 0–16 are pad, punctuation, EOS, and space; 17+ are
    /// letters and IPA). The trailing pad / EOS / period tokens each carry
    /// their own predicted duration, and the vocoder renders "silence-like"
    /// audio across them — which is where the wind-down burst lives. Cutting
    /// at the last content-token boundary removes the burst regardless of
    /// whether it sits in the EOS-token window or the pad window.
    static func durationAlignedEnd(
        predDur: MLMultiArray, tokens: [Int64], rawLen: Int
    ) -> Int {
        let n = min(predDur.count, tokens.count)
        guard n > 0 else { return rawLen }
        let pdPtr = predDur.dataPointer.bindMemory(to: Float.self, capacity: predDur.count)
        var totalFrames: Float = 0
        var perTokenEnd = [Float](repeating: 0, count: n)
        for i in 0..<n {
            totalFrames += pdPtr[i]
            perTokenEnd[i] = totalFrames
        }
        guard totalFrames > 0 else { return rawLen }
        let samplesPerFrame = Float(rawLen) / totalFrames
        var lastContent = -1
        for i in stride(from: n - 1, through: 0, by: -1) {
            if tokens[i] > 16 { lastContent = i; break }
        }
        guard lastContent >= 0 else { return rawLen }
        let contentEnd = Int(perTokenEnd[lastContent] * samplesPerFrame)
        let margin = sampleRate * durMarginMs / 1000
        return min(rawLen, contentEnd + margin)
    }

    // MARK: - Speech-end detection helpers

    private static func framePeakRms(
        buf: UnsafeBufferPointer<Float>, rawLen: Int
    ) -> Float {
        let frame = sampleRate / 100
        let onsetSkip = min(rawLen, sampleRate / 20)
        var peakSsq: Float = 0
        var i = onsetSkip
        while i + frame <= rawLen {
            var ssq: Float = 0
            for j in i..<i + frame { ssq += buf[j] * buf[j] }
            if ssq > peakSsq { peakSsq = ssq }
            i += frame
        }
        return peakSsq > 0 ? (peakSsq / Float(frame)).squareRoot() : 0
    }

    private static func frameRms(
        buf: UnsafeBufferPointer<Float>, start: Int, len: Int
    ) -> Float {
        var ssq: Float = 0
        for j in start..<start + len { ssq += buf[j] * buf[j] }
        return (ssq / Float(len)).squareRoot()
    }

    /// Zero-crossing rate normalised to [0, 1] over a frame. Vocoder
    /// wind-down noise tends to sit at 0.45–0.6; voiced vowels ~0.05–0.2;
    /// unvoiced fricatives 0.3–0.5 (overlaps the burst, so ZCR alone isn't
    /// sufficient — combine with RMS).
    private static func frameZcr(
        buf: UnsafeBufferPointer<Float>, start: Int, len: Int
    ) -> Float {
        guard len > 1 else { return 0 }
        var crossings = 0
        for j in (start + 1)..<(start + len) {
            if (buf[j - 1] >= 0) != (buf[j] >= 0) { crossings += 1 }
        }
        return Float(crossings) / Float(len - 1)
    }

    private static func fallbackTrim(_ rawLen: Int) -> Int {
        max(0, rawLen - sampleRate * trimFallbackMs / 1000)
    }

    // MARK: - Trim strategies

    /// Original v26: backward scan from rawLen, find last 3-frame run of
    /// RMS ≥ peak × 0.3. Returns rawLen unchanged if none found (UNDERTRIM).
    private static func speechEndV26(
        buf: UnsafeBufferPointer<Float>, rawLen: Int
    ) -> Int {
        let frame = sampleRate / 100
        let marginSamples = sampleRate * 35 / 1000
        let floorEnd = max(frame, rawLen / 2)
        let peakRms = framePeakRms(buf: buf, rawLen: rawLen)
        if peakRms <= 0 { return rawLen }
        let threshold = peakRms * 0.3
        let requiredFrames = 3

        var end = rawLen
        var consecutive = 0
        var runRightEdge = rawLen
        var speechEnd: Int? = nil
        while end - frame >= floorEnd {
            let start = end - frame
            let rms = frameRms(buf: buf, start: start, len: frame)
            if rms >= threshold {
                if consecutive == 0 { runRightEdge = end }
                consecutive += 1
                if consecutive >= requiredFrames {
                    speechEnd = runRightEdge
                    break
                }
            } else {
                consecutive = 0
            }
            end -= frame
        }
        return speechEnd.map { min(rawLen, $0 + marginSamples) } ?? rawLen
    }

    /// Like v26, but the backward scan is capped at `trimLookbackMs` so we
    /// can't walk past the current sentence's tail into an earlier word.
    /// If no sustained-loud run is found in the window, falls back to a
    /// fixed trim (`trimFallbackMs`) to clear the burst by brute force.
    private static func speechEndBoundedBack(
        buf: UnsafeBufferPointer<Float>, rawLen: Int
    ) -> Int {
        let frame = sampleRate / 100
        let marginSamples = sampleRate * 35 / 1000
        let lookback = sampleRate * trimLookbackMs / 1000
        let floorEnd = max(frame, rawLen - lookback)
        let peakRms = framePeakRms(buf: buf, rawLen: rawLen)
        if peakRms <= 0 { return rawLen }
        let threshold = peakRms * 0.3
        let requiredFrames = 3

        var end = rawLen
        var consecutive = 0
        var runRightEdge = rawLen
        var speechEnd: Int? = nil
        while end - frame >= floorEnd {
            let start = end - frame
            let rms = frameRms(buf: buf, start: start, len: frame)
            if rms >= threshold {
                if consecutive == 0 { runRightEdge = end }
                consecutive += 1
                if consecutive >= requiredFrames {
                    speechEnd = runRightEdge
                    break
                }
            } else {
                consecutive = 0
            }
            end -= frame
        }
        return speechEnd.map { min(rawLen, $0 + marginSamples) }
            ?? fallbackTrim(rawLen)
    }

    /// Forward scan over the last `trimLookbackMs`. Record the end index of
    /// the last frame with RMS ≥ peak × 0.3, then add a generous margin
    /// (`fwdMarginMs`, default 100 ms) so short unvoiced finals (/t/, /s/)
    /// aren't clipped. Falls back to a fixed trim if no loud frame exists.
    private static func speechEndFwdLastLoud(
        buf: UnsafeBufferPointer<Float>, rawLen: Int
    ) -> Int {
        let frame = sampleRate / 100
        let lookback = sampleRate * trimLookbackMs / 1000
        let searchStart = max(0, rawLen - lookback)
        let peakRms = framePeakRms(buf: buf, rawLen: rawLen)
        if peakRms <= 0 { return rawLen }
        let threshold = peakRms * 0.3
        let margin = sampleRate * fwdMarginMs / 1000

        var lastLoudEnd: Int? = nil
        var i = searchStart
        while i + frame <= rawLen {
            if frameRms(buf: buf, start: i, len: frame) >= threshold {
                lastLoudEnd = i + frame
            }
            i += frame
        }
        if let lle = lastLoudEnd {
            return min(rawLen, lle + margin)
        }
        return fallbackTrim(rawLen)
    }

    /// Finds the last loud frame (as fwd-last-loud), then extends the cut
    /// forward through "quiet-but-present" frames (RMS ≥ peak × 0.02).
    /// STOPS extending if a frame looks like the burst: RMS still above
    /// silence floor but below the loud threshold AND ZCR ≥ 0.45. That
    /// way quiet natural tails (breathy /d/, /ə/ release) get preserved
    /// while the post-utterance burst is cut off.
    private static func speechEndFwdExtend(
        buf: UnsafeBufferPointer<Float>, rawLen: Int
    ) -> Int {
        let frame = sampleRate / 100
        let lookback = sampleRate * trimLookbackMs / 1000
        let searchStart = max(0, rawLen - lookback)
        let peakRms = framePeakRms(buf: buf, rawLen: rawLen)
        if peakRms <= 0 { return rawLen }
        let loudT = peakRms * 0.3
        let quietT = peakRms * 0.02
        let postMargin = sampleRate * 20 / 1000

        var lastLoudEnd: Int? = nil
        var i = searchStart
        while i + frame <= rawLen {
            if frameRms(buf: buf, start: i, len: frame) >= loudT {
                lastLoudEnd = i + frame
            }
            i += frame
        }
        guard var ext = lastLoudEnd else {
            return fallbackTrim(rawLen)
        }

        var j = ext
        while j + frame <= rawLen {
            let rms = frameRms(buf: buf, start: j, len: frame)
            if rms < quietT { break }
            let zcr = frameZcr(buf: buf, start: j, len: frame)
            if zcr > 0.45 && rms < loudT { break }
            ext = j + frame
            j += frame
        }
        return min(rawLen, ext + postMargin)
    }

    /// Scan the last 300 ms. Mark the last "loud" frame and the earliest
    /// subsequent "burst" frame (low RMS + high ZCR). Cut at the leading
    /// edge of the burst run. If no burst is detected but some speech was
    /// found, add a small margin; otherwise fall back.
    private static func speechEndBurstScan(
        buf: UnsafeBufferPointer<Float>, rawLen: Int
    ) -> Int {
        let frame = sampleRate / 100
        let lookback = sampleRate * 300 / 1000
        let searchStart = max(0, rawLen - lookback)
        let peakRms = framePeakRms(buf: buf, rawLen: rawLen)
        if peakRms <= 0 { return rawLen }
        let loudT = peakRms * 0.3
        let silenceT = peakRms * 0.002

        var lastLoudEnd = searchStart
        var anyLoud = false
        var burstStart: Int? = nil
        var i = searchStart
        while i + frame <= rawLen {
            let rms = frameRms(buf: buf, start: i, len: frame)
            if rms >= loudT {
                lastLoudEnd = i + frame
                anyLoud = true
                burstStart = nil
            } else if rms >= silenceT && burstStart == nil {
                let zcr = frameZcr(buf: buf, start: i, len: frame)
                if zcr > 0.45 { burstStart = i }
            }
            i += frame
        }
        let margin = sampleRate * 20 / 1000
        if let bs = burstStart {
            return max(lastLoudEnd, min(rawLen, bs))
        }
        if anyLoud {
            return min(rawLen, lastLoudEnd + margin)
        }
        return fallbackTrim(rawLen)
    }

    private static func adaptiveBoundary(
        buf: UnsafeBufferPointer<Float>, initialEnd: Int
    ) -> Int {
        if Self.adaptiveTrimMs <= 0 || initialEnd <= 0 { return initialEnd }
        let frame = sampleRate / 100  // 10 ms
        let lookback = Self.sampleRate * Self.adaptiveTrimMs / 1000
        let minEnd = max(0, initialEnd - lookback)

        // Peak of the whole chunk for a relative threshold.
        var peak: Float = 1e-6
        for i in 0..<initialEnd { let a = abs(buf[i]); if a > peak { peak = a } }
        let threshold = peak * 0.00562  // -45 dB

        var candidate = initialEnd
        var end = initialEnd
        while end - frame >= minEnd {
            let start = end - frame
            var ssq: Float = 0
            for i in start..<end { ssq += buf[i] * buf[i] }
            let rms = (ssq / Float(frame)).squareRoot()
            if rms < threshold {
                candidate = end
                break
            }
            end -= frame
        }
        return candidate
    }

    /// First-order DC-blocking filter (y[n] = x[n] - x[n-1] + R·y[n-1]).
    /// R=0.995 → ~19 Hz cutoff at 24 kHz.
    private static func dcBlock(_ samples: inout [Float]) {
        let r: Float = 0.995
        var prevX: Float = 0
        var prevY: Float = 0
        for i in samples.indices {
            let x = samples[i]
            let y = x - prevX + r * prevY
            samples[i] = y
            prevX = x
            prevY = y
        }
    }

    private static func microfade(_ samples: inout [Float], fadeSamples: Int) {
        let n = min(fadeSamples, samples.count / 2)
        guard n > 0 else { return }
        for i in 0..<n {
            let g = Float(i) / Float(n)
            samples[i] *= g
            samples[samples.count - 1 - i] *= g
        }
    }

    static func fadeOutTail(_ samples: inout [Float], fadeSamples: Int) {
        let n = min(fadeSamples, samples.count)
        guard n > 0 else { return }
        let start = samples.count - n
        for i in 0..<n {
            let g = Float(n - 1 - i) / Float(n)
            samples[start + i] *= g
        }
    }

    static func fadeInHead(_ samples: inout [Float], fadeSamples: Int) {
        let n = min(fadeSamples, samples.count)
        guard n > 0 else { return }
        for i in 0..<n {
            let g = Float(i) / Float(n)
            samples[i] *= g
        }
    }

    private static func fillRandN(_ arr: MLMultiArray) {
        let count = arr.count
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: count)
        var i = 0
        while i + 1 < count {
            var u1 = Float.random(in: 0..<1)
            if u1 < 1e-7 { u1 = 1e-7 }
            let u2 = Float.random(in: 0..<1)
            let r = sqrt(-2 * log(u1))
            let th = 2 * Float.pi * u2
            ptr[i]     = r * cos(th)
            ptr[i + 1] = r * sin(th)
            i += 2
        }
        if i < count {
            var u1 = Float.random(in: 0..<1)
            if u1 < 1e-7 { u1 = 1e-7 }
            let u2 = Float.random(in: 0..<1)
            ptr[i] = sqrt(-2 * log(u1)) * cos(2 * Float.pi * u2)
        }
    }
}
