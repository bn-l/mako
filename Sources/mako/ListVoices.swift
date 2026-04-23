import Foundation
import ArgumentParser
import FluidAudio

struct ListVoices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-voices",
        abstract: "List available Kokoro voices. Only af_*/am_* are production-supported; the rest are experimental."
    )

    func run() async throws {
        let recommended = TtsConstants.recommendedVoice
        for voice in TtsConstants.availableVoices {
            if voice == recommended {
                print("\(voice)  (default)")
            } else {
                print(voice)
            }
        }
    }
}
