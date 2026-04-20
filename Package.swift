// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "mac-tts",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "mac-tts", targets: ["MacTTSCLI"]),
        .library(name: "TTSHarnessCore", targets: ["TTSHarnessCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.13.6"),
        .package(url: "https://github.com/soniqo/speech-swift.git", from: "0.0.9"),
        .package(url: "https://github.com/KittenML/KittenTTS-swift.git", revision: "4da0abbb92af4e7faf61affabbdb80d334ea768e"),
    ],
    targets: [
        .target(
            name: "TTSHarnessCore",
            resources: [.process("Resources")]
        ),
        .target(
            name: "FluidAudioRunner",
            dependencies: [
                "TTSHarnessCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .target(
            name: "SpeechSwiftRunner",
            dependencies: [
                "TTSHarnessCore",
                .product(name: "CosyVoiceTTS", package: "speech-swift"),
                .product(name: "Qwen3TTSCoreML", package: "speech-swift"),
            ]
        ),
        .target(
            name: "PythonSubprocessRunner",
            dependencies: ["TTSHarnessCore"]
        ),
        .target(
            name: "KittenTTSRunner",
            dependencies: [
                "TTSHarnessCore",
                .product(name: "KittenTTS", package: "KittenTTS-swift"),
            ]
        ),
        .executableTarget(
            name: "MacTTSCLI",
            dependencies: [
                "TTSHarnessCore",
                "FluidAudioRunner",
                "SpeechSwiftRunner",
                "PythonSubprocessRunner",
                "KittenTTSRunner",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "KittenTTS", package: "KittenTTS-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .target(name: "KittenCoreMLRunner"),
            ],
            path: "Sources/mac-tts"
        ),
        .target(name: "KittenCoreMLRunner",dependencies: [
    .target(name: "TTSHarnessCore"),
    .product(name: "KittenTTS", package: "KittenTTS-swift"),]),
        .testTarget(
            name: "TTSHarnessCoreTests",
            dependencies: [ "TTSHarnessCore" ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "FluidAudioRunnerTests",
            dependencies: [
                "TTSHarnessCore",
                "FluidAudioRunner"
            ]
        ),
    ]
)
