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

    // MARK: - `--hq` surface (no synthesis required)

    @Suite("CLI --hq surface")
    struct HQSurfaceTests {

        /// Fish clones in context, so a reference clip without its transcript is not a
        /// degraded clone — it is a differently-voiced one. Cheaper to refuse.
        @Test("--voice-ref without --voice-ref-text is refused")
        func voiceRefNeedsTranscript() throws {
            let r = try CLIEndToEndTests.run(
                ["say", "--hq", "--voice-ref", "/tmp/ref.wav", "hello"])
            #expect(r.status != 0)
            #expect((r.stdout + r.stderr).contains("--voice-ref-text"))
        }

        /// Silently dropping a fish-only option under Kokoro would mean the user hears
        /// something other than what they asked for and has no way to tell.
        @Test("fish-only options without --hq are refused")
        func fishOptionsRequireHQ() throws {
            let r = try CLIEndToEndTests.run(["say", "--preset", "warm", "hello"])
            #expect(r.status != 0)
            #expect((r.stdout + r.stderr).contains("--hq"))
        }

        @Test("--hq and --engine kokoro together are refused")
        func contradictoryEngineIsRefused() throws {
            let r = try CLIEndToEndTests.run(
                ["say", "--hq", "--engine", "kokoro", "hello"])
            #expect(r.status != 0)
        }

        @Test("an unknown preset names the valid ones")
        func unknownPresetIsHelpful() throws {
            let r = try CLIEndToEndTests.run(["say", "--hq", "--preset", "spicy", "hello"])
            #expect(r.status != 0)
            #expect((r.stdout + r.stderr).contains("hot"))
        }

        /// `mako hq` is a verb-only namespace. If it ever gained a text positional,
        /// `mako "some text"` would become ambiguous against the default subcommand.
        @Test("hq takes no text of its own")
        func hqIsVerbOnly() throws {
            let r = try CLIEndToEndTests.run(["hq", "Say this out loud."])
            #expect(r.status != 0)
        }

        /// Must answer from cache and reach no network — see `FishSetup`, which passes
        /// `--offline` precisely so a cold machine cannot be made to provision an
        /// environment just to be told it is not provisioned.
        @Test("doctor answers quickly and reports every dependency")
        func doctorReportsDependencies() throws {
            let started = Date()
            let r = try CLIEndToEndTests.run(["doctor"], timeout: 30)
            #expect(Date().timeIntervalSince(started) < 20)
            let combined = r.stdout + r.stderr
            for expected in ["uv", "sidecar", "voice reference", "weights"] {
                #expect(combined.contains(expected))
            }
        }
    }

    // MARK: - `--hq` synthesis (gated — needs ~7 GB of weights and ~15 GB of RAM)

    /// Both guards are live for anything in here: the sidecar arms its own in-process
    /// oomguard, and mako polls memory in the parent and SIGKILLs the child's process
    /// group. A render started from a test is therefore guarded by construction.
    @Suite("CLI --hq synthesis",
           .enabled(if: ProcessInfo.processInfo.environment["INTEGRATION"] != nil))
    struct HQSynthesisTests {

        @Test("--hq writes a WAV in the bundled voice")
        func hqWritesWav() throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("mako-hq-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let r = try CLIEndToEndTests.run(
                ["say", "--hq", "--format", "wav", "-o", tmp.path,
                 "The report is finished."],
                timeout: 300)
            #expect(r.status == 0, "stderr: \(r.stderr)")
            let size = try FileManager.default
                .attributesOfItem(atPath: tmp.path)[.size] as? Int ?? 0
            // 16-bit mono at 44.1 kHz: at least a second of speech, and not the
            // whole passage's worth, which would mean the text was mis-segmented.
            #expect(size > 88_200)
            #expect(size < 44_100 * 2 * 60)
        }

        /// The kill path is the reason the whole watchdog exists, so it gets exercised
        /// rather than assumed. An absurd floor makes the first poll trip.
        @Test("a watchdog kill fails with a reason, not a bare signal")
        func watchdogKillIsExplained() throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("mako-hq-oom-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: tmp) }
            setenv("MAKO_OOM_FLOOR_MB", "1000000", 1)
            defer { unsetenv("MAKO_OOM_FLOOR_MB") }
            let r = try CLIEndToEndTests.run(
                ["say", "--hq", "--format", "wav", "-o", tmp.path, "The report is finished."],
                timeout: 300)
            #expect(r.status != 0)
            let combined = r.stdout + r.stderr
            #expect(combined.localizedCaseInsensitiveContains("out of memory"))
            #expect(combined.contains("--hq"))
        }

        @Test("--engine kokoro still takes the Kokoro path")
        func kokoroEngineUnaffected() throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("mako-kokoro-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let started = Date()
            let r = try CLIEndToEndTests.run(
                ["say", "--engine", "kokoro", "--format", "wav", "-o", tmp.path,
                 "The report is finished."],
                timeout: 180)
            #expect(r.status == 0, "stderr: \(r.stderr)")
            // Kokoro runs faster than realtime; fish needs ~20 s just to load.
            #expect(Date().timeIntervalSince(started) < 60)
        }
    }
}

/// Anchor class used only for `Bundle(for:)` — Swift Testing suites are
/// structs, so we need a reference type to resolve the test bundle URL.
private final class CLIAnchor {}
