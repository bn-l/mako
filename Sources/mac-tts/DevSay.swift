import Foundation
import ArgumentParser
import FluidAudio
import MacTTSKit

/// `mac-tts dev say` — the `say` path with the knobs that alter the
/// normalizer / runner wiring exposed as explicit flags. Each flag maps
/// onto the `KOKORO_*` env var the runner and normalizer already
/// consume, so scripts can keep using the env form if they prefer.
struct DevSay: AsyncParsableCommand {
    enum G2PMode: String, Sendable, CaseIterable, ExpressibleByArgument {
        case ported, classic
    }

    static let configuration = CommandConfiguration(
        commandName: "say",
        abstract: "Synthesize speech with the ported-G2P / tracing knobs exposed as flags."
    )

    @Argument(help: "Text to synthesize. Use '-' or omit to read from stdin.")
    var text: String?

    @Option(name: [.short, .long], help: "Output path. Default: out.m4a (with ffmpeg) or out.wav.")
    var output: String?

    @Option(name: .long, help: "Voice id (see `mac-tts list-voices`).")
    var voice: String = TtsConstants.recommendedVoice

    @Option(name: .long, help: "Output format: auto|wav|m4a.")
    var format: OutputFormat = .auto

    @Flag(name: .long, help: "Suppress the ffmpeg-missing warning.")
    var quiet: Bool = false

    @Option(
        name: .long,
        help: "G2P pipeline: `ported` (default) or `classic` (legacy normalizer)."
    )
    var g2p: G2PMode = .ported

    @Flag(name: .long, help: "Skip normalization entirely (KOKORO_RAW_TEXT).")
    var rawText: Bool = false

    @Option(name: .long, help: "Playback-speed multiplier passed to Kokoro (KOKORO_SPEED).")
    var speed: Double?

    @Flag(name: .long, help: "Dump the emitted SSML to stderr before synthesis (KOKORO_PREVIEW_SSML).")
    var previewSsml: Bool = false

    @Flag(name: .long, help: "Emit the full per-chunk trace + provenance summary (KOKORO_G2P_TRACE).")
    var trace: Bool = false

    func run() async throws {
        if g2p == .classic { setenv("KOKORO_G2P", "classic", 1) }
        if rawText { setenv("KOKORO_RAW_TEXT", "1", 1) }
        if let speed { setenv("KOKORO_SPEED", String(speed), 1) }
        if previewSsml { setenv("KOKORO_PREVIEW_SSML", "1", 1) }
        if trace { setenv("KOKORO_G2P_TRACE", "1", 1) }

        try await performSay(
            textArgument: text, output: output, voice: voice,
            format: format, quiet: quiet)
    }
}
