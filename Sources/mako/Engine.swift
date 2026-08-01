import Foundation
import ArgumentParser
import FishRunner

/// Which synthesis engine `say` should use.
///
/// Kokoro is the default and stays that way: 82M parameters, a second of cold start,
/// faster than realtime. Fish sounds substantially better and costs about 14.5 GB of
/// peak memory and 2.3x realtime, so it is something you ask for.
enum SpeechEngine: String, CaseIterable, ExpressibleByArgument {
    case kokoro
    case fish
}

/// The `--hq` options shared by `say` and `dev say`.
///
/// Every field is optional so that "the user did not mention this" stays distinguishable
/// from "the user asked for the default" — which is what makes it possible to reject
/// `--preset warm` without `--hq` instead of silently dropping it.
struct FishFlags: ParsableArguments {
    @Flag(name: .long, help: "Use the high-quality engine (fish S2 Pro). Slower, and needs about 15 GB of free memory.")
    var hq: Bool = false

    @Option(name: .long, help: "Engine: kokoro|fish. `--hq` is shorthand for `--engine fish`.")
    var engine: SpeechEngine?

    @Option(name: .long, help: "Reference clip to clone the --hq voice from. Requires --voice-ref-text.")
    var voiceRef: String?

    @Option(name: .long, help: "File holding the reference clip's exact transcript.")
    var voiceRefText: String?

    @Option(name: .long, help: "--hq sampling preset: \(FishOptions.presets.joined(separator: "|")). Default: hot.")
    var preset: String?

    @Flag(name: .long, inversion: .prefixedNo,
          help: "Keep inline [tag] markers for the --hq engine instead of stripping them. Unrecognised tags get read aloud, so this is for text written against the marker register.")
    var markers: Bool?

    @Flag(name: .long, inversion: .prefixedNo,
          help: "Run mako's number/abbreviation normalizer before --hq synthesis. Off by default: fish reads \"$1,234.56\" and \"7:03 a.m.\" natively, and every render validated during the bakeoff went in as raw text.")
    var normalize: Bool?

    @Option(name: .long, help: "--hq sampling seed. Default: 11.")
    var seed: Int?

    var chosenEngine: SpeechEngine {
        if let engine { return engine }
        return hq ? .fish : .kokoro
    }

    /// Set on any of the fish-only options, whether or not `--hq` was given.
    private var mentionsFish: Bool {
        voiceRef != nil || voiceRefText != nil || preset != nil || markers != nil
            || normalize != nil || seed != nil
    }

    func validate() throws {
        if let engine, engine == .kokoro, hq {
            throw ValidationError("--hq and --engine kokoro contradict each other")
        }
        if chosenEngine == .kokoro && mentionsFish {
            throw ValidationError(
                "--voice-ref/--voice-ref-text/--preset/--markers/--seed only apply to the high-quality engine; add --hq")
        }
        if (voiceRef == nil) != (voiceRefText == nil) {
            throw ValidationError(
                "--voice-ref and --voice-ref-text go together — fish clones in context, so it needs the clip's exact transcript alongside the audio")
        }
        if let preset, !FishOptions.presets.contains(preset) {
            throw ValidationError(
                "unknown preset \"\(preset)\" (choose from: \(FishOptions.presets.joined(separator: ", ")))")
        }
    }

    /// Layers the flags over whatever `MAKO_FISH_*` already said.
    func resolvedOptions() -> FishOptions {
        var options = FishOptions.fromEnvironment()
        if let preset { options.preset = preset }
        if let markers { options.keepMarkers = markers }
        if let normalize { options.normalize = normalize }
        if let seed { options.seed = seed }
        if let voiceRef { options.referenceAudio = URL(fileURLWithPath: voiceRef) }
        if let voiceRefText { options.referenceTranscript = URL(fileURLWithPath: voiceRefText) }
        return options
    }
}
