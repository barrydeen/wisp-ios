//
//  ZapCommentImageTests.swift
//  wispTests
//
//  Coverage for the zap-comment image split used by the note details drawer:
//  an image URL in a zap comment renders as an image, and the one-line pill
//  falls back to an `[image]` marker instead of a truncated URL.
//

import Testing
@testable import wisp

struct ZapCommentImageTests {

    @Test func imageOnlyCommentLeavesNoText() {
        let (text, images) = ContentParser.splitImages(from: "https://i.example.com/zombie.jpg")
        #expect(text.isEmpty)
        #expect(images.map(\.url) == ["https://i.example.com/zombie.jpg"])
    }

    @Test func textSurvivesAlongsideTheImage() {
        let (text, images) = ContentParser.splitImages(
            from: "that a lotta zombies https://i.example.com/zombie.jpg"
        )
        #expect(text == "that a lotta zombies")
        #expect(images.count == 1)
    }

    // Newlines collapse to spaces so a multi-line comment still fits the
    // drawer row's two-line label without a dangling blank line.
    @Test func whitespaceAroundTheStrippedUrlCollapses() {
        let (text, _) = ContentParser.splitImages(
            from: "nice one\n\nhttps://i.example.com/pic.png\n"
        )
        #expect(text == "nice one")
    }

    @Test func multipleImagesAreExtractedInOrderAndDeduped() {
        let (text, images) = ContentParser.splitImages(
            from: "https://i.example.com/a.png https://i.example.com/b.gif https://i.example.com/a.png"
        )
        #expect(text.isEmpty)
        #expect(images.map(\.url) == ["https://i.example.com/a.png", "https://i.example.com/b.gif"])
    }

    @Test func plainCommentIsUntouched() {
        let (text, images) = ContentParser.splitImages(from: "  thanks for this  ")
        #expect(text == "thanks for this")
        #expect(images.isEmpty)
    }

    // A non-media link is still a link — it stays in the text rather than
    // being swallowed as an image.
    @Test func nonImageLinkStaysInTheText() {
        let (text, images) = ContentParser.splitImages(from: "see https://example.com/article")
        #expect(text == "see https://example.com/article")
        #expect(images.isEmpty)
    }

    // An extension-less Blossom URL carries no file type in the string, and
    // the feed already renders that segment as an image — so does the drawer.
    @Test func extensionlessBlossomUrlCountsAsAnImage() {
        let hash = "423a2423e536349b9adb8eaa1835f230b7a42798c5a181727b1b4601f96e0e91"
        let (text, images) = ContentParser.splitImages(from: "https://blossom.example.com/\(hash)")
        #expect(text.isEmpty)
        #expect(images.count == 1)
    }

    @Test func compactMarkersReplaceImageUrls() {
        #expect(ContentParser.compactImageMarkers("https://i.example.com/zombie.jpg") == "[image]")
        #expect(
            ContentParser.compactImageMarkers("dead https://i.example.com/zombie.jpg") == "dead [image]"
        )
        #expect(
            ContentParser.compactImageMarkers("https://i.example.com/a.png https://i.example.com/b.png")
                == "[image] [image]"
        )
    }

    @Test func compactMarkersLeavePlainTextAlone() {
        #expect(ContentParser.compactImageMarkers("stack sats") == "stack sats")
        #expect(ContentParser.compactImageMarkers("") == "")
    }
}
