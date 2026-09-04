import Foundation

/// One block of a parsed NIP-23 article body. 1:1 port of Android's
/// `MdBlock` (`ArticleScreen.kt`).
nonisolated enum MdBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case image(url: String, alt: String?)
    case codeBlock(code: String, language: String?)
    case blockQuote(String)
    case horizontalRule
    /// A standalone nostr entity line, normalized to a `nostr:`-prefixed URI.
    /// Rendered by delegating back to `RichContentView`.
    case nostrEmbed(content: String)
}

/// Line-based markdown block parser for long-form articles. Deliberately a
/// 1:1 port of Android's `parseMarkdownBlocks` — same feature set (headings,
/// paragraphs, images, fenced code, blockquotes, horizontal rules, nostr
/// embeds), same omissions (no lists, no tables, no strikethrough), and the
/// same quirks (blockquotes absorb non-empty continuation lines, inline
/// images are extracted out of paragraphs into their own blocks).
nonisolated enum MarkdownBlocks {

    // Same regexes as Android (`ArticleScreen.kt:720-723`).
    static let imageLineRegex = try! NSRegularExpression(
        pattern: #"^!\[([^\]]*)\]\((\S+?)(?:\s+"[^"]*")?\)\s*$"#
    )
    static let inlineImageRegex = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\((\S+?)(?:\s+"[^"]*")?\)"#
    )
    static let nostrEntityLineRegex = try! NSRegularExpression(
        pattern: #"^(?:nostr:)?(?:note1|nevent1|npub1|nprofile1|naddr1)[a-z0-9]+$"#,
        options: [.caseInsensitive]
    )
    static let nostrInlineRegex = try! NSRegularExpression(
        pattern: #"(?:nostr:)?(?:note1|nevent1|npub1|nprofile1|naddr1)[a-z0-9]+"#,
        options: [.caseInsensitive]
    )
    static let horizontalRuleRegex = try! NSRegularExpression(
        pattern: #"^[-*_]{3,}\s*$"#
    )
    static let emojiShortcodeRegex = try! NSRegularExpression(
        pattern: #":([a-zA-Z0-9_-]+):"#
    )

    /// The pubkey an inline entity refers to, when it refers to a person.
    /// Nil for note / event / address refs.
    ///
    /// Article bodies carry mentions as raw bech32 inside markdown text, not
    /// as parsed segments the way note content does, so resolving a name
    /// starts by decoding the entity here.
    static func profilePubkey(from entity: String) -> String? {
        var bare = entity
        for prefix in ["nostr:", "NOSTR:"] where bare.hasPrefix(prefix) {
            bare = String(bare.dropFirst(prefix.count))
        }
        let lower = bare.lowercased()
        guard lower.hasPrefix("npub1") || lower.hasPrefix("nprofile1") else { return nil }
        guard case .profileRef(let pubkey, _)? = Nip19.decodeNostrUri(lower) else { return nil }
        return pubkey
    }

    /// Every pubkey mentioned in an article body, so the profiles behind them
    /// can be fetched. Without this the renderer has nothing to resolve
    /// against and every mention falls back to a short npub.
    static func profileMentions(in content: String) -> [String] {
        let ns = content as NSString
        let matches = nostrInlineRegex.matches(
            in: content, range: NSRange(location: 0, length: ns.length)
        )
        var seen = Set<String>()
        var pubkeys: [String] = []
        for m in matches {
            guard let pubkey = profilePubkey(from: ns.substring(with: m.range)) else { continue }
            if seen.insert(pubkey).inserted { pubkeys.append(pubkey) }
        }
        return pubkeys
    }

    /// Shorten a nostr bech32 entity for inline display — `@npub1xxxx…` for
    /// profile refs, `nevent1xxxx…` for the rest. Port of Android's
    /// `shortenNostrEntity`.
    ///
    /// Only a last resort for a person: a mention resolves to a display name
    /// via `profilePubkey(from:)` first, and reaches this truncated bech32
    /// only when the entity doesn't decode.
    static func shortenNostrEntity(_ entity: String) -> String {
        var bare = entity
        for prefix in ["nostr:", "NOSTR:"] where bare.hasPrefix(prefix) {
            bare = String(bare.dropFirst(prefix.count))
        }
        let lower = bare.lowercased()
        if lower.hasPrefix("npub1") || lower.hasPrefix("nprofile1") {
            return "@\(bare.prefix(10))..."
        }
        return "\(bare.prefix(12))..."
    }

    static func parse(_ content: String) -> [MdBlock] {
        var blocks: [MdBlock] = []
        let lines = content.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                // Empty line — skip.
                i += 1
            } else if trimmed.hasPrefix("```") {
                // Fenced code block.
                let fenceRest = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let language = fenceRest.isEmpty ? nil : fenceRest
                var codeLines: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }  // skip closing ```
                blocks.append(.codeBlock(code: codeLines.joined(separator: "\n"), language: language))
            } else if trimmed.hasPrefix("#") {
                // Heading. Note: only `level` (≤6) marker chars are dropped —
                // surplus '#' beyond six stays in the text, matching Android.
                let level = min(trimmed.prefix(while: { $0 == "#" }).count, 6)
                let text = String(trimmed.dropFirst(level))
                    .trimmingLeadingWhitespace()
                blocks.append(.heading(level: level, text: text))
                i += 1
            } else if fullMatch(horizontalRuleRegex, trimmed) {
                blocks.append(.horizontalRule)
                i += 1
            } else if let img = imageLineMatch(trimmed) {
                // Standalone image.
                blocks.append(.image(url: img.url, alt: img.alt))
                i += 1
            } else if fullMatch(nostrEntityLineRegex, trimmed) {
                // Standalone nostr entity (nevent, nprofile, naddr, note, npub).
                let normalized = trimmed.lowercased().hasPrefix("nostr:") ? trimmed : "nostr:\(trimmed)"
                blocks.append(.nostrEmbed(content: normalized))
                i += 1
            } else if trimmed.hasPrefix(">") {
                // Block quote. Android quirk preserved: once started, the
                // quote also absorbs non-empty continuation lines that lack
                // the `>` prefix, stopping at the first empty line.
                var quoteLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") || (!t.isEmpty && !quoteLines.isEmpty) else { break }
                    var stripped = t
                    if stripped.hasPrefix(">") { stripped = String(stripped.dropFirst()) }
                    quoteLines.append(stripped.trimmingLeadingWhitespace())
                    i += 1
                }
                blocks.append(.blockQuote(quoteLines.joined(separator: " ")))
            } else {
                // Paragraph — collect consecutive non-empty lines, breaking
                // on any block starter.
                var paraLines: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.isEmpty || l.hasPrefix("#") || l.hasPrefix("```")
                        || l.hasPrefix(">") || fullMatch(horizontalRuleRegex, l) {
                        break
                    }
                    // Standalone images / nostr entities become their own block.
                    if imageLineMatch(l) != nil { break }
                    if fullMatch(nostrEntityLineRegex, l) { break }
                    paraLines.append(l)
                    i += 1
                }
                if !paraLines.isEmpty {
                    let text = paraLines.joined(separator: " ")
                    // Extract any inline images from the paragraph text.
                    let ns = text as NSString
                    let imageMatches = inlineImageRegex.matches(
                        in: text, range: NSRange(location: 0, length: ns.length)
                    )
                    let cleanedText = inlineImageRegex.stringByReplacingMatches(
                        in: text,
                        range: NSRange(location: 0, length: ns.length),
                        withTemplate: ""
                    ).trimmingCharacters(in: .whitespaces)
                    if !cleanedText.isEmpty {
                        blocks.append(.paragraph(cleanedText))
                    }
                    for match in imageMatches {
                        let alt = ns.substring(with: match.range(at: 1))
                        let url = ns.substring(with: match.range(at: 2))
                        blocks.append(.image(url: url, alt: alt.isEmpty ? nil : alt))
                    }
                }
            }
        }
        return blocks
    }

    // MARK: - Helpers

    /// Whether `regex` matches the *entire* string — Kotlin `Regex.matches`
    /// semantics (the patterns used here are `^…$`-anchored, so a non-nil
    /// firstMatch is equivalent, but the explicit range check keeps it exact).
    private static func fullMatch(_ regex: NSRegularExpression, _ s: String) -> Bool {
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let m = regex.firstMatch(in: s, range: full) else { return false }
        return NSEqualRanges(m.range, full)
    }

    private static func imageLineMatch(_ s: String) -> (url: String, alt: String?)? {
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let m = imageLineRegex.firstMatch(in: s, range: full) else { return nil }
        let alt = ns.substring(with: m.range(at: 1))
        let url = ns.substring(with: m.range(at: 2))
        return (url: url, alt: alt.isEmpty ? nil : alt)
    }
}

private extension String {
    /// Kotlin `trimStart()` — strip leading whitespace only.
    func trimmingLeadingWhitespace() -> String {
        guard let idx = firstIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(self[idx...])
    }
}
