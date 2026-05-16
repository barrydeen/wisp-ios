import Foundation
import Testing
@testable import wisp

@Suite(.serialized)
struct SafetyTests {

    // MARK: - SafetyFilter

    @Test func wordMatchIsCaseInsensitive() {
        let snap = SafetyFilterSnapshot(
            mutedWords: ["spam", "crypto"],
            blockedPubkeys: [],
            mutedThreads: [],
            wotEnabled: false,
            qualifiedNetwork: [],
            userPubkey: "0000"
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        let evt = makeEvent(kind: 1, pubkey: "alice", content: "Loving SPAM today")
        #expect(SafetyFilter.shared.shouldDrop(event: evt, context: .feed))
    }

    @Test func wordMatchSkipsForThreadsAndMessages() {
        let snap = SafetyFilterSnapshot(
            mutedWords: ["spam"],
            blockedPubkeys: [],
            mutedThreads: [],
            wotEnabled: false,
            qualifiedNetwork: [],
            userPubkey: "0000"
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        let evt = makeEvent(kind: 1, pubkey: "alice", content: "spam")
        #expect(!SafetyFilter.shared.shouldDrop(event: evt, context: .thread(rootId: "abc")))
        #expect(!SafetyFilter.shared.shouldDrop(event: evt, context: .messages))
        #expect(SafetyFilter.shared.shouldDrop(event: evt, context: .feed))
    }

    @Test func blockedPubkeyDropsEverywhere() {
        let snap = SafetyFilterSnapshot(
            mutedWords: [],
            blockedPubkeys: ["alice"],
            mutedThreads: [],
            wotEnabled: false,
            qualifiedNetwork: [],
            userPubkey: "0000"
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        let evt = makeEvent(kind: 1, pubkey: "alice", content: "hello")
        for ctx: SafetyContext in [.feed, .notifications, .thread(rootId: "x"), .messages] {
            #expect(SafetyFilter.shared.shouldDrop(event: evt, context: ctx))
        }
    }

    @Test func mutedThreadDropsRepliesInFeedAndNotifications() {
        let snap = SafetyFilterSnapshot(
            mutedWords: [],
            blockedPubkeys: [],
            mutedThreads: ["root123"],
            wotEnabled: false,
            qualifiedNetwork: [],
            userPubkey: "0000"
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        let reply = makeEvent(kind: 1, pubkey: "alice", content: "later", tags: [["e", "root123", "", "reply"]])
        #expect(SafetyFilter.shared.shouldDrop(event: reply, context: .feed))
        #expect(SafetyFilter.shared.shouldDrop(event: reply, context: .notifications))
        // In thread context the user explicitly opened the thread, so we don't second-guess.
        #expect(!SafetyFilter.shared.shouldDrop(event: reply, context: .thread(rootId: "root123")))
    }

    @Test func wotExemptKindsBypassEvenWhenAuthorOutOfNetwork() {
        let snap = SafetyFilterSnapshot(
            mutedWords: [],
            blockedPubkeys: [],
            mutedThreads: [],
            wotEnabled: true,
            qualifiedNetwork: ["bob"],
            userPubkey: "me"
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        let strangerProfile = makeEvent(kind: 0, pubkey: "stranger", content: "{}")
        #expect(!SafetyFilter.shared.shouldDrop(event: strangerProfile, context: .feed))

        let strangerNote = makeEvent(kind: 1, pubkey: "stranger", content: "hi")
        #expect(SafetyFilter.shared.shouldDrop(event: strangerNote, context: .feed))

        let bobNote = makeEvent(kind: 1, pubkey: "bob", content: "hi")
        #expect(!SafetyFilter.shared.shouldDrop(event: bobNote, context: .feed))

        let myNote = makeEvent(kind: 1, pubkey: "me", content: "hi")
        #expect(!SafetyFilter.shared.shouldDrop(event: myNote, context: .feed))
    }

    @Test func wotInactiveWhenQualifiedSetEmpty() {
        let snap = SafetyFilterSnapshot(
            mutedWords: [],
            blockedPubkeys: [],
            mutedThreads: [],
            wotEnabled: true,
            qualifiedNetwork: [],
            userPubkey: "me"
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        let strangerNote = makeEvent(kind: 1, pubkey: "stranger", content: "hi")
        #expect(!SafetyFilter.shared.shouldDrop(event: strangerNote, context: .feed))
    }

    @Test func mutedAuthorRepostDroppedWhenEmbeddedJsonPresent() {
        let snap = SafetyFilterSnapshot(
            mutedWords: [],
            blockedPubkeys: ["alice"],
            mutedThreads: [],
            wotEnabled: false,
            qualifiedNetwork: [],
            userPubkey: "me"
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        let embedded = #"{"pubkey":"alice","id":"abc","kind":1,"content":"hi"}"#
        let repost = makeEvent(kind: 6, pubkey: "bob", content: embedded, tags: [["e", "abc"], ["p", "alice"]])
        #expect(SafetyFilter.shared.shouldDrop(event: repost, context: .feed))
    }

    @Test func mutedAuthorRepostDroppedWhenContentEmpty() {
        // Many clients omit the embedded event JSON and only emit `e`/`p` tags.
        // The mute filter must still recognise the original author via the `p` tag.
        let snap = SafetyFilterSnapshot(
            mutedWords: [],
            blockedPubkeys: ["alice"],
            mutedThreads: [],
            wotEnabled: false,
            qualifiedNetwork: [],
            userPubkey: "me"
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        let repost = makeEvent(kind: 6, pubkey: "bob", content: "", tags: [["e", "abc"], ["p", "alice"]])
        #expect(SafetyFilter.shared.shouldDrop(event: repost, context: .feed))
    }

    @Test func unmutedAuthorRepostKept() {
        let snap = SafetyFilterSnapshot(
            mutedWords: [],
            blockedPubkeys: ["alice"],
            mutedThreads: [],
            wotEnabled: false,
            qualifiedNetwork: [],
            userPubkey: "me"
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        let repost = makeEvent(kind: 6, pubkey: "bob", content: "", tags: [["e", "abc"], ["p", "carol"]])
        #expect(!SafetyFilter.shared.shouldDrop(event: repost, context: .feed))
    }

    // MARK: - Nip51Mute

    @Test func privateBodyRoundtrip() {
        let pubkeys: Set<String> = ["aa", "bb"]
        let words: Set<String> = ["spam", "shill"]
        let threads: Set<String> = ["root1"]

        let json = Nip51Mute.buildPrivateBodyJson(pubkeys: pubkeys, words: words, threads: threads)
        let parsed = Nip51Mute.parsePrivateBody(json)

        #expect(parsed.pubkeys == pubkeys)
        #expect(parsed.words == words)
        #expect(parsed.threads == threads)
    }

    @MainActor
    @Test func encryptedMuteEventRoundtrip() async throws {
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        let pubHex = Hex.encode(pub)
        let kp = Keypair(privkey: Hex.encode(priv), pubkey: pubHex)

        let event = try await Nip51Mute.buildSignedMuteEvent(
            keypair: kp,
            blockedPubkeys: ["abc"], mutedWords: ["junk"], mutedThreads: ["root1"],
            createdAt: 1_700_000_000
        )

        #expect(event.kind == Nip51Mute.kindMuteList)
        #expect(event.tags.isEmpty)
        #expect(!event.content.isEmpty)
        // Signature verifies — sanity check that we built a valid event.
        #expect(Schnorr.verify(
            sig64: Hex.decode(event.sig)!,
            messageId32: Hex.decode(event.id)!,
            xonlyPubkey32: pub
        ))

        let parsed = try Nip51Mute.decryptAndParse(event: event, privkey32: priv)
        #expect(parsed.pubkeys == ["abc"])
        #expect(parsed.words == ["junk"])
        #expect(parsed.threads == ["root1"])
    }

    @Test func parsesPublicTagsForCrossClientCompat() {
        let event = NostrEvent(
            id: String(repeating: "f", count: 64),
            pubkey: "abc",
            kind: Nip51Mute.kindMuteList,
            createdAt: 0,
            tags: [["p", "blocked1"], ["word", "BadWord"], ["e", "rootX"]],
            content: "",
            sig: ""
        )
        let parsed = Nip51Mute.parsePublicTags(event: event)
        #expect(parsed.pubkeys == ["blocked1"])
        #expect(parsed.words == ["badword"])
        #expect(parsed.threads == ["rootX"])
    }

    // MARK: - Helpers

    private func makeEvent(kind: Int, pubkey: String, content: String, tags: [[String]] = []) -> NostrEvent {
        NostrEvent(
            id: String(repeating: "0", count: 64),
            pubkey: pubkey, kind: kind,
            createdAt: 0,
            tags: tags, content: content, sig: ""
        )
    }
}
