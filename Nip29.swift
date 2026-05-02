import Foundation

/// NIP-29 relay-based groups (chat rooms).
/// Spec: https://github.com/nostr-protocol/nips/blob/master/29.md
/// Direct port of `Nip29.kt` from the Wisp Android client.
nonisolated enum Nip29 {

    // MARK: - Event kinds

    static let kindChatMessage   = 9
    static let kindThread        = 11
    static let kindReply         = 12
    static let kindPutUser       = 9000
    static let kindRemoveUser    = 9001
    static let kindEditMetadata  = 9002
    static let kindDeleteEvent   = 9005
    static let kindCreateGroup   = 9007
    static let kindDeleteGroup   = 9008
    static let kindCreateInvite  = 9009
    static let kindJoinRequest   = 9021
    static let kindLeaveRequest  = 9022
    static let kindGroupMetadata = 39000
    static let kindGroupAdmins   = 39001
    static let kindGroupMembers  = 39002
    static let kindGroupRoles    = 39003

    // MARK: - Defaults

    static let defaultGroupRelay = "wss://chat.wisp.talk"

    // MARK: - Identifiers

    /// 12-char `[a-z0-9]` group id, generated client-side at create time.
    static func generateGroupId() -> String {
        randomString(length: 12)
    }

    /// 16-char `[a-z0-9]` invite code.
    static func generateInviteCode() -> String {
        randomString(length: 16)
    }

    private static func randomString(length: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { chars[Int($0) % chars.count] })
    }

    // MARK: - Invite link

    /// Parses both `wss://host'groupid` and `wss://host'groupid?code=xxx`
    /// (and bare `host'groupid` without the scheme — `wss://` is prepended).
    /// Returns `nil` on malformed input. Relay URL is normalized to lowercase
    /// without a trailing slash.
    static func parseInviteLink(_ raw: String) -> (relayUrl: String, groupId: String, code: String?)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme: String
        if trimmed.lowercased().hasPrefix("wss://") || trimmed.lowercased().hasPrefix("ws://") {
            withScheme = trimmed
        } else {
            withScheme = "wss://" + trimmed
        }

        // Split off the optional ?code=xxx query.
        var body = withScheme
        var code: String?
        if let qIdx = body.firstIndex(of: "?") {
            let query = String(body[body.index(after: qIdx)...])
            body = String(body[..<qIdx])
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2, kv[0] == "code" {
                    let val = kv[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !val.isEmpty { code = val }
                }
            }
        }

        // Body is now `wss://host[/...]'groupid`. The apostrophe is the last `'`.
        guard let apos = body.lastIndex(of: "'") else { return nil }
        let relayPart = String(body[..<apos])
        let groupId = String(body[body.index(after: apos)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !groupId.isEmpty else { return nil }

        var relayUrl = relayPart
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while relayUrl.hasSuffix("/") { relayUrl.removeLast() }
        guard relayUrl.lowercased().hasPrefix("wss://") || relayUrl.lowercased().hasPrefix("ws://") else { return nil }

        return (relayUrl, groupId, code)
    }

    static func buildInviteLink(relayUrl: String, groupId: String, code: String? = nil) -> String {
        var url = relayUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        if let code, !code.isEmpty {
            return "\(url)'\(groupId)?code=\(code)"
        }
        return "\(url)'\(groupId)"
    }

    // MARK: - Builders (sign + return a NostrEvent)

    static func buildChatMessage(privkey32: Data, pubkey: String, groupId: String, relayUrl: String,
                                 content: String, replyTo: (id: String, author: String)? = nil,
                                 extraTags: [[String]] = [],
                                 createdAt: Int = Int(Date().timeIntervalSince1970)) throws -> NostrEvent {
        var tags: [[String]] = [["h", groupId, relayUrl]]
        if let replyTo {
            tags.append(["q", replyTo.id, relayUrl, replyTo.author])
            tags.append(["p", replyTo.author])
        }
        tags.append(contentsOf: extraTags)
        return try NostrEvent.sign(privkey32: privkey32, pubkey: pubkey, kind: kindChatMessage,
                                   createdAt: createdAt, tags: tags, content: content)
    }

    static func buildJoinRequest(privkey32: Data, pubkey: String, groupId: String,
                                 inviteCode: String? = nil, reason: String = "",
                                 createdAt: Int = Int(Date().timeIntervalSince1970)) throws -> NostrEvent {
        var tags: [[String]] = [["h", groupId]]
        if let code = inviteCode, !code.isEmpty { tags.append(["code", code]) }
        return try NostrEvent.sign(privkey32: privkey32, pubkey: pubkey, kind: kindJoinRequest,
                                   createdAt: createdAt, tags: tags, content: reason)
    }

    static func buildLeaveRequest(privkey32: Data, pubkey: String, groupId: String,
                                  reason: String = "",
                                  createdAt: Int = Int(Date().timeIntervalSince1970)) throws -> NostrEvent {
        let tags: [[String]] = [["h", groupId]]
        return try NostrEvent.sign(privkey32: privkey32, pubkey: pubkey, kind: kindLeaveRequest,
                                   createdAt: createdAt, tags: tags, content: reason)
    }

    static func buildCreateGroup(privkey32: Data, pubkey: String, groupId: String,
                                 createdAt: Int = Int(Date().timeIntervalSince1970)) throws -> NostrEvent {
        let tags: [[String]] = [["h", groupId]]
        return try NostrEvent.sign(privkey32: privkey32, pubkey: pubkey, kind: kindCreateGroup,
                                   createdAt: createdAt, tags: tags, content: "")
    }

    static func buildDeleteGroup(privkey32: Data, pubkey: String, groupId: String,
                                 createdAt: Int = Int(Date().timeIntervalSince1970)) throws -> NostrEvent {
        let tags: [[String]] = [["h", groupId]]
        return try NostrEvent.sign(privkey32: privkey32, pubkey: pubkey, kind: kindDeleteGroup,
                                   createdAt: createdAt, tags: tags, content: "")
    }

    static func buildCreateInvite(privkey32: Data, pubkey: String, groupId: String, code: String,
                                  createdAt: Int = Int(Date().timeIntervalSince1970)) throws -> NostrEvent {
        let tags: [[String]] = [["h", groupId], ["code", code]]
        return try NostrEvent.sign(privkey32: privkey32, pubkey: pubkey, kind: kindCreateInvite,
                                   createdAt: createdAt, tags: tags, content: "")
    }

    /// Edit metadata. Pass `nil` for any flag you don't want to change; the relay
    /// uses the inverse keyword (`public`/`open`/`unrestricted`/`visible`) to deterministically
    /// turn a flag off, mirroring the Android client's behavior.
    static func buildEditMetadata(privkey32: Data, pubkey: String, groupId: String,
                                  name: String? = nil, about: String? = nil, picture: String? = nil,
                                  isPrivate: Bool? = nil, isClosed: Bool? = nil,
                                  isRestricted: Bool? = nil, isHidden: Bool? = nil,
                                  createdAt: Int = Int(Date().timeIntervalSince1970)) throws -> NostrEvent {
        var tags: [[String]] = [["h", groupId]]
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            tags.append(["name", name])
        }
        if let about = about?.trimmingCharacters(in: .whitespacesAndNewlines), !about.isEmpty {
            tags.append(["about", about])
        }
        if let picture = picture?.trimmingCharacters(in: .whitespacesAndNewlines), !picture.isEmpty {
            tags.append(["picture", picture])
        }
        if let isPrivate    { tags.append([isPrivate    ? "private"    : "public"]) }
        if let isClosed     { tags.append([isClosed     ? "closed"     : "open"]) }
        if let isRestricted { tags.append([isRestricted ? "restricted" : "unrestricted"]) }
        if let isHidden     { tags.append([isHidden     ? "hidden"     : "visible"]) }
        return try NostrEvent.sign(privkey32: privkey32, pubkey: pubkey, kind: kindEditMetadata,
                                   createdAt: createdAt, tags: tags, content: "")
    }

    static func buildPutUser(privkey32: Data, pubkey: String, groupId: String, targetPubkey: String,
                             roles: [String] = [],
                             createdAt: Int = Int(Date().timeIntervalSince1970)) throws -> NostrEvent {
        let pTag = (["p", targetPubkey] + roles)
        let tags: [[String]] = [["h", groupId], pTag]
        return try NostrEvent.sign(privkey32: privkey32, pubkey: pubkey, kind: kindPutUser,
                                   createdAt: createdAt, tags: tags, content: "")
    }

    static func buildRemoveUser(privkey32: Data, pubkey: String, groupId: String, targetPubkey: String,
                                createdAt: Int = Int(Date().timeIntervalSince1970)) throws -> NostrEvent {
        let tags: [[String]] = [["h", groupId], ["p", targetPubkey]]
        return try NostrEvent.sign(privkey32: privkey32, pubkey: pubkey, kind: kindRemoveUser,
                                   createdAt: createdAt, tags: tags, content: "")
    }

    static func buildReaction(privkey32: Data, pubkey: String, groupId: String,
                              messageId: String, messageAuthorPubkey: String, emoji: String,
                              customEmoji: (shortcode: String, url: String)? = nil,
                              createdAt: Int = Int(Date().timeIntervalSince1970)) throws -> NostrEvent {
        var tags: [[String]] = [
            ["e", messageId],
            ["p", messageAuthorPubkey],
            ["h", groupId],
            ["k", String(kindChatMessage)]
        ]
        if let custom = customEmoji {
            tags.append(["emoji", custom.shortcode, custom.url])
        }
        return try NostrEvent.sign(privkey32: privkey32, pubkey: pubkey, kind: 7,
                                   createdAt: createdAt, tags: tags, content: emoji)
    }

    // MARK: - Parsers

    static func parseGroupMetadata(_ event: NostrEvent) -> GroupMetadata? {
        guard event.kind == kindGroupMetadata else { return nil }
        guard let groupId = event.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1] else { return nil }
        let name    = event.tags.first(where: { $0.count >= 2 && $0[0] == "name" })?[1]
        let picture = event.tags.first(where: { $0.count >= 2 && $0[0] == "picture" })?[1]
        let about   = event.tags.first(where: { $0.count >= 2 && $0[0] == "about" })?[1]
        let isPrivate    = event.tags.contains { !$0.isEmpty && $0[0] == "private" }
        let isClosed     = event.tags.contains { !$0.isEmpty && $0[0] == "closed" }
        let isRestricted = event.tags.contains { !$0.isEmpty && $0[0] == "restricted" }
        let isHidden     = event.tags.contains { !$0.isEmpty && $0[0] == "hidden" }
        return GroupMetadata(groupId: groupId, name: name, picture: picture, about: about,
                             isPrivate: isPrivate, isClosed: isClosed,
                             isRestricted: isRestricted, isHidden: isHidden)
    }

    static func parseGroupAdmins(_ event: NostrEvent) -> [AdminEntry] {
        guard event.kind == kindGroupAdmins else { return [] }
        return event.tags.compactMap { tag in
            guard tag.count >= 2, tag[0] == "p" else { return nil }
            return AdminEntry(pubkey: tag[1], roles: Array(tag.dropFirst(2)))
        }
    }

    static func parseGroupAdminPubkeys(_ event: NostrEvent) -> [String] {
        parseGroupAdmins(event).map { $0.pubkey }
    }

    static func parseGroupMembers(_ event: NostrEvent) -> [String] {
        guard event.kind == kindGroupMembers else { return [] }
        return event.tags.compactMap { tag in
            (tag.count >= 2 && tag[0] == "p") ? tag[1] : nil
        }
    }

    static func parseGroupRoles(_ event: NostrEvent) -> [GroupRole] {
        guard event.kind == kindGroupRoles else { return [] }
        return event.tags.compactMap { tag in
            guard tag.count >= 2, tag[0] == "role" else { return nil }
            return GroupRole(name: tag[1], description: tag.count >= 3 ? tag[2] : nil)
        }
    }

    /// `q` tag wins, then `e` with `reply` marker, then last `e` tag.
    static func extractReplyId(from event: NostrEvent) -> String? {
        if let q = event.tags.first(where: { $0.count >= 2 && $0[0] == "q" })?[1] { return q }
        if let e = event.tags.first(where: { $0.count >= 4 && $0[0] == "e" && $0[3] == "reply" })?[1] { return e }
        return event.tags.last(where: { $0.count >= 2 && $0[0] == "e" })?[1]
    }

    /// Extract the group id an event belongs to. `h` for user events (kind 9 etc.),
    /// `d` for relay-signed metadata events (39000-39003).
    static func extractGroupId(from event: NostrEvent) -> String? {
        if let h = event.tags.first(where: { $0.count >= 2 && $0[0] == "h" })?[1] { return h }
        return event.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1]
    }
}
