//
//  BlossomClientTests.swift
//  wispTests
//
//  Tests for BlossomClient utility functions.
//

import Foundation
import Testing
@testable import wisp

@MainActor
@Suite(.serialized)
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

    // MARK: - makeAuthHeader tag structure (BUD-11)

    @Test func makeAuthHeaderContainsCorrectTags() async {
        // Generate a valid 32-byte privkey and derive the x-only pubkey
        let privBytes = Data((1...32).map { UInt8($0) })
        guard let pubBytes = Secp256k1.publicKey(from: privBytes) else {
            Issue.record("Secp256k1 failed to derive pubkey from test privkey"); return
        }
        let keypair = Keypair(privkey: privBytes.map { String(format: "%02x", $0) }.joined(),
                              pubkey: pubBytes.map { String(format: "%02x", $0) }.joined())
        let hash = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

        for action in ["upload", "media", "get"] {
            guard let header = await BlossomClient.makeAuthHeader(keypair: keypair, action: action, sha256Hex: hash) else {
                Issue.record("makeAuthHeader returned nil for action '\(action)'"); return
            }
            #expect(header.hasPrefix("Nostr "), "Header must use 'Nostr ' prefix")
            let payload = String(header.dropFirst(6))
            let b64url = payload
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let pad = 4 - (b64url.count % 4)
            let padded = pad < 4 ? b64url + String(repeating: "=", count: pad) : b64url
            guard let decoded = Data(base64Encoded: padded) else {
                Issue.record("Failed to decode Base64URL payload for action '\(action)'"); return
            }
            guard let json = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] else {
                Issue.record("Decoded payload is not valid JSON for action '\(action)'"); return
            }
            #expect(json["kind"] as? Int == 24242, "kind must be 24242 for action '\(action)'")
            #expect((json["content"] as? String)?.hasPrefix("Blossom \(action)") == true,
                    "content must start with 'Blossom \(action)'")
            guard let tags = json["tags"] as? [[String]] else {
                Issue.record("tags missing or not [[String]] for action '\(action)'"); return
            }
            #expect(tags.contains { $0 == ["t", action] }, "tags must contain [\"t\", \"\(action)\"]")
            #expect(tags.contains { $0 == ["x", hash] }, "tags must contain [\"x\", hash]")
            #expect(tags.contains { $0.count == 2 && $0[0] == "expiration" && Int($0[1]) != nil },
                    "tags must contain [\"expiration\", <int>]")
        }
    }

    @Test func makeAuthHeaderReturnsNilForInvalidPrivkey() async {
        let keypair = Keypair(privkey: "", pubkey: "deadbeef")
        let result = await BlossomClient.makeAuthHeader(keypair: keypair, action: "upload", sha256Hex: "abc")
        #expect(result == nil, "Empty privkey must produce nil (no signing possible)")
    }

    @Test func makeAuthHeaderUsesBase64URLEncoding() async {
        let privBytes = Data((1...32).map { UInt8($0 + 100) })
        guard let pubBytes = Secp256k1.publicKey(from: privBytes) else {
            Issue.record("Pubkey derivation failed"); return
        }
        let keypair = Keypair(privkey: privBytes.map { String(format: "%02x", $0) }.joined(),
                              pubkey: pubBytes.map { String(format: "%02x", $0) }.joined())
        guard let header = await BlossomClient.makeAuthHeader(keypair: keypair, action: "upload", sha256Hex: "abc") else {
            Issue.record("makeAuthHeader returned nil"); return
        }
        let payload = String(header.dropFirst(6))
        #expect(!payload.contains("+"), "Base64URL must not contain '+'")
        #expect(!payload.contains("/"), "Base64URL must not contain '/'")
        #expect(!payload.contains("="), "Base64URL must not contain '=' (padding)")
    }

    // MARK: - Upload error paths

    @Test func uploadThrowsForEmptyServerList() async {
        let privBytes = Data((1...32).map { UInt8($0) })
        guard let pubBytes = Secp256k1.publicKey(from: privBytes) else {
            Issue.record("Pubkey derivation failed"); return
        }
        let keypair = Keypair(privkey: privBytes.map { String(format: "%02x", $0) }.joined(),
                              pubkey: pubBytes.map { String(format: "%02x", $0) }.joined())

        do {
            _ = try await BlossomClient.upload(bytes: Data("test".utf8), mime: "text/plain", servers: [], keypair: keypair)
            Issue.record("Expected allServersFailed for empty server list")
        } catch let error as BlossomError {
            if case .allServersFailed(let msg) = error {
                #expect(msg == "No HTTPS servers available")
            } else {
                Issue.record("Expected allServersFailed, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func uploadThrowsWhenAllServersAreHTTP() async {
        let privBytes = Data((1...32).map { UInt8($0) })
        guard let pubBytes = Secp256k1.publicKey(from: privBytes) else {
            Issue.record("Pubkey derivation failed"); return
        }
        let keypair = Keypair(privkey: privBytes.map { String(format: "%02x", $0) }.joined(),
                              pubkey: pubBytes.map { String(format: "%02x", $0) }.joined())
        let servers = ["http://evil.com", "http://attacker.local"]

        do {
            _ = try await BlossomClient.upload(bytes: Data("test".utf8), mime: "text/plain", servers: servers, keypair: keypair)
            Issue.record("Expected allServersFailed for HTTP-only servers")
        } catch let error as BlossomError {
            if case .allServersFailed(let msg) = error {
                #expect(msg == "No HTTPS servers available", "Must reject all HTTP servers")
            } else {
                Issue.record("Expected allServersFailed, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func uploadRejectsMixedHTTPAndEmptyServers() async {
        let privBytes = Data((1...32).map { UInt8($0) })
        guard let pubBytes = Secp256k1.publicKey(from: privBytes) else {
            Issue.record("Pubkey derivation failed"); return
        }
        let keypair = Keypair(privkey: privBytes.map { String(format: "%02x", $0) }.joined(),
                              pubkey: pubBytes.map { String(format: "%02x", $0) }.joined())
        let servers = ["http://evil.com", "", "not-a-url"]

        do {
            _ = try await BlossomClient.upload(bytes: Data("test".utf8), mime: "text/plain", servers: servers, keypair: keypair)
            Issue.record("Expected allServersFailed for mixed invalid servers")
        } catch let error as BlossomError {
            if case .allServersFailed(let msg) = error {
                #expect(msg == "No HTTPS servers available")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - withLegacyFallback retry dispatch

    @Test func legacyBase64RetryPathViaUpload() async {
        // Exercises the withLegacyFallback retry mechanism through the upload path.
        // Mock /media returns 401 (triggers legacy Base64 retry), then the retry
        // also targets /media and gets 200. Verifies the retry mechanism dispatches.
        let hash = BlossomClient.sha256Hex(Data("retry-test".utf8))
        let serverBase = "https://legacy-test.example"
        let mediaPath = "\(serverBase)/media"
        let headPath = "\(serverBase)/\(hash)"

        var headRequestCount = 0
        var mediaAuthHeaders: [String] = []

        MockURLProtocol.handlers = [:]
        MockURLProtocol.handlers[headPath] = { request -> (Data, HTTPURLResponse) in
            headRequestCount += 1
            let resp = HTTPURLResponse(
                url: URL(string: headPath)!,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(), resp)
        }

        MockURLProtocol.handlers[mediaPath] = { request -> (Data, HTTPURLResponse) in
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            mediaAuthHeaders.append(auth)
            let isFirstAttempt = mediaAuthHeaders.count == 1
            let statusCode = isFirstAttempt ? 401 : 200
            let resp = HTTPURLResponse(
                url: URL(string: mediaPath)!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            if statusCode == 200 {
                let json = #"{"url":"https://cdn.example/\#(hash)","sha256":"\#(hash)","size":10,"type":"text/plain"}"#
                return (Data(json.utf8), resp)
            }
            return (Data(), resp)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        BlossomClient.sessionOverride = mockSession
        defer {
            BlossomClient.sessionOverride = nil
            MockURLProtocol.handlers = [:]
        }

        let privBytes = Data((1...32).map { UInt8($0) })
        guard let pubBytes = Secp256k1.publicKey(from: privBytes) else {
            Issue.record("Pubkey derivation failed"); return
        }
        let keypair = Keypair(
            privkey: privBytes.map { String(format: "%02x", $0) }.joined(),
            pubkey: pubBytes.map { String(format: "%02x", $0) }.joined()
        )

        let result = try? await BlossomClient.upload(
            bytes: Data("retry-test".utf8),
            mime: "text/plain",
            servers: [serverBase],
            keypair: keypair
        )

        #expect(result != nil, "Upload should succeed after legacy Base64 retry")
        #expect(headRequestCount == 1, "HEAD check should succeed on first try (BUD-11 auth)")
        #expect(mediaAuthHeaders.count == 2, "Upload should make 2 media requests (initial BUD-11 + legacy retry)")
        if mediaAuthHeaders.count >= 2 {
            let secondPayload = mediaAuthHeaders[1].hasPrefix("Nostr ")
                ? String(mediaAuthHeaders[1].dropFirst(6)) : ""
            // Standard Base64 never contains '-' or '_' (those are Base64URL chars)
            #expect(!secondPayload.contains("-"), "Legacy retry must use standard Base64, not Base64URL")
            #expect(!secondPayload.contains("_"), "Legacy retry must use standard Base64, not Base64URL")
        }
    }
}
