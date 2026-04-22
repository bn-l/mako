import AVFoundation
import Foundation
import Testing
@testable import TTSHarnessCore

@Suite("ModelRegistry")
struct ModelRegistryTests {

    @Test("Registry contains expected ids")
    func contents() {
        let ids = Set(ModelRegistry.all.map(\.id))
        #expect(ids.contains("kokoro-fluidaudio"))
        #expect(ids.contains("cosyvoice3-mlx-4bit"))
        #expect(ids.contains("qwen3-tts-coreml-06b"))
    }

    @Test("Every entry has non-empty id, hfRepo, and a backend")
    func entryIntegrity() {
        for entry in ModelRegistry.all {
            #expect(!entry.id.isEmpty)
            #expect(!entry.hfRepo.isEmpty)
            #expect(Backend.allCases.contains(entry.backend))
        }
    }

    @Test("Ids are unique")
    func idsUnique() {
        let ids = ModelRegistry.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("find(id:) returns the matching entry")
    func findHit() throws {
        let hit = try #require(ModelRegistry.find(id: "kokoro-fluidaudio"))
        #expect(hit.backend == .fluidAudio)
        #expect(hit.defaultVoice == "af_heart")
    }

    @Test("find(id:) returns nil for unknown ids")
    func findMiss() {
        #expect(ModelRegistry.find(id: "no-such-model") == nil)
    }
}

@Suite("Passage")
struct PassageTests {

    @Test(arguments: Passage.bundledNames)
    func bundledPassageLoadsNonEmpty(name: String) throws {
        let text = try Passage.load(name)
        #expect(!text.isEmpty, "\(name) should load non-empty")
        // `load` trims surrounding whitespace — the result must not re-introduce it.
        #expect(text.first.map { !$0.isWhitespace } ?? false)
        #expect(text.last.map { !$0.isWhitespace } ?? false)
    }

    @Test("default name loads")
    func defaultLoads() throws {
        let text = try Passage.load(nil)
        #expect(!text.isEmpty)
    }

    @Test("reflexology-class is gone from bundled names")
    func reflexologyRemoved() {
        #expect(!Passage.bundledNames.contains("reflexology-class"))
    }

    @Test("Unknown name that is not a file throws missingResource")
    func missingIsError() {
        #expect(throws: RunnerError.self) {
            _ = try Passage.load("definitely-not-a-real-passage-\(UUID().uuidString)")
        }
    }

    @Test("loadFixture reads homographs.txt")
    func loadFixtureHomographs() throws {
        let text = try Passage.loadFixture("homographs")
        #expect(!text.isEmpty)
    }

    @Test("loadFixture for missing fixture throws")
    func missingFixtureThrows() {
        #expect(throws: RunnerError.self) {
            _ = try Passage.loadFixture("no-such-fixture-\(UUID().uuidString)")
        }
    }

    @Test("Filesystem-path load reads the file and trims")
    func filesystemPathLoad() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-\(UUID().uuidString).txt")
        try "  hello world  \n".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let text = try Passage.load(tmp.path)
        #expect(text == "hello world")
    }
}

@Suite("WAVWriter")
struct WAVWriterTests {

    @Test("writeFloat32PCM round-trips through AVAudioFile")
    func roundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavwriter-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 0.1s of a pure 440Hz sine at 24kHz.
        let sampleRate = 24_000
        let seconds = 0.1
        let count = Int(Double(sampleRate) * seconds)
        let samples: [Float] = (0..<count).map { i in
            sin(2.0 * .pi * 440.0 * Float(i) / Float(sampleRate)) * 0.25
        }
        try WAVWriter.writeFloat32PCM(samples: samples, sampleRate: sampleRate, to: tmp)

        #expect(FileManager.default.fileExists(atPath: tmp.path))
        let size = try FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int ?? 0
        // WAV header is 44 bytes, PCM16 is 2 bytes/sample → at least ~2*count payload.
        #expect(size > count, "wav file should contain the expected sample payload")

        // Round-trip: reopen via AVAudioFile and check frame count and sample rate.
        let reopened = try AVAudioFile(forReading: tmp)
        #expect(Int(reopened.fileFormat.sampleRate) == sampleRate)
        #expect(reopened.length == Int64(count))
    }
}
