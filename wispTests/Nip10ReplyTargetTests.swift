import Foundation
import Testing
@testable import wisp

/// Locks the immediate-parent semantics of `Nip10.replyTarget`, which the
/// notification classifier (`NotificationRepository.classifyKind1`) relies on to
/// show the note a reply *actually* targets — the intermediate reply in a
/// reply-to-a-reply — rather than the thread root (our own OP). `Nip10` is a
/// `nonisolated enum`, so the suite needs no actor isolation.
@Suite struct Nip10ReplyTargetTests {

    private func reply(tags: [[String]]) -> NostrEvent {
        NostrEvent(id: "reply", pubkey: "actor", kind: 1, createdAt: 0, tags: tags, content: "", sig: "")
    }

    /// The bug scenario: C replies to B, which is nested under our root A.
    /// The `reply`-marked tag (B) must win over the `root`-marked tag (A).
    @Test func markedReplyTagWinsOverRoot() {
        let e = reply(tags: [
            ["e", "root-A", "wss://relay", "root"],
            ["e", "parent-B", "wss://relay", "reply"],
        ])
        #expect(Nip10.replyTarget(of: e) == "parent-B")
    }

    /// Legacy positional convention: first e-tag = root, last = immediate parent.
    @Test func legacyPositionalReturnsLastETag() {
        let e = reply(tags: [
            ["e", "root-A"],
            ["e", "parent-B"],
        ])
        #expect(Nip10.replyTarget(of: e) == "parent-B")
    }

    /// Direct reply to a single note (marked root) → that note is the target.
    @Test func singleMarkedRootReturnsItself() {
        let e = reply(tags: [["e", "note-A", "", "root"]])
        #expect(Nip10.replyTarget(of: e) == "note-A")
    }

    /// Direct reply, single unmarked e-tag → that note is the target.
    @Test func singleUnmarkedReturnsItself() {
        let e = reply(tags: [["e", "note-A"]])
        #expect(Nip10.replyTarget(of: e) == "note-A")
    }

    /// `mention`-marked e-tags are threading-irrelevant and must be skipped,
    /// even when a `reply`/`root` pair is present.
    @Test func mentionMarkedTagsAreIgnored() {
        let e = reply(tags: [
            ["e", "mention-X", "", "mention"],
            ["e", "root-A", "", "root"],
            ["e", "parent-B", "", "reply"],
        ])
        #expect(Nip10.replyTarget(of: e) == "parent-B")
    }

    /// A trailing `mention` tag must not hijack the legacy "last e-tag" path.
    @Test func trailingMentionDoesNotBecomeTarget() {
        let e = reply(tags: [
            ["e", "parent-B"],
            ["e", "mention-X", "", "mention"],
        ])
        #expect(Nip10.replyTarget(of: e) == "parent-B")
    }

    /// No e-tags (e.g. a top-level note) → no reply target.
    @Test func noETagsReturnsNil() {
        let e = reply(tags: [["p", "somebody"]])
        #expect(Nip10.replyTarget(of: e) == nil)
    }
}
