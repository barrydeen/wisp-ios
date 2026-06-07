import Foundation

/// Comprehensive emoji → keyword index sourced from Unicode CLDR's English
/// annotations (`cldr-annotations-full/annotations/en/annotations.json`,
/// pre-flattened to `cldr-emoji-keywords-en.json` to drop the `tts` /
/// `default` wrapper and skip non-emoji entries). Covers ~1500 emoji with
/// multiple keywords each, the same data the system emoji keyboard uses.
///
/// `EmojiData.searchEmojis` consults this index first, then falls back to
/// the hand-curated `keywordAliases` table for nostr-culture-specific
/// terms (e.g. "pepe" → 🐸) and slang aliases CLDR doesn't ship ("lol" →
/// 😂, "ded" → 💀, etc.).
///
/// Parsed lazily on first access. Two reverse indexes are built once and
/// cached: `keywordsByEmoji` and `emojisByKeyword`.
enum CldrEmojiKeywords {
    static let keywordsByEmoji: [String: [String]] = loadKeywords()
    static let emojisByKeyword: [String: [String]] = {
        var map: [String: [String]] = [:]
        for (emoji, keywords) in keywordsByEmoji {
            for keyword in keywords {
                map[keyword.lowercased(), default: []].append(emoji)
            }
        }
        return map
    }()

    private static func loadKeywords() -> [String: [String]] {
        guard let url = Bundle.main.url(forResource: "cldr-emoji-keywords-en", withExtension: "json") else {
            return [:]
        }
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else { return [:] }
        // CLDR keys symbol-range emoji WITHOUT the U+FE0F variation
        // selector (e.g. "❤" not "❤️"). Our catalog renders them WITH
        // the selector to force emoji presentation, so lookups fail for
        // those entries. Mirror each single-codepoint BMP-symbol entry
        // with its VS-16 form so either string hits the same keyword
        // list. New entries are written, never overwriting an existing
        // explicit `…\u{FE0F}` key if CLDR had one.
        let vs16: Character = "\u{FE0F}"
        var out = json
        for (emoji, kws) in json {
            guard emoji.unicodeScalars.count == 1 else { continue }
            guard let scalar = emoji.unicodeScalars.first else { continue }
            // U+2300–U+27BF + U+2B00–U+2BFF are the common BMP symbol
            // ranges that need VS-16 for emoji presentation.
            let v = scalar.value
            let needsVs = (0x2300 <= v && v <= 0x27BF) || (0x2B00 <= v && v <= 0x2BFF)
            guard needsVs else { continue }
            let withVs = "\(emoji)\(vs16)"
            if out[withVs] == nil { out[withVs] = kws }
        }
        return out
    }
}
