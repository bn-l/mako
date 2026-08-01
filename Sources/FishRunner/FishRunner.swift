import Foundation
import TTSHarnessCore

/// Fish S2 Pro, via an mlx-audio sidecar.
///
/// There is no Swift or CoreML implementation of fish — the model is a dual
/// autoregressive Qwen3-omni stack over the `fish_s1_dac` codec, and porting it to
/// mlx-swift is a project of its own — so this shells out to Python. `uv run --script`
/// provisions its own CPython from the sidecar's `requires-python`, which is why a user
/// never has to install Python.
///
/// The weights are never resident: each call loads ~6.8 GB, peaks near 14.5 GB, and
/// exits. That is the whole reason `--hq` is opt-in and Kokoro remains the default.
public struct FishRunner: Runner {
    public let modelID = "fish-s2-pro"
    /// Fish decodes at 44.1 kHz. Unrelated to the 22.05 kHz reference clip, which
    /// `load_audio` resamples on the way in.
    public let sampleRate = 44100

    private let options: FishOptions

    public init(options: FishOptions = .fromEnvironment()) {
        self.options = options
    }

    public func synthesize(text: String, to outputURL: URL) async throws {
        guard let uv = Sidecar.locate("uv") else {
            throw RunnerError.missingResource(
                "`uv` is not on PATH — install it with `brew install uv`, then run `mako doctor`")
        }
        let script = try FishResources.sidecarScriptURL()
        let referenceAudio = try resolve(
            options.referenceAudio, fallback: FishResources.referenceAudioURL)
        let referenceTranscript = try resolve(
            options.referenceTranscript, fallback: FishResources.referenceTranscriptURL)

        let prepared = FishText.prepare(
            text, keepMarkers: options.keepMarkers, normalize: options.normalize,
            maxTurnBytes: options.chunkLength)
        // `mako say --hq "[laughing]"` strips down to bare punctuation, which is 20 s of
        // model loading to synthesize nothing.
        guard prepared.contains(where: { $0.isLetter || $0.isNumber }) else {
            throw RunnerError.decodeFailure(
                "there is nothing to say once the markers are removed")
        }

        let arguments = ["run", "--script", script.path]
            + options.sidecarArguments(outputURL: outputURL,
                                       referenceAudio: referenceAudio,
                                       referenceTranscript: referenceTranscript)

        let watchdog = MemoryWatchdog()
        let killReason = KillReason()
        let forward: @Sendable (Data) -> Void = { FileHandle.standardError.write($0) }
        let stderrSink: (@Sendable (Data) -> Void)? = options.progress ? forward : nil
        let result = try await withCheckedThrowingContinuation { continuation in
            // Blocking pipe I/O and waitpid, kept off the cooperative pool.
            DispatchQueue.global().async {
                do {
                    let result = try Sidecar.run(
                        executable: uv,
                        arguments: arguments,
                        environment: ProcessInfo.processInfo.environment,
                        input: Data(prepared.utf8),
                        stderrSink: stderrSink,
                        onSpawn: { pgid in
                            guard !MemoryWatchdog.isDisabled else { return }
                            Task {
                                await watchdog.start { reason in
                                    killReason.set(reason)
                                    kill(-pgid, SIGKILL)
                                }
                            }
                        })
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        await watchdog.stop()

        let stderr = String(decoding: result.standardError, as: UTF8.self)
        guard result.exitCode == 0 else {
            throw RunnerError.subprocessFailed(
                exitCode: result.exitCode,
                stderr: explain(result: result, stderr: stderr, reason: killReason.value))
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw RunnerError.decodeFailure(
                "the sidecar reported success but wrote no audio\n\(tail(of: stderr))")
        }
    }

    private func resolve(_ override: URL?, fallback: () throws -> URL) throws -> URL {
        guard let override else { return try fallback() }
        guard FileManager.default.fileExists(atPath: override.path) else {
            throw RunnerError.missingResource("reference file not found: \(override.path)")
        }
        return override
    }

    /// Turns a dead child into something worth reading.
    ///
    /// The common failure is a memory kill, and it usually comes from the sidecar's own
    /// guard rather than mako's — the sidecar's floor is higher, so it trips first and
    /// this process only ever sees a signal death. Its reason is on stderr, and reporting
    /// "killed by signal 9" instead would throw away the one line that explains anything.
    private func explain(result: SidecarResult, stderr: String, reason: String?) -> String {
        if let reason {
            return "out of memory: \(reason). Retry without --hq, or free some memory first."
        }
        if let trigger = stderr.split(separator: "\n", omittingEmptySubsequences: true)
            .last(where: { $0.contains("[oomguard] !!! TRIGGER:") }) {
            let detail = trigger
                .replacingOccurrences(of: "[oomguard] !!! TRIGGER: ", with: "")
                .replacingOccurrences(of: " -> SIGKILL self", with: "")
            return "out of memory: \(detail). Retry without --hq, or free some memory first."
        }
        if result.signaled {
            return "the sidecar was killed by signal \(result.exitCode - 128)\n\(tail(of: stderr))"
        }
        return tail(of: stderr)
    }
}

/// Progress logging makes the full stderr long and mostly uninteresting; the end of it
/// is where the traceback lives.
private func tail(of text: String, lines: Int = 20) -> String {
    let all = text.split(separator: "\n", omittingEmptySubsequences: false)
    return all.suffix(lines).joined(separator: "\n")
}

/// Set from the watchdog's callback, read after the child is reaped.
private final class KillReason: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? { lock.withLock { stored } }
    func set(_ reason: String) { lock.withLock { stored = reason } }
}
