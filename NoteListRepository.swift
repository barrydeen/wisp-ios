import Foundation
import Observation

/// Per-account note (bookmark) lists (NIP-51 kind 30003 "bookmark set").
/// See `PeopleListRepository` for the architectural pattern.
@Observable
@MainActor
final class NoteListRepository {
    static let shared = NoteListRepository()

    private(set) var lists: [NoteList] = []

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
                kinds: [Nip51UserLists.kindNoteList],
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

    func list(dTag: String) -> NoteList? {
        lists.first { $0.dTag == dTag }
    }

    /// Fast lookup used by the post action menu to show which lists already
    /// contain a given note.
    func listsContaining(noteId: String) -> [NoteList] {
        let normalized = noteId.lowercased()
        return lists.filter { $0.publicNotes.contains(normalized) || $0.privateNotes.contains(normalized) }
    }

    // MARK: - CRUD

    @discardableResult
    func createList(name: String, initialNoteId: String? = nil, keypair: Keypair) -> NoteList? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let dTag = uniqueDTag(forName: trimmed)
        let now = Int(Date().timeIntervalSince1970)
        var publicNotes: [String] = []
        if let id = initialNoteId?.lowercased(), Nip51UserLists.isHexId(id) {
            publicNotes.append(id)
        }
        let list = NoteList(
            pubkey: keypair.pubkey,
            dTag: dTag,
            name: trimmed,
            publicNotes: publicNotes,
            privateNotes: [],
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

    func addNote(_ id: String, to dTag: String, isPrivate: Bool, keypair: Keypair) {
        let normalized = id.lowercased()
        guard Nip51UserLists.isHexId(normalized) else { return }
        guard let idx = lists.firstIndex(where: { $0.dTag == dTag }) else { return }
        var list = lists[idx]
        list.publicNotes.removeAll { $0 == normalized }
        list.privateNotes.removeAll { $0 == normalized }
        if isPrivate {
            list.privateNotes.append(normalized)
        } else {
            list.publicNotes.append(normalized)
        }
        list.createdAt = Int(Date().timeIntervalSince1970)
        lists[idx] = list
        listUpdatedAt[dTag] = list.createdAt
        save(pubkey: keypair.pubkey)
        publish(list, keypair: keypair)
    }

    func removeNote(_ id: String, from dTag: String, keypair: Keypair) {
        let normalized = id.lowercased()
        guard let idx = lists.firstIndex(where: { $0.dTag == dTag }) else { return }
        var list = lists[idx]
        let before = list.publicNotes.count + list.privateNotes.count
        list.publicNotes.removeAll { $0 == normalized }
        list.privateNotes.removeAll { $0 == normalized }
        guard list.publicNotes.count + list.privateNotes.count != before else { return }
        list.createdAt = Int(Date().timeIntervalSince1970)
        lists[idx] = list
        listUpdatedAt[dTag] = list.createdAt
        save(pubkey: keypair.pubkey)
        publish(list, keypair: keypair)
    }

    func setNotePrivacy(_ id: String, in dTag: String, isPrivate: Bool, keypair: Keypair) {
        let normalized = id.lowercased()
        guard let idx = lists.firstIndex(where: { $0.dTag == dTag }) else { return }
        var list = lists[idx]
        let inPublic = list.publicNotes.contains(normalized)
        let inPrivate = list.privateNotes.contains(normalized)
        guard inPublic || inPrivate else { return }
        if isPrivate, inPublic {
            list.publicNotes.removeAll { $0 == normalized }
            list.privateNotes.append(normalized)
        } else if !isPrivate, inPrivate {
            list.privateNotes.removeAll { $0 == normalized }
            list.publicNotes.append(normalized)
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
        guard let parsed = Nip51UserLists.parseNoteList(event, keypair: keypair) else { return }
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
           let decoded = try? JSONDecoder().decode([NoteList].self, from: data) {
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

    private func storageKey(_ pubkey: String) -> String { "note_lists_\(pubkey)" }

    // MARK: - Publish

    private func publish(_ list: NoteList, keypair: Keypair) {
        guard let privkey = Hex.decode(keypair.privkey) else { return }
        let tags = Nip51UserLists.buildNoteListTags(
            dTag: list.dTag,
            name: list.name,
            publicNotes: list.publicNotes
        )
        let content: String
        do {
            content = try Nip51UserLists.buildNoteListPrivateContent(
                privateNotes: list.privateNotes,
                keypair: keypair
            )
        } catch {
            return
        }
        let pubkey = keypair.pubkey
        let createdAt = list.createdAt
        let relays = topWriteRelays(pubkey: pubkey)
        Task.detached {
            guard let event = try? NostrEvent.sign(
                privkey32: privkey,
                pubkey: pubkey,
                kind: Nip51UserLists.kindNoteList,
                createdAt: createdAt,
                tags: tags,
                content: content
            ) else { return }
            _ = await RelayPool.publish(event: event, to: relays, timeout: 6)
            await EventStore.shared.persist([event])
        }
    }

    private func publishDeletion(dTag: String, keypair: Keypair) {
        guard let privkey = Hex.decode(keypair.privkey) else { return }
        let tags: [[String]] = [["d", dTag]]
        let pubkey = keypair.pubkey
        let createdAt = Int(Date().timeIntervalSince1970)
        let relays = topWriteRelays(pubkey: pubkey)
        Task.detached {
            guard let event = try? NostrEvent.sign(
                privkey32: privkey,
                pubkey: pubkey,
                kind: Nip51UserLists.kindNoteList,
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
        let existing = Set(lists.map(\.dTag))
        if !existing.contains(base) { return base }
        var i = 2
        while existing.contains("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }
}
