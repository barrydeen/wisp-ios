import Foundation
import Observation

/// Per-account favorite relays + named relay sets (NIP-51 kinds 10012 and 30002).
///
/// Local source of truth is UserDefaults (per-pubkey). Every mutating operation:
///   1. updates in-memory state,
///   2. writes the new state to UserDefaults,
///   3. signs the matching NIP-51 event and publishes it via `RelayPool.publish`
///      to the user's top write relays so other clients pick it up.
///
/// `bootstrap(keypair:)` queries the user's write relays for the latest 10012 / 30002
/// events and merges them in (newer `createdAt` wins per-set / per-list).
@Observable
@MainActor
final class RelaySetRepository {
    static let shared = RelaySetRepository()

    private(set) var favoriteRelays: [String] = []
    private(set) var relaySets: [RelaySet] = []

    @ObservationIgnored private var loadedFor: String?
    @ObservationIgnored private var favoritesUpdatedAt: Int = 0
    @ObservationIgnored private var relaySetUpdatedAt: [String: Int] = [:]

    private static let indexerRelays = RelayDefaults.indexers

    // MARK: - Lifecycle

    /// Hydrate from UserDefaults for the given pubkey, then async-merge from relays.
    func bootstrap(keypair: Keypair) async {
        let pubkey = keypair.pubkey
        if loadedFor != pubkey {
            loadFromDefaults(pubkey: pubkey)
            loadedFor = pubkey
        }

        let relays = topWriteRelays(pubkey: pubkey)
        let events = await RelayPool.query(
            relays: relays + Self.indexerRelays,
            filter: NostrFilter(
                kinds: [Nip51Lists.kindFavoriteRelays, Nip51Lists.kindRelaySet],
                authors: [pubkey],
                limit: 200
            ),
            timeout: 8
        )

        for event in events {
            switch event.kind {
            case Nip51Lists.kindFavoriteRelays:
                ingestFavoritesEvent(event, persist: true)
            case Nip51Lists.kindRelaySet:
                ingestRelaySetEvent(event, persist: true)
            default:
                break
            }
        }
    }

    // MARK: - Favorites

    func isFavorite(_ url: String) -> Bool {
        guard let n = Nip51Lists.normalize(url) else { return false }
        return favoriteRelays.contains(n)
    }

    func toggleFavorite(_ url: String, keypair: Keypair) {
        if isFavorite(url) {
            removeFavorite(url, keypair: keypair)
        } else {
            addFavorite(url, keypair: keypair)
        }
    }

    func addFavorite(_ url: String, keypair: Keypair) {
        guard let n = Nip51Lists.normalize(url) else { return }
        guard !favoriteRelays.contains(n) else { return }
        favoriteRelays.append(n)
        saveFavorites(pubkey: keypair.pubkey)
        publishFavorites(keypair: keypair)
    }

    func removeFavorite(_ url: String, keypair: Keypair) {
        guard let n = Nip51Lists.normalize(url) else { return }
        guard let idx = favoriteRelays.firstIndex(of: n) else { return }
        favoriteRelays.remove(at: idx)
        saveFavorites(pubkey: keypair.pubkey)
        publishFavorites(keypair: keypair)
    }

    // MARK: - Relay sets

    func relaySet(dTag: String) -> RelaySet? {
        relaySets.first { $0.dTag == dTag }
    }

    @discardableResult
    func createRelaySet(name: String, relays: [String], keypair: Keypair) -> RelaySet? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let dTag = uniqueDTag(forName: trimmed)
        let normalized = relays.compactMap(Nip51Lists.normalize)
        let now = Int(Date().timeIntervalSince1970)

        let set = RelaySet(
            pubkey: keypair.pubkey,
            dTag: dTag,
            name: trimmed,
            relays: dedupePreservingOrder(normalized),
            createdAt: now
        )
        relaySets.append(set)
        relaySetUpdatedAt[dTag] = now
        saveRelaySets(pubkey: keypair.pubkey)
        publishRelaySet(set, keypair: keypair)
        return set
    }

    func renameRelaySet(dTag: String, newName: String, keypair: Keypair) {
        guard let idx = relaySets.firstIndex(where: { $0.dTag == dTag }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var set = relaySets[idx]
        set.name = trimmed
        set.createdAt = Int(Date().timeIntervalSince1970)
        relaySets[idx] = set
        relaySetUpdatedAt[dTag] = set.createdAt
        saveRelaySets(pubkey: keypair.pubkey)
        publishRelaySet(set, keypair: keypair)
    }

    func deleteRelaySet(dTag: String, keypair: Keypair) {
        guard let idx = relaySets.firstIndex(where: { $0.dTag == dTag }) else { return }
        relaySets.remove(at: idx)
        relaySetUpdatedAt.removeValue(forKey: dTag)
        saveRelaySets(pubkey: keypair.pubkey)
        publishRelaySetDeletion(dTag: dTag, keypair: keypair)
    }

    func addRelay(_ url: String, toSet dTag: String, keypair: Keypair) {
        guard let n = Nip51Lists.normalize(url) else { return }
        guard let idx = relaySets.firstIndex(where: { $0.dTag == dTag }) else { return }
        var set = relaySets[idx]
        guard !set.relays.contains(n) else { return }
        set.relays.append(n)
        set.createdAt = Int(Date().timeIntervalSince1970)
        relaySets[idx] = set
        relaySetUpdatedAt[dTag] = set.createdAt
        saveRelaySets(pubkey: keypair.pubkey)
        publishRelaySet(set, keypair: keypair)
    }

    func removeRelay(_ url: String, fromSet dTag: String, keypair: Keypair) {
        guard let n = Nip51Lists.normalize(url) else { return }
        guard let idx = relaySets.firstIndex(where: { $0.dTag == dTag }) else { return }
        var set = relaySets[idx]
        guard let i = set.relays.firstIndex(of: n) else { return }
        set.relays.remove(at: i)
        set.createdAt = Int(Date().timeIntervalSince1970)
        relaySets[idx] = set
        relaySetUpdatedAt[dTag] = set.createdAt
        saveRelaySets(pubkey: keypair.pubkey)
        publishRelaySet(set, keypair: keypair)
    }

    // MARK: - Ingest (incoming events)

    private func ingestFavoritesEvent(_ event: NostrEvent, persist: Bool) {
        guard event.kind == Nip51Lists.kindFavoriteRelays else { return }
        if event.createdAt <= favoritesUpdatedAt { return }
        favoriteRelays = Nip51Lists.parseFavoriteRelays(event)
        favoritesUpdatedAt = event.createdAt
        if persist { saveFavorites(pubkey: event.pubkey) }
    }

    private func ingestRelaySetEvent(_ event: NostrEvent, persist: Bool) {
        guard let parsed = Nip51Lists.parseRelaySet(event) else { return }
        if let existingTs = relaySetUpdatedAt[parsed.dTag], event.createdAt <= existingTs {
            return
        }
        if let idx = relaySets.firstIndex(where: { $0.dTag == parsed.dTag }) {
            relaySets[idx] = parsed
        } else {
            relaySets.append(parsed)
        }
        relaySetUpdatedAt[parsed.dTag] = event.createdAt
        if persist { saveRelaySets(pubkey: event.pubkey) }
    }

    // MARK: - Persistence

    private func loadFromDefaults(pubkey: String) {
        if let arr = UserDefaults.standard.stringArray(forKey: favoritesKey(pubkey)) {
            favoriteRelays = arr
        } else {
            favoriteRelays = []
        }
        favoritesUpdatedAt = UserDefaults.standard.integer(forKey: favoritesTsKey(pubkey))

        if let data = UserDefaults.standard.data(forKey: relaySetsKey(pubkey)),
           let decoded = try? JSONDecoder().decode([RelaySet].self, from: data) {
            relaySets = decoded
            relaySetUpdatedAt = Dictionary(uniqueKeysWithValues: decoded.map { ($0.dTag, $0.createdAt) })
        } else {
            relaySets = []
            relaySetUpdatedAt = [:]
        }
    }

    private func saveFavorites(pubkey: String) {
        UserDefaults.standard.set(favoriteRelays, forKey: favoritesKey(pubkey))
        UserDefaults.standard.set(favoritesUpdatedAt, forKey: favoritesTsKey(pubkey))
    }

    private func saveRelaySets(pubkey: String) {
        if let data = try? JSONEncoder().encode(relaySets) {
            UserDefaults.standard.set(data, forKey: relaySetsKey(pubkey))
        }
    }

    private func favoritesKey(_ pubkey: String) -> String { "favorite_relays_\(pubkey)" }
    private func favoritesTsKey(_ pubkey: String) -> String { "favorite_relays_ts_\(pubkey)" }
    private func relaySetsKey(_ pubkey: String) -> String { "relay_sets_\(pubkey)" }

    // MARK: - Publish

    private func publishFavorites(keypair: Keypair) {
        guard let privkey = Hex.decode(keypair.privkey) else { return }
        let now = Int(Date().timeIntervalSince1970)
        favoritesUpdatedAt = max(favoritesUpdatedAt + 1, now)
        let tags = Nip51Lists.buildFavoriteRelayTags(favoriteRelays)
        let pubkey = keypair.pubkey
        let createdAt = favoritesUpdatedAt
        let relays = topWriteRelays(pubkey: pubkey)
        Task.detached {
            guard let event = try? NostrEvent.sign(
                privkey32: privkey,
                pubkey: pubkey,
                kind: Nip51Lists.kindFavoriteRelays,
                createdAt: createdAt,
                tags: tags,
                content: ""
            ) else { return }
            _ = await RelayPool.publish(event: event, to: relays, timeout: 6)
            await EventStore.shared.persist([event])
        }
    }

    private func publishRelaySet(_ set: RelaySet, keypair: Keypair) {
        guard let privkey = Hex.decode(keypair.privkey) else { return }
        let tags = Nip51Lists.buildRelaySetTags(dTag: set.dTag, name: set.name, relays: set.relays)
        let pubkey = keypair.pubkey
        let createdAt = set.createdAt
        let relays = topWriteRelays(pubkey: pubkey)
        Task.detached {
            guard let event = try? NostrEvent.sign(
                privkey32: privkey,
                pubkey: pubkey,
                kind: Nip51Lists.kindRelaySet,
                createdAt: createdAt,
                tags: tags,
                content: ""
            ) else { return }
            _ = await RelayPool.publish(event: event, to: relays, timeout: 6)
            await EventStore.shared.persist([event])
        }
    }

    /// Publish an "empty" replaceable set to effectively delete it (most clients honour
    /// the latest 30002 with no relay tags as a removal). The d-tag is preserved so the
    /// replacement targets the right address.
    private func publishRelaySetDeletion(dTag: String, keypair: Keypair) {
        guard let privkey = Hex.decode(keypair.privkey) else { return }
        let tags: [[String]] = [["d", dTag]]
        let pubkey = keypair.pubkey
        let createdAt = Int(Date().timeIntervalSince1970)
        let relays = topWriteRelays(pubkey: pubkey)
        Task.detached {
            guard let event = try? NostrEvent.sign(
                privkey32: privkey,
                pubkey: pubkey,
                kind: Nip51Lists.kindRelaySet,
                createdAt: createdAt,
                tags: tags,
                content: ""
            ) else { return }
            _ = await RelayPool.publish(event: event, to: relays, timeout: 6)
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

    private func uniqueDTag(forName name: String) -> String {
        let base = Nip51Lists.dTag(forName: name)
        let existing = Set(relaySets.map(\.dTag))
        if !existing.contains(base) { return base }
        var i = 2
        while existing.contains("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }

    private func dedupePreservingOrder(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for u in urls where seen.insert(u).inserted { out.append(u) }
        return out
    }
}
