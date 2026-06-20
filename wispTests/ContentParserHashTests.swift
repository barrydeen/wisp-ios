//
//  ContentParserHashTests.swift
//  wispTests
//
//  Tests for BUD-01 Blossom URL classification and SHA-256 hash extraction
//  from media URLs (used by BUD-03 fallback fetching).
//

import Testing
@testable import wisp

struct ContentParserHashTests {

    private let hash = "423a2423e536349b9adb8eaa1835f230b7a42798c5a181727b1b4601f96e0e91"

    @Test func extractsHashFromEndOfPath() {
        let url = "https://example.com/media/\(hash).png"
        #expect(ContentParser.sha256Hash(fromUrl: url) == hash)
    }

    @Test func extractsHashWithoutExtension() {
        #expect(ContentParser.sha256Hash(fromUrl: "https://example.com/media/\(hash)") == hash)
    }

    @Test func ignoresHashInQueryParameters() {
        // Regex is anchored to the path end; query params must be ignored.
        let url = "https://example.com/media/image.png?token=\(hash)"
        #expect(ContentParser.sha256Hash(fromUrl: url) == nil)
    }

    @Test func ignoresMidPathHexStrings() {
        // Hash in a non-terminal path segment should not be extracted.
        let url = "https://example.com/\(hash)/image.png"
        #expect(ContentParser.sha256Hash(fromUrl: url) == nil)
    }

    @Test func returnsNilForNonHexPath() {
        #expect(ContentParser.sha256Hash(fromUrl: "https://example.com/media/regular-image-name.jpg") == nil)
    }

    @Test func handlesTrailingSlashAfterHash() {
        let url = "https://example.com/media/\(hash)/"
        #expect(ContentParser.sha256Hash(fromUrl: url) == hash)
    }

    @Test func handlesURLWithPort() {
        // URL.path strips scheme/host/port; regex should match correctly.
        let url = "https://server.com:8080/\(hash).png"
        #expect(ContentParser.sha256Hash(fromUrl: url) == hash)
    }

    @Test func handlesFragmentAfterHash() {
        // URL.path strips the fragment; the hash at path end should be found.
        let url = "https://example.com/\(hash)#section"
        #expect(ContentParser.sha256Hash(fromUrl: url) == hash)
    }

    @Test func returnsNilForInvalidURL() {
        #expect(ContentParser.sha256Hash(fromUrl: "not a url") == nil)
    }

    @Test func extractsHashWithNumericExtension() {
        let url = "https://example.com/\(hash).123"
        #expect(ContentParser.sha256Hash(fromUrl: url) == hash)
    }

    @Test func classifiesBlossomUrlWithoutExtensionAsUnknownMedia() {
        let url = "https://blossom.example.com/\(hash)"
        let segments = ContentParser.parse(content: url, tags: [])
        #expect(segments.count == 1)
        if case .unknownMedia(let meta) = segments.first {
            #expect(meta.url == url)
        } else {
            Issue.record("Expected .unknownMedia for Blossom URL without extension, got \(String(describing: segments.first))")
        }
    }

    @Test func doesNotExtractHashFromNonBlossomUrlDuringDedup() {
        // A regular link whose last path component happens to be 64 hex chars
        // should not be treated as content-addressed during imeta dedup.
        let hashPath = "https://blog.example.com/posts/\(hash)"
        let imetaUrl = "https://blossom.example.com/\(hash).png"
        let tags: [[String]] = [
            ["imeta", "url \(imetaUrl)", "x \(hash)", "m image/png"]
        ]
        let segments = ContentParser.parse(content: hashPath, tags: tags)
        // The imeta URL should still be appended as a media segment because the
        // non-Blossom link did not produce a conflicting hash in the dedup set.
        let hasImeta = segments.contains { seg in
            if case .image(let meta) = seg, meta.url == imetaUrl { return true }
            return false
        }
        #expect(hasImeta, "imeta Blossom mirror should not be deduplicated against a non-Blossom hex path")
    }
}
