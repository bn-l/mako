import Foundation
import Testing
@testable import TTSHarnessCore

/// Golden trace for the `foot-massage` passage — the Phase 9a gate that
/// protects the full `source → KokoroG2P.resolve → emit →
/// compensatorsOnly` chain against silent regressions on a real passage
/// (times, abbreviations, hyphen compounds, Celtic names, room codes,
/// 57th-street ordinal, currency, percent, hertz, 100th, ...).
///
/// The golden lives under `Tests/TTSHarnessCoreTests/Resources/`. When
/// the pipeline legitimately changes output, regenerate the golden with:
///   swift run mac-tts normalize-preview --ported \
///       --file Sources/TTSHarnessCore/Resources/foot-massage.txt \
///       > Tests/TTSHarnessCoreTests/Resources/foot-massage.ported.golden.txt
/// and include the diff + justification in the PR.
///
/// The post-`synthesizeDetailed` chunk trace (`PostFluidAudioTests`
/// per the plan) is NOT in this suite — it requires a FluidAudio model
/// load and so lives behind the `INTEGRATION=1` gate in a separate
/// suite (see `IntegrationTests.swift`).
@Suite("FootMassageGoldenTrace")
struct FootMassageGoldenTrace {

    @Test("Ported pipeline output matches golden on foot-massage")
    func goldenTraceMatches() throws {
        let source = try Passage.load("foot-massage")
        let plan = KokoroG2P.resolve(source)
        let emitted = KokoroG2P.emit(plan)
        let actual = KokoroSSMLNormalizer.compensatorsOnly(emitted.annotatedText)

        guard let goldenURL = Bundle.module.url(
            forResource: "foot-massage.ported.golden", withExtension: "txt"
        ) else {
            Issue.record("missing foot-massage.ported.golden.txt in test bundle")
            return
        }
        let goldenRaw = try String(contentsOf: goldenURL, encoding: .utf8)
        // The golden capture is written with a trailing newline by the CLI's
        // `print`; trim both sides so we compare what the pipeline emits.
        let golden = goldenRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(actual == golden,
            "foot-massage golden diverged. Regenerate with normalize-preview --ported if change is intentional."
        )
    }
}
