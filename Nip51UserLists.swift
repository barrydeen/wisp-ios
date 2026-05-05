import Foundation

/// NIP-51 user lists:
///   - kind 30000 "follow set"      — list of pubkeys (`p` tags)
///   - kind 30003 "bookmark set"    — list of event ids (`e` tags)
///
/// Both kinds are parameterized-replaceable, keyed by `d` tag. List entries can
/// be public (plain tags) or private (NIP-44 encrypted JSON in `event.content`).
/// The encryption peer is the user's own pubkey (self-conversation key) — the
/// canonical NIP-51 pattern for personal private lists.
nonisolated enum Nip51UserLists {
    static let kindPeopleList = 30000
    static let kindNoteList = 30003

    // MARK: - People list (kind 30000)

    static func parsePeopleList(_ event: NostrEvent, keypair: Keypair) -> PeopleList? {
        guard event.kind == kindPeopleList,
              event.pubkey == keypair.pubkey else { return nil }

        var dTag: String?
        var title: String?
        var publicMembers: [String] = []
        var seen = Set<String>()

        for tag in event.tags {
            guard tag.count >= 2 else { continue }
            switch tag[0] {
            case "d": dTag = tag[1]
            case "title", "name": if title == nil { title = tag[1] }
            case "p":
                let key = tag[1].lowercased()
                if isHexPubkey(key), seen.insert(key).inserted { publicMembers.append(key) }
            default: break
            }
        }
        guard let dTag, !dTag.isEmpty else { return nil }

        let privateMembers = decodePrivateTags(
            event: event,
            keypair: keypair,
            tagName: "p",
            validate: { isHexPubkey($0) }
        )
        // De-dupe across public/private (public wins).
        let publicSet = Set(publicMembers)
        let privateOnly = privateMembers.filter { !publicSet.contains($0) }

        return PeopleList(
            pubkey: event.pubkey,
            dTag: dTag,
            name: title ?? dTag,
            publicMembers: publicMembers,
            privateMembers: privateOnly,
            createdAt: event.createdAt
        )
    }

    static func buildPeopleListTags(dTag: String, name: String, publicMembers: [String]) -> [[String]] {
        var tags: [[String]] = [["d", dTag], ["title", name]]
        var seen = Set<String>()
        for member in publicMembers {
            let key = member.lowercased()
            guard isHexPubkey(key), seen.insert(key).inserted else { continue }
            tags.append(["p", key])
        }
        return tags
    }

    @MainActor
    static func buildPeopleListPrivateContent(privateMembers: [String], keypair: Keypair) async throws -> String {
        let entries: [[String]] = privateMembers
            .map { $0.lowercased() }
            .filter { isHexPubkey($0) }
            .map { ["p", $0] }
        return try await encodePrivateTags(entries: entries, keypair: keypair)
    }

    // MARK: - Note list (kind 30003)

    static func parseNoteList(_ event: NostrEvent, keypair: Keypair) -> NoteList? {
        guard event.kind == kindNoteList,
              event.pubkey == keypair.pubkey else { return nil }

        var dTag: String?
        var title: String?
        var publicNotes: [String] = []
        var seen = Set<String>()

        for tag in event.tags {
            guard tag.count >= 2 else { continue }
            switch tag[0] {
            case "d": dTag = tag[1]
            case "title", "name": if title == nil { title = tag[1] }
            case "e":
                let id = tag[1].lowercased()
                if isHexId(id), seen.insert(id).inserted { publicNotes.append(id) }
            default: break
            }
        }
        guard let dTag, !dTag.isEmpty else { return nil }

        let privateNotes = decodePrivateTags(
            event: event,
            keypair: keypair,
            tagName: "e",
            validate: { isHexId($0) }
        )
        let publicSet = Set(publicNotes)
        let privateOnly = privateNotes.filter { !publicSet.contains($0) }

        return NoteList(
            pubkey: event.pubkey,
            dTag: dTag,
            name: title ?? dTag,
            publicNotes: publicNotes,
            privateNotes: privateOnly,
            createdAt: event.createdAt
        )
    }

    static func buildNoteListTags(dTag: String, name: String, publicNotes: [String]) -> [[String]] {
        var tags: [[String]] = [["d", dTag], ["title", name]]
        var seen = Set<String>()
        for id in publicNotes {
            let normalized = id.lowercased()
            guard isHexId(normalized), seen.insert(normalized).inserted else { continue }
            tags.append(["e", normalized])
        }
        return tags
    }

    @MainActor
    static func buildNoteListPrivateContent(privateNotes: [String], keypair: Keypair) async throws -> String {
        let entries: [[String]] = privateNotes
            .map { $0.lowercased() }
            .filter { isHexId($0) }
            .map { ["e", $0] }
        return try await encodePrivateTags(entries: entries, keypair: keypair)
    }

    // MARK: - Private-tag encoding

    /// Encrypt a JSON array of tags (`[["p","<hex>"], …]`) with the user's
    /// self-conversation key. Returns "" when the input is empty so a deletion
    /// of all private members produces a clean event with empty content.
    /// Async because remote-signer accounts dispatch the NIP-44 encrypt over
    /// a relay round-trip via `Signer.nip44Encrypt`.
    @MainActor
    private static func encodePrivateTags(entries: [[String]], keypair: Keypair) async throws -> String {
        guard !entries.isEmpty else { return "" }
        let json = encodeTagsJSON(entries)
        return try await Signer.nip44Encrypt(
            keypair: keypair,
            peerPubkey: keypair.pubkey,
            plaintext: json
        )
    }

    /// Decrypt `event.content` (NIP-44) and pull out values for `tagName`,
    /// keeping only entries that pass `validate`. Returns [] on any failure
    /// (empty content, decrypt error, malformed JSON) — silent so a partial
    /// failure doesn't drop the public part of the list.
    private static func decodePrivateTags(
        event: NostrEvent,
        keypair: Keypair,
        tagName: String,
        validate: (String) -> Bool
    ) -> [String] {
        let payload = event.content
        guard !payload.isEmpty else { return [] }
        guard let privkey = Hex.decode(keypair.privkey),
              let pubkeyBytes = Hex.decode(keypair.pubkey) else { return [] }
        guard let convKey = try? Nip44.getConversationKey(privkey32: privkey, peerXonlyPubkey32: pubkeyBytes),
              let plaintext = try? Nip44.decrypt(payload: payload, conversationKey: convKey),
              let data = plaintext.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else {
            return []
        }
        var seen = Set<String>()
        var out: [String] = []
        for tag in arr {
            guard tag.count >= 2 else { continue }
            guard let name = tag[0] as? String, name == tagName else { continue }
            guard let value = tag[1] as? String else { continue }
            let normalized = value.lowercased()
            if validate(normalized), seen.insert(normalized).inserted {
                out.append(normalized)
            }
        }
        return out
    }

    /// Compact JSON for `[["p","<hex>"], …]`. Hand-rolled to avoid pulling in
    /// dictionary key-ordering surprises and to stay compatible with Android,
    /// which encodes the same shape.
    private static func encodeTagsJSON(_ entries: [[String]]) -> String {
        var out = "["
        for (i, tag) in entries.enumerated() {
            if i > 0 { out.append(",") }
            out.append("[")
            for (j, value) in tag.enumerated() {
                if j > 0 { out.append(",") }
                out.append("\"")
                out.append(escapeJSON(value))
                out.append("\"")
            }
            out.append("]")
        }
        out.append("]")
        return out
    }

    private static func escapeJSON(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                if scalar.value < 0x20 {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    // MARK: - Validation

    private static let hexLowercase: Set<Character> = Set("0123456789abcdef")

    static func isHexPubkey(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { hexLowercase.contains($0) }
    }

    static func isHexId(_ s: String) -> Bool {
        isHexPubkey(s) // same shape: 32-byte hex
    }
}
