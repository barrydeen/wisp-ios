//
//  ContentParserHashTests.swift
//  wispTests
//
//  Tests for BUD-03 SHA-256 hash extraction from media URLs.
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
}
