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

    /// A peer's kind-10050 list, cached the same way as kind-10002. `nil` ←→
    /// "never queried"; `[]` ←→ "fetched, peer has no DM relays". The distinction
    /// matters: an empty list is a definitive signal that DMs to this peer can't
    /// be routed via kind-10050, so callers should fall through to the kind-10002
    /// inbox set rather than re-querying.
    private struct DmEntry {
        let relays: [String]
        let updatedAt: Int
    }

    private var cache: [String: Entry] = [:]
    private var inflight: [String: Task<Entry?, Never>] = [:]
    private var dmCache: [String: DmEntry] = [:]
    private var dmInflight: [String: Task<DmEntry?, Never>] = [:]

    private static let indexerRelays = RelayDefaults.indexers

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

    /// Peer's kind-10050 DM inbox relays. Returns `nil` only when the lookup
    /// failed (no indexer response, network error). Returns `[]` when the
    /// fetch definitively confirmed the peer has no kind-10050 — callers
    /// should treat this as "fall through to NIP-65 inbox" rather than retry.
    func getDmRelays(_ pubkey: String) async -> [String]? {
        if let entry = dmCache[pubkey] { return entry.relays }
        if let entry = loadDmFromDefaults(pubkey) {
            dmCache[pubkey] = entry
            return entry.relays
        }
        if let task = dmInflight[pubkey] { return await task.value?.relays }

        let task = Task<DmEntry?, Never> { [weak self] in
            await self?.fetchDmFromRelays(pubkey)
        }
        dmInflight[pubkey] = task
        let result = await task.value
        dmInflight[pubkey] = nil
        return result?.relays
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
            guard let url = RelayUrlValidator.canonicalize(tag[1]) else { continue }
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

    // MARK: - DM relay ingest + fetch

    /// Update the DM relay cache from a kind-10050 event. Newer `createdAt` wins.
    @discardableResult
    func ingestDm(_ event: NostrEvent) -> Bool {
        guard event.kind == Nip51Lists.kindDmRelays else { return false }
        if let existing = dmCache[event.pubkey], event.createdAt <= existing.updatedAt { return false }
        let relays = Nip51Lists.parseRelaySetList(event)
        let entry = DmEntry(relays: relays, updatedAt: event.createdAt)
        dmCache[event.pubkey] = entry
        saveDmToDefaults(event.pubkey, entry)
        return true
    }

    private func fetchDmFromRelays(_ pubkey: String) async -> DmEntry? {
        let events = await RelayPool.query(
            relays: Self.indexerRelays,
            filter: NostrFilter(kinds: [Nip51Lists.kindDmRelays], authors: [pubkey], limit: 1),
            timeout: 5
        )
        let best = events
            .filter({ $0.kind == Nip51Lists.kindDmRelays })
            .max(by: { $0.createdAt < $1.createdAt })
        if let best {
            ingestDm(best)
            return dmCache[pubkey]
        }
        // No event found — cache the negative result so we don't repeatedly
        // hit the network for peers without a published DM relay list.
        let empty = DmEntry(relays: [], updatedAt: Int(Date().timeIntervalSince1970))
        dmCache[pubkey] = empty
        saveDmToDefaults(pubkey, empty)
        return empty
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

    private func saveDmToDefaults(_ pubkey: String, _ entry: DmEntry) {
        let dict: [String: Any] = [
            "relays": entry.relays,
            "t": entry.updatedAt
        ]
        UserDefaults.standard.set(dict, forKey: "peer_dm_relays_\(pubkey)")
    }

    private func loadDmFromDefaults(_ pubkey: String) -> DmEntry? {
        guard let dict = UserDefaults.standard.dictionary(forKey: "peer_dm_relays_\(pubkey)") else { return nil }
        let relays = dict["relays"] as? [String] ?? []
        let updatedAt = dict["t"] as? Int ?? 0
        return DmEntry(relays: relays, updatedAt: updatedAt)
    }
}
