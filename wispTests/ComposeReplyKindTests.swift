import Foundation
import Testing
@testable import wisp

/// The composer is the live reply path — `ThreadView` presents it as
/// `ComposeView(mode: .reply(...))` for both the sticky reply bar and a card's
/// comment icon. `ThreadViewModel.publishReply` also carries a NIP-22 branch
/// but nothing calls it, so these tests pin the kind and tags on the path that
/// actually publishes: a comment reply must stay kind-1111 and keep its `I`/`K`
/// root scope, because NIP-10 threading can't express an external root.
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

    // MARK: - Comment replies stay kind 1111

    @Test func replyToWebCommentIsKind1111() throws {
        let vm = ComposeViewModel(keypair: keypair, mode: .reply(parent: webComment(), root: nil))
        vm.content = "agreed"
        #expect(vm.determineKind() == Nip22.kindComment)
    }

    @Test func replyToWebCommentCarriesRootScopeNotNip10() throws {
        let vm = ComposeViewModel(keypair: keypair, mode: .reply(parent: webComment(), root: nil))
        vm.content = "agreed"
        let tags = vm.buildBaseTags(kind: vm.determineKind(), materializedContent: vm.content)

        // Root scope preserved, so the reply stays attached to the page.
        #expect(tagValues(tags, "I") == [Self.article])
        #expect(tagValues(tags, "K") == ["web"])
        // Lowercase side points at the parent comment, and declares its kind.
        #expect(tagValues(tags, "e") == ["parentcomment"])
        #expect(tagValues(tags, "k") == [String(Nip22.kindComment)])
        #expect(tagValues(tags, "p").contains("parentpk"))
        // NIP-10 markers would detach it from the external root.
        let eTags = tags.filter { $0.count >= 4 && $0[0] == "e" }
        #expect(!eTags.contains { $0[3] == "root" || $0[3] == "reply" })
    }

    /// A comment whose root is a nostr event (uppercase `E`) has no external
    /// root, so `Nip22.buildReplyTags` returns nil and we fall back to NIP-10
    /// — the pre-existing behavior for that shape.
    @Test func replyToEventRootedCommentFallsBackToNip10() throws {
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
