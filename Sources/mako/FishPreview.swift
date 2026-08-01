import Foundation
import ArgumentParser
import FishRunner
import TTSHarnessCore

/// `mako dev fish-preview` — what `--hq` will actually send to the model.
///
/// The same role `normalize-preview` plays for Kokoro. Worth having separately because
/// a fish render costs 15 GB and several minutes, which is a bad way to discover that a
/// marker survived or a paragraph got split somewhere silly.
struct FishPreview: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fish-preview",
        abstract: "Show the turns `mako say --hq` would send to fish."
    )

    @Argument(help: "Text to prepare. Use '-' or omit to read from stdin.")
    var text: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Keep inline [tag] markers.")
    var markers: Bool = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Run the structural normalizer.")
    var normalize: Bool = false

    @Option(name: .long, help: "Byte budget per turn (matches --hq's chunk length).")
    var chunkLength: Int = 400

    func run() async throws {
        let source: String
        if let text, text != "-" {
            source = text
        } else {
            source = String(decoding: FileHandle.standardInput.readDataToEndOfFile(),
                            as: UTF8.self)
        }
        let prepared = FishText.prepare(
            source, keepMarkers: markers, normalize: normalize, maxTurnBytes: chunkLength)
        let turns = prepared.components(separatedBy: "\n\n")
        print("\(source.count) chars in → \(turns.count) turn(s), budget \(chunkLength) bytes\n")
        for (index, turn) in turns.enumerated() {
            print("── turn \(index + 1) (\(turn.utf8.count) bytes)")
            print(turn)
            print("")
        }
    }
}
