import Foundation

// Duplicated from KittenTTS-swift (internal), Apache 2.0.
// Maps IPA phoneme strings to the integer token sequences the CoreML model expects.
// Symbol table must be identical to the upstream Python / Swift implementation.
enum KittenTextCleaner {
    // Symbol table matches upstream KittenML/KittenTTS kittentts/onnx_model.py EXACTLY.
    // In particular: straight quotes (U+0022 × 3 in punctuation, U+0027 × 2 in IPA),
    // NOT the curly quotes (U+201C/U+201D/U+2019/U+2018) that appear in the KittenTTS-swift
    // port — that mismatch produces silently-dropped or wrongly-tokenised phonemes.
    private static let pad: Character = "$"
    private static let punctuation: String = ";:,.!?¡¿—…\"«»\"\" "
    private static let lettersUpper: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private static let lettersLower: String = "abcdefghijklmnopqrstuvwxyz"
    private static let ipaSymbols: String =
        "ɑɐɒæɓʙβɔɕçɗɖðʤəɘɚɛɜɝɞɟʄɡɠɢʛɦɧħɥʜɨɪʝɭɬɫɮʟɱɯɰŋɳɲɴøɵɸθœɶʘɹɺɾɻʀʁɽʂʃʈʧʉʊʋⱱʌɣɤʍχʎʏʑʐʒʔʡʕʢǀǁǂǃˈˌːˑʼʴʰʱʲʷˠˤ˞↓↑→↗↘'\u{0329}'ᵻ"

    static let startTokenID: Int64 = 0
    static let endTokenID: Int64 = 10
    static let padTokenID: Int64 = 0

    private static let symbolIndex: [Unicode.Scalar: Int] = {
        let all = String(pad) + punctuation + lettersUpper + lettersLower + ipaSymbols
        var map: [Unicode.Scalar: Int] = [:]
        for (i, scalar) in all.unicodeScalars.enumerated() {
            map[scalar] = i
        }
        return map
    }()

    static func encode(_ phonemes: String) -> [Int64] {
        encodeWithLog(phonemes).tokens
    }

    /// Encode and also return the set of scalars that were dropped because
    /// they aren't in the symbol table (diagnostic).
    static func encodeWithLog(_ phonemes: String) -> (tokens: [Int64], dropped: Set<Unicode.Scalar>) {
        var tokens: [Int64] = [startTokenID]
        var dropped: Set<Unicode.Scalar> = []
        for scalar in phonemes.unicodeScalars {
            if let idx = symbolIndex[scalar] {
                tokens.append(Int64(idx))
            } else {
                dropped.insert(scalar)
            }
        }
        tokens.append(endTokenID)
        tokens.append(padTokenID)
        return (tokens, dropped)
    }
}
