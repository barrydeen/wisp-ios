import Foundation

/// NIP-09: event deletion via kind-5.
/// Spec: https://github.com/nostr-protocol/nips/blob/master/09.md
nonisolated enum Nip09 {

    static let kindDeletion: Int = 5

    /// Delete a regular (non-addressable) event by its id.
    static func deletionTagsForEvent(id: String, kind: Int) -> [[String]] {
        [["e", id], ["k", String(kind)]]
    }

    /// Delete an addressable event by its `kind:pubkey:dTag` coordinate.
    static func deletionTagsForAddressable(kind: Int, pubkey: String, dTag: String) -> [[String]] {
        [["a", "\(kind):\(pubkey):\(dTag)"], ["k", String(kind)]]
    }
}
