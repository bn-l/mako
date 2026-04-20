import Foundation
import Testing
@testable import TTSHarnessCore

/// Hard-gate tests for the Phase 8 ported pipeline (KokoroG2P.resolve →
/// emit → compensatorsOnly). Each phrase asserts the exact normalized
/// SSML; any refactor that alters output must update these goldens with
/// explicit justification.
@Suite("NormalizerOutputTests")
struct NormalizerOutputTests {

    private static func port(_ text: String) -> String {
        let plan = KokoroG2P.resolve(text)
        let emitted = KokoroG2P.emit(plan)
        return KokoroSSMLNormalizer.compensatorsOnly(emitted.annotatedText)
    }

    @Test(arguments: [
        // Times — meridiem handling
        (input: "I woke at 5:30 a.m. My alarm was loud.",
         expected: #"I woke at <sub alias="5 30 A M. …">5:30 a.m.</sub> My alarm was loud."#),
        (input: "The meeting ended at 6:47 p.m., finally.",
         expected: #"The meeting ended at <sub alias="6 47 P M">6:47 p.m.</sub>, finally."#),
        (input: "She set her alarm for 5:30 a.m.",
         expected: #"She set her alarm for <sub alias="5 30 A M">5:30 a.m.</sub>"#),

        // Currency
        (input: "The bill came to $47.99.",
         expected: #"The bill came to <sub alias="forty seven dollars and ninety nine cents">$47.99</sub>."#),
        (input: "The laptop cost £129.00 after tax.",
         expected: #"The laptop cost <sub alias="one hundred twenty nine pounds">£129.00</sub> after tax."#),
        (input: "The tip was €65.",
         expected: #"The tip was <sub alias="sixty five euros">€65</sub>."#),

        // Units
        (input: "The processor runs at 3 Hz today.",
         expected: #"The processor runs at <sub alias="three hertz">3 Hz</sub> today."#),
        (input: "The dose is 200 mg per pill.",
         expected: #"The dose is <sub alias="two hundred milligrams">200 mg</sub> per pill."#),

        // Ordinals
        (input: "The runner hit the 100th mile.",
         expected: #"The runner hit the <sub alias="one hundredth">100th</sub> mile."#),
        (input: "The 5th metatarsal ached.",
         expected: #"The <sub alias="fifth">5th</sub> metatarsal ached."#),
        (input: "Her 23rd birthday fell on a Sunday.",
         expected: #"Her <sub alias="twenty third">23rd</sub> birthday fell on a Sunday."#),

        // Ratio + percent
        (input: "The ratio was 2:1 in our favor.",
         expected: #"The ratio was <sub alias="two to one">2:1</sub> in our favor."#),
        (input: "Turnout climbed to 60%.",
         expected: #"Turnout climbed to <sub alias="sixty percent">60%</sub>."#),

        // Temperatures — both degree glyphs
        (input: "It was 98°F outside.",
         expected: #"It was <sub alias="ninety eight degrees Fahrenheit">98°F</sub> outside."#),
        (input: "It was 98ºF outside.",
         expected: #"It was <sub alias="ninety eight degrees Fahrenheit">98ºF</sub> outside."#),

        // Room codes — require place-noun prelude
        (input: "Park near building 12C today.",
         expected: #"Park near building <sub alias="12 see">12C</sub> today."#),

        // Hyphenated compounds
        (input: "The state-of-the-art system shipped.",
         expected: #"The <sub alias="state of the art">state-of-the-art</sub> system shipped."#),
        (input: "She called her mother-in-law.",
         expected: #"She called her <sub alias="mother in law">mother-in-law</sub>."#),

        // Celtic names
        (input: "Mr. McAllister arrived early.",
         expected: #"<sub alias="Mister">Mr.</sub> <sub alias="Mackallister">McAllister</sub> arrived early."#),
        (input: "Dr. Saoirse O'Malley took the call.",
         expected: #"<sub alias="Doctor">Dr.</sub> Saoirse <sub alias="Oh Malley">O'Malley</sub> took the call."#),

        // Technical aliases
        (input: "The IPv6 spec was finalized.",
         expected: #"The <sub alias="I P version six">IPv6</sub> spec was finalized."#),
        (input: "A.I. is changing everything.",
         expected: #"<sub alias="A I">A.I.</sub> is changing everything."#),

        // Years — cue-word
        (input: "She was born in 1999.",
         expected: #"She was born in <sub alias="nineteen ninety nine">1999</sub>."#),
        (input: "The reunion is in 2026.",
         expected: #"The reunion is in <sub alias="twenty twenty six">2026</sub>."#),
        (input: "She graduated in 1905.",
         expected: #"She graduated in <sub alias="nineteen oh five">1905</sub>."#),

        // Years — month name (month stays verbatim; year is wrapped).
        (input: "We met in September 2026.",
         expected: #"We met in September <sub alias="twenty twenty six">2026</sub>."#),

        // Years — decade form
        (input: "They formed in the 1990s.",
         expected: #"They formed in the <sub alias="nineteen nineties">1990s</sub>."#),

        // Dimensions — × and x variants both resolve to "by"
        (input: "Print it on 8.5×11 paper.",
         expected: #"Print it on <sub alias="eight point five by eleven">8.5x11</sub> paper."#),
        (input: "Print it on 8.5x11 paper.",
         expected: #"Print it on <sub alias="eight point five by eleven">8.5x11</sub> paper."#),

        // Ranges — en-dash / em-dash; trailing unit absorbed
        (input: "Wait 250–500 ms before retrying.",
         expected: #"Wait <sub alias="two hundred fifty to five hundred milliseconds">250—500 ms</sub> before retrying."#),
        (input: "Rate it on a 1–10 scale.",
         expected: #"Rate it on a <sub alias="one to ten">1—10</sub> scale."#),

        // Fractions / scores. `overall` lands as a markdown IPA override
        // via the plain-lookup path — stable behaviour, pinned here.
        (input: "She scored 8/10 overall.",
         expected: #"She scored <sub alias="eight out of ten">8/10</sub> [overall](/ˈ O v ə ɹ ˌ ɔ l/)."#),
    ])
    func portedNormalizedSSMLMatches(input: String, expected: String) {
        let actual = Self.port(input)
        #expect(actual == expected, "pipeline diverged for input: \(input)")
    }

    // A couple of phrases that exercise the markdown IPA (occurrence-keyed)
    // emission path. Golden IPA values sourced from the lexicon, so they
    // stay stable across reshuffles of the non-phonetic compensators.
    @Test("O'Brien resolves as a markdown IPA override")
    func oBrienIsOverride() {
        let actual = Self.port("Mr. O'Brien greeted us at the door.")
        let expected =
            #"<sub alias="Mister">Mr.</sub> [O'Brien](/O b ɹ ˈ I ə n/) greeted us at the door."#
        #expect(actual == expected)
    }

    @Test("A.I. sub does not become an IPA override")
    func technicalAliasStaysStructural() {
        let actual = Self.port("A.I. is changing everything.")
        #expect(actual.contains(#"<sub alias="A I">A.I.</sub>"#))
        #expect(!actual.contains("[A.I."))
    }
}
