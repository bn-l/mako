import Foundation
import KittenTTS
import TTSHarnessCore

public struct KittenTTSRunner: Runner {
    public let modelID = "kittentts-coreml"
    public let sampleRate = 24_000

    public init() {}

    public func synthesize(text: String, to outputURL: URL) async throws {
        let tts = try await KittenTTS()
        let result = try await tts.generate(text)
        try result.writeWAV(to: outputURL)
    }
}
