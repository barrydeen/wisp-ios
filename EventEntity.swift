import Foundation
import ObjectBox

// objectbox: entity
//
// `nonisolated` overrides the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
// for this class so reads/writes from the `EventStore` actor (and the ObjectBox
// generated descriptors / bindings, which extend this type) don't cross actor
// boundaries on every property access. Persistence is fundamentally not UI work.
nonisolated class EventEntity {
    var id: Id = 0

    // objectbox: unique
    var eventId: String = ""

    // objectbox: index
    var pubkey: String = ""

    var createdAt: Int = 0

    // objectbox: index
    var kind: Int = 0

    var content: String = ""
    var tags: String = ""
    var sig: String = ""
    var insertedAt: Int = 0

    required init() {}

    convenience init(from event: NostrEvent) {
        self.init()
        self.eventId = event.id
        self.pubkey = event.pubkey
        self.createdAt = event.createdAt
        self.kind = event.kind
        self.content = event.content
        if let data = try? JSONSerialization.data(withJSONObject: event.tags),
           let str = String(data: data, encoding: .utf8) {
            self.tags = str
        } else {
            self.tags = "[]"
        }
        self.sig = event.sig
        self.insertedAt = Int(Date().timeIntervalSince1970)
    }

    func toNostrEvent() -> NostrEvent? {
        let parsedTags: [[String]]
        if let data = tags.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String]] {
            parsedTags = arr
        } else {
            parsedTags = []
        }
        return NostrEvent(
            id: eventId,
            pubkey: pubkey,
            kind: kind,
            createdAt: createdAt,
            tags: parsedTags,
            content: content,
            sig: sig
        )
    }
}
