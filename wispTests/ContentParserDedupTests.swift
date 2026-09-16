//
//  ContentParserDedupTests.swift
//  wispTests
//
//  Regression coverage for content-addressed media de-duplication: the same
//  file served from two different hosts (a Blossom mirror in `content` plus a
//  different host in the imeta tag) must render once, not twice.
//

import Testing
@testable import wisp

struct ContentParserDedupTests {

    private func imageCount(_ segments: [ContentSegment]) -> Int {
        segments.reduce(into: 0) { count, seg in
            if case .image = seg { count += 1 }
        }
    }

    // The bug: an imeta URL on one host plus a Blossom URL in `content` on a
    // different host point to the same SHA-256, but the URL strings differ, so
    // the old URL-only dedup appended the imeta copy as a second image.
    @Test func sameFileDifferentHostsRendersOnce() {
        let hash = "423a2423e536349b9adb8eaa1835f230b7a42798c5a181727b1b4601f96e0e91"
        let content = "Shot of the night.\nhttps://npub1example.blossom.band/\(hash).png"
        let tags: [[String]] = [[
            "imeta",
            "url https://i.nostr.build/aZ2U6GKBPOMT9l96.png",
            "ox \(hash)",
            "x \(hash)",
            "m image/png",
        ]]

        let segments = ContentParser.parse(content: content, tags: tags)
        #expect(imageCount(segments) == 1)
    }

    // The hard real-world case: content carries a random-named nostr.build URL
    // while the imeta tag carries the publishing client's digest-named Blossom
    // mirror — and the imeta has NO `x`/`ox` field, so no hash can link the
    // two. Once content rendered media, an unmatched imeta URL must be treated
    // as a mirror (metadata only), not appended as a second image.
    @Test func contentMediaPlusUnlinkedImetaMirrorRendersOnce() {
        let content = "Who wants noffers? 😎\nhttps://i.nostr.build/YHWpEH3SP1BHeftw.jpg"
        let tags: [[String]] = [[
            "imeta",
            "url https://npub1example.blossom.band/3d2bb19554c6dc277ff51901d8180b10d66c80a3ad90771c4c7acce60b8b2bfd.jpg",
            "m image/jpeg",
            "thumbhash xwcCBwB4aGeAd3eSeHZ3SHh2eDMHaI8L",
            "dim 591x591",
        ]]

        let segments = ContentParser.parse(content: content, tags: tags)
        #expect(imageCount(segments) == 1)
    }

    // The imeta tag's `x`/`ox` is compared case-insensitively against the hash
    // embedded in the content URL's filename.
    @Test func hashMatchIsCaseInsensitive() {
        let lower = "423a2423e536349b9adb8eaa1835f230b7a42798c5a181727b1b4601f96e0e91"
        let upper = lower.uppercased()
        let content = "gm\nhttps://cdn.example.com/\(upper).jpg"
        let tags: [[String]] = [[
            "imeta",
            "url https://other.example.com/photo.jpg",
            "x \(lower)",
            "m image/jpeg",
        ]]

        let segments = ContentParser.parse(content: content, tags: tags)
        #expect(imageCount(segments) == 1)
    }

    // Two imeta tags that are mirrors of the same file (same hash) should also
    // collapse to a single image for a gallery-style post with no URL in body.
    @Test func mirroredImetaTagsRenderOnce() {
        let hash = "423a2423e536349b9adb8eaa1835f230b7a42798c5a181727b1b4601f96e0e91"
        let content = "Gallery caption with no inline URLs"
        let tags: [[String]] = [
            ["imeta", "url https://host-a.example.com/pic.png", "x \(hash)", "m image/png"],
            ["imeta", "url https://host-b.example.com/pic.png", "x \(hash)", "m image/png"],
        ]

        let segments = ContentParser.parse(content: content, tags: tags)
        #expect(imageCount(segments) == 1)
    }

    // Genuinely different images (distinct hashes) must still both render.
    @Test func distinctImagesAllRender() {
        let hashA = "1111111111111111111111111111111111111111111111111111111111111111"
        let hashB = "2222222222222222222222222222222222222222222222222222222222222222"
        let content = "Two shots"
        let tags: [[String]] = [
            ["imeta", "url https://host.example.com/a.png", "x \(hashA)", "m image/png"],
            ["imeta", "url https://host.example.com/b.png", "x \(hashB)", "m image/png"],
        ]

        let segments = ContentParser.parse(content: content, tags: tags)
        #expect(imageCount(segments) == 2)
    }

    // A gallery post whose media lives only in imeta tags (no URL in `content`)
    // must still surface the image — dedup must not drop legitimate entries.
    @Test func imetaOnlyGalleryStillRenders() {
        let content = "Just a caption"
        let tags: [[String]] = [[
            "imeta",
            "url https://i.nostr.build/onlyhere.png",
            "m image/png",
        ]]

        let segments = ContentParser.parse(content: content, tags: tags)
        #expect(imageCount(segments) == 1)
    }
}
