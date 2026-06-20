//
//  BlossomClientTests.swift
//  wispTests
//
//  Tests for BlossomClient utility functions.
//

import Foundation
import Testing
@testable import wisp

private struct ValidAuthEvent {
    let json: String
    let kind: Int
    let pubkey: String
    let createdAt: Int
    let content: String
    let tags: [[String]]
    let id: String
}

private func makeValidAuthEvent(
    kind: Int = 24242,
    pubkey: String = "abc123def456",
    createdAt: Int = 1700000000,
    tags: [[String]] = [["t", "upload"], ["x", "deadbeef"]],
    content: String = "Blossom upload",
    sig: String = String(repeating: "a", count: 128)
) -> ValidAuthEvent {
    let id = NostrEvent.computeId(pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content)
    let tagsJSON = tags.map { "[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" }.joined(separator: ",")
    let json = """
    {"id":"\(id)","pubkey":"\(pubkey)","created_at":\(createdAt),"kind":\(kind),"tags":[\(tagsJSON)],"content":"\(content)","sig":"\(sig)"}
    """
    let compactJSON = json.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "    ", with: "")
    return ValidAuthEvent(json: compactJSON, kind: kind, pubkey: pubkey, createdAt: createdAt, content: content, tags: tags, id: id)
}

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

    @Test func normalizeServerURLStripsTrailingSlashFromOrigin() {
        #expect(BlossomClient.normalizeServerURL("https://blossom.example.com/") == "https://blossom.example.com")
    }

    @Test func normalizeServerURLPreservesPathButStripsQueryAndFragment() {
        // Path is preserved (users with path-prefixed kind-10063 entries keep working).
        // Query and fragment are stripped (not meaningful for Blossom endpoints).
        #expect(BlossomClient.normalizeServerURL("https://blossom.example.com/path?x=1#frag") == "https://blossom.example.com/path")
    }

    @Test func normalizeServerURLPreservesUppercasePath() {
        // Host is lowercased; the path case is preserved.
        #expect(BlossomClient.normalizeServerURL("https://Blossom.Example.com/CAPS") == "https://blossom.example.com/CAPS")
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
        // IP addresses must match exactly; two different IPs are never considered
        // the same domain, even when their last two octets happen to match.
        #expect(BlossomClient.areSameRegistrableDomain("127.0.0.1", "127.0.0.1"))
        #expect(!BlossomClient.areSameRegistrableDomain("127.0.0.1", "10.0.0.1"))
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
        let event = makeValidAuthEvent()
        guard let jsonBytes = event.json.data(using: .utf8) else {
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

        #expect(decodedJSON == event.json)
    }

    @Test func convertToLegacyBase64AuthHandlesPaddingCorrectly() {
        // Generate valid events with content strings of different lengths so their
        // UTF-8 serialisation exercises all three Base64 padding cases (0, 1, 2 padding).
        let contents = ["aaa", "aaab", "aaabb"]
        for content in contents {
            let event = makeValidAuthEvent(content: content)
            guard let jsonData = event.json.data(using: .utf8) else {
                Issue.record("Failed to encode JSON: \(event.json)"); return
            }

            let bud11Header = "Nostr \(jsonData.base64URLEncodedString())"
            guard let legacyHeader = BlossomClient.convertToLegacyBase64Auth(bud11Header) else {
                Issue.record("convertToLegacyBase64Auth returned nil for: \(content)"); return
            }

            let legacyB64 = String(legacyHeader.dropFirst(6))

            // Roundtrip check.
            let decoded = Data(base64Encoded: legacyB64)
            #expect(decoded == jsonData, "Roundtrip failed for content: \(content)")
        }
    }

@Test func convertToLegacyBase64AuthReplacesBase64URLChars() {
        let event = makeValidAuthEvent(content: "test-data_here")
        guard let jsonData = event.json.data(using: .utf8) else {
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
        let event = makeValidAuthEvent()
        guard let jsonData = event.json.data(using: .utf8) else {
            Issue.record("Failed to create test JSON data"); return
        }
        let result = BlossomClient.convertToLegacyBase64Auth("Nostr \(jsonData.base64EncodedString())")
        #expect(result?.hasPrefix("Nostr ") == true)
    }

    @Test func convertToLegacyBase64AuthAcceptsGetAuthEvent() {
        let event = makeValidAuthEvent(kind: 24243, tags: [["t", "get"]], content: "Blossom get")
        guard let jsonData = event.json.data(using: .utf8) else {
            Issue.record("Failed to create test JSON data"); return
        }
        let result = BlossomClient.convertToLegacyBase64Auth("Nostr \(jsonData.base64EncodedString())")
        #expect(result?.hasPrefix("Nostr ") == true)
        if let result {
            let payload = String(result.dropFirst(6))
            #expect(!payload.contains("-"), "Legacy re-encode must use standard Base64, not Base64URL")
            #expect(!payload.contains("_"), "Legacy re-encode must use standard Base64, not Base64URL")
        }
    }

    // MARK: - withLegacyFallback (via convertToLegacyBase64Auth + headWithLegacyFallback surface)

@Test func convertToLegacyBase64AuthIsInverseOfBase64URLEncodedString() {
        // Any round-trip through base64URLEncodedString() → convertToLegacyBase64Auth()
        // must recover the original bytes when the payload is a valid auth event.
        let events = [
            makeValidAuthEvent(tags: [["t", "upload"]], content: "test1"),
            makeValidAuthEvent(tags: [["t", "media"]], content: "longer content here"),
            makeValidAuthEvent(tags: [["t", "get"], ["x", "abc"]], content: "c"),
        ]
        for event in events {
            guard let original = event.json.data(using: .utf8) else {
                Issue.record("Encode failed"); return
            }
            let bud11 = "Nostr \(original.base64URLEncodedString())"
            guard let legacy = BlossomClient.convertToLegacyBase64Auth(bud11) else {
                Issue.record("Conversion returned nil for: \(event.json)"); return
            }
            let legacyB64 = String(legacy.dropFirst(6))
            let recovered = Data(base64Encoded: legacyB64)
            #expect(recovered == original, "Round-trip failed for: \(event.json)")
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
            let expectedKind = action == "get" ? 24243 : 24242
            #expect(json["kind"] as? Int == expectedKind, "kind must be \(expectedKind) for action '\(action)'")
            #expect((json["content"] as? String)?.hasPrefix("Blossom \(action)") == true,
                    "content must start with 'Blossom \(action)'")
            guard let tags = json["tags"] as? [[String]] else {
                Issue.record("tags missing or not [[String]] for action '\(action)'"); return
            }
            #expect(tags.contains { $0 == ["t", action] }, "tags must contain [\"t\", \"\(action)\"]")
            #expect(tags.contains { $0 == ["x", hash] }, "tags must contain [\"x\", hash]")
            #expect(tags.contains { $0.count == 2 && $0[0] == "expiration" && Int($0[1]) != nil },
                    "tags must contain [\"expiration\", <int>]")
            // Signature must be a non-empty 128-character hex string (64-byte Schnorr sig).
            if let sig = json["sig"] as? String {
                #expect(sig.count == 128, "sig must be 64-byte hex")
                #expect(sig.allSatisfy { $0.isHexDigit }, "sig must be hex")
            } else {
                Issue.record("sig missing from auth event for action '\(action)'")
            }
            if let id = json["id"] as? String {
                #expect(id.count == 64, "id must be 32-byte hex")
                #expect(id.allSatisfy { $0.isHexDigit }, "id must be hex")
            } else {
                Issue.record("id missing from auth event for action '\(action)'")
            }
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
            } else {
                Issue.record("Expected allServersFailed, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - withLegacyFallback retry dispatch

    @Test func legacyBase64RetryPathViaUpload() async {
        MockURLProtocol.removeAllHandlers()
        let hash = BlossomClient.sha256Hex(Data("retry-test".utf8))
        let serverBase = "https://legacy-test.example"
        let mediaPath = "\(serverBase)/media"
        let headPath = "\(serverBase)/\(hash)"

        let countersLock = NSLock()
        var headRequestCount = 0
        var mediaAuthHeaders: [String] = []

        
        MockURLProtocol.setHandler(for: headPath) { request -> (Data, HTTPURLResponse) in
            countersLock.lock()
            headRequestCount += 1
            countersLock.unlock()
            let resp = HTTPURLResponse(
                url: URL(string: headPath)!,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(), resp)
        }

        MockURLProtocol.setHandler(for: mediaPath) { request -> (Data, HTTPURLResponse) in
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            countersLock.lock()
            mediaAuthHeaders.append(auth)
            let isFirstAttempt = mediaAuthHeaders.count == 1
            countersLock.unlock()
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
        #expect(headRequestCount == 1, "HEAD check should run once")
        #expect(mediaAuthHeaders.count == 2, "Upload should make 2 media requests (initial BUD-11 + legacy retry)")
        if mediaAuthHeaders.count >= 1 {
            let firstPayload = mediaAuthHeaders[0].hasPrefix("Nostr ")
                ? String(mediaAuthHeaders[0].dropFirst(6)) : ""
            #expect(!firstPayload.contains("+"), "First attempt must use Base64URL, not standard Base64")
            #expect(!firstPayload.contains("/"), "First attempt must use Base64URL, not standard Base64")
            #expect(!firstPayload.contains("="), "Base64URL must omit padding")
        }
        if mediaAuthHeaders.count >= 2 {
            let secondPayload = mediaAuthHeaders[1].hasPrefix("Nostr ")
                ? String(mediaAuthHeaders[1].dropFirst(6)) : ""
            #expect(!secondPayload.contains("-"), "Legacy retry must use standard Base64, not Base64URL")
            #expect(!secondPayload.contains("_"), "Legacy retry must use standard Base64, not Base64URL")
        }
    }

    // MARK: - Upload success paths

    @Test func uploadSucceedsViaMediaEndpoint() async {
        let bodyText = "hello blossom"
        let bytes = Data(bodyText.utf8)
        let hash = BlossomClient.sha256Hex(bytes)
        let server = "https://upload-a.example"

        
        MockURLProtocol.setHandler(for: "\(server)/\(hash)") { request -> (Data, HTTPURLResponse) in
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let resp = HTTPURLResponse(
                url: URL(string: "\(server)/\(hash)")!,
                statusCode: auth.isEmpty ? 401 : 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(), resp)
        }
        MockURLProtocol.setHandler(for: "\(server)/media") { request -> (Data, HTTPURLResponse) in
            let resp = HTTPURLResponse(
                url: URL(string: "\(server)/media")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            let json = #"{"url":"\#(server)/\#(hash)","sha256":"\#(hash)","size":\#(bytes.count),"type":"text/plain"}"#
            return (Data(json.utf8), resp)
        }

        BlossomClient.sessionOverride = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [MockURLProtocol.self]
            return c
        }())
        defer { BlossomClient.sessionOverride = nil;  }

        let keypair = testKeypair(seed: 1)
        do {
            let result = try await BlossomClient.upload(bytes: bytes, mime: "text/plain", servers: [server], keypair: keypair)
            #expect(result.url == "\(server)/\(hash)")
            #expect(result.sha256Hex == hash)
        } catch {
            Issue.record("Upload threw: \(error)")
        }
    }

    @Test func uploadSkipsPUTWhenHEADFindsBlob() async {
        let bodyText = "already mirrored"
        let bytes = Data(bodyText.utf8)
        let hash = BlossomClient.sha256Hex(bytes)
        let server = "https://upload-head.example"
        var mediaRequestCount = 0

        
        MockURLProtocol.setHandler(for: "\(server)/\(hash)") { _ -> (Data, HTTPURLResponse) in
            let resp = HTTPURLResponse(
                url: URL(string: "\(server)/\(hash)")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(), resp)
        }
        MockURLProtocol.setHandler(for: "\(server)/media") { _ -> (Data, HTTPURLResponse) in
            mediaRequestCount += 1
            let resp = HTTPURLResponse(
                url: URL(string: "\(server)/media")!,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(), resp)
        }
        MockURLProtocol.setHandler(for: "\(server)/upload") { _ -> (Data, HTTPURLResponse) in
            mediaRequestCount += 1
            let resp = HTTPURLResponse(
                url: URL(string: "\(server)/upload")!,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(), resp)
        }

        BlossomClient.sessionOverride = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [MockURLProtocol.self]
            return c
        }())
        defer { BlossomClient.sessionOverride = nil;  }

        let keypair = testKeypair(seed: 2)
        do {
            let result = try await BlossomClient.upload(bytes: bytes, mime: "text/plain", servers: [server], keypair: keypair)
            #expect(result.url == "\(server)/\(hash)")
            #expect(mediaRequestCount == 0, "HEAD hit should skip /media and /upload")
        } catch {
            Issue.record("Upload threw: \(error)")
        }
    }

    @Test func uploadFallsBackFromMedia404ToUpload() async {
        let bodyText = "media missing"
        let bytes = Data(bodyText.utf8)
        let hash = BlossomClient.sha256Hex(bytes)
        let server = "https://upload-fallback.example"

        
        MockURLProtocol.setHandler(for: "\(server)/\(hash)") { _ -> (Data, HTTPURLResponse) in
            let resp = HTTPURLResponse(url: URL(string: "\(server)/\(hash)")!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(), resp)
        }
        MockURLProtocol.setHandler(for: "\(server)/media") { _ -> (Data, HTTPURLResponse) in
            let resp = HTTPURLResponse(url: URL(string: "\(server)/media")!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(), resp)
        }
        MockURLProtocol.setHandler(for: "\(server)/upload") { _ -> (Data, HTTPURLResponse) in
            let resp = HTTPURLResponse(url: URL(string: "\(server)/upload")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            let json = #"{"url":"\#(server)/\#(hash)","sha256":"\#(hash)","size":\#(bytes.count),"type":"text/plain"}"#
            return (Data(json.utf8), resp)
        }

        BlossomClient.sessionOverride = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [MockURLProtocol.self]
            return c
        }())
        defer { BlossomClient.sessionOverride = nil;  }

        let keypair = testKeypair(seed: 3)
        do {
            let result = try await BlossomClient.upload(bytes: bytes, mime: "text/plain", servers: [server], keypair: keypair)
            #expect(result.url == "\(server)/\(hash)")
        } catch {
            Issue.record("Upload threw: \(error)")
        }
    }

    @Test func uploadTriesNextServerWhenFirstFails() async {
        let bodyText = "second server wins"
        let bytes = Data(bodyText.utf8)
        let hash = BlossomClient.sha256Hex(bytes)
        let serverA = "https://upload-fail.example"
        let serverB = "https://upload-win.example"

        
        MockURLProtocol.setHandler(for: "\(serverA)/\(hash)") { _ -> (Data, HTTPURLResponse) in
            (Data(), HTTPURLResponse(url: URL(string: "\(serverA)/\(hash)")!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        MockURLProtocol.setHandler(for: "\(serverA)/media") { _ -> (Data, HTTPURLResponse) in
            (Data(), HTTPURLResponse(url: URL(string: "\(serverA)/media")!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        MockURLProtocol.setHandler(for: "\(serverA)/upload") { _ -> (Data, HTTPURLResponse) in
            (Data(), HTTPURLResponse(url: URL(string: "\(serverA)/upload")!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        MockURLProtocol.setHandler(for: "\(serverB)/\(hash)") { _ -> (Data, HTTPURLResponse) in
            (Data(), HTTPURLResponse(url: URL(string: "\(serverB)/\(hash)")!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        MockURLProtocol.setHandler(for: "\(serverB)/media") { _ -> (Data, HTTPURLResponse) in
            let resp = HTTPURLResponse(url: URL(string: "\(serverB)/media")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            let json = #"{"url":"\#(serverB)/\#(hash)","sha256":"\#(hash)","size":\#(bytes.count),"type":"text/plain"}"#
            return (Data(json.utf8), resp)
        }

        BlossomClient.sessionOverride = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [MockURLProtocol.self]
            return c
        }())
        defer { BlossomClient.sessionOverride = nil;  }

        let keypair = testKeypair(seed: 4)
        do {
            let result = try await BlossomClient.upload(bytes: bytes, mime: "text/plain", servers: [serverA, serverB], keypair: keypair)
            #expect(result.url == "\(serverB)/\(hash)")
        } catch {
            Issue.record("Upload threw: \(error)")
        }
    }

    @Test func uploadDispatchesMirrorToOtherServers() async {
        let bodyText = "mirror me"
        let bytes = Data(bodyText.utf8)
        let hash = BlossomClient.sha256Hex(bytes)
        let serverA = "https://upload-mirror-a.example"
        let serverB = "https://upload-mirror-b.example"
        let mirrorCountLock = NSLock()
        var mirrorRequestCount = 0
        let mirrorArrived = DispatchSemaphore(value: 0)

        
        MockURLProtocol.setHandler(for: "\(serverA)/\(hash)") { _ -> (Data, HTTPURLResponse) in
            (Data(), HTTPURLResponse(url: URL(string: "\(serverA)/\(hash)")!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        MockURLProtocol.setHandler(for: "\(serverA)/media") { _ -> (Data, HTTPURLResponse) in
            (Data(), HTTPURLResponse(url: URL(string: "\(serverA)/media")!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        MockURLProtocol.setHandler(for: "\(serverA)/upload") { _ -> (Data, HTTPURLResponse) in
            let resp = HTTPURLResponse(url: URL(string: "\(serverA)/upload")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            let json = #"{"url":"\#(serverA)/\#(hash)","sha256":"\#(hash)","size":\#(bytes.count),"type":"text/plain"}"#
            return (Data(json.utf8), resp)
        }
        MockURLProtocol.setHandler(for: "\(serverB)/mirror") { request -> (Data, HTTPURLResponse) in
            mirrorCountLock.lock()
            mirrorRequestCount += 1
            mirrorCountLock.unlock()
            mirrorArrived.signal()
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let status = auth.hasPrefix("Nostr ") ? 200 : 401
            return (Data(), HTTPURLResponse(url: URL(string: "\(serverB)/mirror")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }

        BlossomClient.sessionOverride = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [MockURLProtocol.self]
            return c
        }())
        defer { BlossomClient.sessionOverride = nil;  }

        let keypair = testKeypair(seed: 5)
        do {
            _ = try await BlossomClient.upload(bytes: bytes, mime: "text/plain", servers: [serverA, serverB], keypair: keypair)
            // Wait deterministically for the detached mirror task to invoke the handler,
            // with a generous timeout so a hung task surfaces as a clear failure.
            let waited = mirrorArrived.wait(timeout: .now() + .seconds(5)) == .success
            #expect(waited, "Mirror PUT should be dispatched to serverB")
            #expect(mirrorRequestCount == 1, "Exactly one mirror request should be made")
        } catch {
            Issue.record("Upload threw: \(error)")
        }
    }

    // MARK: - normalizeServerURL double-slash fix

    @Test func normalizeServerURLCollapsesDoubleSlashInPath() {
        #expect(BlossomClient.normalizeServerURL("https://server.com//foo") == "https://server.com/foo")
        #expect(BlossomClient.normalizeServerURL("https://server.com///foo") == "https://server.com/foo")
    }

    // MARK: - sanitizeMirrorURL HTTPS enforcement

    @Test func sanitizeMirrorURLRejectsHTTPScheme() {
        let result = BlossomClient.sanitizeMirrorURL(
            serverReturnedURL: "http://cdn.azzamo.media/abc123.png",
            uploadHost: "blossom.azzamo.media",
            fallbackURL: "https://blossom.azzamo.media/abc123"
        )
        #expect(result == "https://blossom.azzamo.media/abc123", "HTTP mirror URLs must be rejected")
    }

    // MARK: - areSameRegistrableDomain multi-level TLD

    @Test func sameRegistrableDomainUsesLastThreeLabelsForCoUK() {
        #expect(BlossomClient.areSameRegistrableDomain("cdn.azzamo.co.uk", "blossom.azzamo.co.uk"))
        #expect(!BlossomClient.areSameRegistrableDomain("cdn.other.co.uk", "blossom.azzamo.co.uk"))
    }

    @Test func sameRegistrableDomainUsesLastThreeLabelsForComAU() {
        #expect(BlossomClient.areSameRegistrableDomain("cdn.azzamo.com.au", "blossom.azzamo.com.au"))
        #expect(!BlossomClient.areSameRegistrableDomain("cdn.other.com.au", "blossom.azzamo.com.au"))
    }

    // MARK: - convertToLegacyBase64Auth rejects tampered id

    @Test func convertToLegacyBase64AuthRejectsTamperedEventId() {
        let event = makeValidAuthEvent()
        guard var jsonData = event.json.data(using: .utf8) else {
            Issue.record("Failed to create test JSON data"); return
        }
        // Tamper the id to something different.
        let tampered = event.json.replacingOccurrences(of: event.id, with: String(repeating: "b", count: 64))
        guard let tamperedData = tampered.data(using: .utf8) else {
            Issue.record("Failed to create tampered JSON data"); return
        }
        let bud11Header = "Nostr \(tamperedData.base64URLEncodedString())"
        #expect(BlossomClient.convertToLegacyBase64Auth(bud11Header) == nil,
                "convertToLegacyBase64Auth must reject an event with a tampered id")
    }

    // MARK: - AsyncSemaphore cancellation-safe acquire

    @Test func asyncSemaphoreCancellationDoesNotLeakWaiters() async {
        let semaphore = AsyncSemaphore(value: 1)
        await semaphore.acquire()

        let innerTask = Task {
            await semaphore.acquire()
            await semaphore.release()
            return true
        }
        innerTask.cancel()
        await innerTask.value
        await semaphore.release()

        let second = Task {
            await semaphore.acquire()
            await semaphore.release()
            return true
        }
        let completed = await second.value
        #expect(completed, "Semaphore must remain usable after a cancelled waiter")
    }

    private func testKeypair(seed: UInt8) -> Keypair {
        let privBytes = Data((0..<32).map { UInt8((Int(seed) + Int($0)) % 256) })
        let pubBytes = Secp256k1.publicKey(from: privBytes)!
        return Keypair(
            privkey: privBytes.map { String(format: "%02x", $0) }.joined(),
            pubkey: pubBytes.map { String(format: "%02x", $0) }.joined()
        )
    }
}
