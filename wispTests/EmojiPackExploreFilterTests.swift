import Foundation
import Testing
@testable import wisp

/// Covers `EmojiPackExploreModel.exploreReject` — the quality gate on the
/// Explore feed only. Nothing here applies to a pack added by link or already on
/// the user's kind-10030 list; a thin or self-declared-adult pack is still a
/// valid pack, it just doesn't get an unsolicited row in a browse feed.
@MainActor
struct EmojiPackExploreFilterTests {

    private func pack(
        d: String = "cool-pack",
        title: String? = nil,
        emojiCount: Int = 12,
        tags extra: [[String]] = []
    ) -> (NostrEvent, ResolvedEmojiPack) {
        var tags: [[String]] = [["d", d]]
        if let title { tags.append(["title", title]) }
        for i in 0..<emojiCount {
            tags.append(["emoji", "e\(i)", "https://example.com/e\(i).png"])
        }
        tags.append(contentsOf: extra)
        let event = NostrEvent(
            id: "id",
            pubkey: "author",
            kind: 30030,
            createdAt: 0,
            tags: tags,
            content: "",
            sig: ""
        )
        return (event, EmojiRepository.parsePack(event)!)
    }

    private func rejects(_ input: (NostrEvent, ResolvedEmojiPack)) -> Bool {
        EmojiPackExploreModel.exploreReject(event: input.0, pack: input.1)
    }

    @Test func keepsAnOrdinaryPack() {
        #expect(!rejects(pack()))
    }

    // 96 of 200 live packs carry 3 or fewer emoji, nearly all scratch events.
    @Test func rejectsPacksBelowTheEmojiFloor() {
        for count in 0...3 {
            #expect(rejects(pack(emojiCount: count)), "expected \(count) emoji to be rejected")
        }
        #expect(!rejects(pack(emojiCount: 4)))
    }

    @Test func rejectsPlaceholderNames() {
        #expect(rejects(pack(d: "Test")))
        #expect(rejects(pack(d: "test")))
        #expect(rejects(pack(d: "uuid-ish", title: "Test2")))
        #expect(rejects(pack(d: "uuid-ish", title: "Test avif")))
        #expect(rejects(pack(d: "asdf")))
    }

    // The live sample is full of automated radio-recording artifacts whose only
    // tell is a `_test<n>` / `-test<n>` suffix on the title.
    @Test func rejectsAutomatedTestRecordings() {
        for title in ["WNYC_test45", "WYNC-test16", "WNYC-test414", "WNYC_test_recording", "Wnyc_test45"] {
            #expect(rejects(pack(d: "griot:fm939", title: title)), "expected \(title) to be rejected")
        }
    }

    // The whole reason `test` is separator-bounded rather than a substring.
    @Test func keepsRealNamesThatMerelyContainTest() {
        #expect(!rejects(pack(d: "Contest Winners")))
        #expect(!rejects(pack(d: "Latest Memes")))
        #expect(!rejects(pack(d: "protest")))
    }

    @Test func rejectsSelfDeclaredNsfwByName() {
        #expect(rejects(pack(d: "nsfw", title: "nsfw")))
        #expect(rejects(pack(d: "memes NSFW")))
        #expect(rejects(pack(d: "hentai")))
        #expect(rejects(pack(d: "18+")))
    }

    // What wisp's own composer writes for adult content, so a pack published by
    // wisp and marked NSFW is honored even with a clean name.
    @Test func rejectsNip36ContentWarning() {
        #expect(rejects(pack(d: "perfectly-normal-name", tags: [["content-warning", ""]])))
        #expect(rejects(pack(d: "perfectly-normal-name", tags: [["content-warning", "nudity"]])))
    }

    // The pack that prompted this rule is the largest on the live relays and has
    // the slur glued into a compound word, so it needs unbounded matching.
    @Test func rejectsSlursGluedIntoCompoundNames() {
        #expect(rejects(pack(d: "niggaemotes", emojiCount: 353)))
        #expect(rejects(pack(d: "cool-pack", title: "faggotmemes")))
        #expect(rejects(pack(d: "TRANNYPACK")))
    }

    @Test func rejectsBoundedSlurs() {
        #expect(rejects(pack(d: "coon pack")))
        #expect(rejects(pack(d: "memes retard")))
        #expect(rejects(pack(d: "spic")))
    }

    // The reason the ambiguous slurs are boundary-matched. Rejecting these would
    // be its own failure, so they're pinned as keepers.
    @Test func keepsOrdinaryWordsContainingAmbiguousSubstrings() {
        for name in ["Nigeria", "spicy food", "raccoon", "tycoon", "Pakistan",
                     "fire retardant", "cocoon", "chinkapin"] {
            #expect(!rejects(pack(d: name)), "expected \(name) to be kept")
        }
    }

    // Not a word list: a pack isn't rejected for what its shortcodes are called,
    // only for an explicit declaration. Guards against the filter drifting into
    // content policing.
    @Test func doesNotJudgeShortcodes() {
        var tags: [[String]] = [["d", "big-pack"]]
        for i in 0..<12 { tags.append(["emoji", "e\(i)", "https://example.com/e\(i).png"]) }
        tags.append(["emoji", "lewd", "https://example.com/lewd.png"])
        let event = NostrEvent(
            id: "id", pubkey: "author", kind: 30030, createdAt: 0,
            tags: tags, content: "", sig: ""
        )
        #expect(!EmojiPackExploreModel.exploreReject(event: event, pack: EmojiRepository.parsePack(event)!))
    }
}
