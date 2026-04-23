import Foundation
import ArgumentParser
import FluidAudio
import FluidAudioRunner
import MakoKit

extension OutputFormat: ExpressibleByArgument {}

struct Say: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "say",
        abstract: "Synthesize speech from text via Kokoro. Writes M4A if ffmpeg is installed, else WAV."
    )

    @Argument(help: "Text to synthesize. Use '-' or omit to read from stdin.")
    var text: String?

    @Option(name: [.short, .long], help: "Output path. Default: out.m4a (with ffmpeg) or out.wav.")
    var output: String?

    @Option(name: .long, help: "Voice id (see `mako list-voices`).")
    var voice: String = TtsConstants.recommendedVoice

    @Option(name: .long, help: "Output format: auto|wav|m4a. Default: auto.")
    var format: OutputFormat = .auto

    @Flag(name: .long, help: "Suppress the ffmpeg-missing warning.")
    var quiet: Bool = false

    func run() async throws {
        try await performSay(
            textArgument: text, output: output, voice: voice,
            format: format, quiet: quiet)
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
    quiet: Bool
) async throws {
    let sourceText: String
    switch InputSource.decide(argument: textArgument) {
    case .literal(let s): sourceText = s
    case .stdin:
        let data = FileHandle.standardInput.readDataToEndOfFile()
        sourceText = String(data: data, encoding: .utf8) ?? ""
    }
    guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ValidationError("no input text (pass a string argument or pipe via stdin)")
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

    let runner = KokoroFluidAudioRunner(voice: voice)
    let wavData = try await runner.synthesizeData(text: sourceText)

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
