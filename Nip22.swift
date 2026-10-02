import Foundation

/// NIP-22 comments (kind 1111).
///
/// A comment is always scoped to a root — either a nostr event (`E`/`A` tags)
/// or an external identifier (`I` tag, per NIP-73: a URL, podcast GUID,
/// geohash, ISBN…). Uppercase tags name the *root* scope, lowercase name the
/// *immediate parent*, so a top-level comment repeats the same value in both.
///
/// Two jobs. Rendering: recover enough context that a comment on a web page
/// doesn't read as a stray remark with no subject — see `ExternalRef`.
/// Composing: a reply to a comment must itself be a kind 1111 carrying the
/// parent's root scope forward, whether that root is an external identifier
/// or a nostr event — see `buildReplyTags(to:relayHint:)` and
/// `ComposeViewModel`.
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

    // MARK: - Event-rooted comments

    // A comment can be scoped to a nostr event instead of an external
    // identifier, and in the wild that root is very often a plain kind-1
    // note: a thread starts in NIP-10 and a participant's client switches to
    // comments partway down, carrying `E` = the kind-1 root with `K` = "1".

    /// The event this comment is rooted on (uppercase `E`), or nil when the
    /// root is external or addressable.
    static func rootEventId(of event: NostrEvent) -> String? {
        tagValue(event, "E")
    }

    /// The comment's immediate parent event (lowercase `e`). Equals the root
    /// for a top-level comment; points at another comment further down.
    static func parentEventId(of event: NostrEvent) -> String? {
        tagValue(event, "e")
    }

    /// First value of the first tag with this exact name. Case matters — `E`
    /// and `e` mean different things in this NIP, so this deliberately does
    /// not fold case.
    private static func tagValue(_ event: NostrEvent, _ name: String) -> String? {
        guard let tag = event.tags.first(where: { $0.count >= 2 && $0[0] == name }),
              !tag[1].isEmpty else { return nil }
        return tag[1]
    }

    /// Build the tag set for a kind-1111 reply to `parent`, carrying its root
    /// scope forward unchanged and pointing the lowercase tags at `parent`.
    ///
    /// Any comment parent qualifies — externally rooted (`I`) or event-rooted
    /// (`E`/`A`). NIP-22 forbids answering a comment with a kind-1: the root
    /// scope has to survive the hop, and a kind-1's NIP-10 `e` tags can neither
    /// express an `I` root nor stay visible to `#E` readers, which is how a
    /// branch silently drops out of every comment-aware client. The uppercase
    /// scope is copied verbatim from the parent (the same thing Ditto does in
    /// `usePostComment`), the lowercase side points at the parent event.
    /// Returns nil when `parent` isn't a comment carrying a root scope —
    /// callers fall back to NIP-10 kind-1 threading for plain notes.
    static func buildReplyTags(to parent: NostrEvent, relayHint: String = "") -> [[String]]? {
        guard isComment(parent) else { return nil }
        // Copy the root scope verbatim, one tag per name: `E`/`A`/`I` name the
        // root, `K` its kind, `P` its author. A parent without any of E/A/I is
        // malformed — the reply would be unscoped and unthreadable, so refuse.
        let rootScopeNames: Set<String> = ["E", "A", "I", "K", "P"]
        var seenNames = Set<String>()
        let rootScope = parent.tags.filter { tag in
            guard let name = tag.first, rootScopeNames.contains(name),
                  tag.count >= 2, !tag[1].isEmpty else { return false }
            return seenNames.insert(name).inserted
        }
        guard rootScope.contains(where: { $0[0] == "E" || $0[0] == "A" || $0[0] == "I" }) else {
            return nil
        }

        var tags = rootScope
        // Parent is the comment itself — an event — so the lowercase side uses
        // e/k/p regardless of which form the root scope takes.
        tags.append(["e", parent.id, relayHint, parent.pubkey])
        tags.append(["k", String(kindComment)])
        tags.append(["p", parent.pubkey])
        return tags
    }

    /// Whether `event` belongs on the thread screen rooted at `targets` — the
    /// thread's root id and/or focal id, plus any NIP-22 comment anchors.
    ///
    /// The two threading systems answer this differently. A kind-1 NIP-10
    /// reply carries the conversation root in a lowercase `e` tag, so a
    /// `#e = root` filter reaches its whole tree. A NIP-22 comment carries
    /// only its *immediate parent* in lowercase `e` and names the root in
    /// uppercase `E` — so a comment-to-comment reply matches no lowercase
    /// check even though it hangs off the same root. Thread display and the
    /// live reply stream must accept both forms.
    static func threadsOffRoot(_ event: NostrEvent, targets: Set<String>) -> Bool {
        var parentEventIds: [String] = []
        var rootEventIds: [String] = []
        for tag in event.tags where tag.count >= 2 {
            switch tag[0] {
            case "e": parentEventIds.append(tag[1])
            case "E": rootEventIds.append(tag[1])
            default: break
            }
        }
        return parentEventIds.contains(where: targets.contains)
            || rootEventIds.contains(where: targets.contains)
    }
}
