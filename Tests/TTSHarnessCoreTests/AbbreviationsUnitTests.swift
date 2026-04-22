import Foundation
import Testing
@testable import TTSHarnessCore

/// Unit tests for `KokoroAbbreviations.expand`. Probes the context
/// detector (St. → Saint vs Street, Dr. → Doctor vs Drive) plus the
/// gating rules (onlyIfFollowedBy, onlyIfPrecededBy) one rule at a time.
@Suite("KokoroAbbreviations")
struct KokoroAbbreviationsTests {

    @Test("Mr. → Mister")
    func mister() {
        let out = KokoroAbbreviations.expand("Mr. Smith arrived.")
        #expect(out.contains(#"<sub alias="Mister">Mr.</sub>"#))
    }

    @Test("Dr. in title context → Doctor")
    func drDoctor() {
        let out = KokoroAbbreviations.expand("Dr. Jones spoke.")
        #expect(out.contains(#"<sub alias="Doctor">Dr.</sub>"#))
    }

    @Test("Dr. after bare street name → Drive")
    func drDrive() {
        let out = KokoroAbbreviations.expand("We live on Oak Dr. nearby.")
        #expect(out.contains(#"<sub alias="Drive">Dr.</sub>"#))
    }

    @Test("St. followed by saint name → Saint")
    func stSaint() {
        let out = KokoroAbbreviations.expand("St. Peter's basilica.")
        #expect(out.contains(#"<sub alias="Saint">St.</sub>"#))
    }

    @Test("St. after ordinal → Street")
    func stStreetOrdinal() {
        let out = KokoroAbbreviations.expand("Turn onto 5th St. today.")
        #expect(out.contains(#"<sub alias="Street">St.</sub>"#))
    }

    @Test("St. after house number → Street")
    func stStreetHouseNumber() {
        let out = KokoroAbbreviations.expand("Meet me at 123 Main St. today.")
        #expect(out.contains(#"<sub alias="Street">St.</sub>"#))
    }

    @Test("Ph.D. dotted acronym → letter spelling")
    func phdDotted() {
        let out = KokoroAbbreviations.expand("A Ph.D. student.")
        #expect(out.contains(#"<sub alias="P H D">Ph.D.</sub>"#))
    }

    @Test("U.S.A. wins over U.S. (longest-first)")
    func longestFirst() {
        let out = KokoroAbbreviations.expand("The U.S.A. wins.")
        #expect(out.contains(#"<sub alias="U S A">U.S.A.</sub>"#))
        #expect(!out.contains(#"<sub alias="U S">U.S.</sub>"#))
    }

    @Test("in. requires preceding digit")
    func inchRequiresDigit() {
        let withDigit = KokoroAbbreviations.expand("about 12 in. of rain")
        #expect(withDigit.contains(#"<sub alias="inch">in.</sub>"#))
        let bare = KokoroAbbreviations.expand("Wizard of Oz.")
        #expect(!bare.contains(#"alias="ounce""#))
    }

    @Test("No. requires following digit")
    func numberRequiresDigit() {
        let withDigit = KokoroAbbreviations.expand("See No. 244 on file.")
        #expect(withDigit.contains(#"<sub alias="number">No.</sub>"#))
        let bare = KokoroAbbreviations.expand("No. whatever.")
        #expect(!bare.contains(#"alias="number""#))
    }

    @Test("Case-sensitive state abbreviation: Pa. matches only capitalized form")
    func stateAbbreviationCaseSensitive() {
        let hit = KokoroAbbreviations.expand("Born in Pa. originally.")
        #expect(hit.contains(#"<sub alias="Pennsylvania">Pa.</sub>"#))
        // lowercase `pa.` is not the state abbreviation and should stay unchanged.
        let miss = KokoroAbbreviations.expand("my pa. said so")
        #expect(!miss.contains(#"alias="Pennsylvania""#))
    }

    @Test("Doesn't double-wrap inside an existing <sub> span")
    func doesNotDoubleWrap() {
        let pre = #"The meeting ended at <sub alias="6 47 P M">6:47 p.m.</sub>."#
        let out = KokoroAbbreviations.expand(pre)
        // p.m. inside the alias/source text should not spawn a nested <sub>.
        let subCount = out.components(separatedBy: "<sub ").count - 1
        #expect(subCount == 1, "expected exactly one <sub>, got \(subCount)")
    }

    @Test("etc. → et cetera")
    func etc() {
        let out = KokoroAbbreviations.expand("apples, pears, etc.")
        #expect(out.contains(#"<sub alias="et cetera">etc.</sub>"#))
    }

    @Test("e.g. multi-dot dotted acronym")
    func exempliGratia() {
        let out = KokoroAbbreviations.expand("fruits, e.g. apples")
        #expect(out.contains(#"<sub alias="for example">e.g.</sub>"#))
    }

    @Test("Multi-dot acronym at sentence boundary gets ellipsis tail")
    func multiDotBoundaryEllipsis() {
        // The ellipsis tail only fires when the following sentence
        // starts with a capital letter — otherwise there's no sentence
        // boundary to protect the acronym's last letter from fusing.
        let out = KokoroAbbreviations.expand("We need a Ph.D. Someone qualified.")
        #expect(out.contains(#"alias="P H D. …""#))
    }

    @Test("Multi-dot acronym followed by lowercase does NOT get ellipsis tail")
    func multiDotBoundaryNoEllipsisLowercase() {
        let out = KokoroAbbreviations.expand("A.I. is changing everything.")
        #expect(out.contains(#"<sub alias="A I">A.I.</sub>"#))
        #expect(!out.contains(#"alias="A I. …""#))
    }

    @Test("Single-dot honorific at sentence boundary does NOT get ellipsis tail")
    func honorificBoundaryNoEllipsis() {
        let out = KokoroAbbreviations.expand("Mr. Smith left.")
        // Mr. should remain a plain title, no `. …` appended.
        #expect(out.contains(#"<sub alias="Mister">Mr.</sub>"#))
        #expect(!out.contains(#"alias="Mister. …""#))
    }
}
