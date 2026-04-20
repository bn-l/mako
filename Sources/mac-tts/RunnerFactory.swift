import Foundation
import TTSHarnessCore
import FluidAudioRunner
import SpeechSwiftRunner
import PythonSubprocessRunner
import KittenTTSRunner
import KittenCoreMLRunner

enum RunnerFactory {
    static func make(for entry: ModelEntry) -> Runner {
        switch entry.backend {
        case .fluidAudio:
            switch entry.id {
            case "kokoro-fluidaudio":
                return KokoroFluidAudioRunner(voice: entry.defaultVoice ?? "af_heart")
            case "pocket-tts-fluidaudio":
                return PocketFluidAudioRunner(voice: entry.defaultVoice ?? "alba")
            default:
                fatalError("unknown fluidAudio model id: \(entry.id)")
            }
        case .speechSwift:
            return CosyVoiceRunner()
        case .pythonMLXAudio:
            return PythonSubprocessRunner(
                modelID: entry.id,
                sampleRate: 24_000,
                script: .mlxAudio,
                hfRepo: entry.hfRepo,
                voice: entry.defaultVoice
            )
        case .pythonMLXSpeech:
            return PythonSubprocessRunner(
                modelID: entry.id,
                sampleRate: 24_000,
                script: .mlxSpeech,
                hfRepo: entry.hfRepo,
                voice: entry.defaultVoice
            )
        case .kittenTTS:
            return KittenTTSRunner()
        case .kittenCoreMLNano:
            return KittenCoreMLRunner(
                modelID: entry.id,
                variant: .nano,
                voice: entry.defaultVoice ?? "expr-voice-3-f"
            )
        case .kittenCoreMLMini:
            return KittenCoreMLRunner(
                modelID: entry.id,
                variant: .mini,
                voice: entry.defaultVoice ?? "expr-voice-3-f"
            )
        case .qwen3TtsCoreML:
            return Qwen3TTSCoreMLRunner()
        }
    }
}
