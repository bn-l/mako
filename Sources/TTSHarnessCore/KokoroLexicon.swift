import Foundation

/// Tiered pronunciation-dictionary lookup for the Kokoro TTS path.
///
/// Tiers, in order of precedence:
///   1. `kokorog2p-gold`   — `Resources/kokorog2p/us_gold.json`
///   2. `kokorog2p-silver` — `Resources/kokorog2p/us_silver.json`
///   3. `fluidaudio-gold`   — `~/.cache/fluidaudio/Models/kokoro/us_gold.json`
///                           (compatibility tier, retiring)
///   4. `fluidaudio-silver` — `~/.cache/fluidaudio/Models/kokoro/us_silver.json`
///
/// The bundled kokorog2p dicts are the authority. The FluidAudio-cached
/// tiers exist to avoid regressing words present there but missing from
/// kokorog2p during the port's rollout; every hit on them is logged so
/// we can watch the set shrink and eventually retire the tier.
///
/// A miss is a miss — there is no BART tier here. BART is reached by
/// simply not emitting an override.
public enum KokoroLexicon {

    /// Canonical POS keys that kokorog2p and Misaki use in their
    /// variant-keyed entries. String-backed so callers can pass the
    /// raw dict keys directly; typed so we can reason about the Penn
    /// → universal collapse.
    public enum POSKey: String, Sendable, CaseIterable {
        case defaultVariant = "DEFAULT"
        case noun = "NOUN"
        case verb = "VERB"
        case adjective = "ADJ"
        case adverb = "ADV"
        case determiner = "DT"
        case verbPastTense = "VBD"
        case verbPresentNon3sg = "VBP"
        case verbPastParticiple = "VBN"
        /// The literal `None` variant key that Misaki reserves for stressed
        /// forms of function words (be/can/have/…). Default lookup never
        /// returns this; reach it only via an explicit caller pass.
        case stressed = "None"

        /// Penn-style collapse: VB*→VERB. NN* / JJ* / RB* are not stored
        /// as Penn tags in the US dicts so they map back to themselves.
        public var parent: POSKey {
            switch self {
            case .verbPastTense, .verbPresentNon3sg, .verbPastParticiple:
                return .verb
            default:
                return self
            }
        }
    }

    /// Which file a hit came from. Consumers log this to track retirement
    /// of the compatibility tiers.
    public enum LexiconTier: String, Sendable, CaseIterable {
        case kokorog2pGold = "kokorog2p-gold"
        case kokorog2pSilver = "kokorog2p-silver"
        case fluidAudioGold = "fluidaudio-gold"
        case fluidAudioSilver = "fluidaudio-silver"
    }

    /// A successful lookup.
    public struct Hit: Sendable {
        /// Per-Kokoro-vocab phoneme tokens (one per Unicode scalar of `ipa`).
        public let tokens: [String]
        /// Raw IPA string, concatenated from `tokens`.
        public let ipa: String
        /// The tier the entry was read from.
        public let tier: LexiconTier
        /// `"-"` for a plain single-variant entry, or the variant key
        /// (`DEFAULT`/`NOUN`/…) that matched for POS-keyed entries.
        public let variantKey: String
    }

    // MARK: - Public API

    /// Look up `word`, optionally steering to a POS variant.
    ///
    /// Variant-resolution order when the entry is POS-keyed:
    ///   1. `pos` itself (e.g. `VBD`).
    ///   2. `pos.parent` (`VBD` → `VERB`).
    ///   3. `DEFAULT`.
    /// If any of (1)–(2) resolves to an **explicit** null IPA (a legitimate
    /// "no variant-specific pronunciation" signal in the data), lookup
    /// falls through to the next step rather than returning nil. If
    /// `DEFAULT` itself is null and no non-null variant remains, the
    /// lookup returns nil.
    public static func lookup(_ word: String, pos: POSKey? = nil) -> Hit? {
        Store.shared.lookup(word: word, pos: pos)
    }

    /// Convenience: token list if available.
    public static func lookupTokens(_ word: String, pos: POSKey? = nil) -> [String]? {
        lookup(word, pos: pos)?.tokens
    }

    /// Convenience: raw IPA if available.
    public static func lookupIPA(_ word: String, pos: POSKey? = nil) -> String? {
        lookup(word, pos: pos)?.ipa
    }

    /// Returns tokens ONLY for plain (single-variant) entries.
    /// Homographs return nil — they need context-aware disambiguation
    /// and so belong on the markdown-override path, not in
    /// `TtsCustomLexicon` (which is not position-aware).
    public static func lookupPlainTokens(_ word: String) -> (tokens: [String], tier: LexiconTier)? {
        Store.shared.lookupPlain(word: word)
    }

    /// Does any tier store a POS-keyed (homograph) entry for this word?
    public static func isHomograph(_ word: String) -> Bool {
        Store.shared.isHomograph(word: word)
    }

    /// Enumerate every POS-keyed entry across all tiers. Values are
    /// flattened to `[variantKey: ipaString]` for the normalizer's
    /// auto-discovery path. Null-valued variants are omitted.
    public static func allHomographs() -> [(word: String, variants: [String: String])] {
        Store.shared.allHomographs()
    }

    /// Total number of entries actually loaded across all available tiers
    /// (pre-grow-dictionary expansion). Exposed for diagnostics + tests.
    public static var diagnosticsSnapshot: [LexiconTier: Int] {
        Store.shared.entryCountsByTier
    }
}

// MARK: - Internal representation

extension KokoroLexicon {

    /// A resolved variant value. `.null` represents an explicit `null`
    /// in the source dict — semantically "no variant-specific
    /// pronunciation for this POS", distinct from "key absent".
    enum VariantValue: Sendable {
        case tokens(tokens: [String], ipa: String)
        case null

        var tokensIfPresent: (tokens: [String], ipa: String)? {
            switch self {
            case let .tokens(tokens, ipa): return (tokens, ipa)
            case .null: return nil
            }
        }
    }

    /// One dictionary entry after parsing.
    enum Entry: Sendable {
        case plain(tokens: [String], ipa: String)
        case byPOS(variants: [String: VariantValue])

        var isHomograph: Bool {
            if case .byPOS = self { return true }
            return false
        }
    }
}

// MARK: - Store

extension KokoroLexicon {

    /// Immutable post-load state. Populated once via Swift's
    /// thread-safe static-let initializer semantics; no locks needed.
    fileprivate final class Store: Sendable {
        static let shared = Store.build()

        let tiers: [(tier: LexiconTier, entries: [String: Entry])]
        let entryCountsByTier: [LexiconTier: Int]

        init(tiers: [(LexiconTier, [String: Entry])]) {
            self.tiers = tiers
            var counts: [LexiconTier: Int] = [:]
            for (tier, entries) in tiers {
                counts[tier] = entries.count
            }
            self.entryCountsByTier = counts
        }

        static func build() -> Store {
            let loader = Loader()
            return Store(tiers: loader.loadAllTiers())
        }

        func lookup(word: String, pos: KokoroLexicon.POSKey?) -> Hit? {
            for (tier, entries) in tiers {
                guard let entry = findEntry(word: word, in: entries) else { continue }
                switch entry {
                case let .plain(tokens, ipa):
                    return Hit(tokens: tokens, ipa: ipa, tier: tier, variantKey: "-")
                case let .byPOS(variants):
                    if let hit = resolvePOS(variants: variants, pos: pos, tier: tier) {
                        return hit
                    }
                }
            }
            return nil
        }

        func lookupPlain(word: String) -> (tokens: [String], tier: LexiconTier)? {
            for (tier, entries) in tiers {
                guard let entry = findEntry(word: word, in: entries) else { continue }
                if case let .plain(tokens, _) = entry {
                    return (tokens, tier)
                }
                // Homograph: skip without checking further tiers — any
                // tier finding this word as POS-keyed wins over a plain
                // hit in a lower tier, because it means the word is
                // known-ambiguous.
                return nil
            }
            return nil
        }

        func isHomograph(word: String) -> Bool {
            for (_, entries) in tiers {
                if let entry = findEntry(word: word, in: entries), entry.isHomograph {
                    return true
                }
            }
            return false
        }

        func allHomographs() -> [(word: String, variants: [String: String])] {
            var out: [(String, [String: String])] = []
            var seen = Set<String>()
            for (_, entries) in tiers {
                for (word, entry) in entries {
                    guard case let .byPOS(variants) = entry else { continue }
                    guard seen.insert(word).inserted else { continue }
                    var flat: [String: String] = [:]
                    for (key, value) in variants {
                        if case let .tokens(_, ipa) = value {
                            flat[key] = ipa
                        }
                    }
                    guard !flat.isEmpty else { continue }
                    out.append((word, flat))
                }
            }
            return out
        }

        private func findEntry(word: String, in entries: [String: Entry]) -> Entry? {
            if let hit = entries[word] { return hit }
            let lower = word.lowercased()
            if lower != word, let hit = entries[lower] { return hit }
            return nil
        }

        private func resolvePOS(
            variants: [String: VariantValue],
            pos: KokoroLexicon.POSKey?,
            tier: LexiconTier
        ) -> Hit? {
            let steps: [String] = {
                guard let pos else { return ["DEFAULT"] }
                if pos == .defaultVariant { return ["DEFAULT"] }
                let parent = pos.parent.rawValue
                return parent == pos.rawValue
                    ? [pos.rawValue, "DEFAULT"]
                    : [pos.rawValue, parent, "DEFAULT"]
            }()
            for key in steps {
                guard let value = variants[key], let resolved = value.tokensIfPresent else { continue }
                return Hit(tokens: resolved.tokens, ipa: resolved.ipa, tier: tier, variantKey: key)
            }
            return nil
        }
    }
}

// MARK: - Loader

extension KokoroLexicon {

    fileprivate struct Loader {

        /// Runtime — only checked by the assertion path; bundled as a
        /// snapshot of FluidAudio's downloaded `vocab_index.json`.
        private let allowedTokens: Set<String>

        init() {
            self.allowedTokens = Loader.loadAllowedTokens()
        }

        func loadAllTiers() -> [(LexiconTier, [String: Entry])] {
            var tiers: [(LexiconTier, [String: Entry])] = []
            if let entries = loadBundled(name: "us_gold") {
                tiers.append((.kokorog2pGold, entries))
            }
            if let entries = loadBundled(name: "us_silver") {
                tiers.append((.kokorog2pSilver, entries))
            }
            if let entries = loadFluidAudioCached(name: "us_gold") {
                tiers.append((.fluidAudioGold, entries))
            }
            if let entries = loadFluidAudioCached(name: "us_silver") {
                tiers.append((.fluidAudioSilver, entries))
            }
            return tiers
        }

        private func loadBundled(name: String) -> [String: Entry]? {
            // SwiftPM `.process` flattens the resource tree into the bundle
            // root; there's no `kokorog2p/` subdirectory at runtime even
            // though the source lives under `Resources/kokorog2p/`.
            guard let url = Bundle.module.url(forResource: name, withExtension: "json")
            else { return nil }
            return parse(url: url)
        }

        private func loadFluidAudioCached(name: String) -> [String: Entry]? {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let path = home.appendingPathComponent(".cache/fluidaudio/Models/kokoro/\(name).json")
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            return parse(url: path)
        }

        /// Parse a dict file. Every loaded tier — bundled kokorog2p OR
        /// FluidAudio's cached compatibility tier — is validated against
        /// Kokoro's vocab. An out-of-vocab token is treated as a build-
        /// time regression and fatals (plan Phase 6 "Invariant retained"
        /// clause). If FluidAudio ever updates their cached dict with
        /// tokens outside Kokoro's inventory, the user sees a clear
        /// error instead of silent audio corruption — the update must
        /// be reconciled against `kokoro_vocab_index.json`.
        private func parse(url: URL) -> [String: Entry]? {
            guard let data = try? Data(contentsOf: url),
                let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            var parsed: [String: Entry] = [:]
            parsed.reserveCapacity(raw.count * 2)
            for (word, value) in raw {
                guard let entry = Self.decode(value) else { continue }
                if let offender = self.firstInvalidToken(in: entry) {
                    fatalError(
                        "KokoroLexicon: dict \(url.lastPathComponent) entry "
                            + "\(word) contains token \(offender) not in Kokoro vocabulary "
                            + "(\(self.allowedTokens.count) allowed). This is a build-time "
                            + "regression — re-run Phase 0 parity or update "
                            + "kokoro_vocab_index.json to reconcile."
                    )
                }
                parsed[word] = entry
            }
            return Self.grow(parsed)
        }

        /// Reproduces kokorog2p's `EnLexicon._grow_dictionary`: auto-add
        /// capitalisation variants (lower↔Capitalised) for each entry.
        /// Original entries win on conflict.
        private static func grow(_ raw: [String: Entry]) -> [String: Entry] {
            var extras: [String: Entry] = [:]
            for (key, value) in raw where key.count >= 2 {
                let lower = key.lowercased()
                if key == lower {
                    let cap = pythonCapitalize(key)
                    if key != cap { extras[cap] = value }
                } else if key == pythonCapitalize(lower) {
                    extras[lower] = value
                }
            }
            for (key, value) in raw {
                extras[key] = value
            }
            return extras
        }

        /// Match Python's `str.capitalize`: first char upper, rest lower.
        private static func pythonCapitalize(_ s: String) -> String {
            let lower = s.lowercased()
            guard let first = lower.first else { return lower }
            return String(first).uppercased() + lower.dropFirst()
        }

        private static func decode(_ value: Any) -> Entry? {
            if let ipa = value as? String {
                let tokens = ipa.unicodeScalars.map { String($0) }
                return .plain(tokens: tokens, ipa: ipa)
            }
            guard let dict = value as? [String: Any] else { return nil }
            var variants: [String: VariantValue] = [:]
            for (key, raw) in dict {
                if raw is NSNull {
                    variants[key] = .null
                } else if let ipa = raw as? String {
                    let tokens = ipa.unicodeScalars.map { String($0) }
                    variants[key] = .tokens(tokens: tokens, ipa: ipa)
                }
            }
            guard !variants.isEmpty else { return nil }
            return .byPOS(variants: variants)
        }

        /// Returns the first token (if any) that is not in Kokoro's
        /// vocab. Phase 0 established this is a 0-failure invariant for
        /// the bundled kokorog2p dicts; a caller that finds a non-nil
        /// return here must treat it as a build-time regression.
        private func firstInvalidToken(in entry: Entry) -> String? {
            guard !allowedTokens.isEmpty else { return nil }
            switch entry {
            case let .plain(tokens, _):
                return tokens.first(where: { !allowedTokens.contains($0) })
            case let .byPOS(variants):
                for value in variants.values {
                    if case let .tokens(tokens, _) = value,
                        let bad = tokens.first(where: { !allowedTokens.contains($0) })
                    {
                        return bad
                    }
                }
                return nil
            }
        }

        /// Loads the bundled `kokoro_vocab_index.json` snapshot. Empty
        /// set = validation inert (treated as "accept everything");
        /// should only happen if the bundled snapshot is missing.
        private static func loadAllowedTokens() -> Set<String> {
            guard let url = Bundle.module.url(
                forResource: "kokoro_vocab_index",
                withExtension: "json"
            ),
                let data = try? Data(contentsOf: url),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [] }
            if let vocab = obj["vocab"] as? [String: Any] {
                return Set(vocab.keys)
            }
            return Set(obj.keys)
        }
    }
}

