//
//  BlossomFallbackFetcherTests.swift
//  wispTests
//
//  Tests for BUD-03 fallback fetcher: SHA-256 verification, privacy-first (no auth)
//  GETs, default-server fallback, and URL-without-hash handling.
//

import Foundation
import Testing
@testable import wisp

class MockURLProtocol: URLProtocol {
    static var handlers: [String: (URLRequest) -> (Data, HTTPURLResponse)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let handler = MockURLProtocol.handlers[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (data, response) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
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
        MockURLProtocol.handlers[url] = { _ in (body, response) }
    }

    @Test func fetchReturnsDataWhenSHA256Matches() async {
        let bodyText = "valid image bytes"
        let bodyData = Data(bodyText.utf8)
        let hash = sha(bodyText)
        let server = "https://fallback-a.example"
        let fullURL = "\(server)/\(hash).png"

        MockURLProtocol.handlers = [:]
        BlossomFallbackFetcher.sessionOverride = makeMockSession()
        defer { BlossomFallbackFetcher.sessionOverride = nil; MockURLProtocol.handlers = [:] }
        registerMock(url: fullURL, statusCode: 200, body: bodyData)

        let authorPubkey = "author-fb-001"
        BlossomServerList.save(servers: [server], for: authorPubkey)
        defer { BlossomServerList.save(servers: [], for: authorPubkey) }

        let blobURL = URL(string: "https://origin.example/\(hash).png")!
        let result = await BlossomFallbackFetcher.fetch(url: blobURL, authorPubkey: authorPubkey)
        #expect(result == bodyData)
    }

    @Test func fetchReturnsNilWhenSHA256Mismatches() async {
        let wrongData = Data("wrong bytes".utf8)
        let expectedHash = sha("expected bytes")
        let server = "https://fallback-b.example"
        let fullURL = "\(server)/\(expectedHash).png"

        MockURLProtocol.handlers = [:]
        BlossomFallbackFetcher.sessionOverride = makeMockSession()
        defer { BlossomFallbackFetcher.sessionOverride = nil; MockURLProtocol.handlers = [:] }
        registerMock(url: fullURL, statusCode: 200, body: wrongData)

        let authorPubkey = "author-fb-002"
        BlossomServerList.save(servers: [server], for: authorPubkey)
        defer { BlossomServerList.save(servers: [], for: authorPubkey) }

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

        MockURLProtocol.handlers = [:]
        BlossomFallbackFetcher.sessionOverride = makeMockSession()
        defer { BlossomFallbackFetcher.sessionOverride = nil; MockURLProtocol.handlers = [:] }
        registerMock(url: fullURL, statusCode: 401, body: bodyData)

        let authorPubkey = "author-fb-003"
        BlossomServerList.save(servers: [server], for: authorPubkey)
        defer { BlossomServerList.save(servers: [], for: authorPubkey) }

        let blobURL = URL(string: "https://origin.example/\(hash).png")!
        let result = await BlossomFallbackFetcher.fetch(url: blobURL, authorPubkey: authorPubkey)
        #expect(result == nil, "401 must not trigger auth retry (deanonymization defense)")
    }

    @Test func fetchReturnsNilOnHTTP500() async {
        let hash = sha("error body")
        let server = "https://fallback-d.example"
        let fullURL = "\(server)/\(hash).png"

        MockURLProtocol.handlers = [:]
        BlossomFallbackFetcher.sessionOverride = makeMockSession()
        defer { BlossomFallbackFetcher.sessionOverride = nil; MockURLProtocol.handlers = [:] }
        registerMock(url: fullURL, statusCode: 500, body: Data("error".utf8))

        let authorPubkey = "author-fb-004"
        BlossomServerList.save(servers: [server], for: authorPubkey)
        defer { BlossomServerList.save(servers: [], for: authorPubkey) }

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

        MockURLProtocol.handlers = [:]
        BlossomFallbackFetcher.sessionOverride = makeMockSession()
        defer { BlossomFallbackFetcher.sessionOverride = nil; MockURLProtocol.handlers = [:] }
        registerMock(url: fullURL, statusCode: 200, body: bodyData)

        let authorPubkey = "never-seen-unknown-author-key"
        BlossomServerList.save(servers: [], for: authorPubkey)
        defer { BlossomServerList.save(servers: [], for: authorPubkey) }

        let blobURL = URL(string: "https://origin.example/\(hash).png")!
        let result = await BlossomFallbackFetcher.fetch(url: blobURL, authorPubkey: authorPubkey)
        #expect(result == bodyData, "Must fall back to default server for unknown authors")
    }

    @Test func fetchReturnsNilForURLWithoutHash() async {
        MockURLProtocol.handlers = [:]
        BlossomFallbackFetcher.sessionOverride = makeMockSession()
        defer { BlossomFallbackFetcher.sessionOverride = nil; MockURLProtocol.handlers = [:] }

        let noHashURL = URL(string: "https://example.com/image.png")!
        let result = await BlossomFallbackFetcher.fetch(url: noHashURL, authorPubkey: "somepubkey")
        #expect(result == nil)
    }
}
