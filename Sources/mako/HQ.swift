import Foundation
import ArgumentParser
import FishRunner

/// `mako hq` is a verb-only namespace: there is deliberately no `mako hq "text"`.
///
/// Speech goes through `mako say --hq` and nowhere else, so `say` stays the only default
/// subcommand and `mako "some text"` can never be ambiguous.
struct HQ: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hq",
        abstract: "Manage the high-quality engine used by `mako say --hq`.",
        subcommands: [Install.self]
    )
}

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Download the fish weights (~7 GB) and warm the sidecar environment."
    )

    func run() async throws {
        // Two cold starts in one: uv builds the script environment (fetching a managed
        // CPython 3.12 if the machine has none), then the weights come down. Doing both
        // here is what keeps the first `--hq` from stalling for minutes.
        print("Preparing the high-quality engine. This downloads about 7 GB once.")
        try FishSetup.install()
        print("Done. `mako say --hq \"...\"` is ready.")
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check that everything `mako say` and `mako say --hq` depend on is in place."
    )

    func run() async throws {
        var ready = true
        func report(_ label: String, _ value: String?, hint: String) {
            let padded = label.padding(toLength: 20, withPad: " ", startingAt: 0)
            if let value {
                print("  ✓ \(padded) \(value)")
            } else {
                ready = false
                print("  ✗ \(padded) \(hint)")
            }
        }

        print("say (kokoro, the default engine)")
        report("ffmpeg", findFFmpeg(), hint: "not found — WAV only; `brew install ffmpeg` for M4A")

        print("say --hq (fish s2 pro)")
        let status = FishSetup.status()
        report("uv", status.uvPath, hint: "not on PATH — `brew install uv`")
        report("sidecar", status.scriptPath, hint: "missing from the resource bundle — reinstall mako")
        report("voice reference", status.referenceAudioPath, hint: "missing from the resource bundle — reinstall mako")
        report("voice transcript", status.referenceTranscriptPath, hint: "missing from the resource bundle — reinstall mako")
        report("weights", status.weightsPresent == true ? "cached" : nil,
               hint: "not downloaded — run `mako hq install`")

        if !ready {
            print("\nSome checks failed; see the hints above.")
            throw ExitCode.failure
        }
    }
}
