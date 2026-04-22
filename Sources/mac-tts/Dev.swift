import Foundation
import ArgumentParser

/// Parent for the legacy harness/dev subcommands. Kept around so the
/// workflows built up during development (normalize-preview, matrix
/// sweeps, the full `run` harness) remain reachable from the same
/// binary — just out of the default user surface.
struct Dev: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev",
        abstract: "Development + debugging subcommands (normalizer, tokenizer, model harness).",
        subcommands: [
            DevSay.self,
            List.self,
            Run.self,
            NormalizePreview.self,
            TokenizePreview.self,
            G2PPreview.self,
            KokoroMatrix.self,
            KokoroSmooth.self,
        ]
    )
}
