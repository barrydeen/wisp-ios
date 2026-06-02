import Foundation

/// Shared `:shortcode:` custom-emoji logic used by every compose surface.
///
/// The note composer grew its own `:`-trigger + insert + (missing) tagging
/// inline; the DM / NIP-29 group / live-stream inputs had none. These helpers
/// are the single source of truth so all surfaces detect, insert, and tag
/// custom emoji identically. Pure string work is `nonisolated` so it can run
/// off the main actor (see project notes on MainActor-default isolation).
enum EmojiShortcode {

    // MARK: - Trigger detection

    /// Detect a `:partial` shortcode token immediately to the left of the
    /// caret. Returns the typed query (the text after the `:`) and the UTF-16
    /// offset of the opening `:` (what `insert` / `selectEmoji` expect), or
    /// `nil` when the caret isn't inside an open shortcode token.
    ///
    /// Rules: walk back from the caret collecting the token; bail on
    /// whitespace/newline (a shortcode can't contain one); the `:` must open a
    /// token (be at start-of-text or preceded by whitespace) so we don't fire
    /// inside `http://…` or `a:b`; the query must be non-empty.
    nonisolated static func detectTrigger(in text: String, caretUtf16: Int) -> (query: String, startUtf16: Int)? {
        let ns = text as NSString
        let caret = max(0, min(caretUtf16, ns.length))
        guard caret > 0 else { return nil }
        let prefix = ns.substring(to: caret)

        var colon: String.Index?
        var idx = prefix.endIndex
        while idx > prefix.startIndex {
            let p = prefix.index(before: idx)
            let ch = prefix[p]
            if ch == ":" { colon = p; break }
            // A shortcode is `[a-zA-Z0-9_-]+`; any whitespace/newline ends the
            // search without a trigger.
            if ch.isWhitespace || ch.isNewline { return nil }
            idx = p
        }
        guard let colon else { return nil }

        // The `:` must begin a token.
        if colon > prefix.startIndex {
            let before = prefix[prefix.index(before: colon)]
            if !(before.isWhitespace || before.isNewline) { return nil }
        }

        let query = String(prefix[prefix.index(after: colon)..<prefix.endIndex])
        guard !query.isEmpty else { return nil }

        let utf16Offset = prefix.utf16.distance(
            from: prefix.utf16.startIndex,
            to: colon.samePosition(in: prefix.utf16) ?? prefix.utf16.startIndex
        )
        return (query, utf16Offset)
    }

    // MARK: - Insertion

    /// Splice `":\(shortcode): "` into `text` at the UTF-16 offset of an open
    /// `:` token, replacing the partial token. Mirrors the original
    /// `ComposeViewModel.selectEmoji` so callers stay byte-for-byte
    /// compatible; the caret is restored separately via `caretAfterDiff`.
    nonisolated static func insert(_ shortcode: String, into text: String, atUtf16 startOffset: Int) -> String {
        let s = text
        guard let utf16Start = s.utf16.index(s.utf16.startIndex, offsetBy: startOffset, limitedBy: s.utf16.endIndex),
              let start = String.Index(utf16Start, within: s) else { return text }
        var end = start
        while end < s.endIndex, !isTokenBreak(s[end]) { end = s.index(after: end) }
        var out = s
        out.replaceSubrange(start..<end, with: ":\(shortcode): ")
        return out
    }

    /// Token boundary used by `insert`: whitespace ends the token, except a
    /// non-breaking space (kept so NBSP-joined display names stay intact).
    private nonisolated static func isTokenBreak(_ c: Character) -> Bool {
        if c == "\u{00A0}" { return false }
        return c.isWhitespace
    }

    // MARK: - NIP-30 publish tagging

    /// Scan `content` for `:shortcode:` occurrences and build NIP-30
    /// `["emoji", shortcode, url]` tags for every shortcode `resolve` maps to a
    /// URL. Shortcodes are de-duped; unresolved ones are silently dropped
    /// (they stay as literal `:text:` and render as plain text everywhere).
    nonisolated static func emojiTags(in content: String, resolve: (String) -> String?) -> [[String]] {
        guard content.contains(":"),
              let regex = try? NSRegularExpression(pattern: #":([a-zA-Z0-9_-]+):"#) else { return [] }
        let ns = content as NSString
        var seen = Set<String>()
        var tags: [[String]] = []
        regex.enumerateMatches(in: content, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            let range = match.range(at: 1)
            guard range.location != NSNotFound else { return }
            let code = ns.substring(with: range)
            guard seen.insert(code).inserted else { return }
            if let url = resolve(code) { tags.append(["emoji", code, url]) }
        }
        return tags
    }

    /// Convenience resolving against the active user's own custom emoji.
    @MainActor
    static func emojiTags(in content: String) -> [[String]] {
        let map = EmojiRepository.shared.resolvedCustomMap
        return emojiTags(in: content) { map[$0] }
    }
}

// MARK: - EmojiComposing

/// Adopted by chat view-models (DM / group / live) so they get the `:`-emoji
/// trigger + insert behavior for free. The note composer keeps its own
/// (mention-aware) implementation but shares `EmojiShortcode.insert`.
@MainActor
protocol EmojiComposing: AnyObject {
    /// The draft text being edited. View-models backed by a differently-named
    /// property expose it via a computed `draft` bridge.
    var draft: String { get set }
    var emojiCandidates: [CustomEmoji] { get set }
    /// UTF-16 offset of the open `:` currently being completed, if any.
    var emojiStartUtf16: Int? { get set }
}

extension EmojiComposing {
    /// Refresh the candidate list for the partial shortcode under the caret.
    func updateEmojiTrigger(query: String?, atOffsetUtf16: Int?) {
        emojiStartUtf16 = atOffsetUtf16
        if let query {
            emojiCandidates = EmojiRepository.shared.search(query: query)
        } else {
            emojiCandidates = []
        }
    }

    /// Insert the picked emoji's shortcode at the tracked offset and clear the
    /// trigger. The bound text view re-syncs and restores the caret.
    func selectEmoji(_ emoji: CustomEmoji) {
        guard let startOffset = emojiStartUtf16 else { return }
        draft = EmojiShortcode.insert(emoji.shortcode, into: draft, atUtf16: startOffset)
        emojiCandidates = []
        emojiStartUtf16 = nil
    }
}
