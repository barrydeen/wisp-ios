import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// In-memory store for decrypted DM rumors, backed by `DmStore` (ObjectBox) for
/// durability across cold start. Mirrors Android's `DmRepository` + `DmPersistence`:
/// the in-memory `conversations` cache is hydrated from disk on `bind`, and every
/// new message / reaction is written back through the debounced `DmStore`.
@MainActor
@Observable
final class DmRepository {
    static let shared = DmRepository()

    /// Posted (userInfo["conversationKey"]) whenever a conversation's messages/reactions
    /// change, so an OPEN `DmConversationView` live-updates regardless of which subscription
    /// (global or per-conversation) delivered the wrap. Mirrors the kind-1 `.nostrEventPublished`
    /// bridge used by threads.
    static let conversationDidUpdate = Notification.Name("DmConversationDidUpdate")

    /// conversationKey → ordered messages (ascending by createdAt)
    private(set) var conversations: [String: [DmMessage]] = [:]
    /// Track gift wrap ids we've already processed (across multiple relays). Hydrated
    /// from disk on `bind` so a relay re-stream after restart doesn't re-decrypt.
    private var seenGiftWraps: Set<String> = []
    /// rumorId → (conversationKey, messageId), used to attach reactions/zaps.
    private var rumorIndex: [String: (convKey: String, msgId: String)] = [:]
    /// Reactions whose target message hasn't arrived yet (gift wraps stream out of
    /// order). Applied when the target message is added. Session-only.
    private var pendingReactions: [String: [DmReaction]] = [:]
    /// Per-wrap decrypt-failure counts (session-only, never persisted) so a transient
    /// signer/decrypt failure is retried on the next REQ but a permanently-bad wrap
    /// eventually stops busy-looping.
    private var failedGiftWraps: [String: Int] = [:]

    private var activePubkey: String = ""
    private var hydratedFor: String = ""

    /// Wall-clock floor for firing the incoming-DM haptic. Initialized at
    /// app-launch and bumped to `now` every time the app re-enters the
    /// foreground, so an overnight backlog of gift wraps doesn't buzz the
    /// user when they reopen the app. Mirrors NotificationRepository.
    private var soundEligibleAfter: Int = Int(Date().timeIntervalSince1970)

    init() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.soundEligibleAfter = Int(Date().timeIntervalSince1970)
            }
        }
        #endif
    }

    /// The pubkey this repository's in-memory state currently belongs to. Used by senders to
    /// confirm the active account hasn't changed out from under an in-flight optimistic send.
    var activeAccount: String { activePubkey }

    /// Comma-joined sorted participant pubkeys; stable across sender/receiver.
    nonisolated static func conversationKey(participants: [String]) -> String {
        Set(participants).sorted().joined(separator: ",")
    }

    func bind(activePubkey: String) {
        guard activePubkey != self.activePubkey else { return }
        self.activePubkey = activePubkey
        // Reset volatile state when switching accounts.
        conversations = [:]
        seenGiftWraps = []
        rumorIndex = [:]
        pendingReactions = [:]
        failedGiftWraps = [:]
        hydratedFor = ""
    }

    /// Hydrate persisted conversations from disk into the in-memory cache. Idempotent
    /// per account. Awaited by `MessagesViewModel.start` before its first snapshot so
    /// stored DMs show on cold start even with no live relay traffic.
    func hydrateIfNeeded() async {
        let owner = activePubkey
        guard !owner.isEmpty, hydratedFor != owner else { return }
        hydratedFor = owner
        let entries = await DmStore.shared.loadAll(ownerPubkey: owner)
        guard activePubkey == owner else { return }  // account switched mid-load
        applyHydration(entries)
    }

    @discardableResult
    func addMessage(_ msg: DmMessage, conversationKey: String) -> Bool {
        // Dedupe by composite id (giftWrapId:rumorCreatedAt) while merging relayUrls.
        guard upsertInMemory(msg, conversationKey: conversationKey) else {
            seenGiftWraps.insert(msg.giftWrapId)
            return false
        }
        // Mark seen only after a successful insert — a transient decrypt failure
        // upstream leaves the wrap unseen so the periodic REQ retries it.
        seenGiftWraps.insert(msg.giftWrapId)
        bumpLatestWrapTs(msg.createdAt)
        fireIncomingHaptic(for: msg)
        persist(msg, conversationKey: conversationKey)

        // Apply any reactions that arrived before this message.
        if let pend = pendingReactions.removeValue(forKey: msg.rumorId), !pend.isEmpty {
            for r in pend {
                _ = addReaction(conversationKey: conversationKey, targetRumorId: msg.rumorId, reaction: r)
            }
        }
        notifyConversationUpdated(conversationKey)
        return true
    }

    /// Insert (or merge-by-composite-id) a message into the in-memory conversation,
    /// keeping it sorted and the rumor index current. Pure in-memory bookkeeping —
    /// does NOT persist, mark wraps seen, fire haptics, or apply buffered reactions;
    /// callers layer those on. Returns false when it merged into an existing row
    /// (duplicate id), unioning relay URLs.
    @discardableResult
    private func upsertInMemory(_ msg: DmMessage, conversationKey: String) -> Bool {
        var existing = conversations[conversationKey] ?? []
        if let i = existing.firstIndex(where: { $0.id == msg.id }) {
            var merged = existing[i]
            merged.relayUrls.formUnion(msg.relayUrls)
            existing[i] = merged
            conversations[conversationKey] = existing
            return false
        }
        existing.append(msg)
        existing.sort { $0.createdAt < $1.createdAt }
        conversations[conversationKey] = existing
        rumorIndex[msg.rumorId] = (conversationKey, msg.id)
        return true
    }

    // MARK: - Optimistic outgoing messages

    /// Insert an in-flight optimistic outgoing message (`.sending`). In-memory ONLY:
    /// not persisted (its `giftWrapId` is empty until published) and not added to
    /// `seenGiftWraps`. Promoted to a real, persisted row by `reconcileOptimistic`
    /// once at least one relay accepts the wrap.
    func insertOptimistic(_ msg: DmMessage, conversationKey: String) {
        upsertInMemory(msg, conversationKey: conversationKey)
    }

    /// Promote the optimistic row identified by `tempId` to its delivered form:
    /// swap in `final` (which carries the real composite id, giftWrapId, relayUrls,
    /// content/file metadata and `.sent` state), refresh the rumor index, mark the
    /// self-wrap seen so the relay echo dedups, and persist. Returns false if the
    /// optimistic row is gone (e.g. the account switched and cleared state).
    @discardableResult
    func reconcileOptimistic(tempId: String, conversationKey: String, final: DmMessage) -> Bool {
        guard var arr = conversations[conversationKey],
              let i = arr.firstIndex(where: { $0.id == tempId }) else { return false }
        rumorIndex.removeValue(forKey: arr[i].rumorId)
        arr[i] = final
        arr.sort { $0.createdAt < $1.createdAt }
        conversations[conversationKey] = arr
        rumorIndex[final.rumorId] = (conversationKey, final.id)
        seenGiftWraps.insert(final.giftWrapId)
        persist(final, conversationKey: conversationKey)
        return true
    }

    /// Flip the optimistic row identified by `tempId` to a new send state (in-memory
    /// only). Used to mark a send `.failed` (tap-to-retry) and back to `.sending` on retry.
    func setOptimisticSendState(_ state: DmMessage.SendState, tempId: String, conversationKey: String) {
        guard var arr = conversations[conversationKey],
              let i = arr.firstIndex(where: { $0.id == tempId }) else { return }
        arr[i].sendState = state
        conversations[conversationKey] = arr
    }

    /// Attach a reaction (kind-7 `k=14`) to a message by its rumor id. Deduped by
    /// (author, emoji). If the target message hasn't arrived yet, the reaction is
    /// buffered and applied when it does.
    @discardableResult
    func addReaction(conversationKey: String, targetRumorId: String, reaction: DmReaction) -> Bool {
        var convKey = conversationKey
        var index: Int?
        if let mapped = rumorIndex[targetRumorId] {
            convKey = mapped.convKey
            index = conversations[convKey]?.firstIndex(where: { $0.id == mapped.msgId })
        }
        if index == nil {
            index = conversations[convKey]?.firstIndex(where: { $0.rumorId == targetRumorId })
        }
        guard let i = index, var arr = conversations[convKey] else {
            // Out-of-order: stash until the target message arrives.
            var pend = pendingReactions[targetRumorId] ?? []
            if !pend.contains(where: { $0.authorPubkey == reaction.authorPubkey && $0.emoji == reaction.emoji }) {
                pend.append(reaction)
                pendingReactions[targetRumorId] = pend
            }
            return false
        }
        var msg = arr[i]
        if msg.reactions.contains(where: { $0.authorPubkey == reaction.authorPubkey && $0.emoji == reaction.emoji }) {
            return false
        }
        msg.reactions.append(reaction)
        arr[i] = msg
        conversations[convKey] = arr
        persist(msg, conversationKey: convKey)
        notifyConversationUpdated(convKey)
        return true
    }

    private func notifyConversationUpdated(_ conversationKey: String) {
        NotificationCenter.default.post(
            name: Self.conversationDidUpdate, object: nil,
            userInfo: ["conversationKey": conversationKey]
        )
    }

    private func fireIncomingHaptic(for msg: DmMessage) {
        guard msg.senderPubkey != activePubkey else { return }
        guard msg.createdAt >= soundEligibleAfter else { return }
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState == .active else { return }
        #endif
        Haptics.shared.pulse()
    }

    /// Read-only check used by the ingest path before attempting (expensive) decrypt.
    func isGiftWrapSeen(_ giftWrapId: String) -> Bool {
        seenGiftWraps.contains(giftWrapId)
    }

    /// Pre-seed dedup for self-wraps we publish, so the relay echo doesn't re-insert.
    func markGiftWrapSeen(_ giftWrapId: String) -> Bool {
        seenGiftWraps.insert(giftWrapId).inserted
    }

    /// Record a decrypt failure. Returns true once we've given up (and marks the wrap
    /// seen so the periodic re-REQ stops re-delivering it this session). Not persisted,
    /// so a fresh launch retries — covers transient remote-signer outages.
    @discardableResult
    func recordDecryptFailure(_ giftWrapId: String, maxAttempts: Int = 3) -> Bool {
        let n = (failedGiftWraps[giftWrapId] ?? 0) + 1
        failedGiftWraps[giftWrapId] = n
        if n >= maxAttempts {
            seenGiftWraps.insert(giftWrapId)
            return true
        }
        return false
    }

    func conversationList() -> [DmConversation] {
        conversations.compactMap { (key, msgs) -> DmConversation? in
            guard let last = msgs.last else { return nil }
            return DmConversation(conversationKey: key,
                                  participants: last.participants,
                                  messages: msgs,
                                  lastMessageAt: last.createdAt)
        }
        .sorted { $0.lastMessageAt > $1.lastMessageAt }
    }

    func conversation(_ key: String) -> DmConversation? {
        guard let msgs = conversations[key], let last = msgs.last else { return nil }
        return DmConversation(conversationKey: key,
                              participants: last.participants,
                              messages: msgs,
                              lastMessageAt: last.createdAt)
    }

    // MARK: - Persistence

    private func persist(_ msg: DmMessage, conversationKey: String) {
        let owner = activePubkey
        guard !owner.isEmpty else { return }
        Task { await DmStore.shared.enqueue(ownerPubkey: owner, conversationKey: conversationKey, msg: msg) }
    }

    private func applyHydration(_ entries: [(convKey: String, msg: DmMessage)]) {
        for (convKey, msg) in entries {
            guard seenGiftWraps.insert(msg.giftWrapId).inserted else { continue }
            var arr = conversations[convKey] ?? []
            if arr.contains(where: { $0.id == msg.id }) { continue }
            arr.append(msg)
            conversations[convKey] = arr
            rumorIndex[msg.rumorId] = (convKey, msg.id)
        }
        for key in conversations.keys {
            conversations[key]?.sort { $0.createdAt < $1.createdAt }
        }
    }

    // MARK: - Persisted state (UserDefaults, scoped by active pubkey)

    private var lastReadKey: String { "dm_last_read_\(activePubkey)" }
    private var latestWrapKey: String { "dm_latest_wrap_ts_\(activePubkey)" }

    var lastReadTimestamp: Int {
        get { UserDefaults.standard.integer(forKey: lastReadKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastReadKey) }
    }

    var latestWrapTimestamp: Int {
        get { UserDefaults.standard.integer(forKey: latestWrapKey) }
    }

    func markAllRead() {
        let now = Int(Date().timeIntervalSince1970)
        lastReadTimestamp = now
    }

    var hasUnread: Bool {
        let last = lastReadTimestamp
        return conversations.values.contains { msgs in
            (msgs.last?.createdAt ?? 0) > last
        }
    }

    private func bumpLatestWrapTs(_ ts: Int) {
        if ts > latestWrapTimestamp {
            UserDefaults.standard.set(ts, forKey: latestWrapKey)
        }
    }
}
