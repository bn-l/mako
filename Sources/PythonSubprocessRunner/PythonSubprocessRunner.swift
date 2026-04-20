import Foundation
import TTSHarnessCore

public enum PythonRunnerScript: String, Sendable {
    case mlxAudio = "mlx_audio_runner"
    case mlxSpeech = "mlx_speech_runner"
}

public struct PythonSubprocessRunner: Runner {
    public let modelID: String
    public let sampleRate: Int
    public let script: PythonRunnerScript
    public let hfRepo: String
    public let voice: String?
    public let projectRoot: URL

    public init(
        modelID: String,
        sampleRate: Int,
        script: PythonRunnerScript,
        hfRepo: String,
        voice: String? = nil,
        projectRoot: URL? = nil
    ) {
        self.modelID = modelID
        self.sampleRate = sampleRate
        self.script = script
        self.hfRepo = hfRepo
        self.voice = voice
        self.projectRoot = projectRoot ?? Self.findProjectRoot()
    }

    public func synthesize(text: String, to outputURL: URL) async throws {
        let pythonDir = projectRoot.appendingPathComponent("python")
        let module = "mac_tts_python.runners.\(script.rawValue)"
        var args = [
            "run",
            "python",
            "-m", module,
            "--model", hfRepo,
            "--text", text,
            "--output", outputURL.path,
        ]
        if let voice {
            args.append(contentsOf: ["--voice", voice])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["uv"] + args
        process.currentDirectoryURL = pythonDir

        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.standardOutput

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            throw RunnerError.subprocessFailed(
                exitCode: process.terminationStatus,
                stderr: errText
            )
        }
    }

    static func findProjectRoot() -> URL {
        var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
