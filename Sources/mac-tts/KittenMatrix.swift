import Foundation
import ArgumentParser
import KittenTTS
import TTSHarnessCore

struct KittenMatrix: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kitten-matrix",
        abstract: "Run KittenTTS across all voices × multiple speeds concurrently."
    )

    @Option(name: .long, help: "Output directory.")
    var outDir: String = "outputs/kitten"

    @Option(name: .long, help: "Max concurrent generate() calls.")
    var concurrency: Int = 4

    @Option(name: .long, help: "maxTokensPerChunk for KittenTTSConfig.")
    var maxTokensPerChunk: Int = 1000

    @Option(name: .long, parsing: .upToNextOption, help: "Speeds to try (space-separated).")
    var speeds: [Float] = [1.0, 1.2, 1.4]

    struct Job: Sendable { let voice: KittenVoice; let speed: Float }
    struct Result: Sendable {
        let voice: KittenVoice
        let speed: Float
        let wallSec: Double
        let audioSec: Double
        let filename: String
    }

    func run() async throws {
        let passage = try Passage.load()
        let outURL = URL(fileURLWithPath: outDir)
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

        var jobs: [Job] = []
        for v in KittenVoice.allCases {
            for s in speeds { jobs.append(Job(voice: v, speed: s)) }
        }
        print("Running \(jobs.count) jobs (\(KittenVoice.allCases.count) voices × \(speeds.count) speeds) with concurrency \(concurrency)…")

        let total = jobs.count
        var results: [Result] = []
        var iter = jobs.makeIterator()

        try await withThrowingTaskGroup(of: Result.self) { group in
            for _ in 0..<concurrency {
                guard let job = iter.next() else { break }
                let mtc = maxTokensPerChunk
                group.addTask {
                    try await Self.runOne(job: job, passage: passage, outDir: outURL, mtc: mtc)
                }
            }
            while let result = try await group.next() {
                results.append(result)
                print("  ✓ [\(results.count)/\(total)] \(result.filename)  wall \(String(format: "%.2f", result.wallSec))s  audio \(String(format: "%.2f", result.audioSec))s  RTFx \(String(format: "%.2f", result.audioSec / result.wallSec))")
                if let job = iter.next() {
                    let mtc = maxTokensPerChunk
                    group.addTask {
                        try await Self.runOne(job: job, passage: passage, outDir: outURL, mtc: mtc)
                    }
                }
            }
        }

        results.sort { a, b in
            if a.voice.rawValue != b.voice.rawValue { return a.voice.rawValue < b.voice.rawValue }
            return a.speed < b.speed
        }

        print("")
        print("| voice | speed | wall (s) | audio (s) | RTFx | chars/s | file |")
        print("|---|---:|---:|---:|---:|---:|---|")
        let chars = passage.count
        for r in results {
            let rtf = r.audioSec / r.wallSec
            let cps = Double(chars) / r.wallSec
            print(String(format: "| %@ | %.2f | %.2f | %.2f | %.2f | %.1f | %@ |",
                         r.voice.displayName, r.speed, r.wallSec, r.audioSec, rtf, cps, r.filename))
        }
    }

    private static func runOne(job: Job, passage: String, outDir: URL, mtc: Int) async throws -> Result {
        let speedStr = String(format: "%.1f", job.speed).replacingOccurrences(of: ".", with: "p")
        let filename = "\(job.voice.rawValue)_\(job.voice.displayName.lowercased())_s\(speedStr)_mtc\(mtc).wav"
        let url = outDir.appendingPathComponent(filename)
        let config = KittenTTSConfig(maxTokensPerChunk: mtc)
        let tts = try await KittenTTS(config)
        let start = Date()
        let result = try await tts.generate(passage, voice: job.voice, speed: job.speed)
        let wall = Date().timeIntervalSince(start)
        try result.writeWAV(to: url)
        return Result(voice: job.voice, speed: job.speed, wallSec: wall, audioSec: result.duration, filename: filename)
    }
}
