import Foundation
import Testing

/// End-to-end tests for the `mako` binary. Hermetic by construction —
/// every case forces `--format wav` so no ffmpeg transcode runs. The
/// FluidAudio Kokoro synthesis itself is gated behind `INTEGRATION=1`
/// because it requires a one-time model download; the argument-parsing
/// + output-writing surface still runs in the default case via
/// `list-voices` and `--help`.
///
/// The binary path is resolved from `CommandLine.arguments[0]` — SwiftPM
/// places `mako` 4 directories above the xctest runner. The test
/// target's dependency on `MakoCLI` guarantees the binary exists
/// whenever tests run.
@Suite("CLI end-to-end")
struct CLIEndToEndTests {

    /// Locate the built `mako` binary. The xctest runner is spawned
    /// by the system toolchain (so `CommandLine.arguments[0]` points
    /// into Xcode's usr/bin), but the test bundle itself sits at
    /// `.../<config>/<Pkg>PackageTests.xctest/` — walking up from
    /// `Bundle(for: anchor).bundleURL` gives us the config dir where
    /// SwiftPM also emits the `mako` executable.
    static func binaryURL() -> URL {
        let bundleURL = Bundle(for: CLIAnchor.self).bundleURL
        let configDir = bundleURL.deletingLastPathComponent()
        return configDir.appendingPathComponent("mako")
    }

    struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func run(
        _ args: [String],
        stdin: String? = nil,
        timeout: TimeInterval = 30
    ) throws -> RunResult {
        let binary = binaryURL()
        try #require(
            FileManager.default.isExecutableFile(atPath: binary.path),
            "mako binary not found at \(binary.path) — ensure MakoCLI is built"
        )
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        if stdin != nil { process.standardInput = Pipe() }

        try process.run()
        if let stdin, let pipe = process.standardInput as? Pipe {
            pipe.fileHandleForWriting.write(Data(stdin.utf8))
            try pipe.fileHandleForWriting.close()
        }

        // Basic timeout guard: spin the runloop until exit or deadline.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            process.terminate()
            Issue.record("process timed out after \(timeout)s: mako \(args.joined(separator: " "))")
        }

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        return RunResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    // MARK: - Surface checks (no synthesis required)

    @Test("--help exits 0 and mentions subcommands")
    func helpExitsZero() throws {
        let r = try Self.run(["--help"])
        #expect(r.status == 0)
        let combined = r.stdout + r.stderr
        #expect(combined.contains("say"))
        #expect(combined.contains("list-voices"))
        #expect(combined.contains("dev"))
    }

    @Test("list-voices prints af_heart with the (default) marker")
    func listVoicesDefaultMarker() throws {
        let r = try Self.run(["list-voices"])
        #expect(r.status == 0)
        #expect(r.stdout.contains("af_heart"))
        #expect(r.stdout.contains("(default)"))
    }

    @Test("list-voices prints one voice per line")
    func listVoicesPerLine() throws {
        let r = try Self.run(["list-voices"])
        #expect(r.status == 0)
        let lines = r.stdout.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count > 1)
        for line in lines {
            #expect(line.contains("_"), "voice id expected per line, got: \(line)")
        }
    }

    @Test("say without text and no stdin exits non-zero")
    func sayWithoutInputErrors() throws {
        // Pipe empty stdin so say sees zero bytes and emits the validation error.
        let r = try Self.run(["say"], stdin: "")
        #expect(r.status != 0)
        let combined = r.stdout + r.stderr
        #expect(combined.localizedCaseInsensitiveContains("no input"))
    }

    @Test("say --format m4a + -o .wav errors out")
    func sayOutputConflictErrors() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mako-cli-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = try Self.run(["say", "hello", "--format", "m4a", "-o", tmp.path])
        #expect(r.status != 0)
        let combined = r.stdout + r.stderr
        #expect(combined.localizedCaseInsensitiveContains("conflict"))
    }

    // MARK: - Full synthesis (gated — requires FluidAudio model download)

    @Suite("CLI synthesis",
           .enabled(if: ProcessInfo.processInfo.environment["INTEGRATION"] != nil))
    struct SynthesisTests {

        @Test("say writes a WAV file for a positional argument")
        func sayWritesWavFromArg() throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("mako-cli-arg-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let r = try CLIEndToEndTests.run(
                ["say", "Hello there.", "--format", "wav", "-o", tmp.path],
                timeout: 180
            )
            #expect(r.status == 0, "stderr: \(r.stderr)")
            #expect(FileManager.default.fileExists(atPath: tmp.path))
            let size = try FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int ?? 0
            #expect(size > 44, "wav should have a payload beyond the header")
        }

        @Test("say reads from stdin when no argument is given")
        func sayReadsFromStdin() throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("mako-cli-stdin-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let r = try CLIEndToEndTests.run(
                ["say", "--format", "wav", "-o", tmp.path],
                stdin: "One sentence from standard input.",
                timeout: 180
            )
            #expect(r.status == 0, "stderr: \(r.stderr)")
            #expect(FileManager.default.fileExists(atPath: tmp.path))
        }

        @Test("say '-' reads from stdin")
        func sayDashReadsFromStdin() throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("mako-cli-dash-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let r = try CLIEndToEndTests.run(
                ["say", "-", "--format", "wav", "-o", tmp.path],
                stdin: "Dash means stdin.",
                timeout: 180
            )
            #expect(r.status == 0, "stderr: \(r.stderr)")
            #expect(FileManager.default.fileExists(atPath: tmp.path))
        }
    }
}

/// Anchor class used only for `Bundle(for:)` — Swift Testing suites are
/// structs, so we need a reference type to resolve the test bundle URL.
private final class CLIAnchor {}
