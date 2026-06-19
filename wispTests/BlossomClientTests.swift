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

    @Test func normalizeServerURLRemovesMultipleTrailingSlashes() {
        let normalized = BlossomClient.normalizeServerURL("https://server.com///")
        #expect(normalized == "https://server.com")
    }

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
        // Test with valid kind: 24242 JSON strings of varying lengths.
        // The number of bytes in the UTF-8 representation determines padding:
        // - 0 padding when (bytes % 3 == 0)
        // - 2 padding chars when (bytes % 3 == 1)
        // - 1 padding char when (bytes % 3 == 2)

        // 1 padding: 22 bytes -> 22 % 3 = 1 -> 2 padding chars
        let pad2Json = #"{"kind":24242,"t":"a"}"#  // 28 bytes -> 28 % 3 = 1 -> 2 padding chars
        guard let pad2 = pad2Json.data(using: .utf8) else {
            Issue.record("Failed to encode pad2 JSON")
            return
        }
        let header2 = "Nostr \(pad2.base64URLEncodedString())"
        guard let legacy2 = BlossomClient.convertToLegacyBase64Auth(header2) else {
            Issue.record("convertToLegacyBase64Auth returned nil for pad2")
            return
        }
        let decoded2 = Data(base64Encoded: String(legacy2.dropFirst(6)))
        #expect(decoded2 == pad2)

        // 1 padding: 29 bytes -> 29 % 3 = 2 -> 1 padding char
        let pad1Json = #"{"kind":24242,"tt":"a"}"#  // 29 bytes -> 29 % 3 = 2 -> 1 padding char
        guard let pad1 = pad1Json.data(using: .utf8) else {
            Issue.record("Failed to encode pad1 JSON")
            return
        }
        let header1 = "Nostr \(pad1.base64URLEncodedString())"
        guard let legacy1 = BlossomClient.convertToLegacyBase64Auth(header1) else {
            Issue.record("convertToLegacyBase64Auth returned nil for pad1")
            return
        }
        let decoded1 = Data(base64Encoded: String(legacy1.dropFirst(6)))
        #expect(decoded1 == pad1)

        // No padding: 30 bytes -> 30 % 3 = 0 -> no padding chars
        let noPaddingJson = #"{"kind":24242,"ttt":"a"}"#  // 30 bytes -> 30 % 3 = 0 -> no padding
        guard let noPad = noPaddingJson.data(using: .utf8) else {
            Issue.record("Failed to encode noPadding JSON")
            return
        }
        let header0 = "Nostr \(noPad.base64URLEncodedString())"
        guard let legacy0 = BlossomClient.convertToLegacyBase64Auth(header0) else {
            Issue.record("convertToLegacyBase64Auth returned nil for noPadding")
            return
        }
        let decoded0 = Data(base64Encoded: String(legacy0.dropFirst(6)))
        #expect(decoded0 == noPad)
    }

    @Test func convertToLegacyBase64AuthStandardBase64CharsAreDifferent() {
        // Test that convertToLegacyBase64Auth correctly handles Base64URL special characters.
        // Base64URL uses '-' and '_' instead of standard Base64's '+' and '/'.
        // This function should convert them back.
        
        // Create a signed auth event JSON
        let signedEventJson = """
        {
            "id": "abc123",
            "pubkey": "fbefbeff",
            "created_at": 1234567890,
            "kind": 24242,
            "tags": [["t", "upload"]],
            "content": "test",
            "sig": "signature"
        }
        """
        guard let jsonData = signedEventJson.data(using: .utf8) else {
            Issue.record("Failed to encode test JSON")
            return
        }
        
        // Encode to Base64URL
        let bud11Header = "Nostr \(jsonData.base64URLEncodedString())"
        
        // Convert to legacy Base64
        guard let legacyHeader = BlossomClient.convertToLegacyBase64Auth(bud11Header) else {
            Issue.record("convertToLegacyBase64Auth returned nil")
            return
        }
        
        // Extract the Base64 part (after "Nostr ")
        let legacyBase64 = String(legacyHeader.dropFirst(6))
        
        // Verify it can be decoded (which means '-' and '_' were converted to '+' and '/')
        guard let decodedData = Data(base64Encoded: legacyBase64) else {
            Issue.record("Failed to decode legacy Base64 - conversion may have failed")
            return
        }
        
        // Verify the decoded JSON matches the original
        guard let decodedJson = String(data: decodedData, encoding: .utf8) else {
            Issue.record("Failed to decode JSON string")
            return
        }
        
        #expect(decodedJson == signedEventJson, "Roundtrip should preserve JSON")
    }

    // MARK: - convertToLegacyBase64Auth JSON validation

    @Test func convertToLegacyBase64AuthRejectsInvalidJSON() {
        // Garbage data that is not valid JSON should return nil
        let garbageData = Data([0xFF, 0xFE, 0xFD, 0xFC])
        let header = "Nostr \(garbageData.base64EncodedString())"
        let result = BlossomClient.convertToLegacyBase64Auth(header)
        #expect(result == nil)
    }

    @Test func convertToLegacyBase64AuthRejectsJSONWithoutKind() {
        // Valid JSON but missing "kind" field should return nil
        let json = """
        {"id":"abc123","pubkey":"def456","content":"test"}
        """
        guard let jsonData = json.data(using: .utf8) else {
            Issue.record("Failed to create test JSON data")
            return
        }
        let header = "Nostr \(jsonData.base64EncodedString())"
        let result = BlossomClient.convertToLegacyBase64Auth(header)
        #expect(result == nil)
    }

    @Test func convertToLegacyBase64AuthRejectsJSONWithWrongKind() {
        // Valid JSON with "kind" field but wrong value (not 24242) should return nil
        let json = """
        {"kind":1,"id":"abc123","pubkey":"def456","content":"test"}
        """
        guard let jsonData = json.data(using: .utf8) else {
            Issue.record("Failed to create test JSON data")
            return
        }
        let header = "Nostr \(jsonData.base64EncodedString())"
        let result = BlossomClient.convertToLegacyBase64Auth(header)
        #expect(result == nil)
    }

    @Test func convertToLegacyBase64AuthAcceptsValidAuthEvent() {
        // Valid JSON with kind 24242 should return legacy Base64
        let json = """
        {"kind":24242,"id":"abc123","pubkey":"def456","content":"test"}
        """
        guard let jsonData = json.data(using: .utf8) else {
            Issue.record("Failed to create test JSON data")
            return
        }
        let header = "Nostr \(jsonData.base64EncodedString())"
        let result = BlossomClient.convertToLegacyBase64Auth(header)
        #expect(result != nil)
        #expect(result?.hasPrefix("Nostr ") == true)
    }
}
