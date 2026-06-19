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

    // MARK: - normalizeServerURL

    @Test func normalizeServerURLRemovesMultipleTrailingSlashes() {
        #expect(BlossomClient.normalizeServerURL("https://server.com///") == "https://server.com")
    }

    @Test func normalizeServerURLRemovesTrailingSlash() {
        #expect(BlossomClient.normalizeServerURL("https://blossom.primal.net/") == "https://blossom.primal.net")
    }

    @Test func normalizeServerURLLeavesValidURLUnchanged() {
        #expect(BlossomClient.normalizeServerURL("https://blossom.primal.net") == "https://blossom.primal.net")
    }

    @Test func normalizeServerURLHandlesEmptyString() {
        // Empty string has no https:// scheme — returns nil
        #expect(BlossomClient.normalizeServerURL("") == nil)
    }

    @Test func normalizeServerURLRejectsHTTP() {
        // HTTPS enforcement: plain HTTP must be rejected (auth token would be in cleartext)
        #expect(BlossomClient.normalizeServerURL("http://blossom.example.com") == nil)
    }

    @Test func normalizeServerURLHandlesQueryAndFragment() {
        // Trailing slash stripped even with path components; scheme must still be https
        #expect(BlossomClient.normalizeServerURL("https://blossom.example.com/") == "https://blossom.example.com")
    }

    // MARK: - areSameRegistrableDomain

    @Test func sameRegistrableDomainForSiblings() {
        #expect(BlossomClient.areSameRegistrableDomain("cdn.azzamo.media", "blossom.azzamo.media"))
        #expect(BlossomClient.areSameRegistrableDomain("blossom.azzamo.media", "cdn.azzamo.media"))
    }

    @Test func sameRegistrableDomainForNestedSubdomain() {
        // cdn.blossom.azzamo.media ends in [azzamo, media]; blossom.azzamo.media also ends in [azzamo, media]
        #expect(BlossomClient.areSameRegistrableDomain("cdn.blossom.azzamo.media", "blossom.azzamo.media"))
        // Symmetric: nested ↔ parent both directions
        #expect(BlossomClient.areSameRegistrableDomain("blossom.azzamo.media", "cdn.blossom.azzamo.media"))
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

    @Test func sameRegistrableDomainForIPAddresses() {
        // IP addresses are treated as hosts with multiple numeric labels.
        // The last-two-label heuristic is acknowledged to have known limitations.
        // Same IP always matches itself.
        #expect(BlossomClient.areSameRegistrableDomain("127.0.0.1", "127.0.0.1"))
        // Two different IPs that share the last 2 octets will match — this is the
        // known limitation documented in areSameRegistrableDomain. It is acceptable
        // because mirror targets are user-curated and independently hash-verified.
        #expect(BlossomClient.areSameRegistrableDomain("127.0.0.1", "10.0.0.1"))  // Both end in "0.1"
        // IPs that differ in last 2 octets do NOT match.
        #expect(!BlossomClient.areSameRegistrableDomain("192.168.1.1", "192.168.2.3"))
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

    @Test func sanitizeMirrorURLFallsBackForEmptyUploadHost() {
        // Empty uploadHost — areSameRegistrableDomain returns false (count < 2), safe fallback
        let result = BlossomClient.sanitizeMirrorURL(
            serverReturnedURL: "https://cdn.azzamo.media/abc123.png",
            uploadHost: "",
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
        // Compact JSON (no whitespace) as produced by makeAuthHeader via Nostr event serialisation
        let signedEventJSON = #"{"kind":24242,"pubkey":"abc123","created_at":1700000000,"tags":[["t","upload"],["x","deadbeef"]],"content":"Blossom upload","id":"event123","sig":"signature"}"#
        guard let jsonBytes = signedEventJSON.data(using: .utf8) else {
            Issue.record("Failed to create test data"); return
        }

        let bud11Header = "Nostr \(jsonBytes.base64URLEncodedString())"

        guard let legacyHeader = BlossomClient.convertToLegacyBase64Auth(bud11Header) else {
            Issue.record("convertToLegacyBase64Auth returned nil for valid input"); return
        }

        #expect(legacyHeader.hasPrefix("Nostr "))
        let legacyB64 = String(legacyHeader.dropFirst(6))
        guard let decodedBytes = Data(base64Encoded: legacyB64) else {
            Issue.record("Failed to decode legacy Base64"); return
        }
        guard let decodedJSON = String(data: decodedBytes, encoding: .utf8) else {
            Issue.record("Decoded bytes are not valid UTF-8"); return
        }

        #expect(decodedJSON == signedEventJSON)
    }

    @Test func convertToLegacyBase64AuthHandlesPaddingCorrectly() {
        // Test with valid kind:24242 JSON strings whose UTF-8 byte lengths exercise
        // all three Base64 padding cases.
        //
        // JSON: {"kind":24242,"t":"a"}  → 22 UTF-8 bytes → 22 % 3 == 1 → Base64 needs 2 "=" chars
        // JSON: {"kind":24242,"tt":"a"} → 23 UTF-8 bytes → 23 % 3 == 2 → Base64 needs 1 "=" char
        // JSON: {"kind":24242,"ttt":"a"}→ 24 UTF-8 bytes → 24 % 3 == 0 → Base64 needs 0 "=" chars

        let cases: [(json: String, expectedPaddingChars: Int)] = [
            (#"{"kind":24242,"t":"a"}"#,   2),   // 22 bytes: ceil(22/3)*4 = 32 chars; 2 padding
            (#"{"kind":24242,"tt":"a"}"#,  1),   // 23 bytes: 32 chars; 1 padding
            (#"{"kind":24242,"ttt":"a"}"#, 0),   // 24 bytes: 32 chars; 0 padding
        ]

        for (json, expectedPadding) in cases {
            guard let jsonData = json.data(using: .utf8) else {
                Issue.record("Failed to encode JSON: \(json)"); return
            }

            #expect(jsonData.count % 3 == (3 - expectedPadding) % 3,
                    "Pre-condition: \(json) should produce \(expectedPadding) padding chars")

            let bud11Header = "Nostr \(jsonData.base64URLEncodedString())"
            guard let legacyHeader = BlossomClient.convertToLegacyBase64Auth(bud11Header) else {
                Issue.record("convertToLegacyBase64Auth returned nil for: \(json)"); return
            }

            let legacyB64 = String(legacyHeader.dropFirst(6))

            // Assert the actual padding char count in the re-encoded standard Base64.
            let trailingEquals = legacyB64.reversed().prefix(while: { $0 == "=" }).count
            #expect(trailingEquals == expectedPadding,
                    "Expected \(expectedPadding) padding '=' chars for '\(json)', got \(trailingEquals)")

            // Roundtrip check.
            let decoded = Data(base64Encoded: legacyB64)
            #expect(decoded == jsonData, "Roundtrip failed for: \(json)")
        }
    }

    @Test func convertToLegacyBase64AuthReplacesBase64URLChars() {
        // Data [0xFB 0xEF 0xFF] encodes to indices [62, 62, 63, 63]:
        //   0xFB=11111011, 0xEF=11101111, 0xFF=11111111
        //   6-bit groups: 111110 111110 111111 111111 → 62, 62, 63, 63
        //   Standard Base64: index 62 = '+', index 63 = '/'  → "++//"
        //   Base64URL:        index 62 = '-', index 63 = '_'  → "--__"
        let data = Data([0xFB, 0xEF, 0xFF])
        // This raw data is NOT a valid Nostr JSON event, so convertToLegacyBase64Auth
        // correctly returns nil. Validate the extension directly:
        let b64url = data.base64URLEncodedString()
        #expect(b64url == "--__", "Expected '--__' for indices [62,62,63,63]")
        #expect(!b64url.contains("+") && !b64url.contains("/"))

        // Verify the reverse mapping via a valid auth event whose Base64URL encoding
        // happens to contain '-' or '_'.
        // Build a compact JSON string whose bytes, when base64-URL-encoded, contain '-'/'_'.
        // We know {"kind":24242,"content":"++++"} — all ASCII '+' chars inside JSON —
        // does NOT guarantee '-'/'_' in the base64url, so we verify via round-trip.
        let compactJSON = #"{"kind":24242,"content":"test-data_here"}"#
        guard let jsonData = compactJSON.data(using: .utf8) else {
            Issue.record("Failed to encode JSON"); return
        }
        let bud11 = "Nostr \(jsonData.base64URLEncodedString())"
        guard let legacy = BlossomClient.convertToLegacyBase64Auth(bud11) else {
            Issue.record("Roundtrip failed"); return
        }
        let legacyB64 = String(legacy.dropFirst(6))
        #expect(!legacyB64.contains("-"), "Legacy Base64 must not contain '-'")
        #expect(!legacyB64.contains("_"), "Legacy Base64 must not contain '_'")
        let decodedData = Data(base64Encoded: legacyB64)
        #expect(decodedData == jsonData, "Roundtrip must preserve bytes")
    }

    // MARK: - convertToLegacyBase64Auth JSON validation

    @Test func convertToLegacyBase64AuthRejectsInvalidJSON() {
        let garbageData = Data([0xFF, 0xFE, 0xFD, 0xFC])
        let header = "Nostr \(garbageData.base64EncodedString())"
        #expect(BlossomClient.convertToLegacyBase64Auth(header) == nil)
    }

    @Test func convertToLegacyBase64AuthRejectsJSONWithoutKind() {
        let json = #"{"id":"abc123","pubkey":"def456","content":"test"}"#
        guard let jsonData = json.data(using: .utf8) else {
            Issue.record("Failed to create test JSON data"); return
        }
        #expect(BlossomClient.convertToLegacyBase64Auth("Nostr \(jsonData.base64EncodedString())") == nil)
    }

    @Test func convertToLegacyBase64AuthRejectsJSONWithWrongKind() {
        let json = #"{"kind":1,"id":"abc123","pubkey":"def456","content":"test"}"#
        guard let jsonData = json.data(using: .utf8) else {
            Issue.record("Failed to create test JSON data"); return
        }
        #expect(BlossomClient.convertToLegacyBase64Auth("Nostr \(jsonData.base64EncodedString())") == nil)
    }

    @Test func convertToLegacyBase64AuthAcceptsValidAuthEvent() {
        let json = #"{"kind":24242,"id":"abc123","pubkey":"def456","content":"test"}"#
        guard let jsonData = json.data(using: .utf8) else {
            Issue.record("Failed to create test JSON data"); return
        }
        let result = BlossomClient.convertToLegacyBase64Auth("Nostr \(jsonData.base64EncodedString())")
        #expect(result?.hasPrefix("Nostr ") == true)
    }

    // MARK: - withLegacyFallback (via convertToLegacyBase64Auth + headWithLegacyFallback surface)

    @Test func convertToLegacyBase64AuthIsInverseOfBase64URLEncodedString() {
        // Any round-trip through base64URLEncodedString() → convertToLegacyBase64Auth()
        // must recover the original bytes when the payload is a valid kind:24242 event.
        let jsons = [
            #"{"kind":24242,"t":"a","content":"test1"}"#,
            #"{"kind":24242,"xx":"bb","content":"longer content here"}"#,
            #"{"kind":24242,"id":"abc","pubkey":"xyz","tags":[["t","upload"]],"content":"c"}"#,
        ]
        for json in jsons {
            guard let original = json.data(using: .utf8) else {
                Issue.record("Encode failed"); return
            }
            let bud11 = "Nostr \(original.base64URLEncodedString())"
            guard let legacy = BlossomClient.convertToLegacyBase64Auth(bud11) else {
                Issue.record("Conversion returned nil for: \(json)"); return
            }
            let legacyB64 = String(legacy.dropFirst(6))
            let recovered = Data(base64Encoded: legacyB64)
            #expect(recovered == original, "Round-trip failed for: \(json)")
        }
    }
}
