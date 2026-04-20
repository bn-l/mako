import Foundation
import Testing
@testable import TTSHarnessCore

/// Checkpoint-F round-trip invariant: concatenating every token's
/// `sourceRange` substring (in order) must equal the input minus the
/// inter-token whitespace. Exercised across all nine bundled fixtures
/// — the tokenizer promises this contract for arbitrary prose.
@Suite("TokenSpanTests")
struct TokenSpanTests {

    /// `Passage.bundledNames` covers the eight prose fixtures; the
    /// homograph fixture corpus is a separate resource but deserves the
    /// same round-trip gate.
    static let fixtureNames: [String] = Passage.bundledNames + ["homographs"]

    @Test(arguments: fixtureNames)
    func roundTripHoldsOnBundledFixture(_ name: String) throws {
        let passage = try Passage.loadFixture(name)
        var failures = 0
        for (lineNo, rawLine) in passage.components(separatedBy: .newlines).enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard !trimmed.hasPrefix("===") && !trimmed.hasPrefix("---") else { continue }

            let tokens = KokoroTokenizer.tokenize(rawLine, posTag: false)
            let ns = rawLine as NSString
            let concatenated = tokens
                .map { ns.substring(with: $0.sourceRange) }
                .joined()
            let expected = rawLine.filter { !$0.isWhitespace }
            if concatenated != expected {
                failures += 1
                let detail = """
                    \(name):\(lineNo + 1) round-trip failed
                        expected: \(expected)
                        actual:   \(concatenated)
                    """
                Issue.record(Comment(rawValue: detail))
            }
        }
        #expect(failures == 0, "\(failures) round-trip failure(s) in \(name)")
    }
}
