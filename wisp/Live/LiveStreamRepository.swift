import Foundation
import Observation

struct LiveStream: Identifiable, Hashable {
    var activity: Nip53.LiveActivity
    let aTagValue: String
    var chatters: Set<String>
    var lastChatAt: Int

    var id: String { aTagValue }
}

struct LiveChatMessage: Identifiable, Hashable {
    let id: String
    let senderPubkey: String
    let content: String
    let createdAt: Int
    var replyToId: String?
    var reactions: [String: Set<String>]
    var emojiTags: [String: String]
    var isZapAnnouncement: Bool
    var zapAmountSats: Int64
}

/// In-memory store for NIP-53 live activities, chat messages, reactions, and stream-level zaps.
/// Discovery (kind 30311 / kind 1311 within the past hour) feeds `streams` and chatter counts;
/// per-stream subscriptions feed `messagesByStream` for the currently-open stream view.
/// Not persisted to ObjectBox — live data is ephemeral and re-discovered on cold start.
@Observable
@MainActor
final class LiveStreamRepository {
    static let shared = LiveStreamRepository()
    /// Chat + zap-announcement rows kept per stream. Long-running radio streams
    /// carry months of kind-1311; history pages in on demand and stops here.
    static let maxChatMessages = 1000

    var streams: [String: LiveStream] = [:]
    var messagesByStream: [String: [LiveChatMessage]] = [:]
    var streamZapTotalsSats: [String: Int64] = [:]
    /// Zap totals computed from a bounded relay scan that may have missed older
    /// receipts — rendered with a trailing "+", sidecar-style.
    var zapTotalsUncertain: Set<String> = []
    var currentATag: String?
    /// Host/streamer kind-0 profiles keyed by pubkey, for the live pill row.
    /// Fed by `LiveStreamCoordinator`'s batched fetch and `FeedLiveNowSection`'s
    /// on-screen self-heal. Lives here (not only in `ProfileRepository`) because
    /// this repo is `@Observable` — a write re-renders `LiveNowPill` the moment
    /// an avatar resolves, which `ProfileRepository`'s plain dict can't do.
    var hostProfiles: [String: ProfileData] = [:]

    @ObservationIgnored private var seenChatIds = Set<String>()
    @ObservationIgnored private var seenZapIds = Set<String>()
    @ObservationIgnored private var pendingFollowChatters: [String: Set<String>] = [:]

    /// Show every discovered live stream by default, like Android — requiring a
    /// recent chatter hid streams whose kind-1311 chat lives on relays this
    /// account doesn't read. Staleness is handled by the sidecar freshness rule
    /// instead (event republished within the last hour), not by chat activity.
    var liveNowSorted: [LiveStream] {
        let now = Date().timeIntervalSince1970
        return streams.values
            .filter { $0.activity.status?.lowercased() == "live"
                && now - TimeInterval($0.activity.createdAt) < 3600 }
            .sorted { lhs, rhs in
                if lhs.chatters.count != rhs.chatters.count {
                    return lhs.chatters.count > rhs.chatters.count
                }
                return lhs.lastChatAt > rhs.lastChatAt
            }
    }

    func messages(for aTag: String) -> [LiveChatMessage] {
        messagesByStream[aTag] ?? []
    }

    /// Record a resolved host/streamer profile so visible pills pick up the avatar.
    func setHostProfile(_ profile: ProfileData) {
        hostProfiles[profile.pubkey] = profile
    }

    // MARK: - Ingestion

    /// Upsert a kind-30311 live activity. Drops streams that flip to non-"live" status.
    ///
    /// Liveness follows sidecar's rule: status "live" alone is not enough — the
    /// event must have been republished within the last hour and carry a
    /// streaming URL. Real streams republish every few minutes; abandoned or
    /// test events stay stuck on "live" forever and would otherwise haunt the
    /// LIVE row indefinitely.
    func addActivity(_ event: NostrEvent) {
        guard event.kind == Nip53.kindLiveActivity,
              let activity = Nip53.parseLiveActivity(event) else { return }
        let aTag = Nip53.aTagValue(host: activity.hostPubkey, dTag: activity.dTag)

        let isLive = activity.status?.lowercased() == "live"
            && activity.streamingUrl?.isEmpty == false
            && Date().timeIntervalSince1970 - TimeInterval(event.createdAt) < 3600
        if !isLive {
            streams.removeValue(forKey: aTag)
            return
        }

        var existing = streams[aTag]
        if existing == nil {
            let pending = pendingFollowChatters.removeValue(forKey: aTag) ?? []
            existing = LiveStream(activity: activity, aTagValue: aTag, chatters: pending, lastChatAt: 0)
        } else {
            existing?.activity = activity
        }
        streams[aTag] = existing
    }

    /// Discovery-only: bump the chatter set for the referenced activity (or queue it pending).
    func trackChatter(_ event: NostrEvent) {
        guard event.kind == Nip53.kindLiveChatMessage,
              let aTag = Nip53.getChatActivityRef(event) else { return }

        if var stream = streams[aTag] {
            stream.chatters.insert(event.pubkey)
            if event.createdAt > stream.lastChatAt { stream.lastChatAt = event.createdAt }
            streams[aTag] = stream
        } else {
            pendingFollowChatters[aTag, default: []].insert(event.pubkey)
        }
    }

    /// Per-stream: store full chat content + bump chatter set + bump lastChatAt.
    func addChatMessage(_ event: NostrEvent) {
        guard event.kind == Nip53.kindLiveChatMessage,
              let aTag = Nip53.getChatActivityRef(event) else { return }
        guard seenChatIds.insert(event.id).inserted else { return }

        let replyToId = event.tags.first(where: { tag in
            guard tag.count >= 2, tag[0] == "e" else { return false }
            if tag.count < 4 { return true }
            return tag[3] == "reply" || tag[3] == ""
        })?[1]

        let msg = LiveChatMessage(
            id: event.id,
            senderPubkey: event.pubkey,
            content: event.content,
            createdAt: event.createdAt,
            replyToId: replyToId,
            reactions: [:],
            emojiTags: parseEmojiTags(event.tags),
            isZapAnnouncement: false,
            zapAmountSats: 0
        )

        var list = messagesByStream[aTag] ?? []
        list.append(msg)
        list.sort { $0.createdAt < $1.createdAt }
        if list.count > Self.maxChatMessages {
            list.removeFirst(list.count - Self.maxChatMessages)
        }
        messagesByStream[aTag] = list

        if var stream = streams[aTag] {
            stream.chatters.insert(event.pubkey)
            if event.createdAt > stream.lastChatAt { stream.lastChatAt = event.createdAt }
            streams[aTag] = stream
        } else {
            pendingFollowChatters[aTag, default: []].insert(event.pubkey)
        }
    }

    /// Add a reactor's emoji to a chat message's reaction map. No-op if message not in our list.
    func addReaction(aTag: String, messageId: String, reactor: String, emoji: String) {
        guard var list = messagesByStream[aTag] else { return }
        guard let idx = list.firstIndex(where: { $0.id == messageId }) else { return }
        var msg = list[idx]
        var set = msg.reactions[emoji] ?? []
        if set.insert(reactor).inserted {
            msg.reactions[emoji] = set
            list[idx] = msg
            messagesByStream[aTag] = list
        }
    }

    /// Synthetic chat bubble for a stream-level zap (kind 9735 referencing the activity's a-tag).
    func addStreamZap(_ event: NostrEvent, aTag: String) {
        guard event.kind == 9735 else { return }
        guard seenZapIds.insert(event.id).inserted else { return }

        let amount = Nip57.zapAmountSats(receipt: event)
        let zapper = Nip57.zapperPubkey(receipt: event) ?? event.pubkey
        let msg = LiveChatMessage(
            id: "zap-\(event.id)",
            senderPubkey: zapper,
            content: Nip57.zapMessage(receipt: event) ?? "",
            createdAt: event.createdAt,
            replyToId: nil,
            reactions: [:],
            emojiTags: [:],
            isZapAnnouncement: true,
            zapAmountSats: amount
        )
        var list = messagesByStream[aTag] ?? []
        list.append(msg)
        list.sort { $0.createdAt < $1.createdAt }
        if list.count > Self.maxChatMessages {
            list.removeFirst(list.count - Self.maxChatMessages)
        }
        messagesByStream[aTag] = list

        streamZapTotalsSats[aTag, default: 0] += amount
    }

    // MARK: - Lifecycle

    func setCurrent(_ aTag: String?) {
        currentATag = aTag
    }

    func clear() {
        streams.removeAll()
        messagesByStream.removeAll()
        streamZapTotalsSats.removeAll()
        zapTotalsUncertain.removeAll()
        hostProfiles.removeAll()
        seenChatIds.removeAll()
        seenZapIds.removeAll()
        pendingFollowChatters.removeAll()
        currentATag = nil
    }

    // MARK: - Helpers

    /// Pull NIP-30 custom-emoji shortcode → URL map from event tags (`["emoji", shortcode, url]`).
    private func parseEmojiTags(_ tags: [[String]]) -> [String: String] {
        var map: [String: String] = [:]
        for t in tags where t.count >= 3 && t[0] == "emoji" {
            map[t[1]] = t[2]
        }
        return map
    }
}
