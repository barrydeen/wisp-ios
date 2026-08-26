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
        guard !newIds.isEmpty else { return false }

        lock.lock()
        var changed = false
        for id in newIds {
            if deletedIds.insert(id).inserted { changed = true }
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
    func isDeleted(_ id: String) -> Bool {
        lock.lock()
        let contains = deletedIds.contains(id)
        lock.unlock()
        return contains
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
