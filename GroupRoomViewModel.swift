import Foundation
import Observation

/// One-room chat view-model. Composes messages, sends them, manages reply
/// state, and surfaces relay errors. The room's data lives in the shared
/// `GroupRepository`; this VM is just the UI binding for one `(relayUrl, groupId)`.
@Observable
@MainActor
final class GroupRoomViewModel: EmojiComposing {

    let keypair: Keypair
    let relayUrl: String
    let groupId: String

    @ObservationIgnored let repository: GroupRepository
    @ObservationIgnored private let pool = GroupRelayPool.shared

    var messageText: String = ""
    /// Custom-emoji `:shortcode` autocomplete state (EmojiComposing); `draft`
    /// bridges to the existing `messageText`.
    var draft: String {
        get { messageText }
        set { messageText = newValue }
    }
    var emojiCandidates: [CustomEmoji] = []
    var emojiStartUtf16: Int?
    var isSending: Bool = false
    var sendError: String?
    var replyTarget: GroupMessage?
    var relayError: String?

    init(keypair: Keypair, relayUrl: String, groupId: String, repository: GroupRepository) {
        self.keypair = keypair
        self.relayUrl = relayUrl
        self.groupId = groupId
        self.repository = repository
    }

    var room: GroupRoom? {
        repository.getRoom(relayUrl: relayUrl, groupId: groupId)
    }

    var messages: [GroupMessage] {
        room?.messages ?? []
    }

    func setReplyTarget(_ message: GroupMessage?) { replyTarget = message }
    func clearReplyTarget() { replyTarget = nil }
    func appendToText(_ suffix: String) { messageText += suffix }

    func sendMessage() async {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        sendError = nil
        defer { isSending = false }

        let replyInfo: (id: String, author: String)? = replyTarget.map { ($0.id, $0.senderPubkey) }

        // Auto-mention p-tags from any nostr:npub1... / nostr:nprofile1... in text.
        var extraTags: [[String]] = []
        let pattern = "nostr:(npub1[a-z0-9]+|nprofile1[a-z0-9]+)"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let r = Range(match.range, in: text) else { continue }
                let uri = String(text[r])
                guard let parsed = Nip19.decodeNostrUri(uri) else { continue }
                let pubkey: String?
                switch parsed {
                case .profileRef(let pk, _): pubkey = pk
                default: pubkey = nil
                }
                guard let pk = pubkey else { continue }
                if !extraTags.contains(where: { $0.count >= 2 && $0[0] == "p" && $0[1] == pk }) {
                    extraTags.append(["p", pk])
                }
            }
        }

        // NIP-30 emoji tags for any `:shortcode:` — prefer a URL already seen in
        // this room (collectEmojiUrls), then fall back to the user's own custom
        // emoji so a freshly-picked emoji never seen here is still tagged.
        let roomUrls = collectEmojiUrls(in: text)
        let ownMap = EmojiRepository.shared.resolvedCustomMap
        var emojiMap: [String: String] = [:]
        for tag in EmojiShortcode.emojiTags(in: text, resolve: { roomUrls[$0] ?? ownMap[$0] }) where tag.count >= 3 {
            extraTags.append(tag)
            emojiMap[tag[1]] = tag[2]
        }

        // Build tags inline + route signing through `Signer` so remote
        // (NIP-46) accounts dispatch to the active signer instead of trying
        // to use the empty-string privkey sentinel. Mirrors the tag layout
        // in `Nip29.buildChatMessage`.
        var tags: [[String]] = [["h", groupId, relayUrl]]
        if let replyInfo {
            tags.append(["q", replyInfo.id, relayUrl, replyInfo.author])
            tags.append(["p", replyInfo.author])
        }
        tags.append(contentsOf: extraTags)

        let event: NostrEvent
        do {
            event = try await Signer.sign(
                keypair: keypair,
                kind: Nip29.kindChatMessage,
                tags: tags,
                content: text
            )
        } catch {
            sendError = "Sign failed"
            return
        }

        let result = await pool.publish(event, to: relayUrl)
        switch result {
        case .ok, .duplicate, .timeout:
            // Optimistic local insert.
            let msg = GroupMessage(id: event.id, senderPubkey: keypair.pubkey,
                                   content: text, createdAt: event.createdAt,
                                   replyToId: replyInfo?.id, emojiTags: emojiMap)
            repository.addMessage(msg, relayUrl: relayUrl, groupId: groupId)
            messageText = ""
            replyTarget = nil
        case .rejected(let m):
            sendError = m
        case .authRequired:
            sendError = "Relay requires authentication"
        case .network:
            sendError = "Network error"
        }
    }

    /// Find every `:shortcode:` in `text` and return the subset whose URL we
    /// already know from messages or reactions previously seen in this room.
    private func collectEmojiUrls(in text: String) -> [String: String] {
        guard let room = room else { return [:] }
        let regex = try? NSRegularExpression(pattern: #":([a-zA-Z0-9_-]+):"#)
        guard let regex else { return [:] }
        let nsText = text as NSString
        var seen = Set<String>()
        var result: [String: String] = [:]
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { match, _, _ in
            guard let match = match, match.numberOfRanges >= 2 else { return }
            let codeRange = match.range(at: 1)
            guard codeRange.location != NSNotFound else { return }
            let code = nsText.substring(with: codeRange)
            guard seen.insert(code).inserted else { return }
            // Look in known per-room URLs (collected on incoming reactions) and any cached
            // emoji tags from earlier messages in this room.
            if let url = room.reactionEmojiUrls[code] {
                result[code] = url
            } else if let url = room.messages.lazy.compactMap({ $0.emojiTags[code] }).first {
                result[code] = url
            }
        }
        return result
    }

    func sendReaction(messageId: String, targetPubkey: String, emoji: String) async {
        // Tag layout mirrors `Nip29.buildReaction`; signing routes through
        // `Signer` for remote (NIP-46) account compatibility.
        let tags: [[String]] = [
            ["e", messageId],
            ["p", targetPubkey],
            ["h", groupId],
            ["k", String(Nip29.kindChatMessage)]
        ]
        let event: NostrEvent
        do {
            event = try await Signer.sign(keypair: keypair, kind: 7, tags: tags, content: emoji)
        } catch {
            return
        }
        // Optimistic local update.
        repository.addReaction(messageId: messageId, reactorPubkey: keypair.pubkey,
                               emoji: emoji, emojiUrl: nil,
                               relayUrl: relayUrl, groupId: groupId)
        _ = await pool.publish(event, to: relayUrl)
    }
}
