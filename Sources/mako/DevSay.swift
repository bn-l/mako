import Foundation
import ArgumentParser
import FluidAudio
import MakoKit

/// `mako dev say` — the `say` path with the knobs that alter the
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

    @Option(name: [.short, .long], help: "Output path. If omitted, audio is played via afplay and no file is written.")
    var output: String?

    @Option(name: .long, help: "Voice id (see `mako list-voices`).")
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

    @OptionGroup var fish: FishFlags

    @Option(name: .long, help: "--hq: max bytes of text per internal batch (MAKO_FISH_CHUNK_LENGTH).")
    var chunkLength: Int?

    @Option(name: .long, help: "--hq: max codec tokens per batch; sizes the KV cache (MAKO_FISH_MAX_TOKENS).")
    var maxTokens: Int?

    @Option(name: .long, help: "--hq: mean silence between batches, seconds (MAKO_FISH_GAP_MEAN).")
    var gapMean: Double?

    @Option(name: .long, help: "--hq: standard deviation of that silence (MAKO_FISH_GAP_SD).")
    var gapSd: Double?

    @Option(name: .long, help: "--hq: fade at each batch seam, milliseconds (MAKO_FISH_FADE_MS).")
    var fadeMs: Double?

    @Option(name: .long, help: "--hq: sampling temperature, overriding the preset (MAKO_FISH_TEMPERATURE).")
    var temperature: Double?

    @Option(name: .long, help: "--hq: nucleus sampling cutoff, overriding the preset (MAKO_FISH_TOP_P).")
    var topP: Double?

    @Option(name: .long, help: "--hq: top-k cutoff, overriding the preset (MAKO_FISH_TOP_K).")
    var topK: Int?

    func validate() throws {
        try fish.validate()
    }

    func run() async throws {
        if g2p == .classic { setenv("KOKORO_G2P", "classic", 1) }
        if rawText { setenv("KOKORO_RAW_TEXT", "1", 1) }
        if let speed { setenv("KOKORO_SPEED", String(speed), 1) }
        if previewSsml { setenv("KOKORO_PREVIEW_SSML", "1", 1) }
        if trace { setenv("KOKORO_G2P_TRACE", "1", 1) }

        // Same shape as the KOKORO_* knobs above: the flag sets the env var, and
        // FishOptions.fromEnvironment picks it up, so scripts can use either form.
        if let chunkLength { setenv("MAKO_FISH_CHUNK_LENGTH", String(chunkLength), 1) }
        if let maxTokens { setenv("MAKO_FISH_MAX_TOKENS", String(maxTokens), 1) }
        if let gapMean { setenv("MAKO_FISH_GAP_MEAN", String(gapMean), 1) }
        if let gapSd { setenv("MAKO_FISH_GAP_SD", String(gapSd), 1) }
        if let fadeMs { setenv("MAKO_FISH_FADE_MS", String(fadeMs), 1) }
        if let temperature { setenv("MAKO_FISH_TEMPERATURE", String(temperature), 1) }
        if let topP { setenv("MAKO_FISH_TOP_P", String(topP), 1) }
        if let topK { setenv("MAKO_FISH_TOP_K", String(topK), 1) }

        try await performSay(
            textArgument: text, output: output, voice: voice,
            format: format, quiet: quiet,
            engine: fish.chosenEngine, fishOptions: fish.resolvedOptions())
    }
}
