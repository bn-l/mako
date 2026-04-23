import Foundation
import ArgumentParser
import TTSHarnessCore

/// Runs text through `KokoroSSMLNormalizer.normalize` and prints the
/// result — no model load, no audio. Used to eyeball pipeline decisions
/// (homograph / Penn-context / gold-lexicon overrides) against the
/// homograph fixture without the cost of a full synthesis run.
struct NormalizePreview: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "normalize-preview",
        abstract: "Print normalized SSML for a line or a file, without synthesis."
    )

    @Option(name: .long, help: "Read input lines from this file (default: stdin).")
    var file: String?

    @Flag(name: .long, help: "Emit a separator between input and output for each line.")
    var verbose = false

    @Flag(name: .long, help: "Run the Phase 8 ported pipeline (KokoroG2P.resolve → emit → compensatorsOnly) instead of the classic normalize.")
    var ported = false

    func run() async throws {
        let lines: [String]
        if let file {
            let raw = try String(contentsOfFile: file, encoding: .utf8)
            lines = raw.components(separatedBy: .newlines)
        } else {
            var collected: [String] = []
            while let line = readLine(strippingNewline: true) {
                collected.append(line)
            }
            lines = collected
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("===") || trimmed.hasPrefix("---") {
                print(line)
                continue
            }
            let normalized: String
            if ported {
                let plan = KokoroG2P.resolve(line)
                let emitted = KokoroG2P.emit(plan)
                normalized = KokoroSSMLNormalizer.compensatorsOnly(emitted.annotatedText)
            } else {
                normalized = KokoroSSMLNormalizer.normalize(line)
            }
            if verbose {
                print("IN : \(line)")
                print("OUT: \(normalized)")
            } else {
                print(normalized)
            }
        }
    }
}
