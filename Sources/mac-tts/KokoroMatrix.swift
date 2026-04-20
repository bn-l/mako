import Foundation
import ArgumentParser
import FluidAudio
import TTSHarnessCore

/// Voice × speed timing matrix. Intentionally **bypasses** the ported
/// `KokoroG2P` + `KokoroSSMLNormalizer` pipeline — the passage goes into
/// `KokoroTtsManager` as raw text (per plan checkpoint H decision). The
/// tool exists to compare voices and speeds on the same passage, not to
/// validate normalization, so the bypass keeps the baseline comparable
/// across renders regardless of which pipeline the main runner uses.
/// Any A/B against `mac-tts run` will differ on normalization, not only
/// on voice/speed.
struct KokoroMatrix: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kokoro-matrix",
        abstract: "Voice/speed matrix for Kokoro. NOTE: bypasses KokoroG2P + SSML normalization — raw-text baseline."
    )

    @Option(name: .long, help: "Output directory.")
    var outDir: String = "outputs/kokoro"

    @Option(name: .long, help: "Max concurrent synthesize() calls.")
    var concurrency: Int = 3

    @Option(name: .long, parsing: .upToNextOption, help: "Speeds to try (space-separated).")
    var speeds: [Float] = [1.0, 1.2, 1.4]

    static let americanEnglishVoices: [String] = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore",
        "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
        "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam",
        "am_michael", "am_onyx", "am_puck", "am_santa",
    ]

    struct Job: Sendable { let voice: String; let speed: Float }
    struct Result: Sendable {
        let voice: String
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
        for v in Self.americanEnglishVoices {
            for s in speeds { jobs.append(Job(voice: v, speed: s)) }
        }
        print("Running \(jobs.count) Kokoro jobs (\(Self.americanEnglishVoices.count) voices × \(speeds.count) speeds) with concurrency \(concurrency)…")
        print("  (raw-passage baseline — bypasses KokoroG2P / SSML normalization; not a pipeline regression test)")

        let total = jobs.count
        var results: [Result] = []
        var iter = jobs.makeIterator()

        try await withThrowingTaskGroup(of: Result.self) { group in
            for _ in 0..<concurrency {
                guard let job = iter.next() else { break }
                group.addTask {
                    try await Self.runOne(job: job, passage: passage, outDir: outURL)
                }
            }
            while let result = try await group.next() {
                results.append(result)
                print("  ✓ [\(results.count)/\(total)] \(result.filename)  wall \(String(format: "%.2f", result.wallSec))s  audio \(String(format: "%.2f", result.audioSec))s  RTFx \(String(format: "%.2f", result.audioSec / result.wallSec))")
                if let job = iter.next() {
                    group.addTask {
                        try await Self.runOne(job: job, passage: passage, outDir: outURL)
                    }
                }
            }
        }

        results.sort { a, b in
            if a.voice != b.voice { return a.voice < b.voice }
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
                         r.voice, r.speed, r.wallSec, r.audioSec, rtf, cps, r.filename))
        }
    }

    private static func runOne(job: Job, passage: String, outDir: URL) async throws -> Result {
        let speedStr = String(format: "%.1f", job.speed).replacingOccurrences(of: ".", with: "p")
        let filename = "\(job.voice)_s\(speedStr).wav"
        let url = outDir.appendingPathComponent(filename)
        let manager = KokoroTtsManager(defaultVoice: job.voice)
        try await manager.initialize()
        let start = Date()
        let detailed = try await manager.synthesizeDetailed(
            text: passage,
            voice: job.voice,
            voiceSpeed: job.speed
        )
        let wall = Date().timeIntervalSince(start)
        try detailed.audio.write(to: url, options: [.atomic])
        let totalSamples = detailed.chunks.reduce(0) { $0 + $1.samples.count }
        let audioSec = Double(totalSamples) / 24_000.0
        return Result(voice: job.voice, speed: job.speed, wallSec: wall, audioSec: audioSec, filename: filename)
    }
}
