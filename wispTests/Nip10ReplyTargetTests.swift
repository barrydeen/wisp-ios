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

/// Locks the `p`-tag carry-forward that keeps everyone in a thread notified.
/// Regression guard for the bug where a reply only tagged the direct parent
/// author and dropped earlier participants — e.g. A↔B then B replying to B's
/// own note silently lost A.
@Suite struct Nip10ParticipantTagsTests {

    private func note(pubkey: String, tags: [[String]]) -> NostrEvent {
        NostrEvent(id: "note", pubkey: pubkey, kind: 1, createdAt: 0, tags: tags, content: "", sig: "")
    }

    private func pubkeys(_ tags: [[String]]) -> [String] {
        tags.compactMap { $0.count >= 2 && $0[0] == "p" ? $0[1] : nil }
    }

    /// The reported scenario: B replies to B's own note. That parent already
    /// carries A (from when B replied to A), so A must ride along, and B is
    /// added as the parent author.
    @Test func selfReplyKeepsEarlierParticipant() {
        let parent = note(pubkey: "B", tags: [["e", "root", "", "root"], ["p", "B"], ["p", "A"]])
        #expect(pubkeys(Nip10.participantTags(replyingTo: parent)) == ["B", "A"])
    }

    /// Plain reply: the parent author joins the parent's existing participants.
    @Test func carriesParentParticipantsThenAuthor() {
        let parent = note(pubkey: "B", tags: [["p", "A"]])
        #expect(pubkeys(Nip10.participantTags(replyingTo: parent)) == ["A", "B"])
    }

    /// The author is not duplicated when already present in the parent's p-tags.
    @Test func authorNotDuplicated() {
        let parent = note(pubkey: "B", tags: [["p", "A"], ["p", "B"]])
        #expect(pubkeys(Nip10.participantTags(replyingTo: parent)) == ["A", "B"])
    }

    /// Duplicate p-tags on the parent collapse to one each.
    @Test func deduplicatesRepeatedParticipants() {
        let parent = note(pubkey: "B", tags: [["p", "A"], ["p", "A"], ["p", "C"]])
        #expect(pubkeys(Nip10.participantTags(replyingTo: parent)) == ["A", "C", "B"])
    }

    /// A top-level note (no p-tags) yields just the author.
    @Test func topLevelNoteTagsOnlyAuthor() {
        let parent = note(pubkey: "B", tags: [])
        #expect(pubkeys(Nip10.participantTags(replyingTo: parent)) == ["B"])
    }

    /// End-to-end via buildReplyTags: the full e/p set for replying to B's
    /// self-reply keeps the root e-tag, marks the parent as reply, and carries
    /// both participants.
    @Test func buildReplyTagsCarriesWholeThread() {
        let parent = note(pubkey: "B", tags: [["e", "root", "", "root"], ["p", "B"], ["p", "A"]])
        let tags = Nip10.buildReplyTags(replyTo: parent)
        #expect(tags.contains(["e", "root", "", "root"]))
        #expect(tags.contains(["e", "note", "", "reply"]))
        #expect(pubkeys(tags) == ["B", "A"])
    }
}
