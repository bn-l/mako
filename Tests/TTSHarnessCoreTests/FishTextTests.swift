import Foundation
import Testing
@testable import TTSHarnessCore

/// Unit tests for `FishText`, the text preparation behind `mako say --hq`.
///
/// Two things here can fail silently in a way nobody notices until they hear the audio:
/// a marker that survives into the text gets *read aloud*, and a turn over the byte
/// budget gets truncated mid-sentence by `max_tokens`. Both are covered.
@Suite("FishText")
struct FishTextTests {

    // MARK: - Markers

    @Test("markers are stripped by default")
    func stripsMarkers() {
        #expect(FishText.stripMarkers("[warm] Hello there.", keepMarkers: false)
                == "Hello there.")
    }

    @Test("markers survive when asked for")
    func keepsMarkers() {
        #expect(FishText.stripMarkers("[warm] Hello there.", keepMarkers: true)
                == "[warm] Hello there.")
    }

    @Test("sigh is banned whether or not markers are kept",
          arguments: [true, false])
    func banishesSigh(keep: Bool) {
        let out = FishText.stripMarkers("Right. [sigh] Fine.", keepMarkers: keep)
        #expect(!out.lowercased().contains("sigh"))
        #expect(out == "Right. Fine.")
    }

    @Test("sigh is banned in every spelling it turns up in",
          arguments: ["[sigh]", "[sighing]", "[SIGH]", "[deep sigh]", "[sad][sighing]",
                      "(sigh)", "(sighing)"])
    func banishesSighVariants(spelling: String) {
        let out = FishText.stripMarkers("A \(spelling) B", keepMarkers: true)
        #expect(!out.lowercased().contains("sigh"))
    }

    /// The ban must not reach into words that merely contain the letters. Silently
    /// deleting a legitimate marker is its own bug, and a quiet one.
    @Test("markers that only contain the substring survive",
          arguments: ["[insightful tone]", "[sight unseen]", "[foresight]"])
    func doesNotOvermatchSigh(marker: String) {
        let out = FishText.stripMarkers("A \(marker) B", keepMarkers: true)
        #expect(out == "A \(marker) B")
    }

    /// An LLM writing prose is far likelier to produce a stray `[` than a 200-character
    /// marker, and an unbounded pattern would eat everything up to the next `]`.
    @Test("an unterminated bracket is left alone")
    func leavesUnterminatedBracketIntact() {
        let text = "The array index [0 is wrong and the rest of this sentence matters."
        #expect(FishText.stripMarkers(text, keepMarkers: false) == text)
    }

    @Test("an over-long bracketed span is not treated as a marker")
    func leavesOverlongSpanIntact() {
        let long = "[" + String(repeating: "x", count: 61) + "]"
        #expect(FishText.stripMarkers(long + " tail", keepMarkers: false) == long + " tail")
    }

    @Test("stripping does not leave double spaces behind")
    func tidiesWhitespace() {
        #expect(FishText.stripMarkers("Yes [laughing] no.", keepMarkers: false)
                == "Yes no.")
    }

    // MARK: - Normalization

    /// The normalizer speaks SSML because Kokoro's downstream layer does. Fish does not,
    /// and would read the tag out loud.
    @Test("alias spans collapse to their spoken form")
    func flattensAliasSpans() {
        let ssml = #"She paid <sub alias="forty two dollars">$42</sub> for it."#
        #expect(FishText.flattenAliases(ssml) == "She paid forty two dollars for it.")
    }

    @Test("no SSML survives normalization")
    func normalizationLeavesNoMarkup() {
        let out = FishText.prepare(
            "Dr. Vale paid $1,234.56 on the 3rd.",
            keepMarkers: false, normalize: true, maxTurnBytes: 400)
        #expect(!out.contains("<"))
        #expect(out.contains("Doctor"))
        #expect(out.contains("dollars"))
    }

    /// Raw text is the default because every render judged during the bakeoff went in
    /// that way, and fish reads these forms natively.
    @Test("normalization is off by default")
    func rawByDefault() {
        let text = "Dr. Vale paid $1,234.56."
        #expect(FishText.prepare(text, keepMarkers: false, normalize: false,
                                 maxTurnBytes: 400) == text)
    }

    // MARK: - Segmentation

    @Test("one paragraph makes one turn")
    func paragraphPerTurn() {
        let turns = FishText.segment("First one.\n\nSecond one.", maxTurnBytes: 400)
        #expect(turns == ["First one.", "Second one."])
    }

    @Test("blank-line runs of any size separate turns")
    func toleratesRaggedBlankLines() {
        let turns = FishText.segment("A.\n   \n\n\nB.", maxTurnBytes: 400)
        #expect(turns == ["A.", "B."])
    }

    /// `group_turns_into_batches` will not split an oversized turn, and `max_tokens` then
    /// truncates the batch — so a long paragraph would lose its tail without a word of
    /// warning. This is the test that guards against that.
    @Test("no turn ever exceeds the byte budget")
    func respectsByteBudget() {
        let paragraph = String(repeating: "Dr. Vale checked the 7:03 a.m. train. ", count: 40)
        let turns = FishText.segment(paragraph, maxTurnBytes: 400)
        #expect(turns.count > 1)
        for turn in turns {
            #expect(turn.utf8.count <= 400)
        }
    }

    @Test("subdividing does not lose or reorder any words")
    func subdivisionPreservesText() {
        let paragraph = String(repeating: "Dr. Vale checked the 7:03 a.m. train. ", count: 40)
        let rejoined = FishText.segment(paragraph, maxTurnBytes: 400).joined(separator: " ")
        #expect(rejoined.split(separator: " ") == paragraph.split(separator: " "))
    }

    /// A naive `[.!?]` split turns `2.7` into `2. 7` and `a.m.` into `a. m.`, which
    /// changes what gets spoken. `NLTokenizer` is used precisely to avoid that.
    @Test("subdivision does not split inside abbreviations or decimals")
    func doesNotSplitInsideTokens() {
        let paragraph = String(repeating: "The 2.7 kg parcel left at 7:03 a.m. sharp. ",
                               count: 20)
        for turn in FishText.segment(paragraph, maxTurnBytes: 400) {
            #expect(!turn.hasSuffix("2."))
            #expect(!turn.hasSuffix("a."))
            #expect(!turn.hasPrefix("7 kg"))
            #expect(!turn.hasPrefix("m."))
        }
    }

    /// Last resort: no sentence boundary to cut on, and still no oversized turn.
    @Test("a single sentence over budget falls back to packing words")
    func packsWordsWhenASentenceIsTooLong() {
        let runOn = String(repeating: "word ", count: 200) + "end."
        let turns = FishText.segment(runOn, maxTurnBytes: 400)
        #expect(turns.count > 1)
        for turn in turns {
            #expect(turn.utf8.count <= 400)
        }
    }

    @Test("empty input produces no turns")
    func emptyInput() {
        #expect(FishText.segment("   \n\n  ", maxTurnBytes: 400).isEmpty)
    }
}
