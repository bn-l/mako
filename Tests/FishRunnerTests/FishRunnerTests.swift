import Foundation
import Testing
@testable import FishRunner

/// Unit tests for the parts of the fish runner that do not need a 7 GB model: how
/// options turn into a sidecar command line, and how the environment feeds them.
///
/// Argument construction is worth pinning because the sidecar's own defaults are the
/// *lab* defaults, not the production ones. `gen_fish.py` chunks at 150 bytes and allows
/// 1536 tokens; the settings the production voice was validated against are 400 and 900.
/// Passing them explicitly on every call is what keeps the two from drifting apart.
@Suite("FishOptions")
struct FishOptionsTests {
    private let out = URL(fileURLWithPath: "/tmp/out.wav")
    private let wav = URL(fileURLWithPath: "/voice/ref.wav")
    private let transcript = URL(fileURLWithPath: "/voice/ref.txt")

    private func arguments(_ options: FishOptions) -> [String] {
        options.sidecarArguments(outputURL: out, referenceAudio: wav,
                                 referenceTranscript: transcript)
    }

    private func value(of flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    @Test("the validated production settings are passed explicitly")
    func passesProductionDefaults() {
        let args = arguments(FishOptions())
        #expect(value(of: "--chunk-length", in: args) == "400")
        #expect(value(of: "--max-tokens", in: args) == "900")
        #expect(value(of: "--preset", in: args) == "hot")
        #expect(value(of: "--seed", in: args) == "11")
        #expect(value(of: "--mlx-cache-mb", in: args) == "512")
    }

    @Test("the reference pair and destination are passed as paths")
    func passesPaths() {
        let args = arguments(FishOptions())
        #expect(value(of: "--out", in: args) == "/tmp/out.wav")
        #expect(value(of: "--ref-wav", in: args) == "/voice/ref.wav")
        #expect(value(of: "--ref-text", in: args) == "/voice/ref.txt")
    }

    /// The preset supplies temperature/top-p/top-k, so an unset override must not appear
    /// at all — passing a default would silently overrule whichever preset was chosen.
    @Test("unset sampling overrides are omitted entirely")
    func omitsUnsetOverrides() {
        let args = arguments(FishOptions())
        #expect(!args.contains("--temperature"))
        #expect(!args.contains("--top-p"))
        #expect(!args.contains("--top-k"))
    }

    @Test("set sampling overrides are passed through")
    func passesSetOverrides() {
        var options = FishOptions()
        options.temperature = 0.85
        options.topK = 40
        let args = arguments(options)
        #expect(value(of: "--temperature", in: args) == "0.85")
        #expect(value(of: "--top-k", in: args) == "40")
        #expect(!args.contains("--top-p"))
    }

    /// Text preparation happens in Swift, so neither of these is a sidecar argument.
    @Test("marker and normalization choices stay on the Swift side")
    func textChoicesAreNotSidecarArguments() {
        var options = FishOptions()
        options.keepMarkers = true
        options.normalize = true
        let args = arguments(options)
        #expect(!args.contains { $0.contains("marker") })
        #expect(!args.contains { $0.contains("normalize") })
    }

    @Test("the default is the bundled voice, not an override")
    func defaultsToTheBundledVoice() {
        let options = FishOptions()
        #expect(options.referenceAudio == nil)
        #expect(options.referenceTranscript == nil)
    }

    /// Off by default: fish reads `$1,234.56` natively, and every render judged during
    /// the bakeoff went in as raw text.
    @Test("normalization and markers are both off by default")
    func conservativeTextDefaults() {
        #expect(FishOptions().normalize == false)
        #expect(FishOptions().keepMarkers == false)
    }
}
