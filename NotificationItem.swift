import Foundation

enum NotificationKind: String, Hashable {
    case reply
    case reaction
    case repost
    case zap
    case quote
    case mention
    case dm
    case pollVote
}

struct FlatNotificationItem: Identifiable, Hashable {
    let id: String
    let kind: NotificationKind
    let actorPubkey: String
    let referencedEventId: String
    let timestamp: Int
    var emoji: String? = nil
    var emojiUrl: String? = nil
    var zapSats: Int64 = 0
    var zapMessage: String = ""
    var isPrivateZap: Bool = false
    var quoteEventId: String? = nil
    var actorEventId: String? = nil
    var dmPeerPubkey: String? = nil
    var dmConversationKey: String? = nil
    var dmUnread: Int = 0
    var relayHints: [String] = []
    /// Option ids chosen by a kind-1018 poll voter (for `.pollVote` items).
    var voteOptionIds: [String] = []
    /// Index of the option zapped on a kind-6969 zap poll (annotates `.zap` items
    /// whose target is one of our zap polls).
    var zapPollOptionIndex: Int? = nil
}

struct NotificationSummary: Hashable {
    var replyCount: Int = 0
    var reactionCount: Int = 0
    var zapCount: Int = 0
    var zapSats: Int64 = 0
    var repostCount: Int = 0
    var mentionCount: Int = 0
    var quoteCount: Int = 0
    var dmCount: Int = 0
    var pollVoteCount: Int = 0
}

/// Set-based filter: each type independently toggleable. Mirrors Android.
enum NotificationFilter: String, CaseIterable, Hashable {
    case replies
    case reactions
    case zaps
    case reposts
    case mentions
    case votes
    case dms

    /// Map a `NotificationKind` to its filter bucket.
    /// Quote+mention collapse to .mentions; pollVote → .votes (matches Android).
    static func bucket(for kind: NotificationKind) -> NotificationFilter {
        switch kind {
        case .reply:           .replies
        case .reaction:        .reactions
        case .zap:             .zaps
        case .repost:          .reposts
        case .quote, .mention: .mentions
        case .pollVote:        .votes
        case .dm:              .dms
        }
    }

    var label: String {
        switch self {
        case .replies:   "Replies"
        case .reactions: "Reactions"
        case .zaps:      "Zaps"
        case .reposts:   "Reposts"
        case .mentions:  "Mentions"
        case .votes:     "Votes"
        case .dms:       "DMs"
        }
    }
}
