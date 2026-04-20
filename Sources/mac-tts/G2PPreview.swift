import Foundation
import ArgumentParser
import TTSHarnessCore

/// Runs text through `KokoroG2P.resolve` and prints the resulting plan
/// — normalized text, per-token resolutions, occurrence-keyed
/// overrides, and structural sub-alias fallbacks. Used to eyeball
/// Phase 7 decisions independent of the SSML emitter or the runner
/// (which is still on the classic path until Phase 8 flips the toggle).
///
/// Usage:
///   mac-tts g2p-preview --file foot-massage.txt
///   echo "I live at 123 Elm Dr." | mac-tts g2p-preview
///   mac-tts g2p-preview --file homographs.txt --counts
struct G2PPreview: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "g2p-preview",
        abstract: "Print KokoroG2P.resolve plan for a line or a file, without synthesis."
    )

    @Option(name: .long, help: "Read input lines from this file (default: stdin).")
    var file: String?

    @Flag(name: .long, help: "Only print aggregate counts per line (override/span/plain/oov).")
    var counts = false

    @Flag(name: .long, help: "Skip per-token dump (still show overrides + spans).")
    var noTokens = false

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

        for (idx, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("===") || trimmed.hasPrefix("---") {
                if !counts { print(rawLine) }
                continue
            }

            let result = KokoroG2P.resolve(rawLine)

            if counts {
                let plainHits = result.tokens.filter { $0.isWord && $0.phonemes != nil }.count
                let oovs = result.tokens.filter { $0.isWord && $0.phonemes == nil
                    && !isCoveredByOverride($0.sourceRange, in: result)
                    && !isCoveredBySpan($0.sourceRange, in: result) }.count
                let homographs = result.overrides.filter { $0.reason == .homograph }.count
                let properNames = result.overrides.filter { $0.reason == .properName }.count
                print(String(
                    format: "line %d: plain=%d hom=%d name=%d span=%d oov=%d",
                    idx + 1, plainHits, homographs, properNames,
                    result.structuralSpans.count, oovs
                ))
                continue
            }

            print("LINE: \(rawLine)")
            if result.originalText != result.normalizedText {
                print("NORM: \(result.normalizedText)")
            }

            if !noTokens {
                let ns = result.normalizedText as NSString
                for token in result.tokens where token.isWord {
                    let slice = ns.substring(with: token.sourceRange)
                    let phon = token.phonemes ?? "—"
                    let coveredByOverride = isCoveredByOverride(token.sourceRange, in: result)
                    let coveredBySpan = isCoveredBySpan(token.sourceRange, in: result)
                    let marker: String
                    if coveredByOverride { marker = "[OVR]" }
                    else if coveredBySpan { marker = "[SPN]" }
                    else if token.phonemes != nil { marker = "[LEX]" }
                    else { marker = "[oov]" }
                    let tag = token.tag.isEmpty ? "-" : token.tag
                    print("  \(marker) [\(token.sourceRange.location):\(token.sourceRange.location + token.sourceRange.length)] \(slice) tag=\(tag) ipa=\(phon)")
                }
            }

            for ov in result.overrides {
                let reason = ov.reason.rawValue
                let prov = describeProvenance(ov.provenance)
                print("  OVERRIDE \(reason) \(ov.word) → /\(ov.ipa)/ (\(prov))")
            }
            for span in result.structuralSpans {
                print("  SPAN \(span.reason.rawValue) \(span.sourceText) → \"\(span.alias)\"")
            }
            print("")
        }
    }

    private func isCoveredByOverride(_ range: NSRange, in result: KokoroG2P.G2PResult) -> Bool {
        result.overrides.contains { NSIntersectionRange($0.sourceRange, range).length > 0 }
    }

    private func isCoveredBySpan(_ range: NSRange, in result: KokoroG2P.G2PResult) -> Bool {
        result.structuralSpans.contains { NSIntersectionRange($0.sourceRange, range).length > 0 }
    }

    private func describeProvenance(_ p: KokoroG2P.Provenance) -> String {
        switch p {
        case let .lexicon(tier, variant):
            return variant == "-" ? tier.rawValue : "\(tier.rawValue):\(variant)"
        case let .celticCompose(tier):
            return "celtic-compose:\(tier.rawValue)"
        case let .celticRespelling(tier):
            return "celtic-respell:\(tier.rawValue)"
        case .handTunedOverlay:
            return "hand-tuned"
        }
    }
}
