import SwiftUI

/// Fetch + cache layer for music-track events (kind 36787), keyed by the
/// addressable coordinate `"36787:<author>:<dTag>"`. A near-1:1 port of
/// `ArticleCache`: three-tier lookup — in-memory cache, local ObjectBox event
/// store, then a relay fan-out — with the same replaceable-event twist that
/// kind 36787 lives in the addressable (30000–39999) range, so multiple
/// revisions can come back for one coordinate and the highest `created_at`
/// always wins.
@MainActor
final class MusicTrackCache {
    static let shared = MusicTrackCache()
    private var cache: [String: NostrEvent] = [:]
    private var inflight: [String: Task<NostrEvent?, Never>] = [:]

    /// NIP-01 addressable kind for a single music track.
    static let kind = 36787

    private static let defaultRelays = [
        "wss://relay.damus.io",
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://relay.nostr.band"
    ]

    /// Second-pass fallbacks consulted when the embedded hint + defaults come
    /// back empty. Same breadth-oriented list as `ArticleCache`.
    private static let extraRelays = [
        "wss://nostr.wine",
        "wss://relay.snort.social",
        "wss://offchain.pub",
        "wss://relay.nostr.bg",
        "wss://nostr-pub.wellorder.net",
        "wss://eden.nostr.land"
    ]

    static func coordinate(author: String, dTag: String) -> String {
        "\(kind):\(author):\(dTag)"
    }

    func cached(author: String, dTag: String) -> NostrEvent? {
        cache[Self.coordinate(author: author, dTag: dTag)]
    }

    /// Store a fetched track, keeping the newest version when relays disagree
    /// about which revision of the replaceable event is current.
    func store(_ event: NostrEvent) {
        guard event.kind == Self.kind,
              let dTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1]
        else { return }
        let key = Self.coordinate(author: event.pubkey, dTag: dTag)
        if let existing = cache[key], existing.createdAt >= event.createdAt { return }
        cache[key] = event
    }

    /// First-attempt fetch. Checks the in-memory cache, then the local
    /// ObjectBox event store (a track the user has already seen is free to
    /// retrieve), and finally fans out to the embedded hint + default relays.
    func fetch(author: String, dTag: String, relayHints: [String]) async -> NostrEvent? {
        let key = Self.coordinate(author: author, dTag: dTag)
        if let cached = cache[key] { return cached }
        if let stored = await EventStore.shared.loadAddressable(kind: Self.kind, author: author, dTag: dTag) {
            cache[key] = stored
            return stored
        }
        if let existing = inflight[key] { return await existing.value }
        return await runFetch(author: author, dTag: dTag, relayHints: relayHints, attempt: 0)
    }

    /// Forced retry — bumps the attempt counter and widens the relay set with
    /// the user's outbox-scored relays plus an extra fallback list. Used by the
    /// tap-to-retry affordance on the missing-track card and by the card's one
    /// automatic redundancy retry.
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
            // peers that need extra time. Matches ArticleCache.
            let timeout: TimeInterval = attempt == 0 ? 6 : 10
            var filter = NostrFilter()
            filter.kinds = [Self.kind]
            filter.authors = [author]
            filter.dTags = [dTag]
            let events = await RelayPool.query(relays: relays, filter: filter, timeout: timeout)
            // Replaceable event: different relays may hold different revisions —
            // take the newest matching one.
            return events
                .filter { event in
                    event.kind == Self.kind && event.pubkey == author &&
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
    /// cover the common case on attempt 0; higher attempts blend in the user's
    /// top-scored outbox relays and the extra fallback list, widening the cap to
    /// 12 relays. Same policy as `ArticleCache.relayList`.
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
