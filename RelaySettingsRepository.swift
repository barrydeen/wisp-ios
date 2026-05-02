import Foundation
import Observation

/// Single source of truth for the four user-managed relay lists:
///
///   - `generalRelays` (kind 10002, NIP-65 read/write list)
///   - `dmRelays`      (kind 10050, NIP-17 inbox relays)
///   - `searchRelays`  (kind 10007, NIP-51 search relays)
///   - `blockedRelays` (kind 10006, NIP-51 blocked relays)
///
/// Local source of truth is UserDefaults (per-pubkey). Every mutating operation:
///   1. updates in-memory state,
///   2. writes the new state to UserDefaults,
///   3. signs the matching event and publishes it via `RelayPool.publish` to the
///      user's top write relays + a small indexer fallback set.
///
/// `bootstrap(keypair:)` queries those targets for the latest events of each kind
/// and merges them in (newer `createdAt` wins per-list).
///
/// Kind 10002 events (general list) are also fed into `RelayListRepository` so the
/// existing inbox-relay lookups (threads, replies, extended network) stay coherent.
@Observable
@MainActor
final class RelaySettingsRepository {
    static let shared = RelaySettingsRepository()

    private(set) var generalRelays: [GeneralRelay] = []
    private(set) var dmRelays: [String] = []
    private(set) var searchRelays: [String] = []
    private(set) var blockedRelays: [String] = []

    @ObservationIgnored private var loadedFor: String?
    @ObservationIgnored private var generalUpdatedAt: Int = 0
    @ObservationIgnored private var dmUpdatedAt: Int = 0
    @ObservationIgnored private var searchUpdatedAt: Int = 0
    @ObservationIgnored private var blockedUpdatedAt: Int = 0

    /// Indexer fallback set for *publishing* list metadata. Mirrors Android's
    /// `DEFAULT_INDEXER_RELAYS` so cross-client visibility matches.
    static let indexerRelays = RelayDefaults.onboarding

    // MARK: - Lifecycle

    /// Idempotent — returns immediately once UserDefaults hydration has run for this pubkey.
    /// Callers that need the disk-cached `dmRelays` etc. should `await` this before reading.
    func ensureLoaded(pubkey: String) {
        if loadedFor == pubkey { return }
        loadFromDefaults(pubkey: pubkey)
        loadedFor = pubkey
    }

    /// Force-refresh all relay lists from the network, ignoring local timestamps.
    /// Use when the user updated their lists in another client and wants to pull them in.
    func syncFromNetwork(keypair: Keypair) async {
        generalUpdatedAt = 0
        dmUpdatedAt = 0
        searchUpdatedAt = 0
        blockedUpdatedAt = 0
        await bootstrap(keypair: keypair)
    }

    /// Hydrate from UserDefaults for the given pubkey, then async-merge from relays.
    func bootstrap(keypair: Keypair) async {
        let pubkey = keypair.pubkey
        if loadedFor != pubkey {
            loadFromDefaults(pubkey: pubkey)
            loadedFor = pubkey
        }

        let relays = topWriteRelays(pubkey: pubkey) + Self.indexerRelays
        let events = await RelayPool.query(
            relays: relays,
            filter: NostrFilter(
                kinds: [
                    Nip51Lists.kindRelayList,
                    Nip51Lists.kindDmRelays,
                    Nip51Lists.kindSearchRelays,
                    Nip51Lists.kindBlockedRelays
                ],
                authors: [pubkey],
                limit: 16
            ),
            timeout: 8
        )

        for event in events {
            switch event.kind {
            case Nip51Lists.kindRelayList:    ingestGeneralEvent(event, persist: true)
            case Nip51Lists.kindDmRelays:     ingestDmEvent(event, persist: true)
            case Nip51Lists.kindSearchRelays: ingestSearchEvent(event, persist: true)
            case Nip51Lists.kindBlockedRelays: ingestBlockedEvent(event, persist: true)
            default: break
            }
        }
    }

    // MARK: - General relays (kind 10002)

    func addGeneralRelay(_ url: String, read: Bool = true, write: Bool = true, auth: Bool = false, keypair: Keypair) {
        guard let n = Nip51Lists.normalize(url) else { return }
        guard !generalRelays.contains(where: { $0.url == n }) else { return }
        generalRelays.append(GeneralRelay(url: n, read: read, write: write, auth: auth))
        saveGeneral(pubkey: keypair.pubkey)
        publishGeneral(keypair: keypair)
    }

    func removeGeneralRelay(_ url: String, keypair: Keypair) {
        guard let n = Nip51Lists.normalize(url) else { return }
        guard let idx = generalRelays.firstIndex(where: { $0.url == n }) else { return }
        generalRelays.remove(at: idx)
        saveGeneral(pubkey: keypair.pubkey)
        publishGeneral(keypair: keypair)
    }

    func toggleGeneralRead(_ url: String, keypair: Keypair) {
        guard let n = Nip51Lists.normalize(url) else { return }
        guard let idx = generalRelays.firstIndex(where: { $0.url == n }) else { return }
        generalRelays[idx].read.toggle()
        saveGeneral(pubkey: keypair.pubkey)
        publishGeneral(keypair: keypair)
    }

    func toggleGeneralWrite(_ url: String, keypair: Keypair) {
        guard let n = Nip51Lists.normalize(url) else { return }
        guard let idx = generalRelays.firstIndex(where: { $0.url == n }) else { return }
        generalRelays[idx].write.toggle()
        saveGeneral(pubkey: keypair.pubkey)
        publishGeneral(keypair: keypair)
    }

    /// Toggle the per-relay AUTH flag. Local-only setting (controls whether `RelayPool`
    /// auto-signs NIP-42 challenges); not encoded in the published kind 10002 event.
    func toggleGeneralAuth(_ url: String) {
        guard let n = Nip51Lists.normalize(url) else { return }
        guard let idx = generalRelays.firstIndex(where: { $0.url == n }) else { return }
        generalRelays[idx].auth.toggle()
        if let pubkey = loadedFor {
            saveGeneral(pubkey: pubkey)
        }
    }

    /// Enable AUTH for `url`, adding it as a read+write General relay if missing.
    /// Used by the AUTH approval sheet.
    func approveAuth(_ url: String, keypair: Keypair) {
        guard let n = Nip51Lists.normalize(url) else { return }
        if let idx = generalRelays.firstIndex(where: { $0.url == n }) {
            generalRelays[idx].auth = true
            saveGeneral(pubkey: keypair.pubkey)
        } else {
            generalRelays.append(GeneralRelay(url: n, read: true, write: true, auth: true))
            saveGeneral(pubkey: keypair.pubkey)
            publishGeneral(keypair: keypair)
        }
    }

    /// Synchronous lookup. Returns true if the relay is in the General list with auth=true.
    func isAuthApproved(_ url: String) -> Bool {
        guard let n = Nip51Lists.normalize(url) else { return false }
        return generalRelays.first(where: { $0.url == n })?.auth == true
    }

    /// Thread-safe lookup via UserDefaults — callable from any actor (RelayPool's
    /// socket loops are not main-isolated). Reads the same per-pubkey persisted blob
    /// that `loadFromDefaults` uses, so it always reflects the latest committed state.
    nonisolated static func isAuthApproved(_ url: String, pubkey: String) -> Bool {
        guard let n = Nip51Lists.normalize(url) else { return false }
        let key = "relay_settings_general_\(pubkey)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([GeneralRelay].self, from: data) else { return false }
        return decoded.first(where: { $0.url == n })?.auth == true
    }

    func broadcastGeneral(keypair: Keypair) { publishGeneral(keypair: keypair) }

    // MARK: - DM relays (kind 10050)

    func addDmRelay(_ url: String, keypair: Keypair) {
        guard let n = Nip51Lists.normalize(url) else { return }
        guard !dmRelays.contains(n) else { return }
        dmRelays.append(n)
        saveDm(pubkey: keypair.pubkey)
        publishDm(keypair: keypair)
    }

    func removeDmRelay(_ url: String, keypair: Keypair) {
        guard let n = Nip51Lists.normalize(url) else { return }
        guard let idx = dmRelays.firstIndex(of: n) else { return }
        dmRelays.remove(at: idx)
        saveDm(pubkey: keypair.pubkey)
        publishDm(keypair: keypair)
    }

    func broadcastDm(keypair: Keypair) { publishDm(keypair: keypair) }

    // MARK: - Search relays (kind 10007)

    func addSearchRelay(_ url: String, keypair: Keypair) {
        guard let n = Nip51Lists.normalize(url) else { return }
        guard !searchRelays.contains(n) else { return }
        searchRelays.append(n)
        saveSearch(pubkey: keypair.pubkey)
        publishSearch(keypair: keypair)
    }

    func removeSearchRelay(_ url: String, keypair: Keypair) {
        guard let n = Nip51Lists.normalize(url) else { return }
        guard let idx = searchRelays.firstIndex(of: n) else { return }
        searchRelays.remove(at: idx)
        saveSearch(pubkey: keypair.pubkey)
        publishSearch(keypair: keypair)
    }

    func broadcastSearch(keypair: Keypair) { publishSearch(keypair: keypair) }

    // MARK: - Blocked relays (kind 10006)

    func addBlockedRelay(_ url: String, keypair: Keypair) {
        guard let n = Nip51Lists.normalize(url) else { return }
        guard !blockedRelays.contains(n) else { return }
        blockedRelays.append(n)
        saveBlocked(pubkey: keypair.pubkey)
        publishBlocked(keypair: keypair)
    }

    func removeBlockedRelay(_ url: String, keypair: Keypair) {
        guard let n = Nip51Lists.normalize(url) else { return }
        guard let idx = blockedRelays.firstIndex(of: n) else { return }
        blockedRelays.remove(at: idx)
        saveBlocked(pubkey: keypair.pubkey)
        publishBlocked(keypair: keypair)
    }

    func broadcastBlocked(keypair: Keypair) { publishBlocked(keypair: keypair) }

    // MARK: - Ingest

    private func ingestGeneralEvent(_ event: NostrEvent, persist: Bool) {
        guard event.kind == Nip51Lists.kindRelayList else { return }
        if event.createdAt <= generalUpdatedAt { return }
        let parsed = Nip51Lists.parseGeneralRelayList(event)
        let prevAuth = Dictionary(uniqueKeysWithValues: generalRelays.map { ($0.url, $0.auth) })
        generalRelays = parsed.map { r in
            var copy = r
            copy.auth = prevAuth[r.url] ?? false
            return copy
        }
        generalUpdatedAt = event.createdAt
        if persist { saveGeneral(pubkey: event.pubkey) }
        // Bridge into the existing inbox-relay cache.
        RelayListRepository.shared.ingest(event)
    }

    private func ingestDmEvent(_ event: NostrEvent, persist: Bool) {
        guard event.kind == Nip51Lists.kindDmRelays else { return }
        if event.createdAt <= dmUpdatedAt { return }
        dmRelays = Nip51Lists.parseRelaySetList(event)
        dmUpdatedAt = event.createdAt
        if persist { saveDm(pubkey: event.pubkey) }
    }

    private func ingestSearchEvent(_ event: NostrEvent, persist: Bool) {
        guard event.kind == Nip51Lists.kindSearchRelays else { return }
        if event.createdAt <= searchUpdatedAt { return }
        searchRelays = Nip51Lists.parseRelaySetList(event)
        searchUpdatedAt = event.createdAt
        if persist { saveSearch(pubkey: event.pubkey) }
    }

    private func ingestBlockedEvent(_ event: NostrEvent, persist: Bool) {
        guard event.kind == Nip51Lists.kindBlockedRelays else { return }
        if event.createdAt <= blockedUpdatedAt { return }
        blockedRelays = Nip51Lists.parseRelaySetList(event)
        blockedUpdatedAt = event.createdAt
        if persist { saveBlocked(pubkey: event.pubkey) }
    }

    // MARK: - Persistence

    private func loadFromDefaults(pubkey: String) {
        let d = UserDefaults.standard
        if let data = d.data(forKey: generalKey(pubkey)),
           let decoded = try? JSONDecoder().decode([GeneralRelay].self, from: data) {
            generalRelays = decoded
        } else { generalRelays = [] }
        generalUpdatedAt = d.integer(forKey: generalTsKey(pubkey))

        dmRelays = d.stringArray(forKey: dmKey(pubkey)) ?? []
        dmUpdatedAt = d.integer(forKey: dmTsKey(pubkey))

        searchRelays = d.stringArray(forKey: searchKey(pubkey)) ?? []
        searchUpdatedAt = d.integer(forKey: searchTsKey(pubkey))

        blockedRelays = d.stringArray(forKey: blockedKey(pubkey)) ?? []
        blockedUpdatedAt = d.integer(forKey: blockedTsKey(pubkey))
    }

    private func saveGeneral(pubkey: String) {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(generalRelays) {
            d.set(data, forKey: generalKey(pubkey))
        }
        d.set(generalUpdatedAt, forKey: generalTsKey(pubkey))
    }
    private func saveDm(pubkey: String) {
        UserDefaults.standard.set(dmRelays, forKey: dmKey(pubkey))
        UserDefaults.standard.set(dmUpdatedAt, forKey: dmTsKey(pubkey))
    }
    private func saveSearch(pubkey: String) {
        UserDefaults.standard.set(searchRelays, forKey: searchKey(pubkey))
        UserDefaults.standard.set(searchUpdatedAt, forKey: searchTsKey(pubkey))
    }
    private func saveBlocked(pubkey: String) {
        UserDefaults.standard.set(blockedRelays, forKey: blockedKey(pubkey))
        UserDefaults.standard.set(blockedUpdatedAt, forKey: blockedTsKey(pubkey))
    }

    private func generalKey(_ pubkey: String) -> String   { "relay_settings_general_\(pubkey)" }
    private func generalTsKey(_ pubkey: String) -> String { "relay_settings_general_ts_\(pubkey)" }
    private func dmKey(_ pubkey: String) -> String        { "relay_settings_dm_\(pubkey)" }
    private func dmTsKey(_ pubkey: String) -> String      { "relay_settings_dm_ts_\(pubkey)" }
    private func searchKey(_ pubkey: String) -> String    { "relay_settings_search_\(pubkey)" }
    private func searchTsKey(_ pubkey: String) -> String  { "relay_settings_search_ts_\(pubkey)" }
    private func blockedKey(_ pubkey: String) -> String   { "relay_settings_blocked_\(pubkey)" }
    private func blockedTsKey(_ pubkey: String) -> String { "relay_settings_blocked_ts_\(pubkey)" }

    // MARK: - Publish

    private func publishGeneral(keypair: Keypair) {
        guard let privkey = Hex.decode(keypair.privkey) else { return }
        let now = Int(Date().timeIntervalSince1970)
        generalUpdatedAt = max(generalUpdatedAt + 1, now)
        let tags = Nip51Lists.buildGeneralRelayTags(generalRelays)
        publish(kind: Nip51Lists.kindRelayList, tags: tags,
                createdAt: generalUpdatedAt, privkey: privkey, keypair: keypair)
        saveGeneral(pubkey: keypair.pubkey)
    }

    private func publishDm(keypair: Keypair) {
        guard let privkey = Hex.decode(keypair.privkey) else { return }
        let now = Int(Date().timeIntervalSince1970)
        dmUpdatedAt = max(dmUpdatedAt + 1, now)
        let tags = Nip51Lists.buildRelaySetListTags(dmRelays)
        // Also send the announcement to the DM relays themselves, so peers querying any of
        // those inboxes can resolve the latest list (matches Android's sendToDmRelays).
        publish(kind: Nip51Lists.kindDmRelays, tags: tags,
                createdAt: dmUpdatedAt, privkey: privkey, keypair: keypair,
                extraRelays: dmRelays)
        saveDm(pubkey: keypair.pubkey)
    }

    private func publishSearch(keypair: Keypair) {
        guard let privkey = Hex.decode(keypair.privkey) else { return }
        let now = Int(Date().timeIntervalSince1970)
        searchUpdatedAt = max(searchUpdatedAt + 1, now)
        let tags = Nip51Lists.buildRelaySetListTags(searchRelays)
        publish(kind: Nip51Lists.kindSearchRelays, tags: tags,
                createdAt: searchUpdatedAt, privkey: privkey, keypair: keypair)
        saveSearch(pubkey: keypair.pubkey)
    }

    private func publishBlocked(keypair: Keypair) {
        guard let privkey = Hex.decode(keypair.privkey) else { return }
        let now = Int(Date().timeIntervalSince1970)
        blockedUpdatedAt = max(blockedUpdatedAt + 1, now)
        let tags = Nip51Lists.buildRelaySetListTags(blockedRelays)
        publish(kind: Nip51Lists.kindBlockedRelays, tags: tags,
                createdAt: blockedUpdatedAt, privkey: privkey, keypair: keypair)
        saveBlocked(pubkey: keypair.pubkey)
    }

    private func publish(kind: Int, tags: [[String]], createdAt: Int,
                         privkey: Data, keypair: Keypair,
                         extraRelays: [String] = []) {
        let pubkey = keypair.pubkey
        let relays = Array(Set(topWriteRelays(pubkey: pubkey) + Self.indexerRelays + extraRelays))
        Task.detached {
            guard let event = try? NostrEvent.sign(
                privkey32: privkey,
                pubkey: pubkey,
                kind: kind,
                createdAt: createdAt,
                tags: tags,
                content: ""
            ) else { return }
            _ = await RelayPool.publish(event: event, to: relays, timeout: 6)
            await EventStore.shared.persist([event])
            if kind == Nip51Lists.kindRelayList {
                await MainActor.run { RelayListRepository.shared.ingest(event) }
            }
        }
    }

    // MARK: - Helpers

    private func topWriteRelays(pubkey: String) -> [String] {
        if let board = RelayScoreBoard.load(pubkey: pubkey) {
            let top = board.scoredRelays.prefix(5).map(\.url)
            if !top.isEmpty { return top }
        }
        return ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
    }
}
