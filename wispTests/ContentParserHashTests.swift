//
//  ContentParserHashTests.swift
//  wispTests
//
//  Tests for BUD-03 SHA-256 hash extraction from media URLs.
//

import Testing
@testable import wisp

struct ContentParserHashTests {

    @Test func extractsHashFromEndOfPath() {
        let url = "https://example.com/media/423a2423e536349b9adb8eaa1835f230b7a42798c5a181727b1b4601f96e0e91.png"
        let hash = ContentParser.sha256Hash(fromUrl: url)
        #expect(hash == "423a2423e536349b9adb8eaa1835f230b7a42798c5a181727b1b4601f96e0e91")
    }

    @Test func extractsHashWithoutExtension() {
        let url = "https://example.com/media/423a2423e536349b9adb8eaa1835f230b7a42798c5a181727b1b4601f96e0e91"
        let hash = ContentParser.sha256Hash(fromUrl: url)
        #expect(hash == "423a2423e536349b9adb8eaa1835f230b7a42798c5a181727b1b4601f96e0e91")
    }

    @Test func ignoresHashInQueryParameters() {
        // The regex is anchored to the end of the path, so it should ignore query params
        let url = "https://example.com/media/image.png?token=423a2423e536349b9adb8eaa1835f230b7a42798c5a181727b1b4601f96e0e91"
        let hash = ContentParser.sha256Hash(fromUrl: url)
        #expect(hash == nil)
    }

    @Test func ignoresMidPathHexStrings() {
        // Should not match a 64-char hex string that is not at the end of the path
        let url = "https://example.com/423a2423e536349b9adb8eaa1835f230b7a42798c5a181727b1b4601f96e0e91/image.png"
        let hash = ContentParser.sha256Hash(fromUrl: url)
        #expect(hash == nil)
    }

    @Test func returnsNilForNonHexPath() {
        let url = "https://example.com/media/regular-image-name.jpg"
        let hash = ContentParser.sha256Hash(fromUrl: url)
        #expect(hash == nil)
    }

    @Test func handlesTrailingSlashAfterHash() {
        let url = "https://example.com/media/423a2423e536349b9adb8eaa1835f230b7a42798c5a181727b1b4601f96e0e91/"
        let hash = ContentParser.sha256Hash(fromUrl: url)
        #expect(hash == "423a2423e536349b9adb8eaa1835f230b7a42798c5a181727b1b4601f96e0e91")
    }
}
