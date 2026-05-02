import Foundation
import Observation

/// Per-account hashtag sets (NIP-51 kind 30015 "interest sets").
///
/// Local source of truth is UserDefaults (per-pubkey). Every mutating operation:
///   1. updates in-memory state,
///   2. writes the new state to UserDefaults,
///   3. signs the matching kind-30015 event and publishes it via `RelayPool.publish`
///      to the user's top write relays so other clients pick it up.
///
/// `bootstrap(keypair:)` queries the user's write relays for the latest 30015
/// events and merges them in (newer `createdAt` wins per `dTag`).
@Observable
@MainActor
final class HashtagSetRepository {
    static let shared = HashtagSetRepository()

    private(set) var hashtagSets: [HashtagSet] = []

    @ObservationIgnored private var loadedFor: String?
    @ObservationIgnored private var hashtagSetUpdatedAt: [String: Int] = [:]

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
                kinds: [Nip51Hashtags.kindHashtagSet],
                authors: [pubkey],
                limit: 200
            ),
            timeout: 8
        )

        for event in events {
            ingestHashtagSetEvent(event, persist: true)
        }
    }

    // MARK: - Lookup

    func hashtagSet(dTag: String) -> HashtagSet? {
        hashtagSets.first { $0.dTag == dTag }
    }

    // MARK: - CRUD

    @discardableResult
    func createHashtagSet(name: String, initialHashtags: [String] = [], keypair: Keypair) -> HashtagSet? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let dTag = uniqueDTag(forName: trimmed)
        let normalized = dedupePreservingOrder(initialHashtags.compactMap(Nip51Hashtags.normalize))
        let now = Int(Date().timeIntervalSince1970)

        let set = HashtagSet(
            pubkey: keypair.pubkey,
            dTag: dTag,
            name: trimmed,
            hashtags: normalized,
            createdAt: now
        )
        hashtagSets.append(set)
        hashtagSetUpdatedAt[dTag] = now
        save(pubkey: keypair.pubkey)
        publishHashtagSet(set, keypair: keypair)
        return set
    }

    func renameHashtagSet(dTag: String, newName: String, keypair: Keypair) {
        guard let idx = hashtagSets.firstIndex(where: { $0.dTag == dTag }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var set = hashtagSets[idx]
        set.name = trimmed
        set.createdAt = Int(Date().timeIntervalSince1970)
        hashtagSets[idx] = set
        hashtagSetUpdatedAt[dTag] = set.createdAt
        save(pubkey: keypair.pubkey)
        publishHashtagSet(set, keypair: keypair)
    }

    func deleteHashtagSet(dTag: String, keypair: Keypair) {
        guard let idx = hashtagSets.firstIndex(where: { $0.dTag == dTag }) else { return }
        hashtagSets.remove(at: idx)
        hashtagSetUpdatedAt.removeValue(forKey: dTag)
        save(pubkey: keypair.pubkey)
        publishHashtagSetDeletion(dTag: dTag, keypair: keypair)
    }

    func addHashtag(_ hashtag: String, toSet dTag: String, keypair: Keypair) {
        guard let n = Nip51Hashtags.normalize(hashtag) else { return }
        guard let idx = hashtagSets.firstIndex(where: { $0.dTag == dTag }) else { return }
        var set = hashtagSets[idx]
        guard !set.hashtags.contains(n) else { return }
        set.hashtags.append(n)
        set.createdAt = Int(Date().timeIntervalSince1970)
        hashtagSets[idx] = set
        hashtagSetUpdatedAt[dTag] = set.createdAt
        save(pubkey: keypair.pubkey)
        publishHashtagSet(set, keypair: keypair)
    }

    func removeHashtag(_ hashtag: String, fromSet dTag: String, keypair: Keypair) {
        guard let n = Nip51Hashtags.normalize(hashtag) else { return }
        guard let idx = hashtagSets.firstIndex(where: { $0.dTag == dTag }) else { return }
        var set = hashtagSets[idx]
        guard let i = set.hashtags.firstIndex(of: n) else { return }
        set.hashtags.remove(at: i)
        set.createdAt = Int(Date().timeIntervalSince1970)
        hashtagSets[idx] = set
        hashtagSetUpdatedAt[dTag] = set.createdAt
        save(pubkey: keypair.pubkey)
        publishHashtagSet(set, keypair: keypair)
    }

    // MARK: - Ingest

    private func ingestHashtagSetEvent(_ event: NostrEvent, persist: Bool) {
        guard let parsed = Nip51Hashtags.parseHashtagSet(event) else { return }
        if let existingTs = hashtagSetUpdatedAt[parsed.dTag], event.createdAt <= existingTs {
            return
        }
        if let idx = hashtagSets.firstIndex(where: { $0.dTag == parsed.dTag }) {
            hashtagSets[idx] = parsed
        } else {
            hashtagSets.append(parsed)
        }
        hashtagSetUpdatedAt[parsed.dTag] = event.createdAt
        if persist { save(pubkey: event.pubkey) }
    }

    // MARK: - Persistence

    private func loadFromDefaults(pubkey: String) {
        if let data = UserDefaults.standard.data(forKey: storageKey(pubkey)),
           let decoded = try? JSONDecoder().decode([HashtagSet].self, from: data) {
            hashtagSets = decoded
            hashtagSetUpdatedAt = Dictionary(uniqueKeysWithValues: decoded.map { ($0.dTag, $0.createdAt) })
        } else {
            hashtagSets = []
            hashtagSetUpdatedAt = [:]
        }
    }

    private func save(pubkey: String) {
        if let data = try? JSONEncoder().encode(hashtagSets) {
            UserDefaults.standard.set(data, forKey: storageKey(pubkey))
        }
    }

    private func storageKey(_ pubkey: String) -> String { "hashtag_sets_\(pubkey)" }

    // MARK: - Publish

    private func publishHashtagSet(_ set: HashtagSet, keypair: Keypair) {
        guard let privkey = Hex.decode(keypair.privkey) else { return }
        let tags = Nip51Hashtags.buildHashtagSetTags(dTag: set.dTag, name: set.name, hashtags: set.hashtags)
        let pubkey = keypair.pubkey
        let createdAt = set.createdAt
        let relays = topWriteRelays(pubkey: pubkey)
        Task.detached {
            guard let event = try? NostrEvent.sign(
                privkey32: privkey,
                pubkey: pubkey,
                kind: Nip51Hashtags.kindHashtagSet,
                createdAt: createdAt,
                tags: tags,
                content: ""
            ) else { return }
            _ = await RelayPool.publish(event: event, to: relays, timeout: 6)
            await EventStore.shared.persist([event])
        }
    }

    /// Publish an "empty" replaceable set (only the `d` tag) to effectively delete it.
    /// The d-tag is preserved so the replacement targets the right address.
    private func publishHashtagSetDeletion(dTag: String, keypair: Keypair) {
        guard let privkey = Hex.decode(keypair.privkey) else { return }
        let tags: [[String]] = [["d", dTag]]
        let pubkey = keypair.pubkey
        let createdAt = Int(Date().timeIntervalSince1970)
        let relays = topWriteRelays(pubkey: pubkey)
        Task.detached {
            guard let event = try? NostrEvent.sign(
                privkey32: privkey,
                pubkey: pubkey,
                kind: Nip51Hashtags.kindHashtagSet,
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
        let existing = Set(hashtagSets.map(\.dTag))
        if !existing.contains(base) { return base }
        var i = 2
        while existing.contains("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }

    private func dedupePreservingOrder(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items where seen.insert(item).inserted { out.append(item) }
        return out
    }
}
