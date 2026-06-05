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

    @Test func wotFailsClosedWhenQualifiedSetEmpty() {
        // FAIL CLOSED: WoT on with an uncomputed/lost network must hide every
        // non-exempt stranger event rather than silently no-op — the filter
        // gates potentially graphic content while the graph compute runs.
        // (This inverts the pre-fix fail-open behavior, which was the bug.)
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
        #expect(SafetyFilter.shared.shouldDrop(event: strangerNote, context: .feed))

        // Exempt kinds and the user's own events still pass.
        let strangerProfile = makeEvent(kind: 0, pubkey: "stranger", content: "{}")
        #expect(!SafetyFilter.shared.shouldDrop(event: strangerProfile, context: .feed))
        let myNote = makeEvent(kind: 1, pubkey: "me", content: "hi")
        #expect(!SafetyFilter.shared.shouldDrop(event: myNote, context: .feed))
    }

    @Test func wotKind6RequiresBothAuthorsQualified() {
        let snap = SafetyFilterSnapshot(
            mutedWords: [], blockedPubkeys: [], mutedThreads: [],
            wotEnabled: true, qualifiedNetwork: ["bob"], userPubkey: "me"
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        // Qualified bob reposting unqualified carol leaks her content — drop.
        let embedded = #"{"pubkey":"carol","id":"abc","kind":1,"content":"hi"}"#
        let jsonRepost = makeEvent(kind: 6, pubkey: "bob", content: embedded, tags: [["e", "abc"], ["p", "carol"]])
        #expect(SafetyFilter.shared.shouldDrop(event: jsonRepost, context: .feed))

        // Same via p-tag-only form (no embedded JSON).
        let tagRepost = makeEvent(kind: 6, pubkey: "bob", content: "", tags: [["e", "abc"], ["p", "carol"]])
        #expect(SafetyFilter.shared.shouldDrop(event: tagRepost, context: .feed))

        // Unparseable inner author fails closed.
        let blindRepost = makeEvent(kind: 6, pubkey: "bob", content: "", tags: [["e", "abc"]])
        #expect(SafetyFilter.shared.shouldDrop(event: blindRepost, context: .feed))

        // Unqualified reposter never passes, even wrapping qualified content.
        let strangerRepost = makeEvent(
            kind: 6, pubkey: "stranger",
            content: #"{"pubkey":"bob","id":"abc","kind":1,"content":"hi"}"#,
            tags: [["e", "abc"], ["p", "bob"]]
        )
        #expect(SafetyFilter.shared.shouldDrop(event: strangerRepost, context: .feed))

        // Qualified reposting qualified (or the user) passes.
        let bobRepost = makeEvent(
            kind: 6, pubkey: "bob",
            content: #"{"pubkey":"bob","id":"abc","kind":1,"content":"hi"}"#,
            tags: [["e", "abc"], ["p", "bob"]]
        )
        #expect(!SafetyFilter.shared.shouldDrop(event: bobRepost, context: .feed))
        let repostOfMe = makeEvent(kind: 6, pubkey: "bob", content: "", tags: [["e", "abc"], ["p", "me"]])
        #expect(!SafetyFilter.shared.shouldDrop(event: repostOfMe, context: .feed))
    }

    @Test func wotZapReceiptNotJudgedByEventPubkey() {
        // A kind-9735 receipt is signed by the LN service, not the zapper —
        // the generic gate must NOT drop it for the service pubkey being
        // outside the network (that wrongly killed every zap notification).
        // The real sender is judged post-classification in
        // NotificationRepository.ingest (covered below).
        let snap = SafetyFilterSnapshot(
            mutedWords: [], blockedPubkeys: [], mutedThreads: [],
            wotEnabled: true, qualifiedNetwork: ["bob"], userPubkey: "me"
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        let receipt = makeEvent(kind: 9735, pubkey: "lnservice", content: "", tags: [["p", "me"]])
        #expect(!SafetyFilter.shared.shouldDrop(event: receipt, context: .notifications))
    }

    @Test func isWotQualifiedTruthTable() {
        // Off → everyone qualifies (the helper is a no-op gate).
        SafetyFilter.shared.install(.empty)
        #expect(SafetyFilter.shared.isWotQualified("stranger"))

        let snap = SafetyFilterSnapshot(
            mutedWords: [], blockedPubkeys: [], mutedThreads: [],
            wotEnabled: true, qualifiedNetwork: ["bob"], userPubkey: "me"
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }
        #expect(SafetyFilter.shared.isWotQualified("me"))
        #expect(SafetyFilter.shared.isWotQualified("bob"))
        #expect(!SafetyFilter.shared.isWotQualified("stranger"))

        // Empty network + enabled → only self qualifies (fail closed).
        let emptyNet = SafetyFilterSnapshot(
            mutedWords: [], blockedPubkeys: [], mutedThreads: [],
            wotEnabled: true, qualifiedNetwork: [], userPubkey: "me"
        )
        SafetyFilter.shared.install(emptyNet)
        #expect(SafetyFilter.shared.isWotQualified("me"))
        #expect(!SafetyFilter.shared.isWotQualified("bob"))
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

    // MARK: - isHardBlocked (persistence-time block gate)

    @Test func isHardBlockedMatchesDirectAuthor() {
        let snap = SafetyFilterSnapshot(
            mutedWords: [], blockedPubkeys: ["alice"], mutedThreads: [],
            wotEnabled: false, qualifiedNetwork: [], userPubkey: "me"
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        #expect(SafetyFilter.shared.isHardBlocked(event: makeEvent(kind: 1, pubkey: "alice", content: "hi")))
        #expect(!SafetyFilter.shared.isHardBlocked(event: makeEvent(kind: 1, pubkey: "bob", content: "hi")))
    }

    @Test func isHardBlockedMatchesRepostInnerAuthor() {
        let snap = SafetyFilterSnapshot(
            mutedWords: [], blockedPubkeys: ["alice"], mutedThreads: [],
            wotEnabled: false, qualifiedNetwork: [], userPubkey: "me"
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        let embedded = #"{"pubkey":"alice","id":"abc","kind":1,"content":"hi"}"#
        let jsonRepost = makeEvent(kind: 6, pubkey: "bob", content: embedded, tags: [["e", "abc"], ["p", "alice"]])
        #expect(SafetyFilter.shared.isHardBlocked(event: jsonRepost))

        let tagRepost = makeEvent(kind: 6, pubkey: "bob", content: "", tags: [["e", "abc"], ["p", "alice"]])
        #expect(SafetyFilter.shared.isHardBlocked(event: tagRepost))

        let cleanRepost = makeEvent(kind: 6, pubkey: "bob", content: "", tags: [["e", "abc"], ["p", "carol"]])
        #expect(!SafetyFilter.shared.isHardBlocked(event: cleanRepost))
    }

    @Test func isHardBlockedIgnoresWordThreadAndWot() {
        // A block gate is block-list-only: word / thread / WoT are reversible
        // preferences and must never evict an event from disk permanently.
        let snap = SafetyFilterSnapshot(
            mutedWords: ["spam"], blockedPubkeys: [], mutedThreads: ["root123"],
            wotEnabled: true, qualifiedNetwork: ["bob"], userPubkey: "me"
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        let evt = makeEvent(kind: 1, pubkey: "stranger", content: "spam", tags: [["e", "root123", "", "reply"]])
        #expect(!SafetyFilter.shared.isHardBlocked(event: evt))
        // shouldDrop would still drop it (word + WoT + thread) — proves the
        // semantic difference between the two gates.
        #expect(SafetyFilter.shared.shouldDrop(event: evt, context: .feed))
    }

    @Test func survivesBlockRetainsExemptKindsButDropsContent() {
        let snap = SafetyFilterSnapshot(
            mutedWords: [], blockedPubkeys: ["alice"], mutedThreads: [],
            wotEnabled: false, qualifiedNetwork: [], userPubkey: "me"
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        // Content / engagement kinds from a blocked author never persist.
        for kind in [1, 7, 9735, 20, 1068] {
            #expect(!EventStore.survivesBlock(makeEvent(kind: kind, pubkey: "alice", content: "x")))
        }
        // Identity / config kinds are retained even for a blocked author.
        for kind in [0, 10002, 10030, 30030, 30000] {
            #expect(EventStore.survivesBlock(makeEvent(kind: kind, pubkey: "alice", content: "x")))
        }
        // A repost of a blocked author is dropped; non-blocked content survives.
        let repost = makeEvent(kind: 6, pubkey: "bob", content: "", tags: [["e", "abc"], ["p", "alice"]])
        #expect(!EventStore.survivesBlock(repost))
        #expect(EventStore.survivesBlock(makeEvent(kind: 1, pubkey: "carol", content: "hi")))
    }

    // MARK: - Notification sub-thread suppression

    @MainActor
    @Test func notificationDropsReplyInBlockedSubThread() {
        // Bind to a unique pubkey so the shared singleton's seen-id LRU and
        // self-event set start clean (bind only resets when the active pubkey
        // changes); event ids are unique for the same reason.
        let me = "me_" + UUID().uuidString
        let myNote = "mynote_" + UUID().uuidString

        let snap = SafetyFilterSnapshot(
            mutedWords: [], blockedPubkeys: ["bob"], mutedThreads: [],
            wotEnabled: false, qualifiedNetwork: [], userPubkey: me
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        let repo = NotificationRepository.shared
        repo.bind(activePubkey: me)
        repo.selfEventIds = [myNote]

        // Non-blocked alice replies inside blocked bob's sub-thread: her reply
        // p-tags bob (the NIP-10 ancestor author). Dropped.
        let blockedSubThread = makeEvent(
            kind: 1, pubkey: "alice", content: "+1",
            tags: [["e", myNote, "", "reply"], ["p", me], ["p", "bob"]],
            id: "reply_blocked_" + UUID().uuidString
        )
        #expect(repo.ingest(blockedSubThread, relayUrl: "", persist: false) == false)

        // Same reply with no blocked ancestor still notifies.
        let cleanReply = makeEvent(
            kind: 1, pubkey: "alice", content: "+1",
            tags: [["e", myNote, "", "reply"], ["p", me]],
            id: "reply_clean_" + UUID().uuidString
        )
        #expect(repo.ingest(cleanReply, relayUrl: "", persist: false) == true)

        // A direct mention that incidentally p-tags a blocked user is NOT a
        // sub-thread — scope is `.reply` only, so it still notifies.
        let mention = makeEvent(
            kind: 1, pubkey: "alice", content: "hey",
            tags: [["p", me], ["p", "bob"]],
            id: "mention_" + UUID().uuidString
        )
        #expect(repo.ingest(mention, relayUrl: "", persist: false) == true)
    }

    // MARK: - Notification ingest WoT chokepoint

    @MainActor
    @Test func notificationIngestDropsNonWotAuthors() {
        let me = "me_" + UUID().uuidString
        let myNote = "mynote_" + UUID().uuidString

        let snap = SafetyFilterSnapshot(
            mutedWords: [], blockedPubkeys: [], mutedThreads: [],
            wotEnabled: true, qualifiedNetwork: ["friend"], userPubkey: me
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        let repo = NotificationRepository.shared
        repo.bind(activePubkey: me)
        repo.selfEventIds = [myNote]

        // The gate lives in ingest itself — no caller pre-filter — so even a
        // path that forgets shouldDrop (the 24h-backfill bug) stays safe.
        let strangerReply = makeEvent(
            kind: 1, pubkey: "stranger", content: "graphic",
            tags: [["e", myNote, "", "reply"], ["p", me]],
            id: "wotreply_stranger_" + UUID().uuidString
        )
        #expect(repo.ingest(strangerReply, relayUrl: "", persist: false) == false)
        #expect(!repo.flatItems.contains { $0.actorPubkey == "stranger" })

        let friendReply = makeEvent(
            kind: 1, pubkey: "friend", content: "hello",
            tags: [["e", myNote, "", "reply"], ["p", me]],
            id: "wotreply_friend_" + UUID().uuidString
        )
        #expect(repo.ingest(friendReply, relayUrl: "", persist: false) == true)
    }

    @MainActor
    @Test func notificationIngestZapJudgedByResolvedActor() {
        let me = "me_" + UUID().uuidString
        let myNote = "mynote_" + UUID().uuidString

        let snap = SafetyFilterSnapshot(
            mutedWords: [], blockedPubkeys: [], mutedThreads: [],
            wotEnabled: true, qualifiedNetwork: ["friend"], userPubkey: me
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        let repo = NotificationRepository.shared
        repo.bind(activePubkey: me)
        repo.selfEventIds = [myNote]

        // Both receipts are signed by the same out-of-network LN service —
        // what must decide is the zap-request signer in `description`.
        func receipt(sender: String) -> NostrEvent {
            makeEvent(
                kind: 9735, pubkey: "lnservice", content: "",
                tags: [
                    ["p", me],
                    ["e", myNote],
                    ["description", #"{"pubkey":"\#(sender)","content":"","tags":[]}"#]
                ],
                id: "zap_\(sender)_" + UUID().uuidString
            )
        }
        let strangerReceipt = receipt(sender: "stranger")
        #expect(repo.ingest(strangerReceipt, relayUrl: "", persist: false) == false)
        #expect(repo.ingest(receipt(sender: "friend"), relayUrl: "", persist: false) == true)

        // The dropped receipt must NOT have taken a seen slot — relaxing the
        // filter and re-delivering the same event id notifies. (The seen-mark
        // for zaps is deferred until the actor gate passes.)
        let relaxed = SafetyFilterSnapshot(
            mutedWords: [], blockedPubkeys: [], mutedThreads: [],
            wotEnabled: true, qualifiedNetwork: ["friend", "stranger"], userPubkey: me
        )
        SafetyFilter.shared.install(relaxed)
        #expect(repo.ingest(strangerReceipt, relayUrl: "", persist: false) == true)
    }

    @MainActor
    @Test func notificationIngestPrivateZapExemptFromWot() {
        let me = "me_" + UUID().uuidString
        let myNote = "mynote_" + UUID().uuidString

        let snap = SafetyFilterSnapshot(
            mutedWords: [], blockedPubkeys: [], mutedThreads: [],
            wotEnabled: true, qualifiedNetwork: [], userPubkey: me
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        let repo = NotificationRepository.shared
        repo.bind(activePubkey: me)
        repo.selfEventIds = [myNote]

        // An anonymous NIP-57 zap (empty `anon` tag in the embedded request)
        // classifies as `isPrivateZap` — there is no judgeable sender, so the
        // WoT gate must not eat it (`item.isPrivateZap`, not the gift-wrap
        // `isPrivate` param, which is always false for zaps).
        let anonReceipt = makeEvent(
            kind: 9735, pubkey: "lnservice", content: "",
            tags: [
                ["p", me],
                ["e", myNote],
                ["description", #"{"pubkey":"ephemeral","content":"","tags":[["anon",""]]}"#]
            ],
            id: "zap_anon_" + UUID().uuidString
        )
        #expect(repo.ingest(anonReceipt, relayUrl: "", persist: false) == true)
    }

    @MainActor
    @Test func notificationIngestPrivateRumorExemptFromWot() {
        let me = "me_" + UUID().uuidString
        let myNote = "mynote_" + UUID().uuidString

        let snap = SafetyFilterSnapshot(
            mutedWords: [], blockedPubkeys: [], mutedThreads: [],
            wotEnabled: true, qualifiedNetwork: [], userPubkey: me
        )
        SafetyFilter.shared.install(snap)
        defer { SafetyFilter.shared.install(.empty) }

        let repo = NotificationRepository.shared
        repo.bind(activePubkey: me)
        repo.selfEventIds = [myNote]

        // Gift-wrap rumors are e2e-private and WoT-exempt by design — the
        // sender already reached the user through the DM channel.
        let privateReply = makeEvent(
            kind: 1, pubkey: "dmsender", content: "psst",
            tags: [["e", myNote, "", "reply"], ["p", me]],
            id: "private_" + UUID().uuidString
        )
        #expect(repo.ingest(privateReply, relayUrl: "", isPrivate: true, persist: false) == true)
    }

    @MainActor
    @Test func purgeNonWotQualifiedScrubsInMemoryItems() {
        let me = "me_" + UUID().uuidString
        let myNote = "mynote_" + UUID().uuidString

        // Ingest under a snapshot where alice qualifies…
        let permissive = SafetyFilterSnapshot(
            mutedWords: [], blockedPubkeys: [], mutedThreads: [],
            wotEnabled: true, qualifiedNetwork: ["alice"], userPubkey: me
        )
        SafetyFilter.shared.install(permissive)
        defer { SafetyFilter.shared.install(.empty) }

        let repo = NotificationRepository.shared
        repo.bind(activePubkey: me)
        repo.selfEventIds = [myNote]

        let aliceReply = makeEvent(
            kind: 1, pubkey: "alice", content: "hi",
            tags: [["e", myNote, "", "reply"], ["p", me]],
            id: "purge_alice_" + UUID().uuidString
        )
        #expect(repo.ingest(aliceReply, relayUrl: "", persist: false) == true)
        let privateReply = makeEvent(
            kind: 1, pubkey: "dmsender", content: "psst",
            tags: [["e", myNote, "", "reply"], ["p", me]],
            id: "purge_private_" + UUID().uuidString
        )
        #expect(repo.ingest(privateReply, relayUrl: "", isPrivate: true, persist: false) == true)

        // …then the network shrinks (recompute) and alice falls out.
        let tightened = SafetyFilterSnapshot(
            mutedWords: [], blockedPubkeys: [], mutedThreads: [],
            wotEnabled: true, qualifiedNetwork: [], userPubkey: me
        )
        SafetyFilter.shared.install(tightened)
        repo.purgeNonWotQualified()

        #expect(!repo.flatItems.contains { $0.actorPubkey == "alice" })
        // Private rows keep their gift-wrap exemption through the purge.
        #expect(repo.flatItems.contains { $0.actorPubkey == "dmsender" })
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

    private func makeEvent(kind: Int, pubkey: String, content: String, tags: [[String]] = [],
                           id: String = String(repeating: "0", count: 64)) -> NostrEvent {
        NostrEvent(
            id: id,
            pubkey: pubkey, kind: kind,
            createdAt: 0,
            tags: tags, content: content, sig: ""
        )
    }
}
