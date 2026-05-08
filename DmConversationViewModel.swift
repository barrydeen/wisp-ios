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

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        sendError = nil
        defer { isSending = false }

        let priv = Hex.decode(keypair.privkey) ?? Data()

        // Build extra rumor tags (group p-tags + reply e-tag) so all recipients decrypt the same rumor.
        var extraTags: [[String]] = []
        // Group: include p-tags for participants other than the primary recipient (which buildRumor adds).
        // For 1:1 we send to participants[0] so no extras. For groups, include the rest.
        if participants.count > 1 {
            for p in participants.dropFirst() {
                extraTags.append(["p", p])
            }
        }
        if let reply = replyingTo {
            extraTags.append(["e", reply.rumorId, "", "reply"])
        }

        let rumorCreatedAt = Int(Date().timeIntervalSince1970)
        guard let primary = participants.first else {
            sendError = "No recipient"
            return
        }

        // Send a wrap to each participant + a self-copy.
        var allTargets = participants
        allTargets.append(keypair.pubkey)

        var publishedRelays = Set<String>()
        var firstWrapId: String?
        var firstWrap: NostrEvent?

        let powSnap = PowPreferences.snapshot()

        for recipient in allTargets {
            let isPrimary = recipient == primary
            let isSelf = recipient == keypair.pubkey
            // For non-primary group recipients, swap the recipient p-tag to the primary's value
            // so the rumor's id matches across participants. NIP-17 keeps the rumor identical;
            // only the gift wrap envelope differs per recipient.
            // Mine PoW only for the primary recipient — group fan-out copies are sent without PoW.
            let powBits: Int? = (isPrimary && powSnap.dmEnabled) ? powSnap.dmDifficulty : nil
            let wrap: NostrEvent
            do {
                let wrapRecipient = isPrimary || isSelf ? recipient : primary
                let extras = rumorTagsForBroadcast(primary: primary, extraTags: extraTags)
                let senderPub = keypair.pubkey
                let senderPriv = priv
                if powBits != nil {
                    isMiningPow = true
                    miningAttempts = 0
                }
                // Route the seal's encrypt + sign through `Signer` so remote (NIP-46)
                // accounts dispatch to their signer. The gift wrap's ephemeral key path
                // and PoW mining still run inside the detached task to keep the main
                // actor responsive; Swift hops to MainActor for the Signer calls and
                // back automatically.
                let kp = keypair
                let result: Result<NostrEvent, Swift.Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        let event = try await Nip17.createGiftWrapWithSigner(
                            keypair: kp,
                            recipientPubkey: wrapRecipient,
                            message: text,
                            rumorKind: Nip17.Kind.chatMessage,
                            extraRumorTags: extras,
                            rumorCreatedAt: rumorCreatedAt,
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
            if firstWrapId == nil {
                firstWrapId = wrap.id
                firstWrap = wrap
            }
            // Resolve recipient's inbox relays (kind 10050).
            let targets = isSelf ? await resolveOwnRelays() : await resolveRelays(for: recipient)
            let ok = await RelayPool.publish(event: wrap, to: targets)
            publishedRelays.formUnion(ok)
        }

        // Append optimistically to the local repo so the UI updates immediately.
        if let wrap = firstWrap {
            let rumor = Nip17.buildRumor(
                senderPubkey: keypair.pubkey,
                recipientPubkey: primary,
                content: text,
                kind: Nip17.Kind.chatMessage,
                extraTags: rumorTagsForBroadcast(primary: primary, extraTags: extraTags),
                createdAt: rumorCreatedAt
            )
            let msg = DmMessage(
                id: "\(wrap.id):\(rumorCreatedAt)",
                senderPubkey: keypair.pubkey,
                content: text,
                createdAt: rumorCreatedAt,
                giftWrapId: wrap.id,
                rumorId: rumor.id,
                replyToId: replyingTo?.rumorId,
                participants: participants,
                relayUrls: publishedRelays
            )
            repo.addMessage(msg, conversationKey: conversationKey)
            // Mark the self-copy gift wrap seen so the relay echo doesn't re-insert.
            _ = repo.markGiftWrapSeen(wrap.id)
        }

        draft = ""
        replyingTo = nil
        refresh()
    }

    /// Build the full rumor tag set: ["p", primary] is added by buildRumor; we add the remaining
    /// p-tags + reply tags. We pass only the *extras*; buildRumor handles the primary p-tag itself.
    private func rumorTagsForBroadcast(primary: String, extraTags: [[String]]) -> [[String]] {
        extraTags
    }

    // MARK: - Relay resolution per recipient

    private func resolveOwnRelays() async -> [String] {
        let own = await fetchDmRelays(for: keypair.pubkey)
        if !own.isEmpty { return own }
        // Fallback: user's kind 10002 write relays via outbox cache, otherwise default broadcast.
        return Self.indexerRelays
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
