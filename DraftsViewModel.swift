import Foundation
import Observation

/// View model for the "Drafts & Scheduled" screen.
///
/// Drafts are NIP-37 (kind 31234) addressable events on the user's write relays,
/// self-encrypted with NIP-44. Scheduled posts are normal kind-1 (and friends)
/// events with a future `created_at`, parked on `wss://scheduler.nostrarchives.com`
/// (NIP-42 AUTH required), which broadcasts them at the scheduled time.
///
/// Mirrors `DraftsViewModel.kt` in the Android client.
@Observable
@MainActor
final class DraftsViewModel {

    static let schedulerRelay = "wss://scheduler.nostrarchives.com"

    enum Tab: Hashable { case drafts, scheduled }

    let keypair: Keypair

    var drafts: [Nip37.Draft] = []
    var scheduledPosts: [NostrEvent] = []
    var isLoadingDrafts: Bool = false
    var isLoadingScheduled: Bool = false
    var selectedTab: Tab = .drafts
    var errorMessage: String?

    @ObservationIgnored private var conversationKey: Data?

    init(keypair: Keypair) {
        self.keypair = keypair
    }

    // MARK: - Drafts

    /// Query write relays for the user's NIP-37 drafts, dedupe by `d` tag (latest
    /// `created_at` wins), decrypt, parse, and drop tombstones (empty content).
    func loadDrafts() async {
        isLoadingDrafts = true
        errorMessage = nil
        defer { isLoadingDrafts = false }

        let relays = topWriteRelays()
        var filter = NostrFilter()
        filter.kinds = [Nip37.kindDraft]
        filter.authors = [keypair.pubkey]
        filter.limit = 200

        let events = await RelayPool.query(relays: relays, filter: filter, timeout: 8)

        // Latest wrapper per `d` tag.
        var latestByDTag: [String: NostrEvent] = [:]
        for e in events {
            guard let dTag = e.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1] else { continue }
            if let existing = latestByDTag[dTag], existing.createdAt >= e.createdAt { continue }
            latestByDTag[dTag] = e
        }

        guard let convKey = ensureConversationKey() else {
            errorMessage = "Couldn't derive draft encryption key."
            return
        }

        var parsed: [Nip37.Draft] = []
        for wrapper in latestByDTag.values {
            guard let plaintext = try? Nip44.decrypt(payload: wrapper.content, conversationKey: convKey) else { continue }
            // Empty plaintext from a successfully decrypted but empty payload is also a tombstone.
            if plaintext.isEmpty { continue }
            guard let draft = Nip37.parseDraft(wrapper: wrapper, decryptedJSON: plaintext) else { continue }
            // Empty inner content means the draft was tombstoned by a later replacement.
            let trimmed = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            parsed.append(draft)
        }

        // Deduplicate by trimmed text content — keep newest among identical drafts.
        var latestByContent: [String: Nip37.Draft] = [:]
        for draft in parsed {
            let key = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = latestByContent[key], existing.createdAt >= draft.createdAt { continue }
            latestByContent[key] = draft
        }

        drafts = latestByContent.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Optimistically remove the draft locally, then publish:
    /// (a) a NIP-09 addressable deletion (kind 5 with an `a` tag), and
    /// (b) an empty-content NIP-37 replacement (covers clients that don't honor NIP-09).
    func deleteDraft(dTag: String) async {
        drafts.removeAll { $0.dTag == dTag }
        guard let privkey = Hex.decode(keypair.privkey),
              let convKey = ensureConversationKey() else { return }

        let now = Int(Date().timeIntervalSince1970)
        let relays = topWriteRelays()

        // (a) NIP-09 addressable deletion.
        let delTags = Nip09.deletionTagsForAddressable(kind: Nip37.kindDraft, pubkey: keypair.pubkey, dTag: dTag)
        if let delEvent = try? NostrEvent.sign(
            privkey32: privkey, pubkey: keypair.pubkey,
            kind: Nip09.kindDeletion, createdAt: now, tags: delTags, content: ""
        ) {
            _ = await RelayPool.publish(event: delEvent, to: relays, timeout: 6)
        }

        // (b) Empty-content NIP-37 replacement.
        if let emptyCipher = try? Nip44.encrypt(plaintext: " ", conversationKey: convKey) {
            // Encrypt a single space so NIP-44's non-empty-plaintext rule is satisfied;
            // parseDraft will see content "" after we strip the inner empty content.
            let innerJSON = Nip37.serializeInner(
                pubkeyHex: keypair.pubkey, innerKind: 1, content: "", tags: [], createdAt: now
            )
            if let realCipher = try? Nip44.encrypt(plaintext: innerJSON, conversationKey: convKey) {
                let wrapperTags = Nip37.wrapperTags(dTag: dTag, innerKind: 1)
                if let wrapper = try? NostrEvent.sign(
                    privkey32: privkey, pubkey: keypair.pubkey,
                    kind: Nip37.kindDraft, createdAt: now, tags: wrapperTags, content: realCipher
                ) {
                    _ = await RelayPool.publish(event: wrapper, to: relays, timeout: 6)
                }
            }
            _ = emptyCipher
        }
    }

    // MARK: - Scheduled posts

    /// Connect to the scheduler relay (with NIP-42 AUTH), subscribe for our own
    /// future-dated kind-1 events, collect until EOSE+grace, then return.
    func loadScheduledPosts() async {
        isLoadingScheduled = true
        errorMessage = nil
        defer { isLoadingScheduled = false }

        let relay = Self.schedulerRelay
        await GroupRelayPool.shared.ensureRelay(relay, keypair: keypair)
        await GroupRelayPool.shared.waitForAuthIfNeeded(relayUrl: relay, timeout: 5)

        var filter = NostrFilter()
        filter.kinds = [1]
        filter.authors = [keypair.pubkey]
        filter.limit = 100

        let subId = "scheduled_\(Int(Date().timeIntervalSince1970))"
        let stream = await GroupRelayPool.shared.subscribe(relayUrl: relay, filter: filter, subId: subId)

        var collected: [String: NostrEvent] = [:]
        let collectTask = Task { @MainActor in
            for await event in stream {
                collected[event.id] = event
            }
        }
        // Give the relay 10s to deliver everything (matches Android).
        try? await Task.sleep(for: .seconds(10))
        await GroupRelayPool.shared.cancelSubscription(relayUrl: relay, subId: subId)
        collectTask.cancel()

        scheduledPosts = collected.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Sign a NIP-09 deletion (kind 5 with `e`+`k` tags) and send it to the
    /// scheduler relay via the AUTH-aware retry path.
    func deleteScheduledPost(eventId: String) async {
        scheduledPosts.removeAll { $0.id == eventId }
        guard let privkey = Hex.decode(keypair.privkey) else { return }
        let now = Int(Date().timeIntervalSince1970)
        let tags = Nip09.deletionTagsForEvent(id: eventId, kind: 1)
        guard let event = try? NostrEvent.sign(
            privkey32: privkey, pubkey: keypair.pubkey,
            kind: Nip09.kindDeletion, createdAt: now, tags: tags, content: ""
        ) else { return }
        let relay = Self.schedulerRelay
        await GroupRelayPool.shared.ensureRelay(relay, keypair: keypair)
        _ = await GroupRelayPool.shared.publishWithAuthRetry(event, to: relay)
    }

    // MARK: - Helpers

    private func ensureConversationKey() -> Data? {
        if let conversationKey { return conversationKey }
        guard let priv = Hex.decode(keypair.privkey),
              let pub = Hex.decode(keypair.pubkey),
              let key = try? Nip44.getConversationKey(privkey32: priv, peerXonlyPubkey32: pub) else { return nil }
        conversationKey = key
        return key
    }

    private func topWriteRelays() -> [String] {
        if let board = RelayScoreBoard.load(pubkey: keypair.pubkey) {
            let top = board.scoredRelays.prefix(5).map(\.url)
            if !top.isEmpty { return top }
        }
        return ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
    }
}
