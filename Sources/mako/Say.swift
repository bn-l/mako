import Foundation
import ArgumentParser
import FluidAudio
import FluidAudioRunner
import FishRunner
import MakoKit
import TTSHarnessCore

extension OutputFormat: ExpressibleByArgument {}

struct Say: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "say",
        abstract: "Synthesize speech from text. Plays via afplay, or writes M4A/WAV when -o is given.",
        discussion: "Kokoro by default: small, fast, always available. `--hq` switches to fish S2 Pro, which sounds markedly better but loads about 7 GB of weights per call and renders at roughly 2.3x realtime. Run `mako hq install` once before the first `--hq`."
    )

    @Argument(help: "Text to synthesize. Use '-' or omit to read from stdin.")
    var text: String?

    @Option(name: [.short, .long], help: "Output path. If omitted, audio is played via afplay and no file is written.")
    var output: String?

    @Option(name: .long, help: "Voice id (see `mako list-voices`).")
    var voice: String = TtsConstants.recommendedVoice

    @Option(name: .long, help: "Output format: auto|wav|m4a. Default: auto.")
    var format: OutputFormat = .auto

    @Flag(name: .long, help: "Suppress the ffmpeg-missing warning.")
    var quiet: Bool = false

    @OptionGroup var fish: FishFlags

    func validate() throws {
        try fish.validate()
    }

    func run() async throws {
        try await performSay(
            textArgument: text, output: output, voice: voice,
            format: format, quiet: quiet,
            engine: fish.chosenEngine, fishOptions: fish.resolvedOptions())
    }
}

/// Shared synthesis entry point used by `mako say` and
/// `mako dev say`. The dev variant sets its environment knobs
/// (`KOKORO_*`) before calling in; everything downstream reads them
/// through `ProcessInfo.processInfo.environment`.
func performSay(
    textArgument: String?,
    output: String?,
    voice: String,
    format: OutputFormat,
    quiet: Bool,
    engine: SpeechEngine = .kokoro,
    fishOptions: FishOptions = FishOptions()
) async throws {
    let sourceText: String
    switch InputSource.decide(argument: textArgument) {
    case .literal(let s): sourceText = s
    case .stdin:
        let data = FileHandle.standardInput.readDataToEndOfFile()
        sourceText = String(data: data, encoding: .utf8) ?? ""
    }
    let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw ValidationError("no input text (pass a string argument or pipe via stdin)")
    }
    // Ensure the utterance ends in sentence-final punctuation so the
    // synth lands on natural trailing silence instead of clipping the
    // last phoneme. Short inputs like `mako say "Hmm"` are the motivating
    // case; already-punctuated input is left alone.
    let sentenceEnders: Set<Character> = [".", "!", "?", "…", ":", ";"]
    let synthText = sentenceEnders.contains(trimmed.last!) ? trimmed : trimmed + "."

    let wavData: Data
    switch engine {
    case .kokoro:
        wavData = try await KokoroFluidAudioRunner(voice: voice).synthesizeData(text: synthText)
    case .fish:
        wavData = try await synthesizeViaFish(
            text: synthText, options: fishOptions, voice: voice, quiet: quiet)
    }

    guard let output else {
        try playViaAfplay(wav: wavData)
        return
    }

    let ffmpegPath = findFFmpeg()
    let plan: OutputPlan
    do {
        plan = try OutputResolver.resolve(
            format: format, requested: output, ffmpegAvailable: ffmpegPath != nil)
    } catch let err as OutputResolverError {
        throw ValidationError(err.description)
    }

    if plan.wantM4A && ffmpegPath == nil {
        throw ValidationError("m4a requested but ffmpeg not found on PATH (install with `brew install ffmpeg`)")
    }
    if !plan.wantM4A && format == .auto && ffmpegPath == nil && !quiet {
        let msg = "mako: ffmpeg not found; writing WAV. Install with `brew install ffmpeg` for M4A.\n"
        FileHandle.standardError.write(Data(msg.utf8))
    }

    let parent = plan.url.deletingLastPathComponent().path
    if !parent.isEmpty {
        try? FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true, attributes: nil)
    }

    if plan.wantM4A, let ffmpegPath {
        try transcodeToM4A(wav: wavData, outURL: plan.url, ffmpegPath: ffmpegPath)
    } else {
        try wavData.write(to: plan.url, options: .atomic)
    }
}

/// The `--hq` path. Fish writes a file rather than returning bytes, so this renders to a
/// temp WAV and rejoins the shared output path — `-o`, `--format`, the ffmpeg transcode
/// and afplay all work exactly as they do for Kokoro.
///
/// The whole passage is rendered before anything plays. Streaming batch by batch would
/// break the cross-batch prosody that made fish worth adding: it feeds each batch's codes
/// back as context, so later batches are shaped by earlier ones.
private func synthesizeViaFish(
    text: String, options: FishOptions, voice: String, quiet: Bool
) async throws -> Data {
    if !quiet && voice != TtsConstants.recommendedVoice {
        warn("--voice selects a Kokoro voice and does nothing with --hq. The high-quality "
             + "voice comes from the bundled reference clip; use --voice-ref to change it.")
    }

    let status = FishSetup.status()
    guard status.uvPath != nil else {
        throw ValidationError(
            "--hq needs `uv` on PATH. Install it with `brew install uv`, then run `mako doctor`.")
    }
    guard status.weightsPresent == true else {
        throw ValidationError(
            "--hq needs the fish weights, which are not downloaded yet. Run `mako hq install` "
            + "once (about 7 GB), then try again.")
    }

    if !quiet {
        // Measured: ~8.2 chars/s of rendering, plus ~20 s to load the weights.
        let seconds = 20 + Double(text.count) / 8.2
        if seconds > 60 {
            warn(String(format: "--hq: about %.0f minutes for %d characters. Nothing plays "
                        + "until the whole passage is rendered.", seconds / 60, text.count))
        }
    }

    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mako-hq-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: tmpURL) }
    var options = options
    options.progress = !quiet
    try await FishRunner(options: options).synthesize(text: text, to: tmpURL)
    return try Data(contentsOf: tmpURL)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("mako: \(message)\n".utf8))
}

func playViaAfplay(wav: Data) throws {
    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mako-\(UUID().uuidString).wav")
    try wav.write(to: tmpURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    process.arguments = [tmpURL.path]
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw PlaybackError.afplayFailed(status: process.terminationStatus)
    }
}

enum PlaybackError: Error, CustomStringConvertible {
    case afplayFailed(status: Int32)

    var description: String {
        switch self {
        case let .afplayFailed(status):
            return "afplay exited \(status)"
        }
    }
}

func transcodeToM4A(wav: Data, outURL: URL, ffmpegPath: String) throws {
        // Write ffmpeg output to a sibling temp file and only replace the
        // destination atomically on success — a crashed/non-zero ffmpeg
        // leaves any existing `outURL` intact.
        let tmpURL = outURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(outURL.lastPathComponent).mako-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-y", "-hide_banner", "-loglevel", "error",
            "-f", "wav", "-i", "pipe:0",
            "-c:a", "aac", "-b:a", "128k",
            tmpURL.path,
        ]
        let stdin = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardError = stderr
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")

        try process.run()
        stdin.fileHandleForWriting.write(wav)
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "(no stderr)"
            throw TranscodeError.ffmpegFailed(status: process.terminationStatus, message: errStr)
        }

    if FileManager.default.fileExists(atPath: outURL.path) {
        _ = try FileManager.default.replaceItemAt(outURL, withItemAt: tmpURL)
    } else {
        try FileManager.default.moveItem(at: tmpURL, to: outURL)
    }
}

enum TranscodeError: Error, CustomStringConvertible {
    case ffmpegFailed(status: Int32, message: String)

    var description: String {
        switch self {
        case let .ffmpegFailed(status, message):
            return "ffmpeg exited \(status): \(message)"
        }
    }
}

/// Probes PATH for `ffmpeg` via `/usr/bin/env which ffmpeg`. No caching —
/// each invocation re-checks, so a fresh install mid-session is picked up.
func findFFmpeg() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["which", "ffmpeg"]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do {
        try process.run()
    } catch {
        return nil
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let path = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return path.isEmpty ? nil : path
}
