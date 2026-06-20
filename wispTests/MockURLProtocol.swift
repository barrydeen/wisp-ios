//
//  MockURLProtocol.swift
//  wispTests
//
//  Shared URLProtocol mock for Blossom network tests. Each test suite that needs
//  mock HTTP should configure handlers via `setHandler(for:)` before issuing
//  requests, and clean up via `removeAllHandlers()` in a defer.
//
//  All handler storage is lock-protected so concurrent Swift Testing execution
//  (across suites and within parallel task groups) doesn't corrupt the map.
//

import Foundation

final class MockURLProtocol: URLProtocol {
    private static let handlersLock = NSLock()
    private static var _handlers: [String: (URLRequest) -> (Data, HTTPURLResponse)] = [:]

    static func setHandler(for url: String, _ handler: @escaping (URLRequest) -> (Data, HTTPURLResponse)) {
        handlersLock.lock()
        _handlers[url] = handler
        handlersLock.unlock()
    }

    static func removeAllHandlers() {
        handlersLock.lock()
        _handlers.removeAll()
        handlersLock.unlock()
    }

    static func handler(for url: String) -> ((URLRequest) -> (Data, HTTPURLResponse))? {
        handlersLock.lock()
        defer { handlersLock.unlock() }
        return _handlers[url]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let handler = MockURLProtocol.handler(for: url.absoluteString) else {
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

/// Builds an ephemeral URLSession that routes all requests through `MockURLProtocol`.
/// Each test should call this to get a fresh session and assign it to the relevant
/// session-override static (e.g. `BlossomClient.sessionOverride`).
func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}