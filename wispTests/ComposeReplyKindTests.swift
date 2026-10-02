import Foundation
import Testing
@testable import wisp

/// The composer is the live reply path — `ThreadView` presents it as
/// `ComposeView(mode: .reply(...))` for both the sticky reply bar and a card's
/// comment icon. These tests pin the kind and tags on the path that actually
/// publishes: Wisp renders NIP-22 comments but never emits them itself, so
/// every reply — including one to a kind-1111 comment — is a kind-1 with
/// NIP-10 threading.
@MainActor
struct ComposeReplyKindTests {

    private let keypair = Keypair(privkey: String(repeating: "1", count: 64),
                                  pubkey: String(repeating: "a", count: 64))

    private static let article = "https://bitcoinmagazine.com/guides/some-article"

    /// A NIP-22 comment on a web page, as `Nip22.externalRoot` expects it.
    private func webComment(id: String = "parentcomment", author: String = "parentpk") -> NostrEvent {
        NostrEvent(
            id: id, pubkey: author, kind: Nip22.kindComment, createdAt: 0,
            tags: [
                ["I", Self.article], ["K", "web"],
                ["i", Self.article], ["k", "web"],
            ],
            content: "good article", sig: ""
        )
    }

    private func plainNote(id: String = "parentnote", author: String = "parentpk") -> NostrEvent {
        NostrEvent(id: id, pubkey: author, kind: 1, createdAt: 0,
                   tags: [], content: "hello", sig: "")
    }

    private func tagValues(_ tags: [[String]], _ name: String) -> [String] {
        tags.filter { $0.count >= 2 && $0[0] == name }.map { $0[1] }
    }

    // MARK: - Comment replies publish as kind 1

    @Test func replyToWebCommentIsKind1() throws {
        let vm = ComposeViewModel(keypair: keypair, mode: .reply(parent: webComment(), root: nil))
        vm.content = "agreed"
        #expect(vm.determineKind() == 1)
    }

    @Test func replyToWebCommentUsesNip10NotNip22Tags() throws {
        let vm = ComposeViewModel(keypair: keypair, mode: .reply(parent: webComment(), root: nil))
        vm.content = "agreed"
        let tags = vm.buildBaseTags(kind: vm.determineKind(), materializedContent: vm.content)

        // NIP-10 threading at the parent comment; no `I`/`K` root scope —
        // Wisp doesn't emit NIP-22 comments itself.
        #expect(tagValues(tags, "I").isEmpty)
        #expect(tagValues(tags, "K").isEmpty)
        #expect(tagValues(tags, "k").isEmpty)
        let eTags = tags.filter { $0.count >= 4 && $0[0] == "e" }
        #expect(eTags.contains { $0[1] == "parentcomment" && $0[3] == "reply" })
        #expect(tagValues(tags, "p").contains("parentpk"))
    }

    @Test func replyToEventRootedCommentIsKind1() throws {
        let eventRooted = NostrEvent(
            id: "c2", pubkey: "parentpk", kind: Nip22.kindComment, createdAt: 0,
            tags: [["E", "rootid", "", "rootpk"], ["K", "1"],
                   ["e", "parentid", "", "parentpk"], ["k", "1111"]],
            content: "", sig: ""
        )
        let vm = ComposeViewModel(keypair: keypair, mode: .reply(parent: eventRooted, root: nil))
        vm.content = "hm"
        #expect(vm.determineKind() == 1)
        #expect(tagValues(vm.buildBaseTags(kind: vm.determineKind(), materializedContent: vm.content), "I").isEmpty)
    }

    // MARK: - Non-regressions

    @Test func replyToPlainNoteStaysKind1WithNip10() throws {
        let parent = plainNote()
        let vm = ComposeViewModel(keypair: keypair, mode: .reply(parent: parent, root: nil))
        vm.content = "hi"
        #expect(vm.determineKind() == 1)
        let tags = vm.buildBaseTags(kind: vm.determineKind(), materializedContent: vm.content)
        #expect(tagValues(tags, "I").isEmpty)
        let eTags = tags.filter { $0.count >= 4 && $0[0] == "e" }
        #expect(eTags.contains { $0[1] == "parentnote" && $0[3] == "reply" })
    }

    @Test func newPostIsKind1() throws {
        let vm = ComposeViewModel(keypair: keypair, mode: .new)
        vm.content = "gm"
        #expect(vm.determineKind() == 1)
        #expect(tagValues(vm.buildBaseTags(kind: vm.determineKind(), materializedContent: vm.content), "I").isEmpty)
    }

    /// A poll or gallery reply keeps its own kind — those aren't comments, and
    /// hijacking them to 1111 would break both features.
    @Test func pollAndGalleryRepliesKeepTheirKind() throws {
        let vm = ComposeViewModel(keypair: keypair, mode: .reply(parent: webComment(), root: nil))
        vm.content = "vote"
        vm.pollEnabled = true
        #expect(vm.determineKind() == Nip88.kindPoll)
        #expect(tagValues(vm.buildBaseTags(kind: vm.determineKind(), materializedContent: vm.content), "I").isEmpty)

        vm.pollEnabled = false
        vm.galleryMode = true
        #expect(vm.determineKind() != Nip22.kindComment)
    }
}

/// Where the source card and "Commenting on …" label may appear. A reply
/// carries the same `I`/`K` root scope forward (NIP-22 requires it), so the
/// distinction has to come from the lowercase side: only a top-level comment
/// has the external item as its immediate parent.
@Suite struct Nip22TopLevelVsReplyTests {

    private static let article = "https://arstechnica.com/tech-policy/2026/07/artist-sues"

    /// Top-level comment on a page: uppercase root AND lowercase `i`/`k`.
    private var topLevel: NostrEvent {
        NostrEvent(id: "top", pubkey: "author", kind: Nip22.kindComment, createdAt: 0,
                   tags: [["I", Self.article], ["K", "web"],
                          ["i", Self.article], ["k", "web"]],
                   content: "good piece", sig: "")
    }

    /// Reply to that comment, as NIP-22 clients build it: same uppercase
    /// root, lowercase side pointing at the parent event. (Wisp's own replies
    /// ship as kind-1 instead.)
    private var replyToComment: NostrEvent {
        NostrEvent(id: "reply", pubkey: "author", kind: Nip22.kindComment, createdAt: 0,
                   tags: [["I", Self.article], ["K", "web"],
                          ["e", "top", "", "author"], ["k", "1111"], ["p", "author"]],
                   content: "agreed", sig: "")
    }

    @Test func bothCarryTheRootScope() {
        // The tags are correct on both — the card must not be driven off this.
        #expect(Nip22.externalRoot(of: topLevel)?.value == Self.article)
        #expect(Nip22.externalRoot(of: replyToComment)?.value == Self.article)
    }

    @Test func onlyTopLevelHasAnExternalParent() {
        // …so `externalParent` is what gates the source card and the
        // "Commenting on <host>" label.
        #expect(Nip22.externalParent(of: topLevel)?.value == Self.article)
        #expect(Nip22.externalParent(of: replyToComment) == nil)
    }
}
