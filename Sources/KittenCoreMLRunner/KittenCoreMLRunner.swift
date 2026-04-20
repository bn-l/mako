import Foundation
import TTSHarnessCore

public struct KittenCoreMLRunner: Runner {
    public let modelID: String
    public let sampleRate = 24_000

    private let variant: KittenCoreMLVariant
    private let voice: String
    private let speed: Float
    private let modelURL: URL
    private let voicesDir: URL

    public init(
        modelID: String,
        variant: KittenCoreMLVariant,
        voice: String = "expr-voice-3-f",
        speed: Float = 1.0,
        modelsRoot: URL? = nil
    ) {
        self.modelID = modelID
        self.variant = variant
        self.voice = voice
        self.speed = speed

        let root = modelsRoot
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("models/kittentts-coreml", isDirectory: true)

        switch variant {
        case .nano:
            self.modelURL = root.appendingPathComponent("nano/kittentts_10s.mlmodelc", isDirectory: true)
            self.voicesDir = root.appendingPathComponent("nano/voices", isDirectory: true)
        case .mini:
            self.modelURL = root.appendingPathComponent("mini/kittentts_mini_10s.mlmodelc", isDirectory: true)
            self.voicesDir = root.appendingPathComponent("mini/voices", isDirectory: true)
        }
    }

    public func synthesize(text: String, to outputURL: URL) async throws {
        let engine = try await KittenCoreMLEngine(variant: variant, modelURL: modelURL, voicesDir: voicesDir)
        let samples = try await engine.generate(text: text, voice: voice, speed: speed)
        try WAVWriter.writeFloat32PCM(samples: samples, sampleRate: sampleRate, to: outputURL)
    }
}
