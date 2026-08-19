import Foundation

/// NIP-22 comments (kind 1111).
///
/// A comment is always scoped to a root — either a nostr event (`E`/`A` tags)
/// or an external identifier (`I` tag, per NIP-73: a URL, podcast GUID,
/// geohash, ISBN…). Uppercase tags name the *root* scope, lowercase name the
/// *immediate parent*, so a top-level comment repeats the same value in both.
///
/// Wisp only renders these; it doesn't compose them yet. The job here is to
/// recover enough context that a comment on a web page doesn't read as a
/// stray remark with no subject — see `ExternalContentRef`.
nonisolated enum Nip22 {
    static let kindComment = 1111

    /// The external thing a comment is scoped to, when the scope isn't a
    /// nostr event. `kind` is NIP-73's identifier type (`web`, `podcast:item:guid`,
    /// `isbn`, …); `value` is the identifier itself.
    struct ExternalRef: Equatable {
        let value: String
        let kind: String
        /// Optional hint from the tag's third position — for non-URL
        /// identifiers this is where a human-openable page lives (e.g. a
        /// podcast GUID pointing at its episode page).
        let hint: String?

        /// The URL a "view the original" affordance should open, if any.
        /// Prefers the hint, since for non-`web` kinds the value itself isn't
        /// openable (`podcast:item:guid:…` is an identifier, not a link).
        var openableURL: URL? {
            if let hint, let url = URL(string: hint), url.scheme?.hasPrefix("http") == true {
                return url
            }
            guard kind == "web", let url = URL(string: value),
                  url.scheme?.hasPrefix("http") == true else { return nil }
            return url
        }

        /// Host shown as the source label, e.g. "bitcoinmagazine.com".
        var displayHost: String? {
            guard let host = openableURL?.host else { return nil }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }

    static func isComment(_ event: NostrEvent) -> Bool { event.kind == kindComment }

    /// The comment's root scope when it's external (an `I` tag), else nil.
    ///
    /// Returns nil for comments rooted on a nostr event — those already render
    /// with their parent inline, so they need no extra treatment.
    static func externalRoot(of event: NostrEvent) -> ExternalRef? {
        guard isComment(event) else { return nil }
        // A comment scoped to a nostr event carries E/A; only treat I as the
        // root when neither is present, matching the spec's "root scope"
        // exclusivity.
        let hasEventRoot = event.tags.contains { $0.first == "E" || $0.first == "A" }
        guard !hasEventRoot else { return nil }
        guard let iTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "I" }) else { return nil }
        let kind = event.tags.first(where: { $0.count >= 2 && $0[0] == "K" })?[1] ?? "web"
        let hint = iTag.count >= 3 && !iTag[2].isEmpty ? iTag[2] : nil
        return ExternalRef(value: iTag[1], kind: kind, hint: hint)
    }

    /// The comment's immediate parent when it's external (a lowercase `i` tag).
    /// Equals the root for a top-level comment; differs when replying to
    /// another comment on the same external item.
    static func externalParent(of event: NostrEvent) -> ExternalRef? {
        guard isComment(event) else { return nil }
        let hasEventParent = event.tags.contains { $0.first == "e" || $0.first == "a" }
        guard !hasEventParent else { return nil }
        guard let iTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "i" }) else { return nil }
        let kind = event.tags.first(where: { $0.count >= 2 && $0[0] == "k" })?[1] ?? "web"
        let hint = iTag.count >= 3 && !iTag[2].isEmpty ? iTag[2] : nil
        return ExternalRef(value: iTag[1], kind: kind, hint: hint)
    }

    /// Build the tag set for a kind-1111 reply to `parent`, carrying its root
    /// scope forward unchanged and pointing the lowercase tags at `parent`.
    ///
    /// Only the external-root case is supported, which is the one Wisp can
    /// currently reply to.
    static func buildReplyTags(to parent: NostrEvent, relayHint: String = "") -> [[String]]? {
        guard let root = externalRoot(of: parent) else { return nil }

        var tags: [[String]] = []
        var rootTag = ["I", root.value]
        if let hint = root.hint { rootTag.append(hint) }
        tags.append(rootTag)
        tags.append(["K", root.kind])

        // Parent is the comment itself — an event — so the lowercase side uses
        // e/k/p rather than repeating the I tag.
        tags.append(["e", parent.id, relayHint, parent.pubkey])
        tags.append(["k", String(kindComment)])
        tags.append(["p", parent.pubkey])

        // Carry the root author forward when the parent named one.
        if let rootAuthor = parent.tags.first(where: { $0.count >= 2 && $0[0] == "P" }) {
            tags.append(rootAuthor)
        }
        return tags
    }
}
