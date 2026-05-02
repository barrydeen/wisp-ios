import Foundation

struct NSpamPrepared: Sendable {
    let text: String         // NFKC + invisibles stripped + URLs collapsed + lowercased + ws-collapsed
    let rawText: String      // NFKC-normalized only
    let zeroWidthN: Int
}

/// Mirrors Android's `NSpamPreprocessor`. NFKC normalize → count invisibles → strip them →
/// replace `https?://host/...` with `http://<host>` → lowercase → collapse whitespace.
nonisolated enum NSpamPreprocessor {

    static let invisibleChars: Set<Character> = [
        "\u{180E}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
        "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2060}", "\u{2061}", "\u{2062}", "\u{2063}", "\u{2064}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{FEFF}"
    ]

    private static let urlRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"https?://([^\s/]+)(/\S*)?"#, options: [.caseInsensitive])
    }()

    private static let whitespaceRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\s+"#, options: [])
    }()

    static func countInvisibleChars(_ text: String) -> Int {
        var n = 0
        for ch in text where invisibleChars.contains(ch) { n += 1 }
        return n
    }

    static func preprocess(_ text: String) -> NSpamPrepared {
        let nfkc = text.precomposedStringWithCompatibilityMapping
        let zw = countInvisibleChars(nfkc)

        var stripped = ""
        stripped.reserveCapacity(nfkc.count)
        for ch in nfkc where !invisibleChars.contains(ch) { stripped.append(ch) }

        let collapsed = collapseUrls(stripped).lowercased()
        let final = collapseWhitespace(collapsed).trimmingCharacters(in: .whitespacesAndNewlines)

        return NSpamPrepared(text: final, rawText: nfkc, zeroWidthN: zw)
    }

    // MARK: - Private

    private static func collapseUrls(_ s: String) -> String {
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = urlRegex.matches(in: s, options: [], range: full)
        guard !matches.isEmpty else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var cursor = 0
        for match in matches {
            let mr = match.range
            if mr.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: mr.location - cursor))
            }
            let hostRange = match.range(at: 1)
            if hostRange.location != NSNotFound {
                let host = ns.substring(with: hostRange).lowercased()
                out += "http://" + host
            }
            cursor = mr.location + mr.length
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    private static func collapseWhitespace(_ s: String) -> String {
        let ns = s as NSString
        return whitespaceRegex.stringByReplacingMatches(
            in: s, options: [],
            range: NSRange(location: 0, length: ns.length),
            withTemplate: " "
        )
    }
}
