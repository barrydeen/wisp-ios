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
    /// SHA-256 digest of the file (NIP-92 imeta `x`, falling back to `ox`). Used
    /// to dedupe the same content-addressed file when it's served from more than
    /// one host (e.g. a Blossom mirror in `content` vs the host in the imeta tag),
    /// and by `BlossomFallbackFetcher` to verify retrieved bytes.
    let sha256: String?

    init(url: String, mime: String? = nil, dimension: String? = nil, blurhash: String? = nil, posterUrl: String? = nil, sha256: String? = nil) {
        self.url = url
        self.mime = mime
        self.dimension = dimension
        self.blurhash = blurhash
        self.posterUrl = posterUrl
        self.sha256 = sha256
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

    // MARK: - Blossom Path Regexes (BUD-01)

    // These two regexes serve complementary purposes for BUD-01 (Blossom URLs):

    /// Strict validator: matches ONLY when the entire path IS a SHA-256 hash.
    /// Used by `isBlossomUrl()` to classify a URL as a Blossom URL.
    /// Example match: `/abc123...def789.png` (entire path is hash)
    /// Example non-match: `/users/123/abc123...def789.png` (path has other components)
    private static let blossomPathRegex = try! NSRegularExpression(
        pattern: #"^/[0-9a-f]{64}(\.[a-zA-Z0-9]+)?$"#,
        options: [.caseInsensitive]
    )

    /// Extractor: finds the SHA-256 hash at the END of a path, regardless of prefix.
    /// Used by `sha256Hash()` to extract the hash from URLs that may contain it.
    /// Example match: `/users/123/abc123...def789.png` (extracts abc123...def789)
    /// Example non-match: `/abc123...def789/users/123` (hash is NOT at the end)
    private static let sha256HashRegex = try! NSRegularExpression(
        pattern: #"/([0-9a-f]{64})(?:\.[a-zA-Z0-9]+)?/?$"#,
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
            var x: String?
            var ox: String?
            for entry in tag.dropFirst() {
                if entry.hasPrefix("url ") { url = String(entry.dropFirst(4)) }
                else if entry.hasPrefix("m ") { mime = String(entry.dropFirst(2)) }
                else if entry.hasPrefix("dim ") { dim = String(entry.dropFirst(4)) }
                else if entry.hasPrefix("blurhash ") { blur = String(entry.dropFirst(9)) }
                else if entry.hasPrefix("image ") { image = String(entry.dropFirst(6)) }
                else if entry.hasPrefix("ox ") { ox = String(entry.dropFirst(3)) }
                else if entry.hasPrefix("x ") { x = String(entry.dropFirst(2)) }
            }
            if let url {
                map[url] = MediaMeta(url: url, mime: mime, dimension: dim, blurhash: blur, posterUrl: image, sha256: x ?? ox)
            }
        }
        return map
    }

    // MARK: - Public parse entry

    /// Parse event content into renderable segments.
    /// - Parameters:
    ///   - linksAreInline: Surfaces that render `.link` segments as inline text
    ///     (bio, quoted notes, drafts, group chat — anything passing
    ///     `showLinkPreviews: false` to `RichContentView`) need pass 4 to treat
    ///     `.link` like other inline neighbors. Otherwise a lone `"\n"` text
    ///     between two `.link`s gets zeroed out and the folded inline links
    ///     collide into one line.
    static func parse(
        content: String,
        tags: [[String]],
        emojiMap: [String: String] = [:],
        trimBlankLines: Bool = true,
        linksAreInline: Bool = false
    ) -> [ContentSegment] {
        let imetaMap = parseImetaTags(tags)
        // Preserve imeta tag order so gallery posts (kind 20/21/22) display
        // images in the publisher's intended sequence rather than dict order.
        var imetaUrlOrder: [String] = []
        for tag in tags where tag.first == "imeta" {
            for entry in tag.dropFirst() where entry.hasPrefix("url ") {
                imetaUrlOrder.append(String(entry.dropFirst(4)))
                break
            }
        }
        return parse(
            content: content,
            emojiMap: emojiMap,
            imetaMap: imetaMap,
            imetaUrlOrder: imetaUrlOrder,
            trimBlankLines: trimBlankLines,
            linksAreInline: linksAreInline
        )
    }

    static func parse(
        content: String,
        emojiMap: [String: String] = [:],
        imetaMap: [String: MediaMeta] = [:],
        imetaUrlOrder: [String] = [],
        trimBlankLines: Bool = true,
        linksAreInline: Bool = false
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
                let cleaned = trimTrailingPunctuation(bareDomain)
                let url = "https://\(cleaned)"
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

        // Gallery posts (NIP-68 kind 20, NIP-71 kind 21/22) place media URLs
        // only in imeta tags — the caption in `content` doesn't include them.
        // The regex pass above misses those URLs, so append them here as
        // explicit media segments in imeta tag order (so the publisher's
        // intended first image stays first).
        //
        // The append pass only runs when `content` rendered no media of its
        // own. Per NIP-92 an imeta tag describes a URL that appears in
        // `content`; when a note already shows media, an unmatched imeta URL
        // is the same file on another host (e.g. the publishing client's
        // Blossom mirror), not an extra attachment — and it often carries no
        // `x`/`ox` digest that could prove the match (a nostr.build URL in
        // content vs a digest-named mirror URL in imeta has no common token),
        // so appending it would render the image twice.
        let contentHasMedia = segments.contains { seg in
            switch seg {
            case .image, .video, .audio, .unknownMedia: return true
            default: return false
            }
        }
        if !imetaMap.isEmpty && !contentHasMedia {
            var seenUrls = Set<String>()
            // Content-addressed dedup: two imeta tags are often mirrors of the
            // same file on different hosts, keyed by its SHA-256. A plain
            // URL-string compare misses that and renders the image twice, so we
            // also track the digest — from the imeta `x`/`ox` field or the
            // 64-hex filename embedded in a media URL — and skip any imeta
            // entry whose file we've already appended.
            var seenHashes = Set<String>()
            for seg in segments {
                let segUrl: String?
                switch seg {
                case .link(let url), .inlineLink(let url):
                    segUrl = url
                default:
                    segUrl = nil
                }
                if let segUrl {
                    seenUrls.insert(segUrl)
                    // Only treat terminal 64-hex paths as content-addressed hashes when
                    // the URL is a Blossom URL, avoiding false positives from blogs or
                    // CDNs that happen to end a path in a 64-character hex token.
                    if isBlossomUrl(segUrl), let h = sha256Hash(fromUrl: segUrl) {
                        seenHashes.insert(h)
                    }
                }
            }
            let orderedUrls = imetaUrlOrder.isEmpty ? Array(imetaMap.keys) : imetaUrlOrder
            for url in orderedUrls {
                guard let meta = imetaMap[url] else { continue }
                if seenUrls.contains(url) { continue }
                let metaHash: String? = meta.sha256?.lowercased() ?? sha256Hash(fromUrl: url)
                if let metaHash, seenHashes.contains(metaHash) { continue }
                let imetaClass = meta.mime.flatMap { classifyByMime($0) }
                let ext = fileExtension(url)
                if imetaClass == "image" { segments.append(.image(meta)) }
                else if imetaClass == "video" { segments.append(.video(meta)) }
                else if imetaClass == "audio" { segments.append(.audio(meta)) }
                else if imageExtensions.contains(ext) { segments.append(.image(meta)) }
                else if videoExtensions.contains(ext) { segments.append(.video(meta)) }
                else if audioExtensions.contains(ext) { segments.append(.audio(meta)) }
                else { segments.append(.unknownMedia(meta)) }
                // Record what we just appended so a second imeta tag pointing at
                // the same file (another mirror) doesn't add yet another copy.
                seenUrls.insert(url)
                if let metaHash { seenHashes.insert(metaHash) }
            }
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
                case .link: isBlock = !linksAreInline
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
        if isBlossomUrl(url) { return .unknownMedia(meta ?? MediaMeta(url: url)) }
        if isWebSocket { return .inlineLink(url) }
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

    /// Extracts the content-addressed SHA-256 digest from a media URL.
    /// Anchors the match to the end of the path component to avoid false
    /// positives from query parameters, tracking tokens, or mid-path segments.
    ///
    /// This is internal (not private) because it's used by `BlossomFallbackFetcher`
    /// to validate the hash when retrieving images from author servers.
    static func sha256Hash(fromUrl url: String) -> String? {
        guard let parsed = URL(string: url) else { return nil }
        let path = parsed.path
        let nsPath = path as NSString
        guard let match = sha256HashRegex.firstMatch(in: path, range: NSRange(location: 0, length: nsPath.length)) else { return nil }
        let hashRange = match.range(at: 1)
        guard hashRange.location != NSNotFound else { return nil }
        return nsPath.substring(with: hashRange).lowercased()
    }

    private static func isBlossomUrl(_ url: String) -> Bool {
        guard let parsed = URL(string: url) else { return false }
        let path = parsed.path
        let r = NSRange(location: 0, length: (path as NSString).length)
        return blossomPathRegex.firstMatch(in: path, range: r) != nil
    }

    private static func isStandaloneUrl(content: String, range: NSRange) -> Bool {
        // The URL qualifies for a block-level preview card when it ENDS its
        // line — i.e. the suffix from URL-end up to the next newline (or EOF)
        // is pure whitespace. We don't require the prefix to be empty too:
        // many posts read "…check it out: https://…" with the URL trailing
        // a sentence on the same line, and those should still get a card.
        // Mid-sentence URLs (text follows on the same line) stay inline.
        //
        // Position math stays in NSString (UTF-16) to avoid mixing Swift
        // Character distances with NSString offsets — multi-code-unit
        // emoji (⬛, 🟪) count as 1 Character but 2 code units and would
        // otherwise misalign the slice and trip isWhitespace.
        let nsContent = content as NSString
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
