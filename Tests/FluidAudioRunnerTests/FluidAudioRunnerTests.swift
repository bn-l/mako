import Foundation
import Testing
import FluidAudio
import FluidAudioRunner
@testable import TTSHarnessCore

/// Phase 9a `PostFluidAudioTests` — the post-`synthesizeDetailed` gate
/// from the plan (checkpoint J.3). Chunk text / words / atoms / token
/// count are the only fields FluidAudio's `ChunkInfo` exposes publicly;
/// post-`TtsTextPreprocessor` text + final phonemes stay unreachable
/// until an upstream debug hook lands (checkpoint J.1).
///
/// Requires a FluidAudio Kokoro model download — gated behind
/// `INTEGRATION=1` so `swift test` stays hermetic by default. Invoke with:
///   INTEGRATION=1 swift test --filter PostFluidAudioTests
@Suite("PostFluidAudioTests",
       .enabled(if: ProcessInfo.processInfo.environment["INTEGRATION"] != nil))
struct PostFluidAudioTests {

    /// End-to-end ported-pipeline smoke test against foot-massage. Runs
    /// the model and asserts that chunking produces ≥1 chunk and that
    /// a hyphen-compound surface survives through to the chunker — a
    /// canary for silent second-preprocessor regressions on our spans.
    @Test("foot-massage synthesizes under ported G2P and produces chunks")
    func footMassageSynthesizesUnderPorted() async throws {
        let source = try Passage.load("foot-massage")
        let plan = KokoroG2P.resolve(source)
        let emitted = KokoroG2P.emit(plan)
        let normalized = KokoroSSMLNormalizer.compensatorsOnly(emitted.annotatedText)
        let lexicon = emitted.lexiconEntries.isEmpty
            ? nil
            : TtsCustomLexicon(entries: emitted.lexiconEntries)

        let manager = KokoroTtsManager(defaultVoice: "af_heart", customLexicon: lexicon)
        try await manager.initialize()
        let result = try await manager.synthesizeDetailed(text: normalized, voice: "af_heart")

        #expect(!result.chunks.isEmpty, "synthesis should produce at least one chunk")

        // The `state-of-the-art` hyphen compound is spliced as
        // `<sub alias="state of the art">state-of-the-art</sub>`. After
        // FluidAudio's SSML + second-preprocessor pass, at least one
        // chunk's surface text must still carry the spoken form —
        // otherwise a downstream expander has consumed it.
        let allText = result.chunks.map { $0.text }.joined(separator: " ").lowercased()
        #expect(allText.contains("state of the art") || allText.contains("state-of-the-art"),
                "expected hyphen-compound surface to survive preprocessing")
    }
}
