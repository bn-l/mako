import Foundation
import TTSHarnessCore
import FluidAudioRunner
import SpeechSwiftRunner

enum RunnerFactory {
    static func make(for entry: ModelEntry) -> Runner {
        switch entry.backend {
        case .fluidAudio:
            switch entry.id {
            case "kokoro-fluidaudio":
                return KokoroFluidAudioRunner(voice: entry.defaultVoice ?? "af_heart")
            default:
                fatalError("unknown fluidAudio model id: \(entry.id)")
            }
        case .speechSwift:
            return CosyVoiceRunner()
        case .qwen3TtsCoreML:
            return Qwen3TTSCoreMLRunner()
        }
    }
}
