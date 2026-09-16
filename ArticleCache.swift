import SwiftUI

/// Fetch + cache layer for NIP-23 long-form articles (kind 30023), keyed by
/// the addressable coordinate `"30023:<author>:<dTag>"`. Mirrors
/// `QuotedNoteCache`'s three-tier lookup — in-memory cache, local ObjectBox
/// event store, then a relay fan-out — with one addressable-specific twist:
/// kind 30023 is replaceable, so multiple versions (distinct event ids) can
/// come back for one coordinate and the highest `created_at` always wins.
@MainActor
final class ArticleCache {
    static let shared = ArticleCache()
    private var cache: [String: NostrEvent] = [:]
    private var inflight: [String: Task<NostrEvent?, Never>] = [:]

    private static let defaultRelays = [
        "wss://relay.damus.io",
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://relay.nostr.band"
    ]

    /// Second-pass fallbacks consulted when the embedded hint + defaults come
    /// back empty. Same breadth-oriented list as `QuotedNoteCache`.
    private static let extraRelays = [
        "wss://nostr.wine",
        "wss://relay.snort.social",
        "wss://offchain.pub",
        "wss://relay.nostr.bg",
        "wss://nostr-pub.wellorder.net",
        "wss://eden.nostr.land"
    ]

    static func coordinate(kind: Int = 30023, author: String, dTag: String) -> String {
        "\(kind):\(author):\(dTag)"
    }

    func cached(author: String, dTag: String) -> NostrEvent? {
        cache[Self.coordinate(author: author, dTag: dTag)]
    }

    /// Store a fetched article, keeping the newest version when relays
    /// disagree about which revision of the replaceable event is current.
    func store(_ event: NostrEvent) {
        guard event.kind == 30023,
              let dTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1]
        else { return }
        let key = Self.coordinate(author: event.pubkey, dTag: dTag)
        if let existing = cache[key], existing.createdAt >= event.createdAt { return }
        cache[key] = event
    }

    /// First-attempt fetch. Checks the in-memory cache, then the local
    /// ObjectBox event store (kind 30023 is persisted, so an article the user
    /// has already opened is free to retrieve), and finally fans out to the
    /// embedded hint + default relays.
    func fetch(author: String, dTag: String, relayHints: [String]) async -> NostrEvent? {
        let key = Self.coordinate(author: author, dTag: dTag)
        if let cached = cache[key] { return cached }
        if let stored = await EventStore.shared.loadAddressable(kind: 30023, author: author, dTag: dTag) {
            cache[key] = stored
            return stored
        }
        if let existing = inflight[key] { return await existing.value }
        return await runFetch(author: author, dTag: dTag, relayHints: relayHints, attempt: 0)
    }

    /// Forced retry — bumps the attempt counter and widens the relay set with
    /// the user's outbox-scored relays plus an extra fallback list. Used by
    /// the tap-to-retry affordance on the missing-article card and by the
    /// card's one automatic redundancy retry.
    func refetch(author: String, dTag: String, relayHints: [String], attempt: Int) async -> NostrEvent? {
        let key = Self.coordinate(author: author, dTag: dTag)
        if let cached = cache[key] { return cached }
        if let existing = inflight[key] { return await existing.value }
        return await runFetch(author: author, dTag: dTag, relayHints: relayHints, attempt: attempt)
    }

    private func runFetch(author: String, dTag: String, relayHints: [String], attempt: Int) async -> NostrEvent? {
        let key = Self.coordinate(author: author, dTag: dTag)
        let task = Task<NostrEvent?, Never> { [weak self] in
            guard let self else { return nil }
            let relays = self.relayList(hints: relayHints, attempt: attempt)
            // Retries get a longer window — broader relay sets contain slower
            // peers that need extra time. Matches QuotedNoteCache.
            let timeout: TimeInterval = attempt == 0 ? 6 : 10
            var filter = NostrFilter()
            filter.kinds = [30023]
            filter.authors = [author]
            filter.dTags = [dTag]
            let events = await RelayPool.query(relays: relays, filter: filter, timeout: timeout)
            // Replaceable event: different relays may hold different
            // revisions — take the newest matching one.
            return events
                .filter { event in
                    event.kind == 30023 && event.pubkey == author &&
                        event.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1] == dTag
                }
                .max(by: { $0.createdAt < $1.createdAt })
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        if let result {
            store(result)
            await EventStore.shared.persist([result])
        }
        return result
    }

    /// Build the relay set for a given attempt. Hints + a small default list
    /// cover the common case on attempt 0; higher attempts blend in the
    /// user's top-scored outbox relays and the extra fallback list, widening
    /// the cap to 12 relays. Same policy as `QuotedNoteCache.relayList`.
    private func relayList(hints: [String], attempt: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []

        func append(_ url: String) {
            guard let canon = RelayUrlValidator.canonicalize(url) else { return }
            if seen.insert(canon).inserted { out.append(canon) }
        }

        for r in hints { append(r) }
        for r in Self.defaultRelays { append(r) }

        if attempt > 0 {
            if let pubkey = NostrKey.load()?.pubkey,
               let board = RelayScoreBoard.load(pubkey: pubkey) {
                for entry in board.scoredRelays.prefix(6) { append(entry.url) }
            }
            for r in Self.extraRelays { append(r) }
        }

        let cap = attempt == 0 ? 6 : 12
        return Array(out.prefix(cap))
    }
}
