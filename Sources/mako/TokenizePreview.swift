import Foundation
import ArgumentParser
import TTSHarnessCore

/// Runs text through `KokoroTokenizer.tokenize` and prints one token
/// per line with its source-range slice. Exists mainly to verify the
/// round-trip invariant (checkpoint F): concatenating every token's
/// `sourceRange` substring in order recovers the original text minus
/// inter-token whitespace.
///
/// The tool deliberately does NOT offer a pre-tokenize normalize pass —
/// doing so would shift source ranges into the normalized string and
/// the round-trip check would silently validate a different contract.
/// To inspect the combined behaviour, pipe `normalize-preview` output
/// into this command.
///
/// Usage:
///   mako dev tokenize-preview --file foot-massage.txt
///   echo "Dr. O'Brien's at 5:30 a.m." | mako dev tokenize-preview
///   echo "..." | mako dev tokenize-preview --round-trip
struct TokenizePreview: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tokenize-preview",
        abstract: "Print offset-aware tokens for a line or a file."
    )

    @Option(name: .long, help: "Read input lines from this file (default: stdin).")
    var file: String?

    @Flag(name: .long, help: "Only print round-trip diagnostic (PASS/FAIL per line).")
    var roundTrip = false

    @Flag(name: .long, help: "Skip NLTagger POS annotation.")
    var noPos = false

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

        var totalChecked = 0
        var totalFailed = 0
        for (idx, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("===") || trimmed.hasPrefix("---") {
                if !roundTrip { print(rawLine) }
                continue
            }
            let line = rawLine
            let tokens = KokoroTokenizer.tokenize(line, posTag: !noPos)

            if roundTrip {
                totalChecked += 1
                let ns = line as NSString
                let concat = tokens.map { ns.substring(with: $0.sourceRange) }.joined()
                let expected = line.filter { !$0.isWhitespace }
                let ok = concat == expected
                if !ok { totalFailed += 1 }
                print(String(
                    format: "line %d: %@ tokens=%d source=%d chars concat=%d chars",
                    idx + 1, ok ? "PASS" : "FAIL", tokens.count,
                    expected.count, concat.count
                ))
                if !ok {
                    print("  expected: \(expected)")
                    print("  got:      \(concat)")
                }
                continue
            }

            print("LINE: \(rawLine)")
            let ns = line as NSString
            for token in tokens {
                let slice = ns.substring(with: token.sourceRange)
                let ws: String
                if token.trailingWhitespace.isEmpty {
                    ws = "-"
                } else if token.trailingWhitespace.contains("\n") {
                    ws = "NL"
                } else {
                    ws = "SP\(token.trailingWhitespace.count)"
                }
                let kind = token.isPunctuation ? "punct" : (token.isWord ? "word" : "other")
                let tag = token.tag.isEmpty ? "-" : token.tag
                let srcMark = slice == token.text ? "=" : "[src=\(slice)]"
                print("  [\(token.sourceRange.location):\(token.sourceRange.location + token.sourceRange.length)] \(kind) tag=\(tag) ws=\(ws) text=\(token.text) \(srcMark)")
            }
        }

        if roundTrip {
            let passed = totalChecked - totalFailed
            print("")
            print("=== round-trip: \(passed)/\(totalChecked) lines passed ===")
            if totalFailed > 0 {
                throw ExitCode(1)
            }
        }
    }
}
