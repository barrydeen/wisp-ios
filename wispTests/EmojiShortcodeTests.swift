import Foundation
import Testing
@testable import wisp

struct EmojiShortcodeTests {

    // MARK: - detectTrigger

    @Test func triggerAtStartOfText() {
        let r = EmojiShortcode.detectTrigger(in: ":sm", caretUtf16: 3)
        #expect(r?.query == "sm")
        #expect(r?.startUtf16 == 0)
    }

    @Test func triggerAfterSpace() {
        // The regression this fixes: the old composer walk allowed one space and
        // gobbled the preceding word, so `:emoji` mid-message never fired.
        let r = EmojiShortcode.detectTrigger(in: "hi :sm", caretUtf16: 6)
        #expect(r?.query == "sm")
        #expect(r?.startUtf16 == 3)
    }

    @Test func triggerMidText() {
        let r = EmojiShortcode.detectTrigger(in: "a :sm b", caretUtf16: 5)
        #expect(r?.query == "sm")
        #expect(r?.startUtf16 == 2)
    }

    @Test func noTriggerWithoutColon() {
        #expect(EmojiShortcode.detectTrigger(in: "hello", caretUtf16: 5) == nil)
    }

    @Test func noTriggerForBareColon() {
        #expect(EmojiShortcode.detectTrigger(in: ":", caretUtf16: 1) == nil)
    }

    @Test func noTriggerWhenColonNotTokenStart() {
        // e.g. inside a URL scheme — `:` preceded by a letter.
        #expect(EmojiShortcode.detectTrigger(in: "http:", caretUtf16: 5) == nil)
    }

    @Test func noTriggerForCompletedShortcode() {
        #expect(EmojiShortcode.detectTrigger(in: ":fire:", caretUtf16: 6) == nil)
    }

    @Test func noTriggerWhenSpaceFollowsColon() {
        #expect(EmojiShortcode.detectTrigger(in: "a : ", caretUtf16: 4) == nil)
    }

    // MARK: - insert

    @Test func insertReplacesPartialToken() {
        #expect(EmojiShortcode.insert("fire", into: "hey :fi", atUtf16: 4) == "hey :fire: ")
    }

    @Test func insertMidTextKeepsTail() {
        #expect(EmojiShortcode.insert("fire", into: "a :fi b", atUtf16: 2) == "a :fire:  b")
    }

    // MARK: - emojiTags

    @Test func tagsResolvedShortcodes() {
        let map = ["fire": "https://e/fire.png", "wave": "https://e/wave.png"]
        let tags = EmojiShortcode.emojiTags(in: "hi :fire: and :wave:") { map[$0] }
        #expect(tags == [["emoji", "fire", "https://e/fire.png"],
                         ["emoji", "wave", "https://e/wave.png"]])
    }

    @Test func tagsAreDeduped() {
        let map = ["fire": "https://e/fire.png"]
        let tags = EmojiShortcode.emojiTags(in: ":fire: :fire:") { map[$0] }
        #expect(tags == [["emoji", "fire", "https://e/fire.png"]])
    }

    @Test func tagsOmitUnresolved() {
        let map = ["fire": "https://e/fire.png"]
        let tags = EmojiShortcode.emojiTags(in: ":fire: :unknown:") { map[$0] }
        #expect(tags == [["emoji", "fire", "https://e/fire.png"]])
    }

    @Test func tagsEmptyWithoutShortcodes() {
        #expect(EmojiShortcode.emojiTags(in: "just text") { _ in "x" }.isEmpty)
    }
}
