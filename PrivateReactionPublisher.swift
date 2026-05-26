import Foundation

/// Build + send a private reaction to a gift-wrapped (private) reply.
/// Mirrors `PrivateReplyPublisher` but for kind-7 rumors: the reaction
/// fans out to every conversation participant (target author + every
/// p-tag on the target) plus a self-copy, so all participants on the
/// encrypted chain see consistent reaction counts.
///
/// The rumor carries a `["k", "1"]` tag to distinguish reactions to a
/// kind-1 private reply from DM reactions (which use `["k", "14"]`).
/// `PrivateInteractionRouter` switches on this tag when routing inbound
/// kind-7 rumors.
@MainActor
enum PrivateReactionPublisher {
    enum SendError: Swift.Error {
        case noRecipientRelays
        case noOwnRelays
        case wrapFailed(Swift.Error)
        case publishFailed
        case alreadyReacted
    }

    /// Send a reaction. Inserts an optimistic count entry locally so the
    /// heart fills in on tap, and the existing triple-key dedup in
    /// `EngagementRepository` prevents the self-copy echo from double-counting
    /// when the wrap arrives back via the kind-1059 subscription.
    @discardableResult
    static func react(
        target: NostrEvent,
        keypair: Keypair,
        picked: PickedEmoji
    ) async throws -> NostrEvent {
        let ownRelays = RelaySettingsRepository.shared.dmRelays
        guard !ownRelays.isEmpty else { throw SendError.noOwnRelays }

        // 1. Participant set: target author + every p-tag, minus self.
        var participants: [String] = []
        var seen = Set<String>()
        seen.insert(keypair.pubkey)
        if target.pubkey != keypair.pubkey, seen.insert(target.pubkey).inserted {
            participants.append(target.pubkey)
        }
        for tag in target.tags where tag.count >= 2 && tag[0] == "p" {
            if seen.insert(tag[1]).inserted {
                participants.append(tag[1])
            }
        }

        // 2. Build rumor with stable tag order. `k=1` distinguishes from DM
        //    reactions (`k=14`). Custom emoji adds NIP-30 tag.
        let rumorCreatedAt = Int(Date().timeIntervalSince1970)
        var tags: [[String]] = []
        tags.append(["e", target.id, "", target.pubkey])
        tags.append(["p", target.pubkey])
        tags.append(["k", "1"])
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

        // 3. Optimistic local apply BEFORE publish. The triple-key dedup
        //    (eventId|reactor|emoji) inside EngagementRepository handles the
        //    self-wrap echo and the participant-fan-out echoes — all wraps
        //    decrypt to the same rumor with the same reactor/emoji.
        EngagementRepository.shared.applyOptimisticReaction(
            eventId: target.id,
            pubkey: keypair.pubkey,
            emoji: picked.content,
            customEmojiUrl: customEmojiUrl
        )
        PrivateInteractionStore.shared.markPrivate(rumor.id)

        // 4. Wrap once per recipient + self. Each wrap targets one pubkey
        //    on the outer envelope but carries the same rumor.
        var allWraps: [(wrap: NostrEvent, targets: [String])] = []
        do {
            for recipient in participants {
                let relays = await PeerRelayResolver.resolveDmTargets(pubkey: recipient)
                guard !relays.isEmpty else { continue }
                let wrap = try await Nip17.wrapRumorWithSigner(
                    keypair: keypair,
                    recipientPubkey: recipient,
                    rumor: rumor
                )
                allWraps.append((wrap, relays))
                _ = DmRepository.shared.markGiftWrapSeen(wrap.id)
            }
            let selfWrap = try await Nip17.wrapRumorWithSigner(
                keypair: keypair,
                recipientPubkey: keypair.pubkey,
                rumor: rumor
            )
            allWraps.append((selfWrap, ownRelays))
            _ = DmRepository.shared.markGiftWrapSeen(selfWrap.id)
        } catch {
            // Reverting the optimistic apply isn't quite right here — the
            // triple-key dedup means a future relay-delivered inbound copy
            // (e.g., from a different client we sent earlier) would be
            // dropped because we already counted. Trade-off: occasional
            // ghost reaction on send failure beats double-counts on success.
            throw SendError.wrapFailed(error)
        }

        // 5. Publish in parallel.
        var anyAccepted = false
        await withTaskGroup(of: Bool.self) { group in
            for entry in allWraps {
                group.addTask {
                    let accepted = await RelayPool.publish(event: entry.wrap, to: entry.targets, timeout: 8)
                    return !accepted.isEmpty
                }
            }
            for await ok in group { if ok { anyAccepted = true } }
        }
        guard anyAccepted else { throw SendError.publishFailed }

        // 6. Materialize the synthetic kind-7 NostrEvent the router would
        //    produce on echo. EventPersistQueue writes it to disk so cold
        //    starts see the reaction without waiting for the kind-1059
        //    subscription.
        let synthetic = NostrEvent(
            id: rumor.id,
            pubkey: rumor.pubkey,
            kind: Nip17.Kind.reaction,
            createdAt: rumor.createdAt,
            tags: rumor.tags,
            content: rumor.content,
            sig: ""
        )
        await EventPersistQueue.shared.enqueue(synthetic)
        EmojiRepository.shared.recordUse(picked.frequencyKey)
        return synthetic
    }
}
