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
nonisolated final class DeletionTracker {
    static let shared = DeletionTracker()

    /// Soft cap so a runaway stream of kind-5 events from a malicious relay
    /// can't grow this unbounded. At ~64 bytes per id, 50k entries is ~3 MB.
    private static let maxIds = 50_000

    private var deletedIds: Set<String> = []
    private let lock = NSLock()

    private init() {
        load()
    }

    /// Ingest a kind-5 deletion event. Parses its `e` tags, verifies that
    /// the deletion's author matches the deleted event's author, and records
    /// the deleted ids. Idempotent — re-ingesting the same kind-5 is a no-op.
    func ingest(_ deletionEvent: NostrEvent) {
        guard deletionEvent.kind == Nip09.kindDeletion else { return }
        let author = deletionEvent.pubkey
        var newIds: [String] = []
        for tag in deletionEvent.tags {
            guard tag.count >= 2, tag[0] == "e" else { continue }
            let targetId = tag[1]
            // NIP-09: only the original author may delete. The kind-5 can
            // carry a relay hint in position 2 that we ignore here, and an
            // optional author hint in position 3 — if present, it must match.
            if tag.count >= 4, !tag[3].isEmpty, tag[3] != author {
                continue
            }
            newIds.append(targetId)
        }
        guard !newIds.isEmpty else { return }
        lock.lock()
        for id in newIds {
            deletedIds.insert(id)
        }
        // Evict oldest entries if we've hit the cap. `Set<String>` is unordered,
        // so "oldest" is arbitrary — this is just a memory safety valve.
        if deletedIds.count > Self.maxIds {
            let surplus = deletedIds.count - Self.maxIds
            deletedIds = Set(deletedIds.dropFirst(surplus))
        }
        lock.unlock()
        save()
    }

    /// Batch ingest from persisted kind-5 events loaded on launch.
    func ingestBatch(_ events: [NostrEvent]) {
        for event in events where event.kind == Nip09.kindDeletion {
            ingest(event)
        }
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

    private func save() {
        lock.lock()
        let ids = Array(deletedIds)
        lock.unlock()
        UserDefaults.standard.set(ids, forKey: Self.storageKey)
    }
}
