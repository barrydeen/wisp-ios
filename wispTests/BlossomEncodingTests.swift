//
//  BlossomEncodingTests.swift
//  wispTests
//
//  Tests for BUD-11 Base64URL encoding compliance.
//

import Foundation
import Testing
@testable import wisp

struct BlossomEncodingTests {

    @Test func base64URLEncodedStringRemovesPadding() {
        // "any carnal pleasure." in ASCII is 18 bytes, which requires 2 padding chars in standard Base64
        let data = "any carnal pleasure.".data(using: .utf8)!
        let encoded = data.base64URLEncodedString()
        
        #expect(!encoded.contains("="))
        #expect(encoded == "YW55IGNhcm5hbCBwbGVhc3VyZS4")
    }

    @Test func base64URLEncodedStringReplacesSpecialChars() {
        // Data that produces '+' and '/' in standard Base64
        let data = Data([0xfb, 0xef, 0xff]) // Base64: ++//
        let encoded = data.base64URLEncodedString()
        
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(encoded == "--__")
    }

    @Test func base64URLEncodedStringHandlesEmptyData() {
        let data = Data()
        let encoded = data.base64URLEncodedString()
        #expect(encoded == "")
    }
}
