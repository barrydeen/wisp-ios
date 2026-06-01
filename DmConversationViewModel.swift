import Foundation
import Observation

@Observable
@MainActor
final class DmConversationViewModel {
    let keypair: Keypair
    /// Conversation participants excluding the local user, sorted (matches DmRepository.conversationKey ordering).
    let participants: [String]

    var messages: [DmMessage] = []
    var draft: String = ""
    var isSending: Bool = false
    var sendError: String?
    var replyingTo: DmMessage?
    var isMiningPow: Bool = false
    var miningAttempts: Int = 0

    @ObservationIgnored private let repo = DmRepository.shared
    @ObservationIgnored private var relayCache: [String: [String]] = [:]  // pubkey → relay urls

    private static let indexerRelays = [
        "wss://relay.damus.io",
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://relay.nostr.band",
        "wss://nostr.wine"
    ]

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

    // MARK: - Sending

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        sendError = nil
        defer { isSending = false }
        await performSend(content: text, rumorKind: Nip17.Kind.chatMessage, fileExtraTags: [], fileMetadata: nil)
        if sendError == nil { draft = "" }
    }

    /// Encrypt `picked` with AES-256-GCM, upload the ciphertext to Blossom, and send a
    /// NIP-17 kind-15 file message referencing it. Mirrors Android `sendFileMessage`.
    func sendFile(_ picked: PickedMedia) async {
        guard !isSending else { return }
        isSending = true
        sendError = nil
        defer { isSending = false }

        // Resolve plaintext bytes (images carry their bytes inline; videos live on disk).
        let plain: Data
        if picked.isVideo {
            guard let url = picked.sourceURL, let data = try? Data(contentsOf: url) else {
                sendError = "Could not read video"
                return
            }
            plain = data
        } else {
            plain = picked.data
        }
        guard !plain.isEmpty else { sendError = "Empty file"; return }

        // Encrypt off the main actor (CPU-bound for large media).
        let enc: EncryptedMedia.EncryptedFileResult
        do {
            enc = try await Task.detached(priority: .userInitiated) { try EncryptedMedia.encryptFile(plain) }.value
        } catch {
            sendError = "Encrypt failed"
            return
        }

        // Upload the ciphertext as an opaque blob.
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
            sendError = "Upload failed"
            return
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
        await performSend(content: uploadURL, rumorKind: Nip17.Kind.fileMessage,
                          fileExtraTags: fileTags, fileMetadata: fileMeta)
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

    /// Shared NIP-17 fan-out: builds + gift-wraps the rumor to each participant (+ self),
    /// publishes to each recipient's inbox, and optimistically appends the message locally.
    /// `content` is the chat text or, for kind-15, the Blossom URL.
    private func performSend(content: String, rumorKind: Int,
                             fileExtraTags: [[String]], fileMetadata: EncryptedFileMetadata?) async {
        guard let primary = participants.first else {
            sendError = "No recipient"
            return
        }
        let rumorCreatedAt = Int(Date().timeIntervalSince1970)

        // Build the rumor ONCE. Its tags must be byte-identical across every wrap (NIP-17),
        // so all recipients AND our own self-copy compute the same rumor id and the same
        // conversation key. The p-tags name the conversation participants (the actual
        // recipients), NEVER ourselves — stamping `["p", self]` on the self-copy is what
        // made replies show up as a self-conversation on other clients and hid them from
        // the recipient's thread.
        var tags: [[String]] = participants.map { ["p", $0] }
        tags.append(contentsOf: fileExtraTags)
        if let reply = replyingTo {
            tags.append(["e", reply.rumorId, "", "reply"])
        }
        let rumor = Nip17.buildRumorRaw(
            senderPubkey: keypair.pubkey,
            kind: rumorKind,
            tags: tags,
            content: content,
            createdAt: rumorCreatedAt
        )

        // Wrap the identical rumor once per participant + a self-copy. Only the OUTER
        // gift-wrap envelope's recipient differs; each wrap is encrypted to that specific
        // recipient (so group members can actually decrypt their own copy).
        var allTargets = participants
        allTargets.append(keypair.pubkey)

        var publishedRelays = Set<String>()
        var selfWrap: NostrEvent?
        let powSnap = PowPreferences.snapshot()

        for recipient in allTargets {
            let isPrimary = recipient == primary
            let isSelf = recipient == keypair.pubkey
            // Mine PoW only on the primary recipient's wrap; fan-out + self copies skip it.
            let powBits: Int? = (isPrimary && powSnap.dmEnabled) ? powSnap.dmDifficulty : nil
            let wrap: NostrEvent
            do {
                let kp = keypair
                let r = rumor
                if powBits != nil {
                    isMiningPow = true
                    miningAttempts = 0
                }
                let result: Result<NostrEvent, Swift.Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        let event = try await Nip17.wrapRumorWithSigner(
                            keypair: kp,
                            recipientPubkey: recipient,
                            rumor: r,
                            powTargetBits: powBits,
                            onPowProgress: { attempts in
                                Task { @MainActor [weak self] in
                                    self?.miningAttempts = attempts
                                }
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
                    sendError = "Encrypt failed: \(error)"
                    return
                }
            }
            if isSelf { selfWrap = wrap }
            // Resolve recipient's inbox relays (kind 10050). 8s timeout leaves room for the
            // NIP-42 AUTH round-trip many DM relays require before they accept the EVENT.
            let targets = isSelf ? await resolveOwnRelays() : await resolveRelays(for: recipient)
            let ok = await RelayPool.publish(event: wrap, to: targets, timeout: 8)
            publishedRelays.formUnion(ok)
        }

        // If no relay accepted any wrap, the message went nowhere — surface it rather than
        // optimistically showing a message that wasn't actually delivered.
        guard !publishedRelays.isEmpty else {
            sendError = "Couldn't reach any relay — message not sent"
            return
        }

        // Optimistic local insert, keyed on the SELF-copy wrap — that's the one that echoes
        // back to us via our own kind-1059 subscription. Marking it seen lets the echo dedup
        // cleanly instead of inserting a duplicate.
        let identityWrapId = selfWrap?.id ?? rumor.id
        let msg = DmMessage(
            id: "\(identityWrapId):\(rumorCreatedAt)",
            senderPubkey: keypair.pubkey,
            content: content,
            createdAt: rumorCreatedAt,
            giftWrapId: identityWrapId,
            rumorId: rumor.id,
            replyToId: replyingTo?.rumorId,
            participants: participants,
            relayUrls: publishedRelays,
            fileMetadata: fileMetadata
        )
        repo.addMessage(msg, conversationKey: conversationKey)
        if let sw = selfWrap { _ = repo.markGiftWrapSeen(sw.id) }

        replyingTo = nil
        refresh()
    }

    // MARK: - Relay resolution per recipient

    private func resolveOwnRelays() async -> [String] {
        // Publish the self-copy to the SAME set this account subscribes on for incoming DMs
        // (MessagesViewModel.resolveDmSubscriptionRelays): kind-10050 DM relays, else NIP-65
        // read relays — read from loaded settings (no fragile network round-trip) so our
        // other devices, which listen on exactly these relays, receive it. NOT every general
        // relay; see resolveDmSubscriptionRelays for why that floods the pool.
        RelaySettingsRepository.shared.ensureLoaded(pubkey: keypair.pubkey)
        let dm = RelaySettingsRepository.shared.dmRelays
        if !dm.isEmpty { return dm }
        let reads = await RelayListRepository.shared.getReadRelays(keypair.pubkey)
        return reads.isEmpty ? Self.indexerRelays : reads
    }

    private func resolveRelays(for pubkey: String) async -> [String] {
        if let cached = relayCache[pubkey] { return cached }
        let dm = await fetchDmRelays(for: pubkey)
        if !dm.isEmpty {
            relayCache[pubkey] = dm
            return dm
        }
        // Fallback: kind 10002 read tags, else write tags, else indexers.
        let nip65 = await fetchNip65(for: pubkey)
        let result = nip65.isEmpty ? Self.indexerRelays : nip65
        relayCache[pubkey] = result
        return result
    }

    private func fetchDmRelays(for pubkey: String) async -> [String] {
        let filter = NostrFilter(kinds: [10050], authors: [pubkey], limit: 1)
        let events = await RelayPool.query(relays: Self.indexerRelays, filter: filter, timeout: 4)
        let latest = events.max(by: { $0.createdAt < $1.createdAt })
        return latest?.tags.compactMap { tag in
            (tag.count >= 2 && tag[0] == "relay") ? tag[1] : nil
        } ?? []
    }

    private func fetchNip65(for pubkey: String) async -> [String] {
        let filter = NostrFilter(kinds: [10002], authors: [pubkey], limit: 1)
        let events = await RelayPool.query(relays: Self.indexerRelays, filter: filter, timeout: 4)
        let latest = events.max(by: { $0.createdAt < $1.createdAt })
        // Prefer "read" tags (recipient's inbox); fall back to writes.
        guard let event = latest else { return [] }
        let read = event.tags.compactMap { tag -> String? in
            guard tag.count >= 2, tag[0] == "r" else { return nil }
            if tag.count == 2 { return tag[1] }            // unmarked = both
            return tag[2] == "read" ? tag[1] : nil
        }
        if !read.isEmpty { return read }
        return event.tags.compactMap { tag -> String? in
            guard tag.count >= 2, tag[0] == "r" else { return nil }
            if tag.count == 2 { return tag[1] }
            return tag[2] == "write" ? tag[1] : nil
        }
    }
}
