import Foundation
import Observation

/// Per-stream subscription manager. Owns the three NIP-53 subscriptions (chat / reactions / stream zaps)
/// and routes their events into `LiveStreamRepository`. Builds `chatRelays` per the priority order
/// nevent hints → activity hints → host inbox → host outbox → top scoreboard → fallback.
@Observable
@MainActor
final class LiveStreamViewModel: EmojiComposing {
    let aTagValue: String
    let hostPubkey: String
    let dTag: String
    private let naddrRelayHints: [String]
    let keypair: Keypair

    var chatRelays: [String] = []
    var messageText: String = ""
    /// Custom-emoji `:shortcode` autocomplete state (EmojiComposing); `draft`
    /// bridges to `messageText`.
    var draft: String {
        get { messageText }
        set { messageText = newValue }
    }
    var emojiCandidates: [CustomEmoji] = []
    var emojiStartUtf16: Int?
    var replyTarget: LiveChatMessage?
    var lastError: String?

    @ObservationIgnored private var subs: [RelaySubscription] = []
    @ObservationIgnored private var consumerTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var started = false

    // MARK: Chat history paging (sidecar-style)
    /// Newest page only on open; each scroll-back pulls one more page until the
    /// in-memory cap or the stream's first message is reached.
    var isLoadingOlder = false
    @ObservationIgnored private var reachedOldestHistory = false
    var hasMoreChatHistory: Bool { !reachedOldestHistory }
    var isZapTotalUncertain: Bool {
        LiveStreamRepository.shared.zapTotalsUncertain.contains(aTagValue)
    }

    private static let chatPageSize = 50
    private static let zapScanPageSize = 1000
    /// Public relays that archive kind-9735 receipts for popular streams
    /// (sidecar's ZAP_ARCHIVE_RELAYS) — chat relays alone only hold recent zaps.
    private static let zapArchiveRelays = [
        "wss://nostr21.com", "wss://relay.ditto.pub", "wss://nostr-01.yakihonne.com",
        "wss://relay.nostr.net", "wss://soloco.nl"
    ]

    init(aTagValue: String, hostPubkey: String, dTag: String, naddrRelayHints: [String], keypair: Keypair) {
        self.aTagValue = aTagValue
        self.hostPubkey = hostPubkey
        self.dTag = dTag
        self.naddrRelayHints = naddrRelayHints
        self.keypair = keypair
    }

    var activity: Nip53.LiveActivity? {
        LiveStreamRepository.shared.streams[aTagValue]?.activity
    }

    var messages: [LiveChatMessage] {
        LiveStreamRepository.shared.messages(for: aTagValue)
    }

    var streamZapTotalSats: Int64 {
        LiveStreamRepository.shared.streamZapTotalsSats[aTagValue] ?? 0
    }

    func start() async {
        guard !started else { return }
        started = true
        LiveStreamRepository.shared.setCurrent(aTagValue)

        await resolveChatRelays()
        if chatRelays.isEmpty {
            chatRelays = ["wss://relay.damus.io", "wss://nos.lol", "wss://relay.primal.net"]
        }

        // Recent history first: long-running streams carry months of kind-1311,
        // and backfilling them wholesale stalls the chat for seconds. Pull the
        // newest page up front and page older history on scroll (sidecar-style).
        let initial = await RelayPool.query(
            relays: chatRelays,
            filter: NostrFilter(kinds: [Nip53.kindLiveChatMessage], aTags: [aTagValue], limit: Self.chatPageSize),
            timeout: 8
        )
        for event in initial.sorted(by: { $0.createdAt < $1.createdAt }) {
            LiveStreamRepository.shared.addChatMessage(event)
        }

        let chat = RelayPool.subscribe(
            relays: chatRelays,
            filter: NostrFilter(
                kinds: [Nip53.kindLiveChatMessage],
                aTags: [aTagValue],
                limit: 100,
                since: NostrClock.now() - 10
            ),
            id: "live-chat-\(dTag)"
        )
        let react = RelayPool.subscribe(
            relays: chatRelays,
            filter: NostrFilter(kinds: [7], aTags: [aTagValue], limit: 500),
            id: "live-react-\(dTag)"
        )
        let zap = RelayPool.subscribe(
            relays: chatRelays,
            filter: NostrFilter(kinds: [9735], aTags: [aTagValue], limit: 200),
            id: "live-zap-\(dTag)"
        )
        subs = [chat, react, zap]

        let aTag = aTagValue
        consumerTasks.append(Task {
            for await (event, _) in chat.events {
                await MainActor.run { LiveStreamRepository.shared.addChatMessage(event) }
            }
        })
        consumerTasks.append(Task {
            for await (event, _) in react.events {
                let messageId = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1]
                let targetPubkey = event.tags.first(where: { $0.count >= 2 && $0[0] == "p" })?[1]
                guard let messageId, targetPubkey != nil else { continue }
                await MainActor.run {
                    LiveStreamRepository.shared.addReaction(
                        aTag: aTag,
                        messageId: messageId,
                        reactor: event.pubkey,
                        emoji: event.content
                    )
                }
            }
        })
        consumerTasks.append(Task {
            for await (event, _) in zap.events {
                await MainActor.run { LiveStreamRepository.shared.addStreamZap(event, aTag: aTag) }
            }
        })

        // The live zap sub only sees receipts delivered while watching (plus a
        // small backfill) — a fraction of a popular stream's lifetime total.
        // Scan chat + archive relays once for a much closer number.
        consumerTasks.append(Task { [weak self] in
            await self?.refreshZapTotal()
        })
    }

    /// One-shot kind-9735 scan across the chat relays plus zap-archive relays,
    /// deduped by event id in the repository. Bounded sample: mark the total
    /// uncertain (rendered "+") when relays went quiet or hit the page limit.
    func refreshZapTotal() async {
        var relays = chatRelays
        for url in Self.zapArchiveRelays where !relays.contains(url) {
            relays.append(url)
        }
        if relays.count > 12 {
            relays = Array(relays.prefix(12))
        }
        let (events, responded) = await RelayPool.queryDetailed(
            relays: relays,
            filter: NostrFilter(kinds: [9735], aTags: [aTagValue], limit: Self.zapScanPageSize),
            timeout: 12
        )
        guard !events.isEmpty else { return }
        for event in events.sorted(by: { $0.createdAt < $1.createdAt }) {
            LiveStreamRepository.shared.addStreamZap(event, aTag: aTagValue)
        }
        if events.count >= Self.zapScanPageSize || responded < relays.count {
            LiveStreamRepository.shared.zapTotalsUncertain.insert(aTagValue)
        }
    }

    /// Loads one older page of chat (scroll-back). Pages by count from the
    /// oldest loaded chat message; `until` is inclusive so boundary-second
    /// messages aren't skipped, and the repository dedupes the overlap.
    func loadOlderMessages() async {
        guard !isLoadingOlder, !reachedOldestHistory, !chatRelays.isEmpty else { return }
        let existing = LiveStreamRepository.shared.messages(for: aTagValue)
        guard let oldest = existing.first(where: { !$0.isZapAnnouncement })?.createdAt else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }

        let page = await RelayPool.query(
            relays: chatRelays,
            filter: NostrFilter(
                kinds: [Nip53.kindLiveChatMessage],
                aTags: [aTagValue],
                limit: Self.chatPageSize,
                until: oldest
            ),
            timeout: 8
        )
        for event in page.sorted(by: { $0.createdAt < $1.createdAt }) {
            LiveStreamRepository.shared.addChatMessage(event)
        }
        if page.count < Self.chatPageSize
            || LiveStreamRepository.shared.messages(for: aTagValue).count >= LiveStreamRepository.maxChatMessages {
            reachedOldestHistory = true
        }
    }

    func setReplyTarget(_ msg: LiveChatMessage?) {
        replyTarget = msg
    }

    func cleanup() {
        if LiveStreamRepository.shared.currentATag == aTagValue {
            LiveStreamRepository.shared.setCurrent(nil)
        }
        for t in consumerTasks { t.cancel() }
        consumerTasks.removeAll()
        for s in subs { s.cancel() }
        subs.removeAll()
        started = false
    }

    // MARK: - Send

    /// Sign + publish a kind-1311 chat message. Optimistic — clears the input and adds the
    /// message to the local repo immediately, then publishes in a detached background task
    /// so the UI never blocks on slow/dead relays.
    func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let privkey32 = Hex.decode(keypair.privkey) else { return }

        var tags: [[String]] = [
            ["a", aTagValue, chatRelays.first ?? ""],
            ["p", hostPubkey]
        ]
        if let reply = replyTarget {
            tags.append(["e", reply.id, "", "reply"])
        }
        appendMentionPTags(content: text, into: &tags)
        tags.append(contentsOf: EmojiShortcode.emojiTags(in: text))
        if let client = NostrEvent.clientTagIfEnabled() {
            tags.append(client)
        }

        let event: NostrEvent
        do {
            event = try NostrEvent.sign(
                privkey32: privkey32,
                pubkey: keypair.pubkey,
                kind: Nip53.kindLiveChatMessage,
                createdAt: NostrClock.now(),
                tags: tags,
                content: text
            )
        } catch {
            lastError = error.localizedDescription
            return
        }

        // Optimistic: render immediately, clear input, dismiss reply.
        LiveStreamRepository.shared.addChatMessage(event)
        messageText = ""
        replyTarget = nil

        // Fire-and-forget publish.
        let relays = chatRelays
        Task.detached {
            _ = await RelayPool.publish(event: event, to: relays, timeout: 4)
        }
    }

    /// Sign + publish a kind-7 reaction event targeting a chat message. Optimistically updates
    /// the local reaction map before the network round-trip.
    func sendReaction(messageId: String, targetPubkey: String, emoji: String) async {
        guard let privkey32 = Hex.decode(keypair.privkey) else { return }
        LiveStreamRepository.shared.addReaction(
            aTag: aTagValue,
            messageId: messageId,
            reactor: keypair.pubkey,
            emoji: emoji
        )

        var tags: [[String]] = [
            ["e", messageId],
            ["p", targetPubkey],
            ["a", aTagValue],
            ["k", String(Nip53.kindLiveChatMessage)]
        ]
        if let client = NostrEvent.clientTagIfEnabled() {
            tags.append(client)
        }

        let event: NostrEvent
        do {
            event = try NostrEvent.sign(
                privkey32: privkey32,
                pubkey: keypair.pubkey,
                kind: 7,
                createdAt: NostrClock.now(),
                tags: tags,
                content: emoji
            )
        } catch {
            return
        }
        _ = await RelayPool.publish(event: event, to: chatRelays, timeout: 4)
    }

    // MARK: - Relay routing

    /// Build the per-stream relay set. Priority: nevent hints → activity hints → host inbox →
    /// host outbox → top scoreboard. Deduplicate, cap at 10.
    private func resolveChatRelays() async {
        var ordered: [String] = []
        ordered.append(contentsOf: naddrRelayHints)
        if let hints = activity?.relayHints {
            ordered.append(contentsOf: hints)
        }
        let inbox = await RelayListRepository.shared.getReadRelays(hostPubkey)
        ordered.append(contentsOf: inbox)
        let outbox = await RelayListRepository.shared.getWriteRelays(hostPubkey)
        ordered.append(contentsOf: outbox)
        if let board = RelayScoreBoard.load(pubkey: keypair.pubkey) {
            ordered.append(contentsOf: board.scoredRelays.prefix(3).map(\.url))
        }
        var seen = Set<String>()
        chatRelays = ordered.filter { url in
            guard url.hasPrefix("wss://") else { return false }
            return seen.insert(url).inserted
        }
        if chatRelays.count > 10 {
            chatRelays = Array(chatRelays.prefix(10))
        }
    }

    private func appendMentionPTags(content: String, into tags: inout [[String]]) {
        let pattern = "nostr:(npub1[a-z0-9]+|nprofile1[a-z0-9]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        regex.enumerateMatches(in: content, options: [], range: nsRange) { match, _, _ in
            guard let match, let range = Range(match.range, in: content) else { return }
            let uri = String(content[range])
            guard let data = Nip19.decodeNostrUri(uri) else { return }
            let pubkey: String?
            switch data {
            case .profileRef(let pk, _): pubkey = pk
            default: pubkey = nil
            }
            guard let pubkey else { return }
            if !tags.contains(where: { $0.count >= 2 && $0[0] == "p" && $0[1] == pubkey }) {
                tags.append(["p", pubkey])
            }
        }
    }
}
