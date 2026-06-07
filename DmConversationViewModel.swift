import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class DmConversationViewModel: EmojiComposing {
    let keypair: Keypair
    /// Conversation participants excluding the local user, sorted (matches DmRepository.conversationKey ordering).
    let participants: [String]

    var messages: [DmMessage] = []
    var draft: String = ""
    /// Custom-emoji `:shortcode` autocomplete state (EmojiComposing).
    var emojiCandidates: [CustomEmoji] = []
    var emojiStartUtf16: Int?
    var sendError: String?
    var replyingTo: DmMessage?
    var isMiningPow: Bool = false
    var miningAttempts: Int = 0

    /// Per-participant resolved delivery relays (+ provenance) for the relay panel.
    /// Filled progressively by `loadRelayConfig`. Plain `var` so the panel observes it.
    var allParticipantRelays: [String: PeerDeliveryRelays] = [:]
    /// The local user's own kind-10050 DM relays, shown in the panel's "You" section.
    var userDmRelays: [String] = []
    /// Badge count: every participant relay url + our own DM relays. Mirrors Android.
    var relayCount: Int {
        allParticipantRelays.values.reduce(0) { $0 + $1.urls.count } + userDmRelays.count
    }

    @ObservationIgnored private let repo = DmRepository.shared
    /// Per-conversation scoped kind-1059 subscription, open only while this view is on
    /// screen. Bounded + temporary (see `openScopedSubscription`) so it can't reintroduce
    /// the global-fan-out lag regression.
    @ObservationIgnored private var scopedSub: RelaySubscription?
    @ObservationIgnored private var scopedListener: Task<Void, Never>?
    @ObservationIgnored private var active = false
    @ObservationIgnored private let instanceId = String(UUID().uuidString.prefix(8)).lowercased()
    /// In-flight outgoing messages keyed by their temporary `pending:` id, kept so a
    /// `.failed` send can be retried without re-typing / re-picking.
    @ObservationIgnored private var outgoing: [String: Outgoing] = [:]
    /// Local media previews keyed by temp id, shown in the bubble until the Blossom
    /// upload finishes and the real (decryptable) media metadata is reconciled in.
    @ObservationIgnored private var localOutgoingMedia: [String: LocalOutgoingMedia] = [:]

    private static let indexerRelays = [
        "wss://relay.damus.io",
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://relay.nostr.band",
        "wss://nostr.wine"
    ]

    /// Everything needed to (re)deliver an outgoing message. `rumor` is nil for a media
    /// message until its Blossom upload completes and the kind-15 rumor can be built.
    private struct Outgoing {
        var rumor: Rumor?
        let rumorCreatedAt: Int
        var content: String
        var fileMetadata: EncryptedFileMetadata?
        let replyToId: String?
        let rumorKind: Int
        let pickedMedia: PickedMedia?
    }

    /// A local preview for an in-flight media message (before upload completes).
    struct LocalOutgoingMedia {
        let image: UIImage?
        let isVideo: Bool
        let dim: CGSize
    }

    init(keypair: Keypair, participants: [String]) {
        self.keypair = keypair
        self.participants = participants
    }

    var conversationKey: String {
        DmRepository.conversationKey(participants: participants + [keypair.pubkey])
    }

    func refresh() {
        messages = repo.conversation(conversationKey)?.messages ?? []
    }

    /// Preview for an in-flight media bubble, looked up by the message's (temp) id.
    func localPreview(for message: DmMessage) -> LocalOutgoingMedia? {
        localOutgoingMedia[message.id]
    }

    /// Begin replying to `message`. Ignored for a media message still uploading: its rumor
    /// id (and thus the reply e-tag) isn't final yet, so a reply would tag a parent that
    /// exists on no relay and resolves to nothing locally.
    func beginReply(to message: DmMessage) {
        guard !message.rumorId.hasPrefix(Self.pendingRumorPrefix) else { return }
        replyingTo = message
    }

    // MARK: - Lifecycle (relay config + scoped subscription)

    func start() async {
        guard !active else { return }
        active = true
        refresh()                       // instant paint from the cache
        await loadRelayConfig()         // populates the relay panel (network)
        guard active else { return }    // bail if we were dismissed mid-load
        openScopedSubscription()
    }

    func stop() {
        active = false
        scopedListener?.cancel()
        scopedListener = nil
        scopedSub?.cancel()
        scopedSub = nil
    }

    /// Resolve, for the relay panel, each participant's DM delivery relays (with source)
    /// plus our own DM relays. Seeds instantly from cache, then refreshes from the network.
    /// Mirrors Android `DmConversationViewModel` init.
    func loadRelayConfig() async {
        RelaySettingsRepository.shared.ensureLoaded(pubkey: keypair.pubkey)
        userDmRelays = RelaySettingsRepository.shared.dmRelays

        // Seed synchronously from the kind-10050 cache so the panel paints immediately.
        var map: [String: PeerDeliveryRelays] = [:]
        for p in participants {
            if let cached = RelayListRepository.shared.cachedDmRelays(p), !cached.isEmpty {
                map[p] = PeerDeliveryRelays(urls: cached, source: .dmRelays)
            }
        }
        if !map.isEmpty { allParticipantRelays = map }

        // Refresh each participant from the network, updating incrementally.
        for p in participants {
            let resolved = await PeerRelayResolver.resolveWithSource(pubkey: p)
            guard active else { return }
            if !resolved.urls.isEmpty {
                map[p] = resolved
                allParticipantRelays = map
            }
        }
    }

    /// Open a TEMPORARY kind-1059 (#p:me) subscription on the union of the participants'
    /// DM/inbox relays + our own DM relays, capped to a handful of URLs. This widens
    /// coverage for THIS conversation (catching wraps that landed on relays the global
    /// subscription doesn't watch) without permanently pinning a no-`since` stream on every
    /// relay — it's torn down in `stop()` and rides the connection pool's cap + LRU + idle
    /// TTL, so it does not reintroduce the global-fan-out lag regression.
    private func openScopedSubscription() {
        guard scopedSub == nil else { return }
        let relays = scopedRelaySet()
        guard !relays.isEmpty else { return }
        let filter = NostrFilter(kinds: [Nip17.Kind.giftWrap], pTags: [keypair.pubkey])
        let sub = RelayPool.subscribe(relays: relays, filter: filter, id: "dm-conv-\(instanceId)")
        scopedSub = sub
        scopedListener = Task { [weak self] in
            for await (event, relayUrl) in sub.events {
                guard let self else { break }
                let result = await DmGiftWrapIngestor.ingest(event: event, relayUrl: relayUrl, keypair: self.keypair)
                if result?.conversationKey == self.conversationKey { self.refresh() }
            }
        }
    }

    /// Participant relays first (the point of the scoped sub), then our own DM relays,
    /// canonicalized + deduped + capped at 10 so the sub stays bounded.
    private func scopedRelaySet() -> [String] {
        var ordered: [String] = []
        for p in participants {
            if let d = allParticipantRelays[p] { ordered.append(contentsOf: d.urls) }
        }
        ordered.append(contentsOf: userDmRelays)
        var seen = Set<String>()
        var out: [String] = []
        for u in ordered {
            guard let n = RelayUrlValidator.canonicalize(u) else { continue }
            if seen.insert(n).inserted {
                out.append(n)
                if out.count >= 10 { break }
            }
        }
        return out
    }

    // MARK: - Sending (optimistic)

    /// Send the composer text. Inserts the bubble immediately (`.sending`), clears the
    /// composer, and mines + publishes in the background — reconciling to `.sent`/`.failed`.
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sendError = nil
        let createdAt = NostrClock.now()
        let reply = currentReplyRumorId()
        let rumor = buildRumor(content: text, kind: Nip17.Kind.chatMessage,
                               fileExtraTags: [], replyRumorId: reply, createdAt: createdAt)
        let tempId = Self.makeTempId()
        insertOptimistic(tempId: tempId, content: text, createdAt: createdAt,
                         rumorId: rumor.id, replyToId: reply, fileMetadata: nil)
        outgoing[tempId] = Outgoing(rumor: rumor, rumorCreatedAt: createdAt, content: text,
                                    fileMetadata: nil, replyToId: reply,
                                    rumorKind: Nip17.Kind.chatMessage, pickedMedia: nil)
        draft = ""
        replyingTo = nil
        refresh()
        Task { await deliver(tempId: tempId) }
    }

    /// Send `picked` as a NIP-17 kind-15 file message. Shows a local preview bubble
    /// immediately, then encrypts + uploads to Blossom + publishes in the background.
    func sendFile(_ picked: PickedMedia) {
        sendError = nil
        let createdAt = NostrClock.now()
        let reply = currentReplyRumorId()
        let tempId = Self.makeTempId()
        localOutgoingMedia[tempId] = LocalOutgoingMedia(
            image: UIImage(data: picked.data), isVideo: picked.isVideo, dim: picked.dim
        )
        // No fileMetadata yet — the bubble renders from the local preview while uploading.
        insertOptimistic(tempId: tempId, content: "", createdAt: createdAt,
                         rumorId: "\(Self.pendingRumorPrefix)\(tempId)", replyToId: reply, fileMetadata: nil)
        outgoing[tempId] = Outgoing(rumor: nil, rumorCreatedAt: createdAt, content: "",
                                    fileMetadata: nil, replyToId: reply,
                                    rumorKind: Nip17.Kind.fileMessage, pickedMedia: picked)
        replyingTo = nil
        refresh()
        Task { await uploadAndDeliver(tempId: tempId) }
    }

    /// Re-drive a `.failed` message. Re-wraps + publishes if the rumor was already built
    /// (text, or media whose upload had succeeded); re-runs the media pipeline if the upload
    /// never landed; or — if the in-memory context is gone because the conversation was
    /// re-entered after the failure — rebuilds the (deterministic) rumor for a text message.
    /// Media can't be recovered that way (the original bytes are gone), so it stays failed.
    func retry(_ message: DmMessage) {
        let tempId = message.id
        sendError = nil

        if let draft = outgoing[tempId] {
            repo.setOptimisticSendState(.sending, tempId: tempId, conversationKey: conversationKey)
            refresh()
            if draft.rumor != nil {
                Task { await deliver(tempId: tempId) }
            } else {
                Task { await uploadAndDeliver(tempId: tempId) }
            }
            return
        }

        // No retained context (re-entered the conversation after failing). Rebuild text only.
        guard !message.isFile else { return }
        let rumor = buildRumor(content: message.content, kind: Nip17.Kind.chatMessage,
                               fileExtraTags: [], replyRumorId: message.replyToId,
                               createdAt: message.createdAt)
        outgoing[tempId] = Outgoing(rumor: rumor, rumorCreatedAt: message.createdAt,
                                    content: message.content, fileMetadata: nil,
                                    replyToId: message.replyToId, rumorKind: Nip17.Kind.chatMessage,
                                    pickedMedia: nil)
        repo.setOptimisticSendState(.sending, tempId: tempId, conversationKey: conversationKey)
        refresh()
        Task { await deliver(tempId: tempId) }
    }

    /// React to a DM message; fans the kind-7 (k=14) reaction out to all participants.
    func react(to message: DmMessage, picked: PickedEmoji) async {
        do {
            try await DmReactionPublisher.react(
                message: message, participants: participants,
                conversationKey: conversationKey, keypair: keypair, picked: picked
            )
        } catch {
            sendError = "Reaction failed"
        }
        refresh()
    }

    // MARK: - Send internals

    private static func makeTempId() -> String { "pending:\(UUID().uuidString)" }

    /// Sentinel rumor-id prefix for an in-flight media message whose real (deterministic)
    /// rumor id isn't known until its Blossom upload finishes. Such a message is NOT a valid
    /// reply target — its id can't be used in a reply e-tag yet.
    private static let pendingRumorPrefix = "pending-rumor:"

    /// The current reply target's rumor id, or nil if there's no reply or the target's rumor
    /// id isn't final yet (in-flight media) — guards against tagging a bogus parent on the wire.
    private func currentReplyRumorId() -> String? {
        guard let rid = replyingTo?.rumorId, !rid.hasPrefix(Self.pendingRumorPrefix) else { return nil }
        return rid
    }

    private func buildRumor(content: String, kind: Int, fileExtraTags: [[String]],
                            replyRumorId: String?, createdAt: Int) -> Rumor {
        // p-tags name the conversation participants (never ourselves) so every wrap — and
        // our own self-copy — computes the same rumor id and conversation key (NIP-17).
        var tags: [[String]] = participants.map { ["p", $0] }
        tags.append(contentsOf: fileExtraTags)
        tags.append(contentsOf: EmojiShortcode.emojiTags(in: content))
        if let replyRumorId { tags.append(["e", replyRumorId, "", "reply"]) }
        return Nip17.buildRumorRaw(senderPubkey: keypair.pubkey, kind: kind,
                                   tags: tags, content: content, createdAt: createdAt)
    }

    private func insertOptimistic(tempId: String, content: String, createdAt: Int,
                                  rumorId: String, replyToId: String?,
                                  fileMetadata: EncryptedFileMetadata?) {
        let emojiMap = Dictionary(
            EmojiShortcode.emojiTags(in: content).compactMap { $0.count >= 3 ? ($0[1], $0[2]) : nil },
            uniquingKeysWith: { first, _ in first }
        )
        let msg = DmMessage(
            id: tempId, senderPubkey: keypair.pubkey, content: content, createdAt: createdAt,
            giftWrapId: "", rumorId: rumorId, replyToId: replyToId, participants: participants,
            relayUrls: [], emojiMap: emojiMap, fileMetadata: fileMetadata, sendState: .sending
        )
        repo.insertOptimistic(msg, conversationKey: conversationKey)
    }

    /// Encrypt + upload the picked media, build the kind-15 rumor, then hand off to `deliver`.
    private func uploadAndDeliver(tempId: String) async {
        guard let draft = outgoing[tempId], let picked = draft.pickedMedia else { return }

        // Resolve plaintext bytes (images carry their bytes inline; videos live on disk).
        let plain: Data
        if picked.isVideo {
            guard let url = picked.sourceURL, let data = try? Data(contentsOf: url) else {
                fail(tempId: tempId, "Could not read video"); return
            }
            plain = data
        } else {
            plain = picked.data
        }
        guard !plain.isEmpty else { fail(tempId: tempId, "Empty file"); return }

        let enc: EncryptedMedia.EncryptedFileResult
        do {
            enc = try await Task.detached(priority: .userInitiated) { try EncryptedMedia.encryptFile(plain) }.value
        } catch {
            fail(tempId: tempId, "Encrypt failed"); return
        }

        var servers = BlossomServerList.cached(for: keypair.pubkey)
        if servers.isEmpty { servers = await BlossomServerList.refresh(for: keypair.pubkey) }
        let uploadURL: String
        do {
            let result = try await BlossomClient.upload(
                bytes: enc.encryptedBytes, mime: "application/octet-stream",
                servers: servers, keypair: keypair
            )
            uploadURL = result.url
        } catch {
            fail(tempId: tempId, "Upload failed"); return
        }

        let dim = (picked.dim.width > 0 && picked.dim.height > 0)
            ? "\(Int(picked.dim.width))x\(Int(picked.dim.height))"
            : nil
        let fileTags = EncryptedMedia.buildKind15Tags(
            mimeType: picked.mime, keyHex: enc.keyHex, nonceHex: enc.nonceHex,
            encryptedHash: enc.encryptedSha256Hex, originalHash: enc.originalSha256Hex,
            size: plain.count, dimensions: dim
        )
        let fileMeta = EncryptedFileMetadata(
            fileUrl: uploadURL, mimeType: picked.mime, algorithm: EncryptedMedia.algorithm,
            keyHex: enc.keyHex, nonceHex: enc.nonceHex,
            encryptedHash: enc.encryptedSha256Hex, originalHash: enc.originalSha256Hex,
            size: plain.count, dimensions: dim, blurhash: nil
        )
        let rumor = buildRumor(content: uploadURL, kind: Nip17.Kind.fileMessage,
                               fileExtraTags: fileTags, replyRumorId: draft.replyToId,
                               createdAt: draft.rumorCreatedAt)
        // Persist the built rumor so a publish-stage failure retries the wrap, not the upload.
        outgoing[tempId] = Outgoing(rumor: rumor, rumorCreatedAt: draft.rumorCreatedAt,
                                    content: uploadURL, fileMetadata: fileMeta,
                                    replyToId: draft.replyToId, rumorKind: Nip17.Kind.fileMessage,
                                    pickedMedia: picked)
        await deliver(tempId: tempId)
    }

    /// Wrap the outgoing rumor once per participant (+ a self-copy), publish each copy to
    /// the recipient's inbox relays, and reconcile the optimistic row to `.sent` (or `.failed`).
    private func deliver(tempId: String) async {
        guard let draft = outgoing[tempId], let rumor = draft.rumor else { return }
        guard let primary = participants.first else {
            fail(tempId: tempId, "No recipient"); return
        }

        var allTargets = participants
        allTargets.append(keypair.pubkey)

        let powSnap = PowPreferences.snapshot()
        let ownDmTargets = await resolveOwnRelays()

        var publishedRelays = Set<String>()
        var selfWrap: NostrEvent?

        for recipient in allTargets {
            let isPrimary = recipient == primary
            let isSelf = recipient == keypair.pubkey
            // Mine PoW only on the primary recipient's wrap; fan-out + self copies skip it.
            let powBits: Int? = (isPrimary && powSnap.dmEnabled) ? powSnap.dmDifficulty : nil
            let wrap: NostrEvent
            do {
                let kp = keypair
                let r = rumor
                if powBits != nil { isMiningPow = true; miningAttempts = 0 }
                let result: Result<NostrEvent, Swift.Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        let event = try await Nip17.wrapRumorWithSigner(
                            keypair: kp, recipientPubkey: recipient, rumor: r,
                            powTargetBits: powBits,
                            onPowProgress: { attempts in
                                Task { @MainActor [weak self] in self?.miningAttempts = attempts }
                            }
                        )
                        return .success(event)
                    } catch {
                        return .failure(error)
                    }
                }.value
                isMiningPow = false
                switch result {
                case .success(let e): wrap = e
                case .failure(let error):
                    fail(tempId: tempId, "Encrypt failed: \(error)")
                    return
                }
            }
            if isSelf {
                selfWrap = wrap
                // Pre-seed dedup BEFORE publishing the self-copy: it echoes back on our own
                // kind-1059 subscription(s), possibly before `reconcileOptimistic` rewrites the
                // optimistic row's temp id — marking it seen now makes the echo a no-op so it
                // can't insert a duplicate.
                _ = repo.markGiftWrapSeen(wrap.id)
            }
            // 8s timeout leaves room for the NIP-42 AUTH round-trip many DM relays require.
            let targets = isSelf ? ownDmTargets : await resolveRecipientRelays(for: recipient)
            let ok = await RelayPool.publish(event: wrap, to: targets, timeout: 8)
            publishedRelays.formUnion(ok)
        }

        // If no relay accepted any wrap, leave the bubble in `.failed` (tap to retry).
        guard !publishedRelays.isEmpty else {
            repo.setOptimisticSendState(.failed, tempId: tempId, conversationKey: conversationKey)
            sendError = "Couldn't reach any relay — tap to retry"
            refresh()
            return
        }

        // Promote the optimistic row to its delivered form. The self-copy wrap is the one
        // that echoes back via our kind-1059 subscription; reconcile marks it seen so the
        // echo dedups instead of inserting a duplicate.
        let identityWrapId = selfWrap?.id ?? rumor.id
        let final = DmMessage(
            id: "\(identityWrapId):\(draft.rumorCreatedAt)",
            senderPubkey: keypair.pubkey,
            content: draft.content,
            createdAt: draft.rumorCreatedAt,
            giftWrapId: identityWrapId,
            rumorId: rumor.id,
            replyToId: draft.replyToId,
            participants: participants,
            relayUrls: publishedRelays,
            fileMetadata: draft.fileMetadata,
            sendState: .sent
        )
        let reconciled = repo.reconcileOptimistic(tempId: tempId, conversationKey: conversationKey, final: final)
        if !reconciled, repo.activeAccount == keypair.pubkey {
            // The optimistic row was cleared mid-send (rare: account switched, then switched
            // back, within the publish window). The wrap WAS delivered, so re-insert the real
            // row rather than dropping it. Guarded on the active account so we never write the
            // old account's message into a different account's state.
            repo.addMessage(final, conversationKey: conversationKey)
        }
        outgoing.removeValue(forKey: tempId)
        localOutgoingMedia.removeValue(forKey: tempId)
        sendError = nil
        refresh()
    }

    private func fail(tempId: String, _ error: String) {
        repo.setOptimisticSendState(.failed, tempId: tempId, conversationKey: conversationKey)
        sendError = error
        refresh()
    }

    // MARK: - Relay resolution

    /// Relays the self-copy is published to — the same set this account listens on for
    /// incoming DMs (own kind-10050 ∪ NIP-65 read), so our other devices receive it.
    private func resolveOwnRelays() async -> [String] {
        RelaySettingsRepository.shared.ensureLoaded(pubkey: keypair.pubkey)
        let dm = RelaySettingsRepository.shared.dmRelays
        let read = await RelayListRepository.shared.getReadRelays(keypair.pubkey)
        let merged = canonical(dm + read)
        return merged.isEmpty ? Self.indexerRelays : merged
    }

    /// Recipient delivery targets: the recipient's own inbox (kind-10050 → NIP-65 read).
    /// If the recipient has published no inbox, fall back to public indexer relays as a
    /// best-effort — NEVER to our own relays, which the recipient can't read.
    private func resolveRecipientRelays(for pubkey: String) async -> [String] {
        let resolved = await PeerRelayResolver.resolveWithSource(pubkey: pubkey)
        return resolved.urls.isEmpty ? Self.indexerRelays : resolved.urls
    }

    private func canonical(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for u in urls {
            guard let n = RelayUrlValidator.canonicalize(u) else { continue }
            if seen.insert(n).inserted { out.append(n) }
        }
        return out
    }
}
