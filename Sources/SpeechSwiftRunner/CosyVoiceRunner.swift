import Foundation
import CosyVoiceTTS
import TTSHarnessCore

public struct CosyVoiceRunner: Runner {
    public let modelID = "cosyvoice3-mlx-4bit"
    public let sampleRate = 24_000

    public init() {}

    public func synthesize(text: String, to outputURL: URL) async throws {
        let model = try await CosyVoiceTTSModel.fromPretrained(
            modelId: "aufklarer/CosyVoice3-0.5B-MLX-4bit"
        )
        let samples = model.synthesize(text: text, language: "english")
        guard !samples.isEmpty else {
            throw RunnerError.decodeFailure("CosyVoice produced no samples")
        }
        try WAVWriter.writeFloat32PCM(samples: samples, sampleRate: sampleRate, to: outputURL)
    }
}
