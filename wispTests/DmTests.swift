import Foundation
import Testing
import CryptoKit
import ObjectBox
@testable import wisp

struct DmTests {

    // MARK: - AES-256-GCM encrypted media (NIP-17 kind-15)

    @Test func aesGcmRoundTrip() throws {
        let plain = Data("hello DM media 🔒 with some bytes".utf8)
        let enc = try EncryptedMedia.encryptFile(plain)
        let dec = try EncryptedMedia.decryptFile(enc.encryptedBytes, keyHex: enc.keyHex, nonceHex: enc.nonceHex)
        #expect(dec == plain)
    }

    /// Guards the interop-critical wire layout: the blob is `ciphertext || tag` with NO
    /// nonce prefix. If we ever switched to `SealedBox.combined`, the blob would be 12
    /// bytes longer (nonce prepended) and Android/Amethyst couldn't decrypt it.
    @Test func aesGcmBlobLayoutIsCiphertextPlusTag() throws {
        let plain = Data(repeating: 0xAB, count: 100)
        let enc = try EncryptedMedia.encryptFile(plain)
        #expect(enc.encryptedBytes.count == plain.count + 16)   // ciphertext(==plain) + 16-byte tag
        #expect(Hex.decode(enc.keyHex)?.count == 32)            // 256-bit key
        #expect(Hex.decode(enc.nonceHex)?.count == 12)          // 96-bit nonce
    }

    /// Receive-side interop: a blob produced in the Android/Amethyst format (ciphertext||tag,
    /// nonce carried separately) must decrypt via `EncryptedMedia.decryptFile`.
    @Test func decryptsAndroidStyleBlob() throws {
        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        let plain = Data("cross-client interop payload".utf8)
        let sealed = try AES.GCM.seal(plain, using: key, nonce: nonce)
        let wire = sealed.ciphertext + sealed.tag                // Android emits this; nonce is separate
        let keyHex = Hex.encode(key.withUnsafeBytes { Data($0) })
        let nonceHex = Hex.encode(Data(nonce))
        let dec = try EncryptedMedia.decryptFile(wire, keyHex: keyHex, nonceHex: nonceHex)
        #expect(dec == plain)
    }

    @Test func decryptWithWrongKeyThrows() throws {
        let plain = Data("secret".utf8)
        let enc = try EncryptedMedia.encryptFile(plain)
        let wrongKey = Hex.encode(Data(repeating: 0x00, count: 32))
        #expect(throws: (any Error).self) {
            _ = try EncryptedMedia.decryptFile(enc.encryptedBytes, keyHex: wrongKey, nonceHex: enc.nonceHex)
        }
    }

    // MARK: - Kind-15 tag round-trip

    @Test func kind15TagRoundTrip() {
        let tags = EncryptedMedia.buildKind15Tags(
            mimeType: "image/jpeg", keyHex: "aa", nonceHex: "bb",
            encryptedHash: "cc", originalHash: "dd", size: 1234, dimensions: "800x600"
        )
        let meta = EncryptedMedia.parseKind15Tags(tags, fileUrl: "https://blossom.example/x")
        #expect(meta?.mimeType == "image/jpeg")
        #expect(meta?.algorithm == "aes-gcm")
        #expect(meta?.keyHex == "aa")
        #expect(meta?.nonceHex == "bb")
        #expect(meta?.encryptedHash == "cc")
        #expect(meta?.originalHash == "dd")
        #expect(meta?.size == 1234)
        #expect(meta?.dimensions == "800x600")
        #expect(meta?.fileUrl == "https://blossom.example/x")
    }

    @Test func parseKind15ReturnsNilWithoutRequiredTags() {
        // Missing decryption-key/nonce → not a valid encrypted file message.
        let tags = [["file-type", "image/png"], ["encryption-algorithm", "aes-gcm"]]
        #expect(EncryptedMedia.parseKind15Tags(tags, fileUrl: "https://x") == nil)
    }

    // MARK: - DmMessage persistence payload (Codable)

    @Test func dmMessageCodableRoundTrip() throws {
        let meta = EncryptedFileMetadata(
            fileUrl: "https://b/x", mimeType: "image/png", algorithm: "aes-gcm",
            keyHex: "00", nonceHex: "11", encryptedHash: "22", originalHash: "33",
            size: 999, dimensions: "10x10", blurhash: nil
        )
        let msg = DmMessage(
            id: "gw:123", senderPubkey: "abc", content: "hi", createdAt: 123,
            giftWrapId: "gw", rumorId: "r1", replyToId: "r0", participants: ["p1", "p2"],
            relayUrls: ["wss://a", "wss://b"],
            reactions: [DmReaction(authorPubkey: "x", emoji: "🔥", timestamp: 1, emojiUrl: nil)],
            emojiMap: ["foo": "https://e"], fileMetadata: meta
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(DmMessage.self, from: data)
        #expect(decoded == msg)
    }

    // MARK: - ObjectBox model + DmMessageEntity round-trip

    /// Critical: validates the hand-authored `cModel()` opens (a malformed model would
    /// crash the whole app at launch) AND that a `DmMessageEntity` survives a put/find
    /// with the JSON payload intact. Uses a fresh in-memory store so it touches neither
    /// disk nor the app's shared store.
    @Test func objectBoxModelOpensAndDmEntityRoundTrips() throws {
        let store = try Store(directoryPath: "memory:dmtest-\(UUID().uuidString)")
        defer { store.close() }
        let box = store.box(for: DmMessageEntity.self)

        let msg = DmMessage(
            id: "gw:5", senderPubkey: "s", content: "persisted hi", createdAt: 5,
            giftWrapId: "gw", rumorId: "r", replyToId: nil, participants: ["p"],
            relayUrls: ["wss://a"],
            reactions: [DmReaction(authorPubkey: "x", emoji: "👍", timestamp: 2, emojiUrl: nil)]
        )
        let entity = DmMessageEntity(ownerPubkey: "me", conversationKey: "me,p", msg: msg)
        try box.put(entity)

        let all = try box.all()
        #expect(all.count == 1)
        #expect(all.first?.ownerPlusGiftWrap == "me|gw")
        let back = all.first?.toEntry()
        #expect(back?.convKey == "me,p")
        #expect(back?.msg.content == "persisted hi")
        #expect(back?.msg.rumorId == "r")
        #expect(back?.msg.reactions.first?.emoji == "👍")
    }

    // MARK: - SendState (optimistic send) Codable migration

    /// Backward-compat guard: a payload written before `sendState` existed must decode as
    /// `.sent`, so every persisted row + received message renders delivered, never stuck
    /// "sending". Other defaulted fields (relayUrls/reactions) must also fill in.
    @Test func dmMessageDecodesMissingSendStateAsSent() throws {
        let json = """
        {"id":"gw:1","senderPubkey":"a","content":"hi","createdAt":1,"giftWrapId":"gw","rumorId":"r","participants":["p"]}
        """
        let decoded = try JSONDecoder().decode(DmMessage.self, from: Data(json.utf8))
        #expect(decoded.sendState == .sent)
        #expect(decoded.relayUrls.isEmpty)
        #expect(decoded.reactions.isEmpty)
        #expect(decoded.fileMetadata == nil)
    }

    /// `.sending` / `.failed` / `.sent` survive a Codable round-trip.
    @Test func dmMessageSendStateRoundTrips() throws {
        for state in [DmMessage.SendState.sending, .failed, .sent] {
            var msg = DmMessage(id: "x", senderPubkey: "a", content: "c", createdAt: 1,
                                giftWrapId: "", rumorId: "r", replyToId: nil, participants: ["p"])
            msg.sendState = state
            let data = try JSONEncoder().encode(msg)
            let decoded = try JSONDecoder().decode(DmMessage.self, from: data)
            #expect(decoded.sendState == state)
        }
    }

    // MARK: - Optimistic send: reconcile + echo dedup

    /// Reconciling an optimistic `.sending` row rewrites its temporary id to the real
    /// composite id, attaches relay URLs + `.sent`, and — crucially — the self-copy echo
    /// that later arrives over the subscription dedups by composite id instead of inserting
    /// a duplicate. Uses an UNBOUND repository (empty owner ⇒ `persist()` no-ops, no disk).
    @MainActor
    @Test func optimisticReconcileRewritesIdAndDedupsEcho() {
        let repo = DmRepository()
        let convKey = "me,peer"
        let tempId = "pending:abc"

        var optimistic = DmMessage(id: tempId, senderPubkey: "me", content: "hi", createdAt: 100,
                                   giftWrapId: "", rumorId: "rum1", replyToId: nil, participants: ["peer"])
        optimistic.sendState = .sending
        repo.insertOptimistic(optimistic, conversationKey: convKey)
        #expect(repo.conversation(convKey)?.messages.count == 1)
        #expect(repo.conversation(convKey)?.messages.first?.sendState == .sending)

        // Pre-seed dedup the way `deliver` does before publishing the self-copy.
        _ = repo.markGiftWrapSeen("selfwrap1")

        let final = DmMessage(id: "selfwrap1:100", senderPubkey: "me", content: "hi", createdAt: 100,
                              giftWrapId: "selfwrap1", rumorId: "rum1", replyToId: nil,
                              participants: ["peer"], relayUrls: ["wss://r"], sendState: .sent)
        #expect(repo.reconcileOptimistic(tempId: tempId, conversationKey: convKey, final: final))

        let afterReconcile = repo.conversation(convKey)?.messages ?? []
        #expect(afterReconcile.count == 1)
        #expect(afterReconcile.first?.id == "selfwrap1:100")
        #expect(afterReconcile.first?.sendState == .sent)
        #expect(afterReconcile.first?.relayUrls == ["wss://r"])

        // The self-copy echo (same composite id, different relay) must merge, not duplicate.
        let echo = DmMessage(id: "selfwrap1:100", senderPubkey: "me", content: "hi", createdAt: 100,
                             giftWrapId: "selfwrap1", rumorId: "rum1", replyToId: nil,
                             participants: ["peer"], relayUrls: ["wss://r2"])
        #expect(repo.addMessage(echo, conversationKey: convKey) == false)
        #expect(repo.conversation(convKey)?.messages.count == 1)
        #expect(repo.conversation(convKey)?.messages.first?.relayUrls.contains("wss://r2") == true)
    }

    /// A failed send can be flipped back to `.sending` for retry (in-memory state only).
    @MainActor
    @Test func optimisticFailedThenRetryFlipsState() {
        let repo = DmRepository()
        let convKey = "me,peer"
        let tempId = "pending:xyz"
        var msg = DmMessage(id: tempId, senderPubkey: "me", content: "hi", createdAt: 5,
                            giftWrapId: "", rumorId: "r", replyToId: nil, participants: ["peer"])
        msg.sendState = .sending
        repo.insertOptimistic(msg, conversationKey: convKey)

        repo.setOptimisticSendState(.failed, tempId: tempId, conversationKey: convKey)
        #expect(repo.conversation(convKey)?.messages.first?.sendState == .failed)

        repo.setOptimisticSendState(.sending, tempId: tempId, conversationKey: convKey)
        #expect(repo.conversation(convKey)?.messages.first?.sendState == .sending)
        #expect(repo.conversation(convKey)?.messages.count == 1)
    }
}
