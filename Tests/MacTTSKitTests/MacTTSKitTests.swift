import Foundation
import Testing
@testable import MacTTSKit

@Suite("OutputResolver")
struct OutputResolverTests {

    // MARK: - No -o: default filename derived from format + ffmpeg probe

    @Test("Default: ffmpeg available + auto → out.m4a")
    func defaultAutoWithFFmpeg() throws {
        let plan = try OutputResolver.resolve(format: .auto, requested: nil, ffmpegAvailable: true)
        #expect(plan.url.lastPathComponent == "out.m4a")
        #expect(plan.wantM4A)
    }

    @Test("Default: ffmpeg missing + auto → out.wav")
    func defaultAutoWithoutFFmpeg() throws {
        let plan = try OutputResolver.resolve(format: .auto, requested: nil, ffmpegAvailable: false)
        #expect(plan.url.lastPathComponent == "out.wav")
        #expect(!plan.wantM4A)
    }

    @Test("Default: --format wav → out.wav regardless of ffmpeg")
    func defaultExplicitWav() throws {
        let withFF = try OutputResolver.resolve(format: .wav, requested: nil, ffmpegAvailable: true)
        let noFF = try OutputResolver.resolve(format: .wav, requested: nil, ffmpegAvailable: false)
        #expect(withFF.url.lastPathComponent == "out.wav")
        #expect(noFF.url.lastPathComponent == "out.wav")
        #expect(!withFF.wantM4A && !noFF.wantM4A)
    }

    @Test("Default: --format m4a → out.m4a even if ffmpeg missing (Say validates later)")
    func defaultExplicitM4A() throws {
        let plan = try OutputResolver.resolve(format: .m4a, requested: nil, ffmpegAvailable: false)
        #expect(plan.url.lastPathComponent == "out.m4a")
        #expect(plan.wantM4A)
    }

    // MARK: - `-o` with recognised extension wins over --format

    @Test("-o speech.m4a + --format auto → m4a")
    func outputM4AExtAuto() throws {
        let plan = try OutputResolver.resolve(format: .auto, requested: "speech.m4a", ffmpegAvailable: true)
        #expect(plan.url.path.hasSuffix("speech.m4a"))
        #expect(plan.wantM4A)
    }

    @Test("-o speech.wav + --format auto → wav (even with ffmpeg)")
    func outputWavExtAutoWithFFmpeg() throws {
        let plan = try OutputResolver.resolve(format: .auto, requested: "speech.wav", ffmpegAvailable: true)
        #expect(plan.url.path.hasSuffix("speech.wav"))
        #expect(!plan.wantM4A)
    }

    @Test("-o speech.M4A (case-insensitive) → m4a")
    func outputExtensionCaseInsensitive() throws {
        let plan = try OutputResolver.resolve(format: .auto, requested: "speech.M4A", ffmpegAvailable: false)
        #expect(plan.wantM4A)
    }

    @Test("-o speech.wav + --format wav (matching) → wav")
    func outputExtMatchesFormat() throws {
        let plan = try OutputResolver.resolve(format: .wav, requested: "speech.wav", ffmpegAvailable: true)
        #expect(!plan.wantM4A)
    }

    // MARK: - Hard error on -o/--format mismatch

    @Test("-o speech.wav + --format m4a → error")
    func outputExtFormatConflictWavM4A() {
        #expect(throws: OutputResolverError.self) {
            _ = try OutputResolver.resolve(format: .m4a, requested: "speech.wav", ffmpegAvailable: true)
        }
    }

    @Test("-o speech.m4a + --format wav → error")
    func outputExtFormatConflictM4AWav() {
        #expect(throws: OutputResolverError.self) {
            _ = try OutputResolver.resolve(format: .wav, requested: "speech.m4a", ffmpegAvailable: true)
        }
    }

    @Test("Conflict error message includes both the extension and the format")
    func conflictMessageShape() {
        do {
            _ = try OutputResolver.resolve(format: .m4a, requested: "speech.wav", ffmpegAvailable: true)
            Issue.record("expected throw")
        } catch let err as OutputResolverError {
            let msg = err.description
            #expect(msg.contains(".wav"))
            #expect(msg.contains("m4a"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    // MARK: - `-o` with unrecognised / missing extension falls back to --format

    @Test("-o out.bin + --format auto + ffmpeg → m4a container at given path")
    func unrecognisedExtAutoWithFFmpeg() throws {
        let plan = try OutputResolver.resolve(format: .auto, requested: "out.bin", ffmpegAvailable: true)
        #expect(plan.url.path.hasSuffix("out.bin"))
        #expect(plan.wantM4A)
    }

    @Test("-o out.bin + --format auto + no ffmpeg → wav container at given path")
    func unrecognisedExtAutoNoFFmpeg() throws {
        let plan = try OutputResolver.resolve(format: .auto, requested: "out.bin", ffmpegAvailable: false)
        #expect(plan.url.path.hasSuffix("out.bin"))
        #expect(!plan.wantM4A)
    }

    @Test("-o noext + --format wav → wav")
    func noExtensionExplicitFormat() throws {
        let plan = try OutputResolver.resolve(format: .wav, requested: "noext", ffmpegAvailable: true)
        #expect(plan.url.lastPathComponent == "noext")
        #expect(!plan.wantM4A)
    }

    @Test("-o relative path preserved")
    func relativePathPreserved() throws {
        let plan = try OutputResolver.resolve(
            format: .auto, requested: "out/nested/audio.wav", ffmpegAvailable: true)
        #expect(plan.url.path.hasSuffix("out/nested/audio.wav"))
        #expect(!plan.wantM4A)
    }

    @Test("-o absolute path preserved")
    func absolutePathPreserved() throws {
        let plan = try OutputResolver.resolve(
            format: .auto, requested: "/tmp/mac-tts-resolver/sample.m4a", ffmpegAvailable: true)
        #expect(plan.url.path == "/tmp/mac-tts-resolver/sample.m4a")
        #expect(plan.wantM4A)
    }
}

@Suite("InputSource")
struct InputSourceTests {

    @Test("nil argument → stdin")
    func nilIsStdin() {
        #expect(InputSource.decide(argument: nil) == .stdin)
    }

    @Test("'-' argument → stdin")
    func dashIsStdin() {
        #expect(InputSource.decide(argument: "-") == .stdin)
    }

    @Test("non-empty argument → literal")
    func literalArg() {
        #expect(InputSource.decide(argument: "hello world") == .literal("hello world"))
    }

    @Test("empty string argument → literal empty string (stdin reserved for nil/-)")
    func emptyStringIsLiteral() {
        // The emptiness check is Say's job, not InputSource's.
        #expect(InputSource.decide(argument: "") == .literal(""))
    }

    @Test("Multi-word arg is kept verbatim")
    func multiWordLiteral() {
        #expect(InputSource.decide(argument: "foo bar -baz") == .literal("foo bar -baz"))
    }
}
