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
    case pollEnded
}

struct FlatNotificationItem: Identifiable, Hashable {
    let id: String
    let kind: NotificationKind
    /// Mutable so a consolidated poll row can re-point at its most-recent
    /// voter as new votes fold in. Required (no default) in the memberwise init.
    var actorPubkey: String
    let referencedEventId: String
    /// Mutable so a consolidated poll row floats to its newest vote's time.
    var timestamp: Int
    var emoji: String? = nil
    var emojiUrl: String? = nil
    var zapSats: Int64 = 0
    var zapMessage: String = ""
    var isPrivateZap: Bool = false
    /// True when this row was materialized from a gift-wrapped rumor (private
    /// reply or private reaction). Drives the lock-icon overlay in
    /// `NotificationRowView`. Independent of `isPrivateZap`, which only flags
    /// zap receipts routed through DM relays.
    var isPrivate: Bool = false
    var quoteEventId: String? = nil
    var actorEventId: String? = nil
    var dmPeerPubkey: String? = nil
    var dmConversationKey: String? = nil
    var dmUnread: Int = 0
    var relayHints: [String] = []
    /// For `.reply` rows: whether `referencedEventId` (the immediate parent the
    /// actor replied to) is one of my own notes. Drives the caption — "replying
    /// to your note" vs "replying in your thread" when the parent is someone
    /// else's reply nested under my note. Defaults `true` (direct-reply wording).
    var replyTargetIsMine: Bool = true
    /// Option ids chosen by a kind-1018 poll voter (for `.pollVote` items).
    /// On a consolidated poll row this holds the most-recent voter's choice,
    /// used for the collapsed-row hint.
    var voteOptionIds: [String] = []
    /// Consolidated poll-vote state: voterPubkey -> their latest vote.
    /// Latest-wins by timestamp so a re-vote updates rather than stacks.
    /// Empty on every non-poll item. A `.pollVote` row aggregates every
    /// voter on one poll here instead of spawning a row per vote — that keeps
    /// a busy poll from evicting itself out of the capped flat buffer.
    var pollVotes: [String: PollVoteRecord] = [:]
    /// Index of the option zapped on a kind-6969 zap poll (annotates `.zap` items
    /// whose target is one of our zap polls).
    var zapPollOptionIndex: Int? = nil
    /// Additional zaps from the same actor against the same referenced event,
    /// folded into this row so a spammer can't push everything else off-screen.
    /// Populated by the view model at display time; always empty on freshly
    /// classified items in the repository.
    var mergedZaps: [FlatNotificationItem] = []

    /// Total sats across the primary zap and every merged duplicate. Used by
    /// the row + bolt-icon label so the displayed amount reflects the full
    /// contribution from this actor on this note.
    var totalZapSats: Int64 {
        mergedZaps.reduce(zapSats) { $0 + $1.zapSats }
    }

    /// Distinct voters folded into a consolidated poll row.
    var pollVoterCount: Int { pollVotes.count }

    /// optionId -> number of voters currently picking it (consolidated rows).
    /// Reflects latest-wins state, so a voter who changed their pick only
    /// counts toward their current choice.
    var pollVoteCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for record in pollVotes.values {
            for id in record.optionIds { counts[id, default: 0] += 1 }
        }
        return counts
    }
}

/// One voter's latest choice on a poll, tracked inside a consolidated
/// `.pollVote` notification row.
struct PollVoteRecord: Hashable {
    let timestamp: Int
    let optionIds: [String]
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
    var pollEndedCount: Int = 0
}

/// Set-based filter: each type independently toggleable. Mirrors Android.
enum NotificationFilter: String, CaseIterable, Hashable {
    case replies
    case reactions
    case zaps
    case reposts
    case mentions
    case dms
    case votes

    /// Map a `NotificationKind` to its filter bucket.
    /// Quote+mention collapse to .mentions; pollVote and pollEnded → .votes.
    static func bucket(for kind: NotificationKind) -> NotificationFilter {
        switch kind {
        case .reply:               .replies
        case .reaction:            .reactions
        case .zap:                 .zaps
        case .repost:              .reposts
        case .quote, .mention:     .mentions
        case .pollVote, .pollEnded: .votes
        case .dm:                  .dms
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
