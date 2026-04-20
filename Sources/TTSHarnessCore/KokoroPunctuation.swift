import Foundation

/// Swift port of `kokorog2p/punctuation.py`. Normalizes Unicode
/// punctuation to the limited set Kokoro's vocabulary recognises
/// (`; : , . ! ? — … " ( ) " "`) and collapses multi-character sequences
/// (`...` → `…`, `--` → `—`, ` - ` → ` — `) to single marks.
///
/// Exposed independently of the tokenizer so other pipeline stages can
/// run it eagerly — e.g. before SSML wrapping, where a curly quote in
/// an alias attribute would otherwise leak through unchanged.
public enum KokoroPunctuation {

    /// Punctuation marks in Kokoro's vocabulary (mirrors upstream
    /// `KOKORO_PUNCTUATION`). Everything else is either normalized to
    /// one of these or dropped.
    public static let kokoroMarks: Set<Character> = [
        ";", ":", ",", ".", "!", "?",
        "\u{2014}",  // — em-dash
        "\u{2026}",  // … ellipsis
        "\"", "(", ")",
        "\u{201C}",  // left curly
        "\u{201D}",  // right curly
    ]

    /// Single-character map. Values of `" "` mean "replace with space"
    /// (safer than deletion — prevents `hello/world` → `helloworld`).
    private static let charMap: [Character: String] = {
        var m: [Character: String] = [:]
        // Apostrophes → ASCII apostrophe.
        for ch in ["\u{2019}", "\u{2018}", "`", "\u{00B4}", "\u{02B9}", "\u{2032}", "\u{FF07}"] {
            m[Character(ch)] = "'"
        }
        // Dashes → em-dash.
        for ch in ["\u{2013}", "\u{2212}", "\u{2015}", "\u{2012}", "\u{2E3A}", "\u{2E3B}"] {
            m[Character(ch)] = "\u{2014}"
        }
        // Exotic quotes → straight double quote.
        for ch in ["\u{201A}", "\u{201B}", "\u{201E}", "\u{201F}",
                   "\u{00AB}", "\u{00BB}", "\u{2039}", "\u{203A}",
                   "\u{300C}", "\u{300D}", "\u{300E}", "\u{300F}",
                   "\u{300A}", "\u{300B}"] {
            m[Character(ch)] = "\""
        }
        // Fullwidth / ideographic punctuation.
        m["\u{FF1B}"] = ";"   // ；
        m["\u{FF1A}"] = ":"   // ：
        m["\u{FE30}"] = ":"   // ︰
        m["\u{FF0C}"] = ","   // ，
        m["\u{3001}"] = ","   // 、
        m["\u{FF0E}"] = "."   // ．
        m["\u{3002}"] = "."   // 。
        m["\u{FF61}"] = "."   // ｡
        m["\u{FF01}"] = "!"   // ！
        m["\u{FF1F}"] = "?"   // ？
        m["\u{00A1}"] = "!"   // ¡ (inverted — common in Spanish prose)
        m["\u{00BF}"] = "?"   // ¿
        m["\u{2049}"] = "?"   // ⁉
        m["\u{2048}"] = "!"   // ⁈
        m["\u{203C}"] = "!"   // ‼
        m["\u{2E2E}"] = "?"   // ⸮
        // Brackets → parentheses.
        for ch in ["\u{FF3B}", "\u{3010}", "\u{3014}", "\u{3008}",
                   "\u{FF5B}", "\u{FF08}", "[", "{"] {
            m[Character(ch)] = "("
        }
        for ch in ["\u{FF3D}", "\u{3011}", "\u{3015}", "\u{3009}",
                   "\u{FF5D}", "\u{FF09}", "]", "}"] {
            m[Character(ch)] = ")"
        }
        // Fullwidth variants of semantically-meaningful ASCII → ASCII.
        // Downstream stages (SSML normalizer, number expander, URL/email
        // wrappers) rely on the ASCII form, so mapping rather than dropping
        // keeps them functional if the pipeline ever sees fullwidth input.
        m["\u{FF03}"] = "#"   // ＃
        m["\u{FF04}"] = "$"   // ＄
        m["\u{FF05}"] = "%"   // ％
        m["\u{FF06}"] = "&"   // ＆
        m["\u{FF0A}"] = "*"   // ＊
        m["\u{FF0B}"] = "+"   // ＋
        m["\u{FF1D}"] = "="   // ＝
        m["\u{FF20}"] = "@"   // ＠
        m["\u{FF3F}"] = "_"   // ＿
        // Dimension separator. `8.5×11` reads as "eight point five by eleven"
        // only if a downstream wrapper can see an `x` between the digits —
        // the glyph must survive KokoroPunctuation's strip pass.
        m["\u{00D7}"] = "x"   // ×
        // Purely decorative / layout-only characters → space. ASCII chars
        // that still carry semantic weight (`@#$%&*+/=_°`) are deliberately
        // left untouched so downstream stages (Phase 7 normalize→tokenize,
        // Phase 4 number/SSML wrappers) can pattern-match them. The only
        // ASCII entries here are genuinely noise-glyphs in prose.
        let remove = "~^\\|<>"
            + "\u{FF5E}\u{FF3E}\u{FF5C}\u{FF1C}\u{FF1E}"
            + "\u{2020}\u{2021}\u{00A7}\u{00B6}\u{2022}\u{00B7}\u{00B1}\u{00F7}\u{00A9}\u{00AE}\u{2122}"
            + "\u{2192}\u{2190}\u{2191}\u{2193}\u{2194}\u{2195}"
        for ch in remove {
            if m[ch] == nil { m[ch] = " " }
        }
        return m
    }()

    /// Multi-character sequences (`...`, `--`, etc.) → single
    /// Kokoro-compatible marks. Order matters — alternation picks the
    /// first successful match.
    private static let sequencePattern: NSRegularExpression = {
        // ICU's named-capture grammar is `[A-Za-z][A-Za-z0-9]*` — no
        // underscores — so camelCase the group names.
        let pattern =
            "(?<spacedEllipsis>\\s*\\.\\s+\\.\\s+\\.\\s*)"           // ". . ."
            + "|(?<dotRun>\\.{2,})"                                  // "..", "..."
            + "|(?<fullwidthDotRun>\u{FF0E}{2,})"                    // "．．"
            + "|(?<middleDotRun>\u{30FB}{3,})"                       // "・・・"
            + "|(?<spacedDoubleHyphen>\\s+--\\s+)"                   // " -- "
            + "|(?<doubleHyphen>--)"                                 // "--"
            + "|(?<spacedHyphen>\\s+-\\s+)"                          // " - "
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Normalize `text` in-place: collapse multi-char sequences, then
    /// translate exotic single characters. The return is safe to feed
    /// into any downstream span wrapper — every remaining punctuation
    /// character is in `kokoroMarks`, so SSML attributes built from the
    /// output won't contain a stray curly quote.
    public static func normalize(_ text: String) -> String {
        let ns = text as NSString
        let matches = sequencePattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var collapsed = text
        for match in matches.reversed() {
            guard let r = Range(match.range, in: collapsed) else { continue }
            let slice = String(collapsed[r])
            let replacement: String
            switch kindOf(match: match, in: ns) {
            case .ellipsis: replacement = "\u{2026}"
            case .spacedDash: replacement = " \u{2014} "
            case .doubleHyphen: replacement = "\u{2014}"
            case .other: replacement = slice
            }
            collapsed.replaceSubrange(r, with: replacement)
        }
        var out = String()
        out.reserveCapacity(collapsed.count)
        for ch in collapsed {
            if let replacement = charMap[ch] {
                out.append(replacement)
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private enum MatchKind { case ellipsis, spacedDash, doubleHyphen, other }

    private static let ellipsisGroups = [
        "spacedEllipsis", "dotRun", "fullwidthDotRun", "middleDotRun",
    ]
    private static let spacedDashGroups = ["spacedDoubleHyphen", "spacedHyphen"]

    private static func kindOf(match: NSTextCheckingResult, in ns: NSString) -> MatchKind {
        for name in ellipsisGroups {
            if match.range(withName: name).location != NSNotFound { return .ellipsis }
        }
        for name in spacedDashGroups {
            if match.range(withName: name).location != NSNotFound { return .spacedDash }
        }
        if match.range(withName: "doubleHyphen").location != NSNotFound { return .doubleHyphen }
        return .other
    }
}
