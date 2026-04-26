import Foundation

/// In-memory + UserDefaults cache of NIP-65 (kind:10002) read/write relay lists.
///
/// Threads need a pubkey's *read* (inbox) relays to discover replies and to publish replies that
/// will reach that pubkey. Onboarding's outbox builder only keeps write relays for the score board,
/// so this repository handles the inbox axis separately. Falls back to an on-demand indexer query
/// when a pubkey isn't cached.
@MainActor
final class RelayListRepository {
    static let shared = RelayListRepository()

    private struct Entry {
        let read: [String]
        let write: [String]
        let updatedAt: Int
    }

    private var cache: [String: Entry] = [:]
    private var inflight: [String: Task<Entry?, Never>] = [:]

    private static let indexerRelays = [
        "wss://indexer.nostrarchives.com",
        "wss://indexer.coracle.social",
        "wss://relay.damus.io",
        "wss://relay.primal.net"
    ]

    // MARK: - Public read API

    func getReadRelays(_ pubkey: String) async -> [String] {
        let entry = await loadEntry(pubkey)
        if let read = entry?.read, !read.isEmpty { return read }
        // Fall back to write relays so that "anyone who follows them" still has a chance of seeing it.
        return entry?.write ?? []
    }

    func getWriteRelays(_ pubkey: String) async -> [String] {
        let entry = await loadEntry(pubkey)
        if let write = entry?.write, !write.isEmpty { return write }
        return entry?.read ?? []
    }

    /// Synchronous lookup against the in-memory + UserDefaults cache only. Returns nil on miss.
    func cachedReadRelays(_ pubkey: String) -> [String]? {
        if let entry = cache[pubkey] {
            if !entry.read.isEmpty { return entry.read }
            return entry.write.isEmpty ? nil : entry.write
        }
        if let entry = loadFromDefaults(pubkey) {
            cache[pubkey] = entry
            if !entry.read.isEmpty { return entry.read }
            return entry.write.isEmpty ? nil : entry.write
        }
        return nil
    }

    // MARK: - Ingest

    /// Update the cache from a kind:10002 event. Newer `createdAt` wins.
    @discardableResult
    func ingest(_ event: NostrEvent) -> Bool {
        guard event.kind == 10002 else { return false }
        if let existing = cache[event.pubkey], event.createdAt <= existing.updatedAt { return false }

        var read: [String] = []
        var write: [String] = []
        for tag in event.tags {
            guard tag.count >= 2, tag[0] == "r" else { continue }
            let url = tag[1]
            guard RelayUrlValidator.isValid(url) else { continue }
            if tag.count == 2 {
                read.append(url); write.append(url)
            } else {
                switch tag[2] {
                case "read": read.append(url)
                case "write": write.append(url)
                default: read.append(url); write.append(url)
                }
            }
        }

        let entry = Entry(read: read, write: write, updatedAt: event.createdAt)
        cache[event.pubkey] = entry
        saveToDefaults(event.pubkey, entry)
        return true
    }

    // MARK: - Private

    private func loadEntry(_ pubkey: String) async -> Entry? {
        if let entry = cache[pubkey] { return entry }
        if let entry = loadFromDefaults(pubkey) {
            cache[pubkey] = entry
            return entry
        }
        if let task = inflight[pubkey] { return await task.value }

        let task = Task<Entry?, Never> { [weak self] in
            await self?.fetchFromRelays(pubkey)
        }
        inflight[pubkey] = task
        let result = await task.value
        inflight[pubkey] = nil
        return result
    }

    private func fetchFromRelays(_ pubkey: String) async -> Entry? {
        let events = await RelayPool.query(
            relays: Self.indexerRelays,
            filter: NostrFilter(kinds: [10002], authors: [pubkey], limit: 1),
            timeout: 5
        )
        guard let best = events
            .filter({ $0.kind == 10002 })
            .max(by: { $0.createdAt < $1.createdAt }) else { return nil }
        ingest(best)
        return cache[pubkey]
    }

    // MARK: - Persistence

    private func saveToDefaults(_ pubkey: String, _ entry: Entry) {
        let dict: [String: Any] = [
            "r": entry.read,
            "w": entry.write,
            "t": entry.updatedAt
        ]
        UserDefaults.standard.set(dict, forKey: "relaylist_\(pubkey)")
    }

    private func loadFromDefaults(_ pubkey: String) -> Entry? {
        guard let dict = UserDefaults.standard.dictionary(forKey: "relaylist_\(pubkey)") else { return nil }
        let read = dict["r"] as? [String] ?? []
        let write = dict["w"] as? [String] ?? []
        let updatedAt = dict["t"] as? Int ?? 0
        guard !read.isEmpty || !write.isEmpty else { return nil }
        return Entry(read: read, write: write, updatedAt: updatedAt)
    }
}
