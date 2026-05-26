import Foundation
import Observation

/// Tracks rumor ids of gift-wrap-materialized events (private replies / reactions)
/// for the active account. Backed by UserDefaults per-pubkey so the lock icon
/// survives cold restart even before the kind-1059 subscription re-streams the
/// wraps and re-marks them.
///
/// Single source of truth for "is this event id a private rumor": consumed by
/// compose (suppress public publish), thread render (lock chip + hide repost/quote),
/// engagement ingest, and notification classification.
@MainActor
@Observable
final class PrivateInteractionStore {
    static let shared = PrivateInteractionStore()

    private(set) var privateEventIds: Set<String> = []

    private var activePubkey: String = ""

    private var key: String { "private_event_ids_\(activePubkey)" }

    func bind(activePubkey: String) {
        if activePubkey == self.activePubkey { return }
        self.activePubkey = activePubkey
        let cached = UserDefaults.standard.stringArray(forKey: key) ?? []
        privateEventIds = Set(cached)
    }

    @discardableResult
    func markPrivate(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        guard privateEventIds.insert(id).inserted else { return false }
        if !activePubkey.isEmpty {
            UserDefaults.standard.set(Array(privateEventIds), forKey: key)
        }
        return true
    }

    func contains(_ id: String) -> Bool {
        privateEventIds.contains(id)
    }

    func clear() {
        privateEventIds = []
        if !activePubkey.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
