import Foundation

public enum Backend: String, Sendable, CaseIterable {
    case fluidAudio
    case speechSwift
    case pythonMLXAudio
    case pythonMLXSpeech
    case kittenTTS
    case kittenCoreMLNano
    case kittenCoreMLMini
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
            id: "pocket-tts-fluidaudio",
            hfRepo: "FluidInference/pocket-tts-coreml",
            backend: .fluidAudio,
            defaultVoice: "alba"
        ),
        .init(
            id: "cosyvoice3-mlx-4bit",
            hfRepo: "aufklarer/CosyVoice3-0.5B-MLX-4bit",
            backend: .speechSwift
        ),
        .init(
            id: "fishaudio-s2-pro-mlx-8bit",
            hfRepo: "mlx-community/fishaudio-s2-pro-8bit-mlx",
            backend: .pythonMLXSpeech
        ),
        .init(
            id: "qwen3-tts-12hz-17b-mlx-bf16",
            hfRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
            backend: .pythonMLXAudio
        ),
        .init(
            id: "voxtral-4b-tts-mlx-4bit",
            hfRepo: "mlx-community/Voxtral-4B-TTS-2603-mlx-4bit",
            backend: .pythonMLXAudio,
            defaultVoice: "casual_male"
        ),
        .init(
            id: "longcat-audiodit-mlx-8bit",
            hfRepo: "mlx-community/longcat-audiodit-3.5b-8bit-mlx",
            backend: .pythonMLXSpeech
        ),
        .init(
            id: "kittentts-swift",
            hfRepo: "KittenML/KittenTTS-swift",
            backend: .kittenTTS
        ),
        .init(
            id: "kittentts-coreml-nano",
            hfRepo: "alexwengg/kittentts-coreml",
            backend: .kittenCoreMLNano,
            defaultVoice: "expr-voice-3-f"
        ),
        .init(
            id: "kittentts-coreml-mini",
            hfRepo: "alexwengg/kittentts-coreml",
            backend: .kittenCoreMLMini,
            defaultVoice: "expr-voice-3-f"
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
