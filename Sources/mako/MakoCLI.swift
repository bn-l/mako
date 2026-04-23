import Foundation
import ArgumentParser
import TTSHarnessCore

@main
struct Mako: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mako",
        abstract: "Text-to-speech via Kokoro. Plays via afplay by default; writes M4A/WAV when -o is given.",
        version: "0.3.0",
        subcommands: [Say.self, ListVoices.self, Dev.self],
        defaultSubcommand: Say.self
    )
}

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List known models.")

    func run() async throws {
        func pad(_ s: String, _ w: Int) -> String {
            s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
        }
        print("\(pad("id", 35))  \(pad("backend", 20))  hfRepo")
        print(String(repeating: "-", count: 100))
        for e in ModelRegistry.all {
            print("\(pad(e.id, 35))  \(pad(e.backend.rawValue, 20))  \(e.hfRepo)")
        }
    }
}

struct RunMetric: Sendable {
    let id: String
    let backend: String
    let wallSec: Double?
    let peakRSSBytes: UInt64?
    let avgRSSBytes: UInt64?
    let status: String
    let note: String?
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run synthesis for one or all models.")

    @Option(name: .long, help: "Model id (from `mako dev list`).")
    var model: String?

    @Flag(name: .long, help: "Run every model.")
    var all = false

    @Flag(name: .long, help: "Skip Python subprocess models.")
    var skipPython = false

    @Option(name: .long, help: "Output directory.")
    var outputDir: String = "outputs"

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Passage source.",
            discussion: "Bundled name (one of: \(Passage.bundledNames.joined(separator: ", "))) or path to a .txt file."
        )
    )
    var passage: String = Passage.defaultName

    func run() async throws {
        let passage = try Passage.load(self.passage)
        let charCount = passage.count
        let wordCount = passage.split { $0.isWhitespace }.count
        let outDir = URL(fileURLWithPath: outputDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let entries = try resolveEntries()
        var metrics: [RunMetric] = []
        for entry in entries {
            if skipPython, entry.backend.rawValue.hasPrefix("python") {
                print("skip \(entry.id) — --skip-python set")
                metrics.append(RunMetric(
                    id: entry.id, backend: entry.backend.rawValue,
                    wallSec: nil, peakRSSBytes: nil, avgRSSBytes: nil,
                    status: "skipped", note: "--skip-python"
                ))
                continue
            }
            let runner = RunnerFactory.make(for: entry)
            let outURL = outDir.appendingPathComponent("\(entry.id).wav")
            print("▶ \(entry.id) → \(outURL.path)")
            let sampler = RSSSampler()
            await sampler.start()
            let start = Date()
            var status = "ok"
            var note: String? = nil
            do {
                try await runner.synthesize(text: passage, to: outURL)
            } catch {
                status = "failed"
                note = "\(error)"
                print("  ✗ \(error)")
            }
            let elapsed = Date().timeIntervalSince(start)
            let m = await sampler.stop()
            let peakMB = Double(m.peakBytes) / 1024 / 1024
            let avgMB = Double(m.avgBytes) / 1024 / 1024
            if status == "ok" {
                print(String(format: "  ✓ %.2fs  peak %.0fMB  avg %.0fMB  (%d samples)",
                             elapsed, peakMB, avgMB, m.sampleCount))
            }
            metrics.append(RunMetric(
                id: entry.id, backend: entry.backend.rawValue,
                wallSec: elapsed, peakRSSBytes: m.peakBytes, avgRSSBytes: m.avgBytes,
                status: status, note: note
            ))
        }
        if all {
            let summaryURL = outDir.appendingPathComponent("summary.md")
            try writeSummary(metrics, chars: charCount, words: wordCount, to: summaryURL)
            print("📝 summary → \(summaryURL.path)")
        }
    }

    private func writeSummary(_ metrics: [RunMetric], chars: Int, words: Int, to url: URL) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var out = "# TTS harness run summary\n\n"
        out += "Generated: \(iso.string(from: Date()))\n\n"
        out += "Passage: \(chars) chars, \(words) words.\n\n"
        out += "| model | backend | status | wall (s) | chars/s | words/s | peak RSS (MB) | avg RSS (MB) | note |\n"
        out += "|---|---|---|---:|---:|---:|---:|---:|---|\n"
        for m in metrics {
            let wall = m.wallSec.map { String(format: "%.2f", $0) } ?? "—"
            let cps = m.wallSec.map { String(format: "%.1f", Double(chars) / $0) } ?? "—"
            let wps = m.wallSec.map { String(format: "%.1f", Double(words) / $0) } ?? "—"
            let peak = m.peakRSSBytes.map { String(format: "%.0f", Double($0) / 1024 / 1024) } ?? "—"
            let avg = m.avgRSSBytes.map { String(format: "%.0f", Double($0) / 1024 / 1024) } ?? "—"
            let note = (m.note ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "|", with: "\\|")
            out += "| \(m.id) | \(m.backend) | \(m.status) | \(wall) | \(cps) | \(wps) | \(peak) | \(avg) | \(note) |\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    private func resolveEntries() throws -> [ModelEntry] {
        if all { return ModelRegistry.all }
        guard let id = model else {
            throw ValidationError("pass --model <id> or --all")
        }
        guard let entry = ModelRegistry.find(id: id) else {
            throw ValidationError("unknown model id: \(id)")
        }
        return [entry]
    }
}
