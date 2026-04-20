import Foundation
import Testing
@testable import TTSHarnessCore

/// Every resolved token reports which tier it came from; this suite
/// pins the expected tier for a curated input so a silent shift — a
/// word dropping from gold to silver, or an entry disappearing entirely
/// — fails the test. `fluidaudio-*` tiers are NOT asserted here because
/// they depend on the user's `~/.cache/fluidaudio` state; the test
/// target has to remain hermetic.
@Suite("LexiconProvenanceTests")
struct LexiconProvenanceTests {

    @Test("Common words resolve from kokorog2p-gold as plain entries")
    func plainWordsLiveInGold() throws {
        for word in ["newspaper", "morning", "apartment"] {
            let hit = try #require(KokoroLexicon.lookup(word))
            #expect(hit.tier == .kokorog2pGold, "\(word) should come from kokorog2p-gold")
            #expect(hit.variantKey == "-", "\(word) should be a plain (single-variant) entry")
        }
    }

    @Test("POS-keyed entries resolve DEFAULT when no POS hint is given")
    func posKeyedEntryFallsBackToDefault() throws {
        let hit = try #require(KokoroLexicon.lookup("read"))
        #expect(hit.tier == .kokorog2pGold)
        #expect(hit.variantKey == "DEFAULT")
    }

    @Test("Penn VBD variant resolves from kokorog2p-gold")
    func vbdVariantResolves() throws {
        let hit = try #require(KokoroLexicon.lookup("read", pos: .verbPastTense))
        #expect(hit.tier == .kokorog2pGold)
        #expect(hit.variantKey == "VBD")
        #expect(hit.ipa == "ɹˈɛd")
    }

    @Test("Penn VBN variant resolves from kokorog2p-gold")
    func vbnVariantResolves() throws {
        let hit = try #require(KokoroLexicon.lookup("read", pos: .verbPastParticiple))
        #expect(hit.tier == .kokorog2pGold)
        #expect(hit.variantKey == "VBN")
    }

    @Test("Homograph resolver tags provenance with the variant key")
    func homographProvenanceCarriesVariant() throws {
        let plan = KokoroG2P.resolve("I read the letter yesterday before dinner.")
        let override = try #require(plan.overrides.first { $0.word == "read" })
        #expect(override.reason == .pennContext)
        guard case let .lexicon(tier, variant) = override.provenance else {
            Issue.record("expected .lexicon provenance, got \(override.provenance)")
            return
        }
        #expect(tier == .kokorog2pGold)
        #expect(variant == "VBD")
    }

    @Test("Hand-tuned overlay wins for 'live'")
    func handTunedOverlayFires() throws {
        let plan = KokoroG2P.resolve("We live in a small apartment near the park.")
        let override = try #require(plan.overrides.first { $0.word == "live" })
        #expect(override.reason == .homograph)
        guard case .handTunedOverlay = override.provenance else {
            Issue.record("'live' should resolve via the hand-tuned overlay, got \(override.provenance)")
            return
        }
    }

    @Test("Unknown words produce a miss (no hit)")
    func missingWordReturnsNil() {
        // Nonce word the dict cannot plausibly contain.
        #expect(KokoroLexicon.lookup("zzqxflomp") == nil)
    }

    @Test("Diagnostics snapshot reports non-empty gold + silver tiers")
    func bundledTiersLoaded() {
        let snap = KokoroLexicon.diagnosticsSnapshot
        #expect((snap[.kokorog2pGold] ?? 0) > 50_000,
                "gold tier should be the full ~90k+ kokorog2p dict")
        #expect((snap[.kokorog2pSilver] ?? 0) > 50_000,
                "silver tier should be the full ~93k+ kokorog2p dict")
    }
}
