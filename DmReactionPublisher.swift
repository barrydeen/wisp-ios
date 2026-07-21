import Foundation

/// Build + send a reaction to a DM message (kind-14): a kind-7 rumor carrying
/// `["e", targetRumorId]`, `["p", targetAuthor]`, `["k", "14"]`, wrapped in NIP-17
/// gift wraps — one per conversation participant + a self-copy — so everyone on the
/// encrypted thread sees consistent reactions. Mirrors Android
/// `DmConversationViewModel.sendReaction`. Distinct from `PrivateReactionPublisher`
/// (which targets `k=1` private replies to public notes) so the proven public-reply
/// path isn't disturbed.
@MainActor
enum DmReactionPublisher {
    enum SendError: Swift.Error {
        case noOwnRelays
        case wrapFailed(Swift.Error)
        case publishFailed
    }

    /// React to `message` in the conversation identified by `conversationKey` whose
    /// other participants are `participants` (excluding the local user). Applies the
    /// reaction optimistically to `DmRepository` before publishing.
    @discardableResult
    static func react(
        message: DmMessage,
        participants: [String],
        conversationKey: String,
        keypair: Keypair,
        picked: PickedEmoji
    ) async throws -> Bool {
        let ownRelays = await resolveOwnDmRelays(keypair: keypair)
        guard !ownRelays.isEmpty else { throw SendError.noOwnRelays }

        let rumorCreatedAt = NostrClock.now()
        var tags: [[String]] = []
        tags.append(["e", message.rumorId])
        tags.append(["p", message.senderPubkey])
        tags.append(["k", "14"])
        var customEmojiUrl: String? = nil
        if case .custom(let shortcode, let url) = picked {
            tags.append(["emoji", shortcode, url])
            customEmojiUrl = url
        }
        let rumor = Nip17.buildRumorRaw(
            senderPubkey: keypair.pubkey,
            kind: Nip17.Kind.reaction,
            tags: tags,
            content: picked.content,
            createdAt: rumorCreatedAt
        )

        // Optimistic local apply — deduped by (author, emoji) in DmRepository, so the
        // self-wrap echo arriving back via the kind-1059 subscription won't double-count.
        let reaction = DmReaction(
            authorPubkey: keypair.pubkey,
            emoji: picked.content,
            timestamp: rumorCreatedAt,
            emojiUrl: customEmojiUrl
        )
        DmRepository.shared.addReaction(
            conversationKey: conversationKey,
            targetRumorId: message.rumorId,
            reaction: reaction
        )

        // One wrap per recipient + self; same rumor → same rumor id on every device.
        var recipients = participants
        recipients.append(keypair.pubkey)
        var wraps: [(wrap: NostrEvent, targets: [String])] = []
        do {
            for recipient in recipients {
                let isSelf = recipient == keypair.pubkey
                let relays = isSelf ? ownRelays : await PeerRelayResolver.resolveDmTargets(pubkey: recipient)
                guard !relays.isEmpty else { continue }
                let wrap = try await Nip17.wrapRumorWithSigner(
                    keypair: keypair,
                    recipientPubkey: recipient,
                    rumor: rumor
                )
                wraps.append((wrap, relays))
                _ = DmRepository.shared.markGiftWrapSeen(wrap.id)
            }
        } catch {
            throw SendError.wrapFailed(error)
        }
        guard !wraps.isEmpty else { throw SendError.publishFailed }

        var anyAccepted = false
        await withTaskGroup(of: Bool.self) { group in
            for entry in wraps {
                group.addTask {
                    let accepted = await RelayPool.publish(event: entry.wrap, to: entry.targets, timeout: 8)
                    return !accepted.isEmpty
                }
            }
            for await ok in group { if ok { anyAccepted = true } }
        }
        guard anyAccepted else { throw SendError.publishFailed }

        EmojiRepository.shared.recordUse(picked.frequencyKey)
        return true
    }

    /// Own DM relays for the self-copy: kind-10050 if present, else NIP-65 write relays
    /// (matches the lenient fallback the DM send path uses so reactions work for users
    /// without an explicit kind-10050 list).
    private static func resolveOwnDmRelays(keypair: Keypair) async -> [String] {
        RelaySettingsRepository.shared.ensureLoaded(pubkey: keypair.pubkey)
        let dm = RelaySettingsRepository.shared.dmRelays
        if !dm.isEmpty { return dm }
        return await RelayListRepository.shared.getWriteRelays(keypair.pubkey)
    }
}
