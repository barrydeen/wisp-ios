//
//  BlossomClientTests.swift
//  wispTests
//
//  Tests for BlossomClient utility functions.
//

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
}
