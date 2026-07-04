import Foundation

enum BlossomServerList {
    /// First entry of `defaultServers`. Kept for single-value callers
    /// (e.g. initial seed in `ComposeViewModel`); use `defaultServers` for the
    /// full multi-default list passed to `BlossomClient.upload`.
    static let defaultServer = "https://blossom.primal.net"

    /// Multi-default server list. Distributed community servers reduce the
    /// primal.net choke point when no user list is stored. Ordering is
    /// significant: the first server is tried first.
    static let defaultServers: [String] = [
        "https://blossom.primal.net",
        "https://nostr.build",
        "https://cdn.nostrcheck.me",
    ]

    static let kindServerList = 10063

    /// Set true while `MediaServersView` is on screen so background `refresh(...)`
    /// calls (e.g. from the composer) don't stomp the user's in-progress edits.
    nonisolated(unsafe) static var editorOpen = false

    /// Returns `true` only when the user has explicitly saved a server list for
    /// this pubkey. Used by `BlossomFallbackFetcher` to skip fallback for
    /// authors with no published kind-10063 list — there are no servers we can
    /// meaningfully try, so we return nil instead of bouncing off primal.net.
    static func hasStoredServers(for pubkey: String) -> Bool {
        !((UserDefaults.standard.stringArray(forKey: storageKey(pubkey)) ?? []).isEmpty)
    }

    /// Cached server list for the given pubkey, or the multi-default fallback.
    static func cached(for pubkey: String) -> [String] {
        let stored = UserDefaults.standard.stringArray(forKey: storageKey(pubkey)) ?? []
        return stored.isEmpty ? defaultServers : stored
    }

    /// Persist a user-edited server list. Empty input is floored to the defaults
    /// so a stray "save []" never produces a kind-10063 with zero `server` tags.
    static func save(servers: [String], for pubkey: String) {
        let final = servers.isEmpty ? defaultServers : servers
        UserDefaults.standard.set(final, forKey: storageKey(pubkey))
    }

    /// Fetch the user's kind-10063 server list from their write relays and cache it.
    /// Falls back to `[defaultServer]` if no event is found. Cheap to call repeatedly —
    /// caller is expected to invoke on first composer open per session.
    static func refresh(for pubkey: String) async -> [String] {
        let writeRelays = topWriteRelays(for: pubkey, limit: 5)
        guard !writeRelays.isEmpty else {
            cache(servers: defaultServers, for: pubkey)
            return defaultServers
        }
        let events = await RelayPool.query(
            relays: writeRelays,
            filter: NostrFilter(kinds: [kindServerList], authors: [pubkey], limit: 5),
            timeout: 6
        )
        let latest = events
            .filter { $0.kind == kindServerList }
            .max(by: { $0.createdAt < $1.createdAt })

        guard let event = latest else {
            cache(servers: defaultServers, for: pubkey)
            return defaultServers
        }
        let servers = parseServers(event)
        let final = servers.isEmpty ? defaultServers : servers
        if !editorOpen {
            cache(servers: final, for: pubkey)
        }
        return final
    }

    private static func parseServers(_ event: NostrEvent) -> [String] {
        var out: [String] = []
        for tag in event.tags where tag.count >= 2 && tag[0] == "server" {
            let url = tag[1]
            guard !url.isEmpty, !out.contains(url) else { continue }
            // Defense-in-depth: a kind-10063 event is published by the user but
            // mirrored through relays they don't control. Re-validate via the
            // shared normalizer so anything that doesn't match HTTPS + valid
            // host is dropped here, not later at request time.
            guard BlossomClient.normalizeServerURL(url) != nil else { continue }
            out.append(url)
        }
        return out
    }

    private static func topWriteRelays(for pubkey: String, limit: Int) -> [String] {
        guard let board = RelayScoreBoard.load(pubkey: pubkey) else { return [] }
        return board.scoredRelays.prefix(limit).map(\.url)
    }

    private static func cache(servers: [String], for pubkey: String) {
        UserDefaults.standard.set(servers, forKey: storageKey(pubkey))
    }

    private static func storageKey(_ pubkey: String) -> String {
        "blossom_servers_\(pubkey)"
    }
}
