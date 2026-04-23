// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "mako",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "mako", targets: ["MakoCLI"]),
        .library(name: "TTSHarnessCore", targets: ["TTSHarnessCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.13.6"),
        .package(url: "https://github.com/soniqo/speech-swift.git", from: "0.0.9"),
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
        .executableTarget(
            name: "MakoCLI",
            dependencies: [
                "TTSHarnessCore",
                "FluidAudioRunner",
                "SpeechSwiftRunner",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .target(name: "MakoKit"),
            ],
            path: "Sources/mako"
        ),
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
        .target(
            name: "MakoKit",
            dependencies: [
                "TTSHarnessCore",
                "FluidAudioRunner"
            ]
        ),
        .testTarget(
            name: "MakoKitTests",
            dependencies: [ "MakoKit", .target(name: "MakoCLI"),]
        ),
    ]
)
