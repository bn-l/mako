import Foundation
import Testing
@testable import TTSHarnessCore

/// Gate on homograph resolution. Each probe pins the IPA the ported
/// pipeline MUST emit (or explicitly NOT emit an override for) on a
/// sentence drawn from the Phase 0 homograph fixture. The corpus as a
/// whole contains some cases NLTagger cannot currently disambiguate —
/// those are intentionally absent from this gate. Landing new cues in
/// `KokoroG2P.resolveHomograph` should add probes here, not relax them.
@Suite("POSDecisionTests")
struct POSDecisionTests {

    struct Probe: Sendable {
        let sentence: String
        let word: String
        let expectedIPA: String
        let reason: KokoroG2P.OverrideReason
    }

    static let probes: [Probe] = [
        // read — Penn-context cues
        Probe(sentence: "I read the letter yesterday before dinner.",
              word: "read", expectedIPA: "ɹˈɛd", reason: .pennContext),
        Probe(sentence: "She had read every book on the shelf.",
              word: "read", expectedIPA: "ɹˈɛd", reason: .pennContext),
        Probe(sentence: "I read the newspaper every morning.",
              word: "read", expectedIPA: "ɹˈid", reason: .homograph),

        // wind — hand-tuned overlay (NLTagger-driven)
        Probe(sentence: "The wind blew across the field.",
              word: "wind", expectedIPA: "wˈɪnd", reason: .homograph),
        Probe(sentence: "She will wind the thread onto a spool.",
              word: "wind", expectedIPA: "wˈInd", reason: .homograph),

        // live — hand-tuned overlay
        Probe(sentence: "They broadcast the live concert nationwide.",
              word: "live", expectedIPA: "lˈIv", reason: .homograph),
        Probe(sentence: "We live in a small apartment near the park.",
              word: "live", expectedIPA: "lˈɪv", reason: .homograph),

        // lead / tear — hand-tuned
        Probe(sentence: "The pipes were made of lead.",
              word: "lead", expectedIPA: "lˈɛd", reason: .homograph),
        Probe(sentence: "Let me lead the way out of here.",
              word: "lead", expectedIPA: "lˈid", reason: .homograph),
        Probe(sentence: "A single tear ran down her cheek.",
              word: "tear", expectedIPA: "tˈɪɹ", reason: .homograph),
        Probe(sentence: "Please do not tear the paper.",
              word: "tear", expectedIPA: "tˈɛɹ", reason: .homograph),

        // contract / project / progress / permit / present — plural-subject
        // verb promotion (Phase 8 P1). Noun side uses the DEFAULT IPA.
        Probe(sentence: "Muscles contract when stimulated.",
              word: "contract", expectedIPA: "kəntɹˈækt", reason: .homograph),
        Probe(sentence: "He signed the contract in blue ink.",
              word: "contract", expectedIPA: "kˈɑntɹˌækt", reason: .homograph),
        Probe(sentence: "Models project sales will rise.",
              word: "project", expectedIPA: "pɹəʤˈɛkt", reason: .homograph),
        Probe(sentence: "The project is behind schedule.",
              word: "project", expectedIPA: "pɹˈɑʤˌɛkt", reason: .homograph),
        Probe(sentence: "Trainees progress through the levels slowly.",
              word: "progress", expectedIPA: "pɹəɡɹˈɛs", reason: .homograph),
        Probe(sentence: "The progress report is due Friday.",
              word: "progress", expectedIPA: "pɹˈɑɡɹəs", reason: .homograph),
        Probe(sentence: "Regulations permit two pets per unit.",
              word: "permit", expectedIPA: "pəɹmˈɪt", reason: .homograph),
        Probe(sentence: "The parking permit is on the dashboard.",
              word: "permit", expectedIPA: "pˈɜɹmɪt", reason: .homograph),
        Probe(sentence: "Consultants present their reports to the board.",
              word: "present", expectedIPA: "pɹizˈɛnt", reason: .homograph),
        Probe(sentence: "The present situation is tense.",
              word: "present", expectedIPA: "pɹˈɛzᵊnt", reason: .homograph),

        // used — Penn-context habitual
        Probe(sentence: "We are used to the early shifts.",
              word: "used", expectedIPA: "jˈust", reason: .pennContext),

        // Irregular-plural subjects — the first heuristic only caught
        // regular -s plurals. The clause-local resolver has to read
        // `children`/`women`/`men`/`people` as legitimate plural
        // subjects licensing a verb reading of the homograph.
        Probe(sentence: "Children present awards each year.",
              word: "present", expectedIPA: "pɹizˈɛnt", reason: .homograph),
        Probe(sentence: "People project confidence under pressure.",
              word: "project", expectedIPA: "pɹəʤˈɛkt", reason: .homograph),
        Probe(sentence: "Women record meetings daily.",
              word: "record", expectedIPA: "ɹəkˈɔɹd", reason: .homograph),
        Probe(sentence: "Men lead teams here.",
              word: "lead", expectedIPA: "lˈid", reason: .homograph),
    ]

    @Test(arguments: probes)
    func probeResolvesExpectedVariant(_ probe: Probe) {
        let plan = KokoroG2P.resolve(probe.sentence)
        let matches = plan.overrides.filter { $0.word.lowercased() == probe.word.lowercased() }
        guard let first = matches.first else {
            Issue.record(
                "no override emitted for '\(probe.word)' in: \(probe.sentence)"
            )
            return
        }
        #expect(first.ipa == probe.expectedIPA,
                "IPA mismatch for '\(probe.word)' in: \(probe.sentence)")
        #expect(first.reason == probe.reason,
                "reason mismatch for '\(probe.word)' in: \(probe.sentence)")
    }

    @Test("Regression guards: noun-context homographs stay on DEFAULT")
    func nounContextDoesNotPromoteToVerb() {
        let cases: [(String, String, String)] = [
            // subject-promotion guardrails: singular noun subjects must
            // NOT get promoted, or we regress "The contract expires".
            ("The contract expires in May.", "contract", "kˈɑntɹˌækt"),
            ("Her contract is binding.", "contract", "kˈɑntɹˌækt"),
            ("His present was unexpected.", "present", "pɹˈɛzᵊnt"),
            ("The present moment matters.", "present", "pɹˈɛzᵊnt"),
            // Noun-compound guardrails: `[Det] [plural-Noun] [H] [Noun]
            // [finite-Verb]` is a compound-head subject NP, not a
            // verb frame. The resolver must see the leading Determiner
            // and refuse to promote even though a plural noun sits
            // between Det and H.
            ("The analysts project manager resigned.",
                "project", "pɹˈɑʤˌɛkt"),
            ("The trainees progress report was late.",
                "progress", "pɹˈɑɡɹəs"),
        ]
        for (sentence, word, expectedIPA) in cases {
            let plan = KokoroG2P.resolve(sentence)
            if let hit = plan.overrides.first(where: { $0.word.lowercased() == word }) {
                #expect(hit.ipa == expectedIPA,
                        "'\(word)' should resolve to DEFAULT /\(expectedIPA)/ in: \(sentence), got /\(hit.ipa)/")
            }
            // If no override fires at all, that's also acceptable — BART
            // gets the noun-stress reading for free; the concrete
            // regression this guards is a wrongful VERB promotion.
        }
    }
}

extension POSDecisionTests.Probe: CustomTestStringConvertible {
    var testDescription: String { "\(word) in: \(sentence)" }
}
