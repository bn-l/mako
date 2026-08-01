import Foundation
import TTSHarnessCore

/// Provisioning for the fish engine — what `mako hq install` and `mako doctor` drive.
///
/// Both go through the sidecar rather than reimplementing anything in Swift, so the
/// Hugging Face cache is resolved by `huggingface_hub` itself and `HF_HOME` /
/// `HF_HUB_CACHE` are honoured instead of guessed at.
public enum FishSetup {
    public struct Status: Sendable {
        public let uvPath: String?
        public let scriptPath: String?
        public let referenceAudioPath: String?
        public let referenceTranscriptPath: String?
        public let weightsPresent: Bool?

        public var isReady: Bool {
            uvPath != nil && scriptPath != nil && referenceAudioPath != nil
                && referenceTranscriptPath != nil && weightsPresent == true
        }
    }

    public static func status() -> Status {
        let uv = Sidecar.locate("uv")
        let script = try? FishResources.sidecarScriptURL()
        return Status(
            uvPath: uv,
            scriptPath: script?.path,
            referenceAudioPath: (try? FishResources.referenceAudioURL())?.path,
            referenceTranscriptPath: (try? FishResources.referenceTranscriptURL())?.path,
            // `--check` also proves the uv script environment resolves, which is the
            // other half of "is --hq ready" and the slow half on a cold cache.
            weightsPresent: (uv != nil && script != nil) ? weightsPresent(uv: uv!, script: script!) : nil)
    }

    /// Downloads the weights (~7 GB) and warms the uv script environment, streaming the
    /// progress bars straight through to the terminal.
    public static func install() throws {
        guard let uv = Sidecar.locate("uv") else {
            throw RunnerError.missingResource(
                "`uv` is not on PATH — install it with `brew install uv`")
        }
        let script = try FishResources.sidecarScriptURL()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uv)
        process.arguments = ["run", "--script", script.path, "--prefetch"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RunnerError.subprocessFailed(
                exitCode: process.terminationStatus,
                stderr: "weight download failed; see the output above")
        }
    }

    private static func weightsPresent(uv: String, script: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uv)
        // `--offline` matters more than it looks. Without it, a machine that has never
        // run `mako hq install` would have uv silently build the whole script
        // environment — a managed CPython plus mlx-audio, hundreds of megabytes — just to
        // be told the weights are missing. And this call discards stderr, so the user
        // would watch `mako doctor` hang with no explanation. Offline, an unbuilt
        // environment simply fails, which is the honest answer: not ready.
        process.arguments = ["run", "--offline", "--script", script.path, "--check"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["weights"] as? Bool ?? false
    }
}
