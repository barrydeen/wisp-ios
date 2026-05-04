import Foundation

struct MediaMeta: Hashable {
    let url: String
    let mime: String?
    let dimension: String?
    let blurhash: String?
    /// Optional poster image URL — typically supplied alongside a video via the
    /// NIP-92 imeta `image <url>` field. Lets the gallery / inline player show a
    /// frame preview before the user taps to play, without having to pre-decode
    /// the video itself.
    let posterUrl: String?

    init(url: String, mime: String? = nil, dimension: String? = nil, blurhash: String? = nil, posterUrl: String? = nil) {
        self.url = url
        self.mime = mime
        self.dimension = dimension
        self.blurhash = blurhash
        self.posterUrl = posterUrl
    }
}

enum ContentSegment: Hashable {
    case text(String)
    case image(MediaMeta)
    case video(MediaMeta)
    case audio(MediaMeta)
    case unknownMedia(MediaMeta)
    case link(String)            // standalone URL → preview card
    case inlineLink(String)      // inline URL → tap text
    case nostrNote(eventId: String, relayHints: [String])
    case nostrProfile(pubkey: String, relayHints: [String])
    case nostrAddressable(dTag: String, relays: [String], author: String?, kind: Int?)
    case customEmoji(shortcode: String, url: String)
    case hashtag(String)
    case lightningInvoice(invoice: String, amountSats: Int64?, description: String?)
}

enum ContentParser {

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "svg"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m3u8"]
    private static let audioExtensions: Set<String> = ["mp3", "wav", "ogg", "m4a", "flac", "aac"]

    private static let imageMimePrefixes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp", "image/svg+xml", "image/heic", "image/heif", "image/avif"]
    private static let videoMimePrefixes: Set<String> = ["video/mp4", "video/quicktime", "video/webm", "application/vnd.apple.mpegurl", "application/x-mpegurl"]
    private static let audioMimePrefixes: Set<String> = ["audio/mpeg", "audio/wav", "audio/ogg", "audio/mp4", "audio/flac", "audio/aac", "audio/x-wav"]

    private static let blossomPathRegex = try! NSRegularExpression(
        pattern: #"^/[0-9a-f]{64}$"#,
        options: [.caseInsensitive]
    )

    // Mirrors Android's combined regex with the same TLD whitelist + hashtag, npub, nostr-uri, bare bech32 patterns.
    private static let combinedRegex: NSRegularExpression = {
        let tlds = "com|net|org|io|dev|app|pro|ai|co|me|info|xyz|cc|tv|to|gg|sh|im|is|it|rs|ly|site|online|store|tech|cloud|social|world|earth|space|lol|wtf|family|life|art|design|blog|news|live|video|media|chat|games|money|finance|agency|studio|build|run|codes|systems|network|zone|pub|blue|limo|fyi|wiki|page|link|click|exchange|markets|fun|club|today"
        let pattern = #"nostr:(?:note1|nevent1|npub1|nprofile1|naddr1)[a-z0-9]+"#
            + #"|(?<!\w)(npub1[a-z0-9]{58})(?!\w|\.[a-zA-Z])"#
            + #"|(?:https?|wss?):\/\/\S+"#
            + #"|(?<!\w)((?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+(?:\#(tlds))(?:\/\S*)?)(?!\w)"#
            + #"|(?<!\w)#([a-zA-Z0-9_][a-zA-Z0-9_-]*)"#
            + #"|(?<!\w)((?:note1|nevent1|nprofile1|naddr1)[a-z0-9]{10,})(?!\w)"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let bolt11Regex = try! NSRegularExpression(
        pattern: #"(lightning:)?(lnbc|lntb|lnbcrt)[0-9a-z]{50,}"#,
        options: [.caseInsensitive]
    )

    private static let emojiShortcodeRegex = try! NSRegularExpression(pattern: #":([a-zA-Z0-9_-]+):"#)

    // MARK: - imeta tags (NIP-92)

    static func parseImetaTags(_ tags: [[String]]) -> [String: MediaMeta] {
        var map: [String: MediaMeta] = [:]
        for tag in tags {
            guard tag.first == "imeta", tag.count >= 2 else { continue }
            var url: String?
            var mime: String?
            var dim: String?
            var blur: String?
            var image: String?
            for entry in tag.dropFirst() {
                if entry.hasPrefix("url ") { url = String(entry.dropFirst(4)) }
                else if entry.hasPrefix("m ") { mime = String(entry.dropFirst(2)) }
                else if entry.hasPrefix("dim ") { dim = String(entry.dropFirst(4)) }
                else if entry.hasPrefix("blurhash ") { blur = String(entry.dropFirst(9)) }
                else if entry.hasPrefix("image ") { image = String(entry.dropFirst(6)) }
            }
            if let url {
                map[url] = MediaMeta(url: url, mime: mime, dimension: dim, blurhash: blur, posterUrl: image)
            }
        }
        return map
    }

    // MARK: - Public parse entry

    static func parse(
        content: String,
        tags: [[String]],
        emojiMap: [String: String] = [:],
        trimBlankLines: Bool = true
    ) -> [ContentSegment] {
        let imetaMap = parseImetaTags(tags)
        return parse(content: content, emojiMap: emojiMap, imetaMap: imetaMap, trimBlankLines: trimBlankLines)
    }

    static func parse(
        content: String,
        emojiMap: [String: String] = [:],
        imetaMap: [String: MediaMeta] = [:],
        trimBlankLines: Bool = true
    ) -> [ContentSegment] {
        var segments: [ContentSegment] = []
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        let matches = combinedRegex.matches(in: content, range: fullRange)

        var lastEnd = 0
        for match in matches {
            let range = match.range
            if range.location > lastEnd {
                let plain = nsContent.substring(with: NSRange(location: lastEnd, length: range.location - lastEnd))
                if !plain.isEmpty { segments.append(.text(plain)) }
            }

            let token = nsContent.substring(with: range)
            let bareDomain = capture(match: match, group: 2, in: nsContent)
            let hashtag = capture(match: match, group: 3, in: nsContent)

            if let hashtag, !hashtag.isEmpty, token.hasPrefix("#") {
                segments.append(.hashtag(hashtag))
            } else if let bareDomain, !bareDomain.isEmpty, !token.lowercased().hasPrefix("http") {
                let url = "https://\(bareDomain)"
                segments.append(classifyUrl(url, content: content, range: range, imetaMap: imetaMap))
            } else if token.lowercased().hasPrefix("nostr:") {
                segments.append(decodeNostrToken(token))
            } else if isBareBech32(token) {
                segments.append(decodeNostrToken("nostr:\(token)"))
            } else {
                // full URL match (http/https/ws/wss)
                let trimmed = trimTrailingPunctuation(token)
                segments.append(classifyUrl(trimmed, content: content, range: range, imetaMap: imetaMap))
            }

            lastEnd = range.location + range.length
        }

        if lastEnd < nsContent.length {
            let trailing = nsContent.substring(from: lastEnd)
            if !trailing.isEmpty { segments.append(.text(trailing)) }
        }

        // Pass 2: split text segments on custom emoji shortcodes
        if !emojiMap.isEmpty {
            segments = segments.flatMap { seg -> [ContentSegment] in
                if case .text(let text) = seg {
                    return splitTextForEmojis(text, emojiMap: emojiMap)
                }
                return [seg]
            }
        }

        // Pass 3: detect lightning invoices in text segments
        segments = segments.flatMap { seg -> [ContentSegment] in
            if case .text(let text) = seg {
                return splitTextForInvoices(text)
            }
            return [seg]
        }

        // Pass 4: trim blank lines preceding block segments
        if trimBlankLines, segments.count > 1 {
            for i in 0..<(segments.count - 1) {
                let next = segments[i + 1]
                let isBlock: Bool
                switch next {
                // .nostrProfile (npub @mention) is rendered inline by
                // RichInlineTextView, not as a card — leave preceding blank
                // lines alone so a bio that puts a mention on its own line,
                // or after a paragraph break, keeps the line break the user
                // typed.
                case .text, .inlineLink, .customEmoji, .hashtag, .nostrProfile: isBlock = false
                default: isBlock = true
                }
                if isBlock, case .text(let text) = segments[i] {
                    let trimmed = trimTrailingNewlines(text)
                    if trimmed != text {
                        segments[i] = .text(trimmed.isEmpty ? "" : trimmed + "\n")
                    }
                }
            }
        }

        return segments
    }

    // MARK: - Helpers

    private static func capture(match: NSTextCheckingResult, group: Int, in nsContent: NSString) -> String? {
        guard group < match.numberOfRanges else { return nil }
        let r = match.range(at: group)
        guard r.location != NSNotFound else { return nil }
        return nsContent.substring(with: r)
    }

    private static func isBareBech32(_ token: String) -> Bool {
        let lower = token.lowercased()
        return lower.hasPrefix("note1") || lower.hasPrefix("nevent1") ||
               lower.hasPrefix("npub1") || lower.hasPrefix("nprofile1") ||
               lower.hasPrefix("naddr1")
    }

    private static func decodeNostrToken(_ token: String) -> ContentSegment {
        guard let decoded = Nip19.decodeNostrUri(token) else {
            return .text(token)
        }
        switch decoded {
        case .noteRef(let eventId, let relays, _):
            return .nostrNote(eventId: eventId, relayHints: relays)
        case .profileRef(let pubkey, let relays):
            return .nostrProfile(pubkey: pubkey, relayHints: relays)
        case .addressRef(let dTag, let relays, let author, let kind):
            return .nostrAddressable(dTag: dTag, relays: relays, author: author, kind: kind)
        }
    }

    private static func classifyUrl(_ url: String, content: String, range: NSRange, imetaMap: [String: MediaMeta]) -> ContentSegment {
        let meta = imetaMap[url]
        let mime = meta?.mime
        let imetaClass = mime.flatMap { classifyByMime($0) }
        let ext = fileExtension(url)
        let isWebSocket = url.lowercased().hasPrefix("wss://") || url.lowercased().hasPrefix("ws://")

        if imetaClass == "image" { return .image(meta!) }
        if imetaClass == "video" { return .video(meta!) }
        if imetaClass == "audio" { return .audio(meta!) }
        if imageExtensions.contains(ext) { return .image(meta ?? MediaMeta(url: url)) }
        if videoExtensions.contains(ext) { return .video(meta ?? MediaMeta(url: url)) }
        if audioExtensions.contains(ext) { return .audio(meta ?? MediaMeta(url: url)) }
        if isWebSocket { return .inlineLink(url) }
        if isBlossomUrl(url) { return .unknownMedia(meta ?? MediaMeta(url: url)) }
        if isStandaloneUrl(content: content, range: range) { return .link(url) }
        return .inlineLink(url)
    }

    private static func classifyByMime(_ mime: String) -> String? {
        let lower = mime.lowercased()
        if imageMimePrefixes.contains(where: { lower.hasPrefix($0) }) { return "image" }
        if videoMimePrefixes.contains(where: { lower.hasPrefix($0) }) { return "video" }
        if audioMimePrefixes.contains(where: { lower.hasPrefix($0) }) { return "audio" }
        return nil
    }

    private static func fileExtension(_ url: String) -> String {
        let withoutQuery = url.split(separator: "?").first.map(String.init) ?? url
        if let dot = withoutQuery.lastIndex(of: ".") {
            return String(withoutQuery[withoutQuery.index(after: dot)...]).lowercased()
        }
        return ""
    }

    private static func isBlossomUrl(_ url: String) -> Bool {
        guard let parsed = URL(string: url) else { return false }
        let path = parsed.path
        let r = NSRange(location: 0, length: (path as NSString).length)
        return blossomPathRegex.firstMatch(in: path, range: r) != nil
    }

    private static func isStandaloneUrl(content: String, range: NSRange) -> Bool {
        // All position math stays in NSString (UTF-16) to avoid mixing
        // Swift Character distances with NSString offsets — that mismatch
        // breaks for content with multi-code-unit emoji (e.g. ⬛, 🟪),
        // because Swift counts each emoji as one Character while NSString
        // counts it as two code units, and the resulting prefix slice
        // includes emoji that fail `isWhitespace`.
        let nsContent = content as NSString
        let beforeRange = NSRange(location: 0, length: range.location)
        let lastNewline = nsContent.range(
            of: "\n",
            options: .backwards,
            range: beforeRange
        )
        let prefixStart = lastNewline.location == NSNotFound
            ? 0
            : lastNewline.location + lastNewline.length
        let prefix = nsContent.substring(with: NSRange(
            location: prefixStart,
            length: range.location - prefixStart
        ))
        if !prefix.allSatisfy(\.isWhitespace) { return false }

        let afterStart = range.location + range.length
        let afterRange = NSRange(location: afterStart, length: nsContent.length - afterStart)
        let firstNewline = nsContent.range(
            of: "\n",
            options: [],
            range: afterRange
        )
        let suffixEnd = firstNewline.location == NSNotFound
            ? nsContent.length
            : firstNewline.location
        let suffix = nsContent.substring(with: NSRange(
            location: afterStart,
            length: suffixEnd - afterStart
        ))
        return suffix.allSatisfy(\.isWhitespace)
    }

    private static func trimTrailingPunctuation(_ url: String) -> String {
        let punct: Set<Character> = [".", ",", ")", "]", ";", ":", "!", "?"]
        var s = url
        while let last = s.last, punct.contains(last) {
            s.removeLast()
        }
        return s
    }

    private static func trimTrailingNewlines(_ s: String) -> String {
        var out = s
        while out.last == "\n" { out.removeLast() }
        return out
    }

    private static func splitTextForEmojis(_ text: String, emojiMap: [String: String]) -> [ContentSegment] {
        let ns = text as NSString
        let matches = emojiShortcodeRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return [.text(text)] }

        var result: [ContentSegment] = []
        var lastEnd = 0
        var anyFound = false
        for match in matches {
            let shortcodeRange = match.range(at: 1)
            guard shortcodeRange.location != NSNotFound else { continue }
            let shortcode = ns.substring(with: shortcodeRange)
            guard let url = emojiMap[shortcode] else { continue }
            anyFound = true
            let r = match.range
            if r.location > lastEnd {
                result.append(.text(ns.substring(with: NSRange(location: lastEnd, length: r.location - lastEnd))))
            }
            result.append(.customEmoji(shortcode: shortcode, url: url))
            lastEnd = r.location + r.length
        }
        if !anyFound { return [.text(text)] }
        if lastEnd < ns.length {
            result.append(.text(ns.substring(from: lastEnd)))
        }
        return result
    }

    private static func splitTextForInvoices(_ text: String) -> [ContentSegment] {
        let ns = text as NSString
        let matches = bolt11Regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return [.text(text)] }

        var result: [ContentSegment] = []
        var lastEnd = 0
        var anyFound = false
        for match in matches {
            let raw = ns.substring(with: match.range)
            var invoice = raw.lowercased()
            if invoice.hasPrefix("lightning:") { invoice = String(invoice.dropFirst("lightning:".count)) }
            guard let decoded = Bolt11.decode(invoice) else { continue }
            anyFound = true
            let r = match.range
            if r.location > lastEnd {
                result.append(.text(ns.substring(with: NSRange(location: lastEnd, length: r.location - lastEnd))))
            }
            result.append(.lightningInvoice(invoice: invoice, amountSats: decoded.amountSats, description: decoded.description))
            lastEnd = r.location + r.length
        }
        if !anyFound { return [.text(text)] }
        if lastEnd < ns.length {
            result.append(.text(ns.substring(from: lastEnd)))
        }
        return result
    }

    // MARK: - Custom emoji tags (NIP-30)

    static func parseEmojiTags(_ tags: [[String]]) -> [String: String] {
        var map: [String: String] = [:]
        for tag in tags {
            guard tag.first == "emoji", tag.count >= 3 else { continue }
            map[tag[1]] = tag[2]
        }
        return map
    }

    // MARK: - Aspect ratio

    static func parseAspectRatio(_ dim: String?) -> CGFloat? {
        guard let dim else { return nil }
        let parts = dim.split(separator: "x")
        guard parts.count == 2,
              let w = Double(parts[0]),
              let h = Double(parts[1]),
              h > 0 else { return nil }
        return CGFloat(w / h)
    }
}
