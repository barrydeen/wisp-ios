import Foundation
import Testing
@testable import wisp

/// Covers `EmojiRepository.parsePack` — the shared kind-30030 reader behind the
/// pack cards (discovery feed, `naddr` note content, and the subscribed-pack
/// list in settings), so a malformed pack can't reach the UI as a half-rendered
/// card.
@MainActor
struct EmojiPackTests {

    private func event(
        pubkey: String = String(repeating: "a", count: 64),
        kind: Int = 30030,
        createdAt: Int = 1_700_000_000,
        tags: [[String]]
    ) -> NostrEvent {
        NostrEvent(
            id: String(repeating: "b", count: 64),
            pubkey: pubkey,
            kind: kind,
            createdAt: createdAt,
            tags: tags,
            content: "",
            sig: ""
        )
    }

    @Test func parsesTitleEmojisAndAddress() {
        let pk = String(repeating: "a", count: 64)
        let pack = EmojiRepository.parsePack(event(tags: [
            ["d", "my-pack"],
            ["title", "My Pack"],
            ["emoji", "pepe", "https://example.com/pepe.png"],
            ["emoji", "wojak", "https://example.com/wojak.png"]
        ]))

        #expect(pack?.address == "30030:\(pk):my-pack")
        #expect(pack?.dTag == "my-pack")
        #expect(pack?.title == "My Pack")
        #expect(pack?.emojis.count == 2)
        #expect(pack?.emojis.first?.shortcode == "pepe")
        #expect(pack?.emojis.first?.url == "https://example.com/pepe.png")
    }

    @Test func rejectsNonEmojiSetKinds() {
        // A card must never render for, say, a long-form article naddr that
        // happened to route through the 30030 branch.
        #expect(EmojiRepository.parsePack(event(kind: 30023, tags: [["d", "x"]])) == nil)
    }

    @Test func rejectsMissingDTag() {
        // Without a `d` tag there is no replaceable coordinate to subscribe to.
        #expect(EmojiRepository.parsePack(event(tags: [
            ["title", "No d tag"],
            ["emoji", "pepe", "https://example.com/pepe.png"]
        ])) == nil)
    }

    @Test func titleIsOptional() {
        let pack = EmojiRepository.parsePack(event(tags: [
            ["d", "untitled"],
            ["emoji", "pepe", "https://example.com/pepe.png"]
        ]))
        #expect(pack != nil)
        #expect(pack?.title == nil)
    }

    @Test func skipsMalformedAndDuplicateEmojiTags() {
        let pack = EmojiRepository.parsePack(event(tags: [
            ["d", "messy"],
            ["emoji", "pepe", "https://example.com/pepe.png"],
            ["emoji", "pepe", "https://example.com/other.png"],  // duplicate shortcode
            ["emoji", "noUrl"],                                   // too few fields
            ["emoji", "", "https://example.com/blank.png"],       // empty shortcode
            ["emoji", "empty", ""]                                // empty url
        ]))

        #expect(pack?.emojis.count == 1)
        // First writer wins on a duplicate shortcode.
        #expect(pack?.emojis.first?.url == "https://example.com/pepe.png")
    }

    @Test func emptyPackParsesButHasNoEmojis() {
        // Parsing succeeds; the discovery feed is what filters these out, so
        // an empty pack the user already subscribed to still renders its title.
        let pack = EmojiRepository.parsePack(event(tags: [["d", "empty"], ["title", "Empty"]]))
        #expect(pack != nil)
        #expect(pack?.emojis.isEmpty == true)
    }
}
