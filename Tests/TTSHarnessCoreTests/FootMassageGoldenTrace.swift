import Foundation
import Testing
@testable import TTSHarnessCore

/// Parameterized golden traces for the full ported pipeline
/// (`KokoroG2P.resolve → emit → compensatorsOnly`) on every bundled
/// passage. Guards against silent regressions on real prose: times,
/// abbreviations, hyphen compounds, Celtic names, room codes, ordinals,
/// currency, percent, units — each passage exercises a different mix.
///
/// Goldens live under `Tests/TTSHarnessCoreTests/Resources/` as
/// `<name>.ported.golden.txt`. When the pipeline legitimately changes
/// output, regenerate them with:
///   swift run mako dev normalize-preview --ported \
///       --file Sources/TTSHarnessCore/Resources/<name>.txt \
///       > Tests/TTSHarnessCoreTests/Resources/<name>.ported.golden.txt
/// and include the diff + justification in the PR.
///
/// The post-`synthesizeDetailed` chunk trace is NOT in this suite — it
/// requires a FluidAudio model load and lives behind `INTEGRATION=1` in
/// `FluidAudioRunnerTests`.
@Suite("PortedPipelineGoldenTrace")
struct PortedPipelineGoldenTrace {

    /// Every prose passage we ship. Homographs isn't prose; it's a
    /// fixture, covered separately by `LexiconProvenanceTests` /
    /// `POSDecisionTests`.
    static let passages: [String] = ["foot-massage", "gulliver", "micro-corpus", "brutal"]

    @Test(arguments: passages)
    func goldenMatches(_ name: String) throws {
        let source = try Passage.load(name)
        let plan = KokoroG2P.resolve(source)
        let emitted = KokoroG2P.emit(plan)
        let actual = KokoroSSMLNormalizer.compensatorsOnly(emitted.annotatedText)

        guard let goldenURL = Bundle.module.url(
            forResource: "\(name).ported.golden", withExtension: "txt"
        ) else {
            Issue.record("missing \(name).ported.golden.txt in test bundle")
            return
        }
        let goldenRaw = try String(contentsOf: goldenURL, encoding: .utf8)
        // The golden capture is written with a trailing newline by the CLI's
        // `print`; trim both sides so we compare what the pipeline emits.
        let golden = goldenRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(actual == golden,
            "\(name) golden diverged. Regenerate with `mako dev normalize-preview --ported` if change is intentional."
        )
    }
}
