import Foundation
import ArgumentParser
import FluidAudio
import TTSHarnessCore

/// Chunk-boundary DSP exploration. Intentionally **bypasses** the ported
/// `KokoroG2P` + `KokoroSSMLNormalizer` pipeline — the passage goes into
/// `KokoroTtsManager` as raw text (per plan checkpoint H decision). The
/// tool probes post-synthesis smoothing strategies (microfade, crossfade,
/// silence injection) on chunk seams, which is orthogonal to what the
/// normalizer does. A/B comparisons against `mac-tts run` will differ on
/// normalization, not only on smoothing.
struct KokoroSmooth: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kokoro-smooth",
        abstract: "Chunk-seam smoothing variants. NOTE: bypasses KokoroG2P + SSML normalization — raw-text baseline."
    )

    @Option(name: .long, help: "Voice.")
    var voice: String = "af_heart"

    @Option(name: .long, help: "Speed.")
    var speed: Float = 1.4

    @Option(name: .long, help: "Output directory.")
    var outDir: String = "outputs/kokoro-smooth"

    func run() async throws {
        let passage = try Passage.load()
        let outURL = URL(fileURLWithPath: outDir)
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

        let manager = KokoroTtsManager(defaultVoice: voice)
        try await manager.initialize()

        print("Synthesizing \(voice) @ speed=\(speed)…")
        print("  (raw-passage baseline — bypasses KokoroG2P / SSML normalization; not a pipeline regression test)")
        let detailed = try await manager.synthesizeDetailed(
            text: passage,
            voice: voice,
            voiceSpeed: speed
        )
        print("  got \(detailed.chunks.count) chunks (total \(detailed.chunks.reduce(0) { $0 + $1.samples.count }) samples)")

        for (i, c) in detailed.chunks.enumerated() {
            let dur = Double(c.samples.count) / 24_000.0
            print(String(format: "    [%02d] %.2fs pauseAfter=%dms  \"%@\"", i, dur, c.pauseAfterMs, c.text.prefix(60).description))
        }

        let sr = 24_000
        let chunks: [[Float]] = detailed.chunks.map { Array($0.samples) }
        let pausesMs: [Int] = detailed.chunks.map { $0.pauseAfterMs }

        let tag = "\(voice)_s\(String(format: "%.1f", speed).replacingOccurrences(of: ".", with: "p"))"

        // Baseline — use raw detailed.audio (WAV bytes already assembled by the SDK)
        let baselineURL = outURL.appendingPathComponent("\(tag)_00-baseline.wav")
        try detailed.audio.write(to: baselineURL, options: [.atomic])
        print("  ✓ \(baselineURL.lastPathComponent)")

        // 01 — micro-fade (3ms) on each chunk edge, concat
        let microOnly = concatWithMicrofade(chunks: chunks, pausesMs: pausesMs, sampleRate: sr, microfadeMs: 3)
        try writeWav(samples: microOnly, sampleRate: sr, to: outURL.appendingPathComponent("\(tag)_01-microfade.wav"))

        // 02 — crossfade (20ms equal-power) between every chunk, no silence
        let crossOnly = concatWithCrossfade(chunks: chunks, sampleRate: sr, crossfadeMs: 20)
        try writeWav(samples: crossOnly, sampleRate: sr, to: outURL.appendingPathComponent("\(tag)_02-crossfade.wav"))

        // 03 — explicit silences: honor pauseAfterMs, inject 40ms at zero-pause splits, no fades
        let silenceOnly = concatWithSilences(chunks: chunks, pausesMs: pausesMs, sampleRate: sr, zeroPauseFillMs: 40)
        try writeWav(samples: silenceOnly, sampleRate: sr, to: outURL.appendingPathComponent("\(tag)_03-silence.wav"))

        // 04 — combined: microfade + honor sentence pauses + crossfade at zero-pause splits
        let combined = concatCombined(chunks: chunks, pausesMs: pausesMs, sampleRate: sr, microfadeMs: 3, crossfadeMs: 20)
        try writeWav(samples: combined, sampleRate: sr, to: outURL.appendingPathComponent("\(tag)_04-combined.wav"))

        // 05 — aggressive silence: 100ms at every split + microfade
        let longSilence = concatWithSilences(chunks: chunks.map { microfade($0, sampleRate: sr, ms: 3) },
                                             pausesMs: pausesMs.map { max($0, 100) },
                                             sampleRate: sr, zeroPauseFillMs: 100)
        try writeWav(samples: longSilence, sampleRate: sr, to: outURL.appendingPathComponent("\(tag)_05-longsilence.wav"))

        print("done. \(outURL.path)")
    }

    // MARK: - DSP

    private func microfade(_ samples: [Float], sampleRate: Int, ms: Int) -> [Float] {
        var out = samples
        let n = max(1, sampleRate * ms / 1000)
        let count = out.count
        let fadeIn = min(n, count / 2)
        for i in 0..<fadeIn {
            out[i] *= Float(i) / Float(fadeIn)
        }
        let fadeOut = min(n, count / 2)
        for i in 0..<fadeOut {
            out[count - 1 - i] *= Float(i) / Float(fadeOut)
        }
        return out
    }

    private func concatWithMicrofade(chunks: [[Float]], pausesMs: [Int], sampleRate: Int, microfadeMs: Int) -> [Float] {
        var out: [Float] = []
        for (i, c) in chunks.enumerated() {
            out.append(contentsOf: microfade(c, sampleRate: sampleRate, ms: microfadeMs))
            if i < chunks.count - 1 {
                let ms = pausesMs[i]
                let n = sampleRate * ms / 1000
                if n > 0 { out.append(contentsOf: [Float](repeating: 0, count: n)) }
            }
        }
        return out
    }

    private func concatWithCrossfade(chunks: [[Float]], sampleRate: Int, crossfadeMs: Int) -> [Float] {
        guard let first = chunks.first else { return [] }
        var out = first
        let cf = sampleRate * crossfadeMs / 1000
        for i in 1..<chunks.count {
            let next = chunks[i]
            let overlap = min(cf, min(out.count, next.count) / 2)
            if overlap <= 0 {
                out.append(contentsOf: next)
                continue
            }
            for j in 0..<overlap {
                let t = Float(j) / Float(overlap - 1)
                let gOut = cos(0.5 * .pi * t)   // equal-power
                let gIn  = sin(0.5 * .pi * t)
                out[out.count - overlap + j] = out[out.count - overlap + j] * gOut + next[j] * gIn
            }
            out.append(contentsOf: next[overlap..<next.count])
        }
        return out
    }

    private func concatWithSilences(chunks: [[Float]], pausesMs: [Int], sampleRate: Int, zeroPauseFillMs: Int) -> [Float] {
        var out: [Float] = []
        for (i, c) in chunks.enumerated() {
            out.append(contentsOf: c)
            if i < chunks.count - 1 {
                let ms = pausesMs[i] > 0 ? pausesMs[i] : zeroPauseFillMs
                let n = sampleRate * ms / 1000
                if n > 0 { out.append(contentsOf: [Float](repeating: 0, count: n)) }
            }
        }
        return out
    }

    private func concatCombined(chunks: [[Float]], pausesMs: [Int], sampleRate: Int, microfadeMs: Int, crossfadeMs: Int) -> [Float] {
        let faded = chunks.map { microfade($0, sampleRate: sampleRate, ms: microfadeMs) }
        guard let first = faded.first else { return [] }
        var out = first
        let cf = sampleRate * crossfadeMs / 1000
        for i in 1..<faded.count {
            let next = faded[i]
            let pauseMs = pausesMs[i - 1]
            if pauseMs > 0 {
                let n = sampleRate * pauseMs / 1000
                out.append(contentsOf: [Float](repeating: 0, count: n))
                out.append(contentsOf: next)
            } else {
                let overlap = min(cf, min(out.count, next.count) / 2)
                if overlap <= 0 {
                    out.append(contentsOf: next)
                    continue
                }
                for j in 0..<overlap {
                    let t = Float(j) / Float(overlap - 1)
                    let gOut = cos(0.5 * .pi * t)
                    let gIn  = sin(0.5 * .pi * t)
                    out[out.count - overlap + j] = out[out.count - overlap + j] * gOut + next[j] * gIn
                }
                out.append(contentsOf: next[overlap..<next.count])
            }
        }
        return out
    }

    private func writeWav(samples: [Float], sampleRate: Int, to url: URL) throws {
        try WAVWriter.writeFloat32PCM(samples: samples, sampleRate: sampleRate, to: url)
        print("  ✓ \(url.lastPathComponent)")
    }
}
