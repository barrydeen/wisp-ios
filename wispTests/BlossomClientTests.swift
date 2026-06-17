//
//  BlossomClientTests.swift
//  wispTests
//
//  Tests for BlossomClient utility functions.
//

import Foundation
import Testing
@testable import wisp

struct BlossomClientTests {

    @Test func normalizeServerURLRemovesTrailingSlash() {
        let normalized = BlossomClient.normalizeServerURL("https://blossom.primal.net/")
        #expect(normalized == "https://blossom.primal.net")
    }

    @Test func normalizeServerURLLeavesValidURLUnchanged() {
        let normalized = BlossomClient.normalizeServerURL("https://blossom.primal.net")
        #expect(normalized == "https://blossom.primal.net")
    }

    @Test func normalizeServerURLHandlesEmptyString() {
        let normalized = BlossomClient.normalizeServerURL("")
        #expect(normalized == "")
    }

    // MARK: - areSameRegistrableDomain

    @Test func sameRegistrableDomainForSiblings() {
        #expect(BlossomClient.areSameRegistrableDomain("cdn.azzamo.media", "blossom.azzamo.media"))
        #expect(BlossomClient.areSameRegistrableDomain("blossom.azzamo.media", "cdn.azzamo.media"))
    }

    @Test func sameRegistrableDomainForNestedSubdomain() {
        #expect(BlossomClient.areSameRegistrableDomain("cdn.blossom.azzamo.media", "blossom.azzamo.media"))
    }

    @Test func sameRegistrableDomainForIdenticalHost() {
        #expect(BlossomClient.areSameRegistrableDomain("blossom.azzamo.media", "blossom.azzamo.media"))
    }

    @Test func sameRegistrableDomainFalseForDifferentDomains() {
        #expect(!BlossomClient.areSameRegistrableDomain("cdn.blossom.media", "blossom.azzamo.media"))
        #expect(!BlossomClient.areSameRegistrableDomain("evil.com", "blossom.azzamo.media"))
        #expect(!BlossomClient.areSameRegistrableDomain("a.example.com", "b.other.com"))
    }

    @Test func sameRegistrableDomainFalseForShortHosts() {
        #expect(!BlossomClient.areSameRegistrableDomain("media", "azzamo.media"))
        #expect(!BlossomClient.areSameRegistrableDomain("foo", "bar"))
    }

    @Test func sameRegistrableDomainCaseInsensitive() {
        #expect(BlossomClient.areSameRegistrableDomain("CDN.Azzamo.MEDIA", "blossom.azzamo.media"))
    }

    // MARK: - sanitizeMirrorURL

    @Test func sanitizeMirrorURLAcceptsSameHost() {
        let result = BlossomClient.sanitizeMirrorURL(
            serverReturnedURL: "https://blossom.azzamo.media/abc123.png",
            uploadHost: "blossom.azzamo.media",
            fallbackURL: "https://blossom.azzamo.media/abc123"
        )
        #expect(result == "https://blossom.azzamo.media/abc123.png")
    }

    @Test func sanitizeMirrorURLAcceptsCdnSiblingSubdomain() {
        let result = BlossomClient.sanitizeMirrorURL(
            serverReturnedURL: "https://cdn.azzamo.media/abc123.png",
            uploadHost: "blossom.azzamo.media",
            fallbackURL: "https://blossom.azzamo.media/abc123"
        )
        #expect(result == "https://cdn.azzamo.media/abc123.png")
    }

    @Test func sanitizeMirrorURLAcceptsNestedCdnSibling() {
        let result = BlossomClient.sanitizeMirrorURL(
            serverReturnedURL: "https://cdn.blossom.azzamo.media/abc123.png",
            uploadHost: "blossom.azzamo.media",
            fallbackURL: "https://blossom.azzamo.media/abc123"
        )
        #expect(result == "https://cdn.blossom.azzamo.media/abc123.png")
    }

    @Test func sanitizeMirrorURLFallsBackForUnrelatedHost() {
        let result = BlossomClient.sanitizeMirrorURL(
            serverReturnedURL: "https://evil.com/abc123.png",
            uploadHost: "blossom.azzamo.media",
            fallbackURL: "https://blossom.azzamo.media/abc123"
        )
        #expect(result == "https://blossom.azzamo.media/abc123")
    }

    @Test func sanitizeMirrorURLFallsBackForDifferentBaseDomain() {
        let result = BlossomClient.sanitizeMirrorURL(
            serverReturnedURL: "https://cdn.blossom.media/abc123.png",
            uploadHost: "blossom.azzamo.media",
            fallbackURL: "https://blossom.azzamo.media/abc123"
        )
        #expect(result == "https://blossom.azzamo.media/abc123")
    }

    @Test func sanitizeMirrorURLFallsBackForMalformedURL() {
        let result = BlossomClient.sanitizeMirrorURL(
            serverReturnedURL: "not a real url",
            uploadHost: "blossom.azzamo.media",
            fallbackURL: "https://blossom.azzamo.media/abc123"
        )
        #expect(result == "https://blossom.azzamo.media/abc123")
    }

    // MARK: - convertToLegacyBase64Auth

    @Test func convertToLegacyBase64AuthReturnsNilForNonNostrHeader() {
        #expect(BlossomClient.convertToLegacyBase64Auth("Bearer abc123") == nil)
        #expect(BlossomClient.convertToLegacyBase64Auth("") == nil)
    }

    @Test func convertToLegacyBase64AuthRoundtripPreservesSignedEventJSON() {
        // Simulate a signed event JSON that would be Base64URL-encoded by makeAuthHeader.
        let signedEventJSON = #"{"kind":24242,"pubkey":"abc123","created_at":1700000000,"tags":[["t","upload"],["x","deadbeef"]],"content":"Blossom upload","id":"event123","sig":"signature"}"#
        guard let jsonBytes = signedEventJSON.data(using: .utf8) else {
            Issue.record("Failed to create test data")
            return
        }

        // Simulate BUD-11 encoding (Base64URL without padding).
        let bud11Encoded = jsonBytes.base64URLEncodedString()
        let bud11Header = "Nostr \(bud11Encoded)"

        // Convert back to standard Base64 (legacy encoding).
        guard let legacyHeader = BlossomClient.convertToLegacyBase64Auth(bud11Header) else {
            Issue.record("convertToLegacyBase64Auth returned nil for valid input")
            return
        }

        // Decode the legacy Base64 header.
        #expect(legacyHeader.hasPrefix("Nostr "))
        let legacyB64 = String(legacyHeader.dropFirst(6))
        guard let decodedBytes = Data(base64Encoded: legacyB64) else {
            Issue.record("Failed to decode legacy Base64")
            return
        }

        // The decoded bytes should match the original signed event JSON exactly.
        guard let decodedJSON = String(data: decodedBytes, encoding: .utf8) else {
            Issue.record("Decoded bytes are not valid UTF-8")
            return
        }

        #expect(decodedJSON == signedEventJSON)
    }

    @Test func convertToLegacyBase64AuthHandlesPaddingCorrectly() {
        // Input data whose standard Base64 requires 0, 1, or 2 padding chars.
        // 3 bytes → 4 Base64 chars (no padding)
        let noPadding = Data([0x01, 0x02, 0x03])
        let header0 = "Nostr \(noPadding.base64URLEncodedString())"
        if let legacy0 = BlossomClient.convertToLegacyBase64Auth(header0) {
            let decoded0 = Data(base64Encoded: String(legacy0.dropFirst(6)))
            #expect(decoded0 == noPadding)
        }

        // 1 byte → 2 Base64 chars + 2 padding
        let pad2 = Data([0xFF])
        let header2 = "Nostr \(pad2.base64URLEncodedString())"
        if let legacy2 = BlossomClient.convertToLegacyBase64Auth(header2) {
            let decoded2 = Data(base64Encoded: String(legacy2.dropFirst(6)))
            #expect(decoded2 == pad2)
        }

        // 2 bytes → 3 Base64 chars + 1 padding
        let pad1 = Data([0xAB, 0xCD])
        let header1 = "Nostr \(pad1.base64URLEncodedString())"
        if let legacy1 = BlossomClient.convertToLegacyBase64Auth(header1) {
            let decoded1 = Data(base64Encoded: String(legacy1.dropFirst(6)))
            #expect(decoded1 == pad1)
        }
    }

    @Test func convertToLegacyBase64AuthUsesStandardBase64Chars() {
        // Data that produces only '-' in Base64URL (index 62 = '-').
        // 0xFB 0xEF 0xBE → four identical 6-bit groups of value 62.
        let data = Data([0xFB, 0xEF, 0xBE])
        let header = "Nostr \(data.base64URLEncodedString())"

        // Verify the Base64URL encoding uses '-' for index 62.
        #expect(header.dropFirst(6).contains("-") || header.dropFirst(6).contains("_"))

        guard let legacy = BlossomClient.convertToLegacyBase64Auth(header) else {
            Issue.record("convertToLegacyBase64Auth returned nil")
            return
        }
        let legacyB64 = String(legacy.dropFirst(6))

        // Legacy encoding must use standard Base64 chars only ('+' and '/', no '-' or '_').
        #expect(!legacyB64.contains("-"))
        #expect(!legacyB64.contains("_"))

        // Roundtrip: legacy Base64 must decode to original bytes.
        let decoded = Data(base64Encoded: legacyB64)
        #expect(decoded == data)
    }
}
