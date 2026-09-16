import Foundation

/// Tracks NIP-09 (kind 5) deletion events and provides a fast lookup for
/// whether a given event id has been deleted.
///
/// NIP-09 lets an author delete their own event by publishing kind 5 with
/// `e` tags naming the events to retract. Without tracking these, a deleted
/// note stays visible — relays may keep their copy, and the local cache
/// certainly does.
///
/// Deletions are discovered two ways:
/// 1. The follows feed subscription includes kind 5, so deletions from
///    followed authors arrive live.
/// 2. On launch, a catch-up query pulls recent kind-5 events from the
///    user's own write relays and indexers.
///
/// Only deletions from the event's own author are honoured (NIP-09
/// requirement); a third party can't delete someone else's note.
///
/// Callers are on the MainActor (`FeedViewModel`, `ProfileViewModel`,
/// `SearchViewModel`, `ThreadViewModel`), so nothing here may block: ingest
/// only touches memory under the lock, and the UserDefaults write is
/// debounced onto `saveQueue`. See `scheduleSave`.
nonisolated final class DeletionTracker: @unchecked Sendable {
    static let shared = DeletionTracker()

    /// Soft cap so a runaway stream of kind-5 events from a malicious relay
    /// can't grow this unbounded. At ~64 bytes per id, 50k entries is ~3 MB.
    private static let maxIds = 50_000

    /// Window over which ingests coalesce into a single write. A burst — a
    /// profile's kind-5 catch-up returns hundreds of events across ~25
    /// relays — then costs one serialization instead of one per event.
    private static let saveDebounce: DispatchTimeInterval = .milliseconds(750)

    private var deletedIds: Set<String> = []
    /// target event id -> pubkeys that signed a kind-5 naming it.
    ///
    /// `deletedIds` answers "was this retracted" for the app-wide safety gate,
    /// which trusts the optional author hint inside the kind-5. That hint is
    /// absent on most requests, so it can't distinguish an author retracting
    /// their own note from a stranger naming someone else's. Keeping the
    /// signer lets a caller that already knows the target's author demand a
    /// match — see `isDeleted(eventId:author:)`.
    private var requestSigners: [String: Set<String>] = [:]
    /// Event ids already asked about over the network this session. A negative
    /// answer is cached too, or every re-render of a missing quote re-queries.
    private var checkedOverNetwork: Set<String> = []
    private var inflightChecks: [String: Task<Void, Never>] = [:]
    private let lock = NSLock()

    /// True while a debounced write is pending, so a burst enqueues exactly
    /// one. Guarded by `lock`.
    private var saveScheduled = false

    private let saveQueue = DispatchQueue(label: "talk.wisp.deletion-tracker.save", qos: .utility)

    private init() {
        load()
    }

    /// Ingest a kind-5 deletion event. Returns true if it recorded an id the
    /// tracker didn't already hold.
    @discardableResult
    func ingest(_ deletionEvent: NostrEvent) -> Bool {
        ingestBatch([deletionEvent])
    }

    /// Batch ingest — from the persisted kind-5 events loaded on launch, or
    /// from a profile's deletion catch-up query.
    ///
    /// One lock acquisition and at most one scheduled write for the whole
    /// batch. Ingesting per-event used to re-serialize the entire id set to
    /// UserDefaults once per event, synchronously on the MainActor: opening
    /// the profile of an author with many deletions stalled the UI for
    /// seconds and could trip the watchdog.
    @discardableResult
    func ingestBatch(_ events: [NostrEvent]) -> Bool {
        var newIds: [String] = []
        for event in events where event.kind == Nip09.kindDeletion {
            let author = event.pubkey
            for tag in event.tags {
                guard tag.count >= 2, tag[0] == "e" else { continue }
                // NIP-09: only the original author may delete. The kind-5 can
                // carry a relay hint in position 2 that we ignore here, and an
                // optional author hint in position 3 — if present, it must match.
                if tag.count >= 4, !tag[3].isEmpty, tag[3] != author { continue }
                newIds.append(tag[1])
            }
        }
        // Signer per id, for callers that can verify it against the target's
        // real author rather than the kind-5's own optional hint.
        var signers: [(id: String, signer: String)] = []
        for event in events where event.kind == Nip09.kindDeletion {
            for id in Nip09.deletedEventIds(event) {
                signers.append((id, event.pubkey))
            }
        }

        guard !newIds.isEmpty else { return false }

        lock.lock()
        var changed = false
        for id in newIds {
            if deletedIds.insert(id).inserted { changed = true }
        }
        for entry in signers {
            requestSigners[entry.id, default: []].insert(entry.signer)
        }
        // Evict oldest entries if we've hit the cap. `Set<String>` is unordered,
        // so "oldest" is arbitrary — this is just a memory safety valve.
        if changed, deletedIds.count > Self.maxIds {
            let surplus = deletedIds.count - Self.maxIds
            deletedIds = Set(deletedIds.dropFirst(surplus))
        }
        lock.unlock()

        // Re-ingesting a batch we already hold — every revisit to the same
        // profile does exactly that — now costs nothing beyond the scan.
        if changed { scheduleSave() }
        return changed
    }

    /// Fast lookup: has this event id been deleted?
    ///
    /// Honors the kind-5's optional author hint, which most requests omit —
    /// see `isDeleted(eventId:author:)` for the stricter reading available
    /// when the caller knows who wrote the target.
    func isDeleted(_ id: String) -> Bool {
        lock.lock()
        let contains = deletedIds.contains(id)
        lock.unlock()
        return contains
    }

    /// Whether `author` retracted `eventId` — the strict NIP-09 reading, for
    /// callers that already know the target's author.
    ///
    /// False when the author is unknown: an unattributable kind-5 proves
    /// nothing, and treating it as proof would let anyone blank out someone
    /// else's note by publishing one.
    func isDeleted(eventId: String, author: String?) -> Bool {
        guard let author else { return false }
        lock.lock()
        let signed = requestSigners[eventId]?.contains(author) ?? false
        lock.unlock()
        return signed
    }

    // MARK: - On-demand check

    /// Ask relays once whether `author` retracted `eventId`, and return the
    /// answer. Repeat calls for the same id reuse the first result — including
    /// a negative one — for the rest of the session.
    ///
    /// Callers should already be showing a placeholder: this explains a note
    /// that failed to render, and is never a gate on one that succeeded.
    @discardableResult
    func check(eventId: String, author: String?, relayHints: [String]) async -> Bool {
        guard let author else { return false }
        if isDeleted(eventId: eventId, author: author) { return true }

        lock.lock()
        let existing = inflightChecks[eventId]
        let alreadyChecked = checkedOverNetwork.contains(eventId)
        lock.unlock()

        if let existing {
            await existing.value
            return isDeleted(eventId: eventId, author: author)
        }
        if alreadyChecked { return false }

        let relays = checkRelays(hints: relayHints)
        let task = Task {
            let events = await RelayPool.query(
                relays: relays,
                filter: Nip09.deletionFilter(eventId: eventId, authors: [author]),
                timeout: 5
            )
            // Route through the normal ingest so the app-wide gate and the
            // signer map learn about it too.
            DeletionTracker.shared.ingestBatch(events)
        }
        lock.lock()
        inflightChecks[eventId] = task
        lock.unlock()

        await task.value

        lock.lock()
        inflightChecks[eventId] = nil
        checkedOverNetwork.insert(eventId)
        lock.unlock()

        return isDeleted(eventId: eventId, author: author)
    }

    /// The quote's own relay hints first — a deletion request travels to the
    /// relays that carried the note — then the generic fallback set.
    private func checkRelays(hints: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for url in hints + RelayDefaults.fallbacks {
            guard let canon = RelayUrlValidator.canonicalize(url) else { continue }
            if seen.insert(canon).inserted { out.append(canon) }
        }
        return Array(out.prefix(6))
    }

    /// Drop everything, in memory and on disk. Called from the full app-data
    /// wipe alongside the other in-memory singletons.
    func clear() {
        lock.lock()
        deletedIds.removeAll()
        requestSigners.removeAll()
        checkedOverNetwork.removeAll()
        let tasks = inflightChecks.values
        inflightChecks.removeAll()
        lock.unlock()
        tasks.forEach { $0.cancel() }
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    // MARK: - Persistence

    private static let storageKey = "nip09_deleted_event_ids"

    private func load() {
        let ids = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
        lock.lock()
        deletedIds = Set(ids)
        lock.unlock()
    }

    /// Queue a debounced write of the whole set off the MainActor.
    ///
    /// Losing the tail of a debounce window to a kill is harmless: kind-5
    /// events are persisted in `EventStore`, and `FeedViewModel.start`
    /// re-seeds the tracker from them on the next launch. This store is a
    /// cold-start fast path, not the source of truth.
    private func scheduleSave() {
        lock.lock()
        if saveScheduled {
            lock.unlock()
            return
        }
        saveScheduled = true
        lock.unlock()

        saveQueue.asyncAfter(deadline: .now() + Self.saveDebounce) { [self] in
            lock.lock()
            saveScheduled = false
            let ids = Array(deletedIds)
            lock.unlock()
            UserDefaults.standard.set(ids, forKey: Self.storageKey)
        }
    }
}
