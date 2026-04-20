import Foundation
import Qwen3TTSCoreML
import TTSHarnessCore

public struct Qwen3TTSCoreMLRunner: Runner {
    public let modelID = "qwen3-tts-coreml-06b"
    public let sampleRate = 24_000
    public let maxCharsPerChunk = 140

    public init() {}

    public func synthesize(text: String, to outputURL: URL) async throws {
        let model = try await Qwen3TTSCoreMLModel.fromPretrained()
        let chunks = Self.chunk(text, maxChars: maxCharsPerChunk)
        var allSamples: [Float] = []
        let silence = [Float](repeating: 0, count: sampleRate / 5) // 200ms gap
        for (i, chunk) in chunks.enumerated() {
            let samples = try model.synthesize(
                text: chunk,
                language: "english",
                maxTokens: 250
            )
            if samples.isEmpty {
                throw RunnerError.decodeFailure("chunk \(i) produced no samples: \(chunk)")
            }
            if !allSamples.isEmpty { allSamples.append(contentsOf: silence) }
            allSamples.append(contentsOf: samples)
        }
        guard !allSamples.isEmpty else {
            throw RunnerError.decodeFailure("Qwen3TTSCoreML produced no samples")
        }
        try WAVWriter.writeFloat32PCM(samples: allSamples, sampleRate: sampleRate, to: outputURL)
    }

    static func chunk(_ text: String, maxChars: Int) -> [String] {
        let separators: Set<Character> = [".", ";", ":", "!", "?"]
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if separators.contains(ch) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }

        var chunks: [String] = []
        var buffer = ""
        for sentence in sentences {
            if sentence.count >= maxChars {
                if !buffer.isEmpty { chunks.append(buffer); buffer = "" }
                chunks.append(contentsOf: splitLong(sentence, maxChars: maxChars))
                continue
            }
            let candidate = buffer.isEmpty ? sentence : buffer + " " + sentence
            if candidate.count > maxChars {
                chunks.append(buffer)
                buffer = sentence
            } else {
                buffer = candidate
            }
        }
        if !buffer.isEmpty { chunks.append(buffer) }
        return chunks
    }

    static func splitLong(_ text: String, maxChars: Int) -> [String] {
        let words = text.split(separator: " ")
        var chunks: [String] = []
        var buffer = ""
        for word in words {
            let candidate = buffer.isEmpty ? String(word) : buffer + " " + word
            if candidate.count > maxChars {
                if !buffer.isEmpty { chunks.append(buffer) }
                buffer = String(word)
            } else {
                buffer = candidate
            }
        }
        if !buffer.isEmpty { chunks.append(buffer) }
        return chunks
    }
}
