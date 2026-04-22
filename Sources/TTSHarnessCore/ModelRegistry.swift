import Foundation

public enum Backend: String, Sendable, CaseIterable {
    case fluidAudio
    case speechSwift
    case qwen3TtsCoreML
}

public struct ModelEntry: Sendable {
    public let id: String
    public let hfRepo: String
    public let backend: Backend
    public let defaultVoice: String?

    public init(
        id: String,
        hfRepo: String,
        backend: Backend,
        defaultVoice: String? = nil
    ) {
        self.id = id
        self.hfRepo = hfRepo
        self.backend = backend
        self.defaultVoice = defaultVoice
    }
}

public enum ModelRegistry {
    public static let all: [ModelEntry] = [
        .init(
            id: "kokoro-fluidaudio",
            hfRepo: "FluidInference/kokoro-82m-coreml",
            backend: .fluidAudio,
            defaultVoice: "af_heart"
        ),
        .init(
            id: "cosyvoice3-mlx-4bit",
            hfRepo: "aufklarer/CosyVoice3-0.5B-MLX-4bit",
            backend: .speechSwift
        ),
        .init(
            id: "qwen3-tts-coreml-06b",
            hfRepo: "aufklarer/Qwen3-TTS-CoreML",
            backend: .qwen3TtsCoreML
        ),
    ]

    public static func find(id: String) -> ModelEntry? {
        all.first { $0.id == id }
    }
}
