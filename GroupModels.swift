import Foundation

/// Pure value types for NIP-29 groups. Mirrors the Kotlin models in
/// `wisp.app/nostr/Nip29.kt` and `wisp.app/repo/GroupRepository.kt`.

struct GroupMetadata: Hashable {
    let groupId: String
    var name: String?
    var picture: String?
    var about: String?
    var isPrivate: Bool
    var isClosed: Bool
    var isRestricted: Bool
    var isHidden: Bool
}

struct AdminEntry: Hashable {
    let pubkey: String
    let roles: [String]
}

struct GroupRole: Hashable {
    let name: String
    let description: String?
}

struct GroupMessage: Hashable, Identifiable {
    let id: String                                 // Event id.
    let senderPubkey: String
    let content: String
    let createdAt: Int
    var replyToId: String?
    var reactions: [String: [String]]              // emoji -> reactor pubkeys
    var emojiTags: [String: String]                // shortcode -> URL (NIP-30)

    init(id: String, senderPubkey: String, content: String, createdAt: Int,
         replyToId: String? = nil,
         reactions: [String: [String]] = [:],
         emojiTags: [String: String] = [:]) {
        self.id = id
        self.senderPubkey = senderPubkey
        self.content = content
        self.createdAt = createdAt
        self.replyToId = replyToId
        self.reactions = reactions
        self.emojiTags = emojiTags
    }
}

struct GroupRoom: Identifiable, Hashable {
    let groupId: String
    let relayUrl: String
    var metadata: GroupMetadata?
    var messages: [GroupMessage]
    var lastMessageAt: Int
    var admins: [String]
    var members: [String]
    var reactionEmojiUrls: [String: String]

    /// Stable id for List rows / NavigationPath — matches the on-disk roomKey form
    /// (sans owner-pubkey prefix; the repository scopes to a single owner already).
    var id: String { "\(relayUrl)|\(groupId)" }

    // Identity-only Hashable so navigation/list rows don't churn when messages mutate.
    static func == (lhs: GroupRoom, rhs: GroupRoom) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    init(groupId: String, relayUrl: String, metadata: GroupMetadata? = nil,
         messages: [GroupMessage] = [], lastMessageAt: Int = 0,
         admins: [String] = [], members: [String] = [],
         reactionEmojiUrls: [String: String] = [:]) {
        self.groupId = groupId
        self.relayUrl = relayUrl
        self.metadata = metadata
        self.messages = messages
        self.lastMessageAt = lastMessageAt
        self.admins = admins
        self.members = members
        self.reactionEmojiUrls = reactionEmojiUrls
    }
}

/// One entry per discovered (but not joined) group, surfaced on the Discover screen.
struct DiscoveredGroup: Hashable, Identifiable {
    let relayUrl: String
    let metadata: GroupMetadata
    let memberCount: Int
    var id: String { "\(relayUrl)|\(metadata.groupId)" }
}

/// One-shot preview fetched before a join attempt or to populate Discover rows.
struct GroupPreview: Hashable {
    let metadata: GroupMetadata?
    let members: [String]
}

enum JoinError: Error, Hashable {
    case rejected(message: String)
    case authRequired
    case timeout
    case network
    case invalidLink
}

enum AdminError: Error, Hashable {
    case notAuthenticated
    case rejected(message: String)
    case timeout
    case network
}

/// `"\(ownerPubkey)|\(relayUrl)|\(groupId)"`. Stable across processes; used as
/// the unique key in the ObjectBox `GroupMetaEntity` and `GroupMessageEntity` tables.
nonisolated func groupRoomKey(ownerPubkey: String, relayUrl: String, groupId: String) -> String {
    "\(ownerPubkey)|\(relayUrl)|\(groupId)"
}
