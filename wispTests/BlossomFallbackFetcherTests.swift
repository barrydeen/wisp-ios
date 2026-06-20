//
//  BlossomFallbackFetcherTests.swift
//  wispTests
//
//  Tests for BUD-03 fallback fetcher: SHA-256 verification, privacy-first (no auth)
//  GETs, default-server fallback, URL-without-hash handling, cooldown cache, and
//  multi-server chunking.
//

import Foundation
import Testing
@testable import wisp

private func cleanupServerList(pubkey: String) {
    UserDefaults.standard.removeObject(forKey: "blossom_servers_\(pubkey)")
}

@MainActor
@Suite(.serialized)
struct BlossomFallbackFetcherTests {

    private func sha(_ text: String) -> String {
        BlossomClient.sha256Hex(Data(text.utf8))
    }

    private func registerMock(url: String, statusCode: Int, body: Data) {
        let response = HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        MockURLProtocol.setHandler(for: url) { _ in (body, response) }
    }

    @Test func fetchReturnsDataWhenSHA256Matches() async {
        let bodyText = "valid image bytes"
        let bodyData = Data(bodyText.utf8)
        let hash = sha(bodyText)
        let server = "https://fallback-a.example"
        let fullURL = "\(server)/\(hash).png"

        MockURLProtocol.removeAllHandlers()
        BlossomFallbackFetcher.sessionOverride = makeMockSession()
        defer { BlossomFallbackFetcher.sessionOverride = nil }
        registerMock(url: fullURL, statusCode: 200, body: bodyData)

        let authorPubkey = "author-fb-001"
        BlossomServerList.save(servers: [server], for: authorPubkey)
        defer { cleanupServerList(pubkey: authorPubkey) }

        let blobURL = URL(string: "https://origin.example/\(hash).png")!
        let result = await BlossomFallbackFetcher.fetch(url: blobURL, authorPubkey: authorPubkey)
        #expect(result == bodyData)
    }

    @Test func fetchReturnsNilWhenSHA256Mismatches() async {
        let wrongData = Data("wrong bytes".utf8)
        let expectedHash = sha("expected bytes")
        let server = "https://fallback-b.example"
        let fullURL = "\(server)/\(expectedHash).png"

        MockURLProtocol.removeAllHandlers()
        BlossomFallbackFetcher.sessionOverride = makeMockSession()
        defer { BlossomFallbackFetcher.sessionOverride = nil }
        registerMock(url: fullURL, statusCode: 200, body: wrongData)

        let authorPubkey = "author-fb-002"
        BlossomServerList.save(servers: [server], for: authorPubkey)
        defer { cleanupServerList(pubkey: authorPubkey) }

        let blobURL = URL(string: "https://origin.example/\(expectedHash).png")!
        let result = await BlossomFallbackFetcher.fetch(url: blobURL, authorPubkey: authorPubkey)
        #expect(result == nil, "SHA-256 mismatch must reject the data")
    }

    @Test func fetchReturnsNilOnHTTP401NoAuthSent() async {
        let bodyText = "auth required"
        let bodyData = Data(bodyText.utf8)
        let hash = sha(bodyText)
        let server = "https://fallback-c.example"
        let fullURL = "\(server)/\(hash).png"

        MockURLProtocol.removeAllHandlers()
        BlossomFallbackFetcher.sessionOverride = makeMockSession()
        defer { BlossomFallbackFetcher.sessionOverride = nil }
        registerMock(url: fullURL, statusCode: 401, body: bodyData)

        let authorPubkey = "author-fb-003"
        BlossomServerList.save(servers: [server], for: authorPubkey)
        defer { cleanupServerList(pubkey: authorPubkey) }

        let blobURL = URL(string: "https://origin.example/\(hash).png")!
        let result = await BlossomFallbackFetcher.fetch(url: blobURL, authorPubkey: authorPubkey)
        #expect(result == nil, "401 must not trigger auth retry (deanonymization defense)")
    }

    @Test func fetchReturnsNilOnHTTP500() async {
        let hash = sha("error body")
        let server = "https://fallback-d.example"
        let fullURL = "\(server)/\(hash).png"

        MockURLProtocol.removeAllHandlers()
        BlossomFallbackFetcher.sessionOverride = makeMockSession()
        defer { BlossomFallbackFetcher.sessionOverride = nil }
        registerMock(url: fullURL, statusCode: 500, body: Data("error".utf8))

        let authorPubkey = "author-fb-004"
        BlossomServerList.save(servers: [server], for: authorPubkey)
        defer { cleanupServerList(pubkey: authorPubkey) }

        let blobURL = URL(string: "https://origin.example/\(hash).png")!
        let result = await BlossomFallbackFetcher.fetch(url: blobURL, authorPubkey: authorPubkey)
        #expect(result == nil)
    }

    @Test func fetchFallsBackToDefaultServerForUnknownAuthor() async {
        let bodyText = "primal default"
        let bodyData = Data(bodyText.utf8)
        let hash = sha(bodyText)
        let defaultServer = BlossomServerList.defaultServer
        let fullURL = "\(defaultServer)/\(hash).png"

        MockURLProtocol.removeAllHandlers()
        BlossomFallbackFetcher.sessionOverride = makeMockSession()
        defer { BlossomFallbackFetcher.sessionOverride = nil }
        registerMock(url: fullURL, statusCode: 200, body: bodyData)

        let authorPubkey = "never-seen-unknown-author-key"
        cleanupServerList(pubkey: authorPubkey)
        defer { cleanupServerList(pubkey: authorPubkey) }

        let blobURL = URL(string: "https://origin.example/\(hash).png")!
        let result = await BlossomFallbackFetcher.fetch(url: blobURL, authorPubkey: authorPubkey)
        #expect(result == bodyData, "Must fall back to default server for unknown authors")
    }

    @Test func fetchReturnsNilForURLWithoutHash() async {
        MockURLProtocol.removeAllHandlers()
        BlossomFallbackFetcher.sessionOverride = makeMockSession()
        defer { BlossomFallbackFetcher.sessionOverride = nil }

        let noHashURL = URL(string: "https://example.com/image.png")!
        let result = await BlossomFallbackFetcher.fetch(url: noHashURL, authorPubkey: "somepubkey")
        #expect(result == nil)
    }

    @Test func fetchRetriesSecondServerWhenFirstFails() async {
        let bodyText = "second server"
        let bodyData = Data(bodyText.utf8)
        let hash = sha(bodyText)
        let serverA = "https://fallback-a.example"
        let serverB = "https://fallback-b.example"

        MockURLProtocol.removeAllHandlers()
        BlossomFallbackFetcher.sessionOverride = makeMockSession()
        defer { BlossomFallbackFetcher.sessionOverride = nil }
        registerMock(url: "\(serverA)/\(hash).png", statusCode: 500, body: Data())
        registerMock(url: "\(serverB)/\(hash).png", statusCode: 200, body: bodyData)

        let authorPubkey = "author-fb-multi"
        BlossomServerList.save(servers: [serverA, serverB], for: authorPubkey)
        defer { cleanupServerList(pubkey: authorPubkey) }

        let blobURL = URL(string: "https://origin.example/\(hash).png")!
        let result = await BlossomFallbackFetcher.fetch(url: blobURL, authorPubkey: authorPubkey)
        #expect(result == bodyData)
    }

    @Test func fetchSkipsHTTPServers() async {
        let bodyText = "https only"
        let bodyData = Data(bodyText.utf8)
        let hash = sha(bodyText)
        let httpsServer = "https://fallback-https.example"

        MockURLProtocol.removeAllHandlers()
        BlossomFallbackFetcher.sessionOverride = makeMockSession()
        defer { BlossomFallbackFetcher.sessionOverride = nil }
        registerMock(url: "\(httpsServer)/\(hash).png", statusCode: 200, body: bodyData)

        let authorPubkey = "author-fb-scheme"
        BlossomServerList.save(servers: ["http://insecure.example", httpsServer], for: authorPubkey)
        defer { cleanupServerList(pubkey: authorPubkey) }

        let blobURL = URL(string: "https://origin.example/\(hash).png")!
        let result = await BlossomFallbackFetcher.fetch(url: blobURL, authorPubkey: authorPubkey)
        #expect(result == bodyData, "HTTP servers must be filtered out; HTTPS server should succeed")
    }

    @Test func fetchWorksForExtensionlessHashURL() async {
        let bodyText = "extensionless"
        let bodyData = Data(bodyText.utf8)
        let hash = sha(bodyText)
        let server = "https://fallback-ext.example"

        MockURLProtocol.removeAllHandlers()
        BlossomFallbackFetcher.sessionOverride = makeMockSession()
        defer { BlossomFallbackFetcher.sessionOverride = nil }
        registerMock(url: "\(server)/\(hash)", statusCode: 200, body: bodyData)

        let authorPubkey = "author-fb-ext"
        BlossomServerList.save(servers: [server], for: authorPubkey)
        defer { cleanupServerList(pubkey: authorPubkey) }

        let blobURL = URL(string: "https://origin.example/\(hash)")!
        let result = await BlossomFallbackFetcher.fetch(url: blobURL, authorPubkey: authorPubkey)
        #expect(result == bodyData)
    }

    @Test func fetchChunksServersBeyondConcurrencyCap() async {
        let bodyText = "fourth server"
        let bodyData = Data(bodyText.utf8)
        let hash = sha(bodyText)
        let servers = (1...4).map { "https://fallback-\($0).example" }

        MockURLProtocol.removeAllHandlers()
        BlossomFallbackFetcher.sessionOverride = makeMockSession()
        defer { BlossomFallbackFetcher.sessionOverride = nil }

        for (idx, server) in servers.enumerated() {
            let status = (idx == 3) ? 200 : 500
            registerMock(url: "\(server)/\(hash).png", statusCode: status, body: status == 200 ? bodyData : Data())
        }

        let authorPubkey = "author-fb-chunk"
        BlossomServerList.save(servers: servers, for: authorPubkey)
        defer { cleanupServerList(pubkey: authorPubkey) }

        let blobURL = URL(string: "https://origin.example/\(hash).png")!
        let result = await BlossomFallbackFetcher.fetch(url: blobURL, authorPubkey: authorPubkey)
        #expect(result == bodyData, "Server beyond maxConcurrentFetches must still be tried")
    }

    @Test func cooldownPreventsImmediateRetry() async {
        let hash = sha("cooldown")
        let server = "https://fallback-cd.example"
        let invocationCountLock = NSLock()
        var invocationCount = 0

        MockURLProtocol.removeAllHandlers()
        BlossomFallbackFetcher.sessionOverride = makeMockSession()
        defer { BlossomFallbackFetcher.sessionOverride = nil }
        MockURLProtocol.setHandler(for: "\(server)/\(hash).png") { _ -> (Data, HTTPURLResponse) in
            invocationCountLock.lock()
            invocationCount += 1
            invocationCountLock.unlock()
            let resp = HTTPURLResponse(
                url: URL(string: "\(server)/\(hash).png")!,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(), resp)
        }

        let authorPubkey = "author-fb-cd"
        BlossomServerList.save(servers: [server], for: authorPubkey)
        defer { cleanupServerList(pubkey: authorPubkey) }

        let blobURL = URL(string: "https://origin.example/\(hash).png")!
        let first = await BlossomFallbackFetcher.fetch(url: blobURL, authorPubkey: authorPubkey)
        #expect(first == nil)
        #expect(invocationCount == 1, "First fetch should hit the network once")

        let second = await BlossomFallbackFetcher.fetch(url: blobURL, authorPubkey: authorPubkey)
        #expect(second == nil, "Second fetch during cooldown must not retry")
        #expect(invocationCount == 1, "Cooldown must suppress the second network request")
    }

    @Test func fetchSendsNoAuthorizationHeader() async {
        let bodyText = "no auth header"
        let bodyData = Data(bodyText.utf8)
        let hash = sha(bodyText)
        let server = "https://fallback-noauth.example"
        var capturedAuth: String? = "unset"

        MockURLProtocol.removeAllHandlers()
        BlossomFallbackFetcher.sessionOverride = makeMockSession()
        defer { BlossomFallbackFetcher.sessionOverride = nil }
        MockURLProtocol.setHandler(for: "\(server)/\(hash).png") { request -> (Data, HTTPURLResponse) in
            capturedAuth = request.value(forHTTPHeaderField: "Authorization")
            let resp = HTTPURLResponse(
                url: URL(string: "\(server)/\(hash).png")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (bodyData, resp)
        }

        let authorPubkey = "author-fb-noauth"
        BlossomServerList.save(servers: [server], for: authorPubkey)
        defer { cleanupServerList(pubkey: authorPubkey) }

        let blobURL = URL(string: "https://origin.example/\(hash).png")!
        let result = await BlossomFallbackFetcher.fetch(url: blobURL, authorPubkey: authorPubkey)
        #expect(result == bodyData)
        #expect(capturedAuth == nil, "Fallback GET must never send an Authorization header")
    }

    @Test func integrityMismatchDoesNotRecordCooldown() async {
        let correctBodyText = "correct"
        let correctBodyData = Data(correctBodyText.utf8)
        let hash = sha(correctBodyText)
        let wrongData = Data("wrong".utf8)
        let serverA = "https://fallback-ia.example"
        let serverB = "https://fallback-ib.example"

        MockURLProtocol.removeAllHandlers()
        BlossomFallbackFetcher.sessionOverride = makeMockSession()
        defer { BlossomFallbackFetcher.sessionOverride = nil }
        registerMock(url: "\(serverA)/\(hash).png", statusCode: 200, body: wrongData)
        registerMock(url: "\(serverB)/\(hash).png", statusCode: 200, body: correctBodyData)

        let authorPubkey = "author-fb-integ"
        BlossomServerList.save(servers: [serverA, serverB], for: authorPubkey)
        defer { cleanupServerList(pubkey: authorPubkey) }

        let blobURL = URL(string: "https://origin.example/\(hash).png")!
        let result = await BlossomFallbackFetcher.fetch(url: blobURL, authorPubkey: authorPubkey)
        #expect(result == correctBodyData, "Integrity mismatch on first server must not suppress second server")
    }
}
