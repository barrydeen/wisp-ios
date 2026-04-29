import Foundation
import Observation

/// Per-account store for muted words, blocked pubkeys, and muted thread roots, mirroring
/// Android's `MuteRepository`. Backed by per-pubkey UserDefaults entries and synced to
/// relays as a NIP-51 kind:10000 event with a NIP-44-encrypted private body.
///
/// Words are stored already-lowercased so the hot-path substring check in `SafetyFilter`
/// avoids per-event allocation.
@Observable
@MainActor
final class MuteRepository {
    static let shared = MuteRepository()

    private(set) var activePubkey: String?
    private(set) var mutedWords: Set<String> = []
    private(set) var blockedPubkeys: Set<String> = []
    private(set) var mutedThreads: Set<String> = []
    private(set) var lastUpdatedAt: Int = 0

    @ObservationIgnored private var binding = false
    @ObservationIgnored private var activePrivkey32: Data?
    @ObservationIgnored private var syncSubscription: RelaySubscription?
    @ObservationIgnored private var syncListener: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    func bind(activePubkey pk: String, privkey32: Data?) {
        binding = true
        defer { binding = false }
        unbindSync()
        activePubkey = pk
        activePrivkey32 = privkey32
        let d = UserDefaults.standard
        mutedWords = Set(d.stringArray(forKey: Self.wordsKey(pk)) ?? [])
        // Lowercase on load so historical entries written before
        // `blockUser` normalized the input (and any uppercase hex pubkeys
        // received via `merge(event:)`) still match the lowercase pubkeys
        // that come off the wire from relays.
        blockedPubkeys = Set((d.stringArray(forKey: Self.pubkeysKey(pk)) ?? []).map { $0.lowercased() })
        mutedThreads = Set(d.stringArray(forKey: Self.threadsKey(pk)) ?? [])
        lastUpdatedAt = d.integer(forKey: Self.updatedAtKey(pk))

        // Install a synchronous SafetyFilter snapshot from the local mute
        // state so any view model that opens before `MainView`'s async
        // `rebuildSnapshot()` finishes (NotificationsViewModel races MainView's
        // .task on cold launch) still sees the blocked-pubkey set. WoT data
        // arrives via the async rebuild that runs right after.
        SafetyFilter.shared.install(SafetyFilterSnapshot(
            mutedWords: mutedWords,
            blockedPubkeys: blockedPubkeys,
            mutedThreads: mutedThreads,
            wotEnabled: false,
            qualifiedNetwork: [],
            userPubkey: pk
        ))
    }

    func unbind() {
        binding = true
        defer { binding = false }
        unbindSync()
        activePubkey = nil
        activePrivkey32 = nil
        mutedWords = []
        blockedPubkeys = []
        mutedThreads = []
        lastUpdatedAt = 0
    }

    private func unbindSync() {
        syncListener?.cancel()
        syncListener = nil
        syncSubscription?.cancel()
        syncSubscription = nil
    }

    // MARK: - Mutators

    func addMutedWord(_ word: String) {
        let normalized = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !mutedWords.contains(normalized) else { return }
        mutedWords.insert(normalized)
        commitChange()
    }

    func removeMutedWord(_ word: String) {
        let normalized = word.lowercased()
        guard mutedWords.remove(normalized) != nil else { return }
        commitChange()
    }

    func blockUser(_ pubkey: String) {
        let normalized = pubkey.lowercased()
        guard !normalized.isEmpty, !blockedPubkeys.contains(normalized) else { return }
        blockedPubkeys.insert(normalized)
        commitChange()
        // Drop their entries from the in-memory notification state immediately
        // — without this, single-actor groups (`user replied`) and multi-actor
        // reaction groups linger in the UI until the next cold launch even
        // though SafetyFilter would now drop them.
        NotificationRepository.shared.purgeAuthor(normalized)
        // Broadcast so any open feed / thread view models can drop their
        // in-memory events for this author too.
        NotificationCenter.default.post(name: .userBlocked, object: normalized)
        // Eagerly purge their cached events so feed reseeds and notification
        // hydration can't resurface them.
        Task.detached { await EventStore.shared.removeByAuthor(normalized) }
    }

    func unblockUser(_ pubkey: String) {
        let normalized = pubkey.lowercased()
        guard blockedPubkeys.remove(normalized) != nil else { return }
        commitChange()
    }

    func muteThread(_ rootEventId: String) {
        guard !rootEventId.isEmpty, !mutedThreads.contains(rootEventId) else { return }
        mutedThreads.insert(rootEventId)
        commitChange()
    }

    func unmuteThread(_ rootEventId: String) {
        guard mutedThreads.remove(rootEventId) != nil else { return }
        commitChange()
    }

    func containsMutedWord(_ content: String) -> Bool {
        guard !mutedWords.isEmpty else { return false }
        let lower = content.lowercased()
        for w in mutedWords where lower.contains(w) { return true }
        return false
    }

    func isBlocked(_ pubkey: String) -> Bool { blockedPubkeys.contains(pubkey) }

    func isThreadMuted(_ rootEventId: String) -> Bool { mutedThreads.contains(rootEventId) }

    // MARK: - Sync

    /// Build a fresh kind:10000 event reflecting the current state and publish to the user's
    /// write relays. Self-encrypted via NIP-44; tags are empty so other clients see only an
    /// opaque blob.
    func republish(privkey32: Data) async {
        guard let pk = activePubkey else { return }
        let words = mutedWords
        let pubkeys = blockedPubkeys
        let threads = mutedThreads
        let createdAt = max(Int(Date().timeIntervalSince1970), lastUpdatedAt + 1)
        do {
            let event = try Nip51Mute.buildSignedMuteEvent(
                privkey32: privkey32,
                ownPubkey: pk,
                blockedPubkeys: pubkeys,
                mutedWords: words,
                mutedThreads: threads,
                createdAt: createdAt
            )
            lastUpdatedAt = createdAt
            UserDefaults.standard.set(createdAt, forKey: Self.updatedAtKey(pk))
            let writeRelays = await RelayListRepository.shared.getWriteRelays(pk)
            let relays = writeRelays.isEmpty ? Self.fallbackRelays : writeRelays
            _ = await RelayPool.publish(event: event, to: relays, timeout: 6)
        } catch {
            // Encryption / signing failure: keep the local state so the user isn't left without
            // their list. Next mutation will re-attempt.
        }
    }

    /// Open a long-lived subscription for our own kind:10000 and merge any newer event we see.
    /// Also kicks one immediate `RelayPool.query` for fast hydration on launch.
    func startSync(privkey32: Data) {
        guard let pk = activePubkey else { return }
        unbindSync()
        let priv = privkey32
        let pubkey = pk

        Task { [weak self] in
            // Union write relays + fallback relays so the mute list still
            // resolves when the user's NIP-65 write set is exotic (paid /
            // filter / private relays that don't carry the kind-10000) and
            // their actual mute event lives on a public big-relay set
            // (damus / primal / nos.lol). Without this union, a user whose
            // 12 write relays don't include any of those big-relay hosts
            // would never sync their existing mute list.
            let writeRelays = await RelayListRepository.shared.getWriteRelays(pubkey)
            var seen = Set<String>()
            var relays: [String] = []
            for r in writeRelays where seen.insert(r).inserted { relays.append(r) }
            for r in Self.fallbackRelays where seen.insert(r).inserted { relays.append(r) }
            let filter = NostrFilter(kinds: [Nip51Mute.kindMuteList], authors: [pubkey], limit: 5)
            // Quick hydration first.
            let initial = await RelayPool.query(relays: relays, filter: filter, timeout: 6)
            for event in initial {
                await self?.merge(event: event, privkey32: priv)
            }
            await MainActor.run {
                guard let self else { return }
                let sub = RelayPool.subscribe(relays: relays, filter: filter, id: "mute-self-sync")
                self.syncSubscription = sub
                self.syncListener = Task { [weak self] in
                    for await (event, _) in sub.events {
                        await self?.merge(event: event, privkey32: priv)
                    }
                }
            }
        }
    }

    /// Apply an inbound kind:10000 if it's newer than our local state. Merges decrypted
    /// private body with any public tags (some clients still publish public ["p", x]).
    func merge(event: NostrEvent, privkey32: Data) async {
        guard event.kind == Nip51Mute.kindMuteList,
              event.pubkey == activePubkey,
              event.createdAt > lastUpdatedAt else { return }

        let parsed = (try? Nip51Mute.decryptAndParse(event: event, privkey32: privkey32))
            ?? Nip51Mute.parsePublicTags(event: event)

        let previousBlocked = blockedPubkeys
        mutedWords = parsed.words
        // Lowercase here too — NIP-51 mute entries from other clients can be
        // mixed-case hex; they'd otherwise miss the lowercase pubkey from a
        // relay event in `SafetyFilter.shouldDrop`.
        blockedPubkeys = Set(parsed.pubkeys.map { $0.lowercased() })
        mutedThreads = parsed.threads
        lastUpdatedAt = event.createdAt

        // Newly-arrived block entries that we didn't have before need their
        // in-memory traces purged from open view state — without this, a fresh
        // mute list arriving from relay sync after the first paint leaves
        // already-rendered cards / notification rows from those authors
        // visible until the next cold launch.
        let newlyBlocked = blockedPubkeys.subtracting(previousBlocked)
        if !newlyBlocked.isEmpty {
            for pk in newlyBlocked {
                NotificationRepository.shared.purgeAuthor(pk)
                NotificationCenter.default.post(name: .userBlocked, object: pk)
                Task.detached { await EventStore.shared.removeByAuthor(pk) }
            }
            // Also rebuild SafetyFilter snapshot synchronously so subsequent
            // event ingestions see the new block set without waiting for
            // commitChange's async rebuild.
            SafetyFilter.shared.install(SafetyFilterSnapshot(
                mutedWords: mutedWords,
                blockedPubkeys: blockedPubkeys,
                mutedThreads: mutedThreads,
                wotEnabled: SafetyFilter.shared.snapshot.wotEnabled,
                qualifiedNetwork: SafetyFilter.shared.snapshot.qualifiedNetwork,
                userPubkey: SafetyFilter.shared.snapshot.userPubkey
            ))
        }

        guard let pk = activePubkey else { return }
        let d = UserDefaults.standard
        d.set(Array(mutedWords), forKey: Self.wordsKey(pk))
        d.set(Array(blockedPubkeys), forKey: Self.pubkeysKey(pk))
        d.set(Array(mutedThreads), forKey: Self.threadsKey(pk))
        d.set(lastUpdatedAt, forKey: Self.updatedAtKey(pk))
        await SafetyFilter.shared.rebuildSnapshot()
    }

    // MARK: - Storage keys

    static func wordsKey(_ pubkey: String) -> String { "muted_words_\(pubkey)" }
    static func pubkeysKey(_ pubkey: String) -> String { "blocked_pubkeys_\(pubkey)" }
    static func threadsKey(_ pubkey: String) -> String { "muted_threads_\(pubkey)" }
    static func updatedAtKey(_ pubkey: String) -> String { "mute_list_updated_at_\(pubkey)" }

    static let fallbackRelays = [
        "wss://relay.damus.io",
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://relay.nostr.band"
    ]

    // MARK: - Private

    private func commitChange() {
        if binding { return }
        guard let pk = activePubkey else { return }
        let d = UserDefaults.standard
        d.set(Array(mutedWords), forKey: Self.wordsKey(pk))
        d.set(Array(blockedPubkeys), forKey: Self.pubkeysKey(pk))
        d.set(Array(mutedThreads), forKey: Self.threadsKey(pk))
        Task { await SafetyFilter.shared.rebuildSnapshot() }
        if let priv = activePrivkey32 {
            Task { [priv] in await self.republish(privkey32: priv) }
        }
    }
}

extension Notification.Name {
    /// Posted when the user blocks someone via `MuteRepository.blockUser`.
    /// `object` is the normalized (lowercased) blocked pubkey. Open feed /
    /// thread view models listen and drop matching in-memory events so the
    /// UI updates without waiting for a cold-launch reseed.
    static let userBlocked = Notification.Name("WispUserBlocked")
}
