import Foundation
import Testing
@testable import wisp

/// NIP-22 comments must be treated as replies everywhere they're counted:
/// engagement boxes (feed cards / thread headers) and the notification feed.
/// Wisp renders 1111s from other clients but never publishes them, so these
/// paths only ever see foreign comments.
@Suite @MainActor struct Nip22CountingTests {

    init() {
        // Deterministic filter state: no blocks, WoT off — the tests exercise
        // counting, not the safety gate.
        SafetyFilter.shared.install(.empty)
    }

    private func comment(id: String, author: String, parent: String, at: Int = 100) -> NostrEvent {
        NostrEvent(id: id, pubkey: author, kind: Nip22.kindComment, createdAt: at,
                   tags: [["e", parent]], content: "nice", sig: "")
    }

    // MARK: - Engagement counts

    @Test func forwardedCommentRaisesReplyCountOnce() {
        let repo = EngagementRepository.shared
        repo.clear()
        let note = "note-nip22-1"
        let c = comment(id: "c1", author: "carol", parent: note)
        repo.ingestForwarded(c)
        repo.ingestForwarded(c) // re-delivery must not inflate
        #expect(repo.box(for: note).counts.replies == 1)
    }

    @Test func commentsAndKind1RepliesCountTogether() {
        let repo = EngagementRepository.shared
        repo.clear()
        let note = "note-nip22-2"
        repo.ingestForwarded(comment(id: "c1", author: "carol", parent: note))
        repo.ingestForwarded(comment(id: "c2", author: "dave", parent: note))
        repo.ingestForwarded(NostrEvent(id: "r1", pubkey: "erin", kind: 1, createdAt: 100,
                                        tags: [["e", note]], content: "hi", sig: ""))
        #expect(repo.box(for: note).counts.replies == 3)
    }

    /// An external-root comment (no lowercase `e` at a tracked note) must not
    /// be attributed anywhere — it's a reply to a web page, not to our note.
    @Test func externalRootCommentAttributesNowhere() {
        let repo = EngagementRepository.shared
        repo.clear()
        let note = "note-nip22-3"
        repo.ingestForwarded(NostrEvent(
            id: "c-ext", pubkey: "carol", kind: Nip22.kindComment, createdAt: 100,
            tags: [["I", "https://example.com/a"], ["K", "web"], ["i", "https://example.com/a"], ["k", "web"]],
            content: "on the web", sig: ""
        ))
        // The comment has no `e` tag at a tracked note, so no box is
        // attributed anything — the untouched box reads zero replies.
        #expect(repo.box(for: note).counts.replies == 0)
    }

    // MARK: - Notification classification

    private let me = String(repeating: "a", count: 64)
    private let them = String(repeating: "b", count: 64)

    private func makeRepo(selfIds: Set<String> = []) -> NotificationRepository {
        let repo = NotificationRepository()
        repo.bind(activePubkey: me)
        repo.selfEventIds = selfIds
        return repo
    }

    /// A comment e-tagging one of my events classifies as a reply, pointing at
    /// the event it actually replied to.
    @Test func eTaggedCommentBecomesReplyNotification() {
        let repo = makeRepo(selfIds: ["my-note"])
        let ingested = repo.ingest(
            comment(id: "c1", author: them, parent: "my-note"),
            relayUrl: "", persist: false
        )
        #expect(ingested)
        let item = repo.flatItems.first { $0.id == "c1" }
        #expect(item?.kind == .reply)
        #expect(item?.referencedEventId == "my-note")
    }

    /// An external-root comment that p-tags me is conversation aimed at me —
    /// it surfaces as a reply row too, referencing the comment itself.
    @Test func externalRootCommentPTaggingMeBecomesReplyNotification() {
        let repo = makeRepo()
        let event = NostrEvent(
            id: "c2", pubkey: them, kind: Nip22.kindComment, createdAt: 100,
            tags: [["I", "https://example.com/a"], ["K", "web"],
                   ["i", "https://example.com/a"], ["k", "web"], ["p", me]],
            content: "you were mentioned on the page", sig: ""
        )
        #expect(repo.ingest(event, relayUrl: "", persist: false))
        let item = repo.flatItems.first { $0.id == "c2" }
        #expect(item?.kind == .reply)
        #expect(item?.referencedEventId == "c2")
    }

    /// Kind-1 p-tag-only hits keep classifying as `.mention` — the `.reply`
    /// fallback is comment-only.
    @Test func plainNoteMentionStillClassifiesAsMention() {
        let repo = makeRepo()
        let note = NostrEvent(id: "n1", pubkey: them, kind: 1, createdAt: 100,
                              tags: [["p", me]], content: "hey", sig: "")
        #expect(repo.ingest(note, relayUrl: "", persist: false))
        #expect(repo.flatItems.first { $0.id == "n1" }?.kind == .mention)
    }
}
