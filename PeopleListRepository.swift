import Foundation
import Observation

/// Per-account people lists (NIP-51 kind 30000 "follow set").
///
/// Local source of truth is UserDefaults (per-pubkey). Every mutating operation:
///   1. updates in-memory state,
///   2. writes the new state to UserDefaults,
///   3. signs the matching kind-30000 event and publishes it via `RelayPool.publish`
///      to the user's top write relays so other clients pick it up.
///
/// Private members are encrypted with NIP-44 using the user's self-conversation
/// key (privkey × own pubkey). Other clients (e.g. Android Wisp) recover them
/// the same way.
@Observable
@MainActor
final class PeopleListRepository {
    static let shared = PeopleListRepository()

    private(set) var lists: [PeopleList] = []

    @ObservationIgnored private var loadedFor: String?
    @ObservationIgnored private var listUpdatedAt: [String: Int] = [:]

    private static let indexerRelays = RelayDefaults.indexers

    // MARK: - Lifecycle

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
                kinds: [Nip51UserLists.kindPeopleList],
                authors: [pubkey],
                limit: 200
            ),
            timeout: 8
        )

        for event in events {
            ingest(event, keypair: keypair, persist: true)
        }
    }

    // MARK: - Lookup

    func list(dTag: String) -> PeopleList? {
        lists.first { $0.dTag == dTag }
    }

    // MARK: - CRUD

    @discardableResult
    func createList(name: String, keypair: Keypair) -> PeopleList? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let dTag = uniqueDTag(forName: trimmed)
        let now = Int(Date().timeIntervalSince1970)
        let list = PeopleList(
            pubkey: keypair.pubkey,
            dTag: dTag,
            name: trimmed,
            publicMembers: [],
            privateMembers: [],
            createdAt: now
        )
        lists.append(list)
        listUpdatedAt[dTag] = now
        save(pubkey: keypair.pubkey)
        publish(list, keypair: keypair)
        return list
    }

    func renameList(dTag: String, newName: String, keypair: Keypair) {
        guard let idx = lists.firstIndex(where: { $0.dTag == dTag }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = lists[idx]
        list.name = trimmed
        list.createdAt = Int(Date().timeIntervalSince1970)
        lists[idx] = list
        listUpdatedAt[dTag] = list.createdAt
        save(pubkey: keypair.pubkey)
        publish(list, keypair: keypair)
    }

    func deleteList(dTag: String, keypair: Keypair) {
        guard let idx = lists.firstIndex(where: { $0.dTag == dTag }) else { return }
        lists.remove(at: idx)
        listUpdatedAt.removeValue(forKey: dTag)
        save(pubkey: keypair.pubkey)
        publishDeletion(dTag: dTag, keypair: keypair)
    }

    func addMember(_ pubkey: String, to dTag: String, isPrivate: Bool, keypair: Keypair) {
        let normalized = pubkey.lowercased()
        guard Nip51UserLists.isHexPubkey(normalized) else { return }
        guard let idx = lists.firstIndex(where: { $0.dTag == dTag }) else { return }
        var list = lists[idx]
        // Remove from both arrays first, then re-insert in target visibility.
        list.publicMembers.removeAll { $0 == normalized }
        list.privateMembers.removeAll { $0 == normalized }
        if isPrivate {
            list.privateMembers.append(normalized)
        } else {
            list.publicMembers.append(normalized)
        }
        list.createdAt = Int(Date().timeIntervalSince1970)
        lists[idx] = list
        listUpdatedAt[dTag] = list.createdAt
        save(pubkey: keypair.pubkey)
        publish(list, keypair: keypair)
    }

    func removeMember(_ pubkey: String, from dTag: String, keypair: Keypair) {
        let normalized = pubkey.lowercased()
        guard let idx = lists.firstIndex(where: { $0.dTag == dTag }) else { return }
        var list = lists[idx]
        let before = list.publicMembers.count + list.privateMembers.count
        list.publicMembers.removeAll { $0 == normalized }
        list.privateMembers.removeAll { $0 == normalized }
        guard list.publicMembers.count + list.privateMembers.count != before else { return }
        list.createdAt = Int(Date().timeIntervalSince1970)
        lists[idx] = list
        listUpdatedAt[dTag] = list.createdAt
        save(pubkey: keypair.pubkey)
        publish(list, keypair: keypair)
    }

    func setMemberPrivacy(_ pubkey: String, in dTag: String, isPrivate: Bool, keypair: Keypair) {
        let normalized = pubkey.lowercased()
        guard let idx = lists.firstIndex(where: { $0.dTag == dTag }) else { return }
        var list = lists[idx]
        let inPublic = list.publicMembers.contains(normalized)
        let inPrivate = list.privateMembers.contains(normalized)
        guard inPublic || inPrivate else { return }
        if isPrivate, inPublic {
            list.publicMembers.removeAll { $0 == normalized }
            list.privateMembers.append(normalized)
        } else if !isPrivate, inPrivate {
            list.privateMembers.removeAll { $0 == normalized }
            list.publicMembers.append(normalized)
        } else {
            return
        }
        list.createdAt = Int(Date().timeIntervalSince1970)
        lists[idx] = list
        listUpdatedAt[dTag] = list.createdAt
        save(pubkey: keypair.pubkey)
        publish(list, keypair: keypair)
    }

    // MARK: - Ingest

    private func ingest(_ event: NostrEvent, keypair: Keypair, persist: Bool) {
        guard let parsed = Nip51UserLists.parsePeopleList(event, keypair: keypair) else { return }
        if let existingTs = listUpdatedAt[parsed.dTag], event.createdAt <= existingTs {
            return
        }
        if let idx = lists.firstIndex(where: { $0.dTag == parsed.dTag }) {
            lists[idx] = parsed
        } else {
            lists.append(parsed)
        }
        listUpdatedAt[parsed.dTag] = event.createdAt
        if persist { save(pubkey: event.pubkey) }
    }

    // MARK: - Persistence

    private func loadFromDefaults(pubkey: String) {
        if let data = UserDefaults.standard.data(forKey: storageKey(pubkey)),
           let decoded = try? JSONDecoder().decode([PeopleList].self, from: data) {
            lists = decoded
            listUpdatedAt = Dictionary(uniqueKeysWithValues: decoded.map { ($0.dTag, $0.createdAt) })
        } else {
            lists = []
            listUpdatedAt = [:]
        }
    }

    private func save(pubkey: String) {
        if let data = try? JSONEncoder().encode(lists) {
            UserDefaults.standard.set(data, forKey: storageKey(pubkey))
        }
    }

    private func storageKey(_ pubkey: String) -> String { "people_lists_\(pubkey)" }

    // MARK: - Publish

    private func publish(_ list: PeopleList, keypair: Keypair) {
        let tags = Nip51UserLists.buildPeopleListTags(
            dTag: list.dTag,
            name: list.name,
            publicMembers: list.publicMembers
        )
        let createdAt = list.createdAt
        let relays = topWriteRelays(pubkey: keypair.pubkey)
        Task { @MainActor in
            let content: String
            do {
                content = try await Nip51UserLists.buildPeopleListPrivateContent(
                    privateMembers: list.privateMembers,
                    keypair: keypair
                )
            } catch { return }
            guard let event = try? await Signer.sign(
                keypair: keypair,
                kind: Nip51UserLists.kindPeopleList,
                tags: tags,
                content: content,
                createdAt: createdAt
            ) else { return }
            _ = await RelayPool.publish(event: event, to: relays, timeout: 6)
            await EventStore.shared.persist([event])
        }
    }

    /// Replace the addressable record with an empty stub so the list disappears
    /// from clients that honor newer-wins semantics. The d-tag is preserved so
    /// the replacement targets the right address.
    private func publishDeletion(dTag: String, keypair: Keypair) {
        let tags: [[String]] = [["d", dTag]]
        let createdAt = Int(Date().timeIntervalSince1970)
        let relays = topWriteRelays(pubkey: keypair.pubkey)
        Task { @MainActor in
            guard let event = try? await Signer.sign(
                keypair: keypair,
                kind: Nip51UserLists.kindPeopleList,
                tags: tags,
                content: "",
                createdAt: createdAt
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
        let existing = Set(lists.map(\.dTag))
        if !existing.contains(base) { return base }
        var i = 2
        while existing.contains("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }
}
