import Foundation

struct NSpamNoteInput: Sendable {
    let content: String
    let tags: [[String]]
    let createdAt: Int
}

/// Pure-Swift port of Android's `NSpamFeatures`. Builds a fixed-size 262,541-element vector
/// from a list of recent notes by the same author. Values are sums (n-grams), means
/// (structural features), or aggregates (group features). The model was trained on this
/// exact layout; any drift in regex behavior, hash sign, or feature ordering breaks scoring.
nonisolated enum NSpamFeatures {

    static let nChar = 131_072
    static let nWord = 131_072
    static let nStructural = 17
    static let nGroup = 6
    static let total = nChar + nWord + nStructural + nGroup

    private static let wordPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"[\p{L}\p{N}_]{2,}"#, options: [])
    }()
    private static let whitespacePattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\s+"#, options: [])
    }()
    private static let urlPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"https?://([^\s/]+)"#, options: [.caseInsensitive])
    }()
    private static let mentionPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:nostr:)?(?:npub1|note1|nprofile1|nevent1|naddr1)[0-9a-z]+"#,
            options: [.caseInsensitive]
        )
    }()
    private static let hashtagPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"#\w+"#, options: [])
    }()
    private static let nonwsTokenPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\S+"#, options: [])
    }()
    private static let unicodeDigitPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\p{N}"#, options: [])
    }()
    private static let unicodePunctPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\p{P}"#, options: [])
    }()
    private static let tokenizePattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\p{L}[\p{L}\p{M}\p{N}_]*|\p{N}+|https?://\S+|[#@][\w]+"#,
            options: []
        )
    }()
    /// Mirrors Kotlin's `[\p{IsEmoji_Presentation}\p{IsExtended_Pictographic}]`. NSRegularExpression
    /// uses ICU under the hood and accepts both property names directly.
    private static let emojiPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"[\p{Emoji_Presentation}\p{Extended_Pictographic}]"#,
            options: []
        )
    }()

    static func extractFeatures(_ notes: [NSpamNoteInput]) -> [Float] {
        var features = [Float](repeating: 0, count: total)
        let n = notes.count
        if n == 0 { return features }

        let preps = notes.map { NSpamPreprocessor.preprocess($0.content) }

        let charText = preps.map(\.rawText).joined(separator: " ")
        hashCharWbNgrams(charText, into: &features)

        let wordText = preps.map(\.text).joined(separator: " ")
        hashWordNgrams(wordText, into: &features)

        var structuralSums = [Float](repeating: 0, count: nStructural)
        var charLengths: [Float] = []
        charLengths.reserveCapacity(n)
        var bodyKeys: [String] = []
        bodyKeys.reserveCapacity(n)
        var rawTexts: [String] = []
        rawTexts.reserveCapacity(n)

        for note in notes {
            let raw = note.content
            let tags = note.tags
            rawTexts.append(raw)

            // Body key: drop invisibles, trim, lowercase, take 200 chars.
            let strippedKey = raw.filter { !NSpamPreprocessor.invisibleChars.contains($0) }
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let bodyKey = String(strippedKey.prefix(200))
            bodyKeys.append(bodyKey)

            let struc = extractStructural(raw: raw, tags: tags)
            for j in 0..<nStructural { structuralSums[j] += struc[j] }
            charLengths.append(Float(raw.utf16.count))
        }

        let structOffset = nChar + nWord
        for i in 0..<nStructural {
            features[structOffset + i] = structuralSums[i] / Float(n)
        }

        let groupOffset = structOffset + nStructural
        features[groupOffset] = Float(n)
        if n > 1 {
            let createdAts = notes.map(\.createdAt)
            let span = (createdAts.max() ?? 0) - (createdAts.min() ?? 0)
            features[groupOffset + 1] = Float(span) / 3600.0
        } else {
            features[groupOffset + 1] = 0
        }
        let uniqueBodies = Set(bodyKeys.filter { !$0.isEmpty })
        features[groupOffset + 2] = Float(uniqueBodies.count)

        if n >= 2 {
            features[groupOffset + 3] = populationStdDev(charLengths)

            let tokenLists: [[String]] = rawTexts.map { allMatches(of: tokenizePattern, in: $0.lowercased()) }
            let firstTokens = tokenLists.compactMap { $0.first }
            if !firstTokens.isEmpty {
                var counts: [String: Int] = [:]
                for t in firstTokens { counts[t, default: 0] += 1 }
                let maxCount = counts.values.max() ?? 0
                features[groupOffset + 4] = Float(maxCount) / Float(n)
            }

            let tokenSets = tokenLists.map { Set($0) }
            var jaccSum = 0.0
            var jaccCount = 0
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let a = tokenSets[i]
                    let b = tokenSets[j]
                    let unionCount = a.union(b).count
                    if unionCount > 0 {
                        let inter = a.intersection(b).count
                        jaccSum += Double(inter) / Double(unionCount)
                    }
                    jaccCount += 1
                }
            }
            if jaccCount > 0 {
                features[groupOffset + 5] = Float(jaccSum / Double(jaccCount))
            }
        }

        return features
    }

    // MARK: - Structural (17 features)

    private static func extractStructural(raw: String, tags: [[String]]) -> [Float] {
        let utf16Len = raw.utf16.count
        let lenChars = Float(utf16Len)
        let lenTokens = Float(allMatches(of: nonwsTokenPattern, in: raw).count)

        let urlMatches = matchRanges(of: urlPattern, in: raw)
        let urlCount = Float(urlMatches.count)
        var domains = Set<String>()
        let ns = raw as NSString
        for match in urlMatches {
            if match.numberOfRanges >= 2 {
                let r = match.range(at: 1)
                if r.location != NSNotFound {
                    domains.insert(ns.substring(with: r).lowercased())
                }
            }
        }
        let uniqueDomains = Float(domains.count)

        let mentionCount = Float(allMatches(of: mentionPattern, in: raw).count)
        let hashtagCount = Float(allMatches(of: hashtagPattern, in: raw).count)

        var tagP: Float = 0, tagE: Float = 0, tagT: Float = 0, tagOther: Float = 0
        for t in tags {
            guard !t.isEmpty else { continue }
            switch t[0] {
            case "p": tagP += 1
            case "e": tagE += 1
            case "t": tagT += 1
            default: tagOther += 1
            }
        }

        let emojiCount = Float(allMatches(of: emojiPattern, in: raw).count)
        let emojiRatio: Float = utf16Len > 0 ? emojiCount / Float(utf16Len) : 0
        let zeroWidthCount = Float(NSpamPreprocessor.countInvisibleChars(raw))

        var alphaCount = 0
        var capsCount = 0
        for ch in raw where ch.isLetter {
            alphaCount += 1
            if ch.isUppercase { capsCount += 1 }
        }
        let capsRatio: Float = alphaCount > 0 ? Float(capsCount) / Float(alphaCount) : 0

        let digitCount = allMatches(of: unicodeDigitPattern, in: raw).count
        let digitRatio: Float = utf16Len > 0 ? Float(digitCount) / Float(utf16Len) : 0

        let punctCount = allMatches(of: unicodePunctPattern, in: raw).count
        let punctRatio: Float = utf16Len > 0 ? Float(punctCount) / Float(utf16Len) : 0

        return [
            lenChars, lenTokens, urlCount, uniqueDomains,
            mentionCount, hashtagCount, tagP, tagE, tagT, tagOther,
            emojiCount, emojiRatio, zeroWidthCount,
            capsRatio, digitRatio, punctRatio,
            0  // dup_body_bucket — zeroed for portability
        ]
    }

    // MARK: - n-gram hashing

    private static func hashWordNgrams(_ text: String, into features: inout [Float]) {
        let tokens = allMatches(of: wordPattern, in: text)
        for token in tokens {
            hashInto(token, features: &features, offset: nChar, nFeatures: nWord)
        }
        if tokens.count >= 2 {
            for i in 0..<(tokens.count - 1) {
                let bigram = tokens[i] + " " + tokens[i + 1]
                hashInto(bigram, features: &features, offset: nChar, nFeatures: nWord)
            }
        }
    }

    private static func hashCharWbNgrams(_ text: String, into features: inout [Float]) {
        let normalized = whitespacePattern.stringByReplacingMatches(
            in: text, options: [],
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: " "
        )
        for word in normalized.split(separator: " ", omittingEmptySubsequences: true) {
            let padded = " " + word + " "
            // Char n-grams over UTF-16 view to match Kotlin's CharSequence indexing.
            let units = Array(padded.utf16)
            for n in 3...5 {
                if units.count < n { continue }
                for start in 0...(units.count - n) {
                    if let s = String(utf16CodeUnits: Array(units[start..<(start + n)]), count: n) as String? {
                        hashInto(s, features: &features, offset: 0, nFeatures: nChar)
                    }
                }
            }
        }
    }

    private static func hashInto(_ token: String, features: inout [Float], offset: Int, nFeatures: Int) {
        let bytes = Data(token.utf8)
        let h = MurmurHash3.hash32(bytes)
        // Mirror Kotlin's `kotlin.math.abs(hash.toLong()) % nFeatures` (long-promote avoids
        // Int32.min sign trap) and the >=0 sign branch.
        let absH = abs(Int64(h))
        let index = Int(absH % Int64(nFeatures))
        let sign: Float = h >= 0 ? 1 : -1
        features[offset + index] += sign
    }

    // MARK: - Helpers

    private static func populationStdDev(_ values: [Float]) -> Float {
        let n = values.count
        if n <= 1 { return 0 }
        let mean = values.reduce(0, +) / Float(n)
        var variance: Double = 0
        for v in values {
            let d = Double(v - mean)
            variance += d * d
        }
        variance /= Double(n)
        return Float(sqrt(variance))
    }

    private static func allMatches(of regex: NSRegularExpression, in text: String) -> [String] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let results = regex.matches(in: text, options: [], range: full)
        return results.map { ns.substring(with: $0.range) }
    }

    private static func matchRanges(of regex: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, options: [], range: full)
    }

}
