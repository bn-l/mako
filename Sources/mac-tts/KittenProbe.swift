import Foundation
import ArgumentParser
import KittenTTS
import TTSHarnessCore

struct KittenProbe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kitten-probe",
        abstract: "Binary-search KittenTTS maxTokensPerChunk limit where ONNX /bert/Expand fails."
    )

    @Option(name: .long, help: "Known-good lower bound.")
    var lo: Int = 400

    @Option(name: .long, help: "Known-bad upper bound.")
    var hi: Int = 1000

    func run() async throws {
        let passage = try Passage.load()
        var lo = self.lo
        var hi = self.hi

        print("Probing KittenTTS maxTokensPerChunk limit via binary search in [\(lo), \(hi)]…")

        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            print("  trying mtc=\(mid)…", terminator: " ")
            let ok = await tryGenerate(passage: passage, mtc: mid)
            if ok {
                print("ok")
                lo = mid
            } else {
                print("fail")
                hi = mid
            }
        }

        print("")
        print("Highest-known-good mtc: \(lo)")
        print("Lowest-known-bad mtc:   \(hi)")
    }

    private func tryGenerate(passage: String, mtc: Int) async -> Bool {
        do {
            let config = KittenTTSConfig(maxTokensPerChunk: mtc)
            let tts = try await KittenTTS(config)
            _ = try await tts.generate(passage, voice: .bella, speed: 1.0)
            return true
        } catch {
            return false
        }
    }
}
