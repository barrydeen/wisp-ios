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
        // "any carnal pleasure." in ASCII is 20 bytes, which requires 1 padding char in standard Base64.
        let data = "any carnal pleasure.".data(using: .utf8)!
        let encoded = data.base64URLEncodedString()

        #expect(!encoded.contains("="))
        #expect(encoded == "YW55IGNhcm5hbCBwbGVhc3VyZS4")

        // Roundtrip: Base64URL → standard Base64 → original bytes.
        var standard = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder > 0 {
            standard += String(repeating: "=", count: 4 - remainder)
        }
        #expect(Data(base64Encoded: standard) == data)
    }

    @Test func base64URLEncodedStringReplacesSpecialChars() {
        // Data that produces '+' and '/' in standard Base64
        let data = Data([0xfb, 0xef, 0xff]) // Base64: ++//
        let encoded = data.base64URLEncodedString()

        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(encoded == "--__")

        // Roundtrip
        let standard = "--__".replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=="
        #expect(Data(base64Encoded: standard) == data)
    }

    @Test func base64URLEncodedStringHandlesBoundaryBytePatterns() {
        let cases: [Data] = [
            Data([0x00]),            // all-zero 6-bit group
            Data([0xff]),            // all-one 6-bit group
            Data([0x00, 0x00, 0x00]),
            Data([0xff, 0xff, 0xff]),
            Data((0..<32).map { UInt8($0) }),
        ]
        for original in cases {
            let encoded = original.base64URLEncodedString()
            #expect(!encoded.contains("+"))
            #expect(!encoded.contains("/"))
            #expect(!encoded.contains("="))

            var standard = encoded
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let remainder = standard.count % 4
            if remainder > 0 {
                standard += String(repeating: "=", count: 4 - remainder)
            }
            #expect(Data(base64Encoded: standard) == original, "Roundtrip failed for \(original.map { String(format: "%02x", $0) }.joined())")
        }
    }

    @Test func base64URLEncodedStringHandlesEmptyData() {
        let data = Data()
        let encoded = data.base64URLEncodedString()
        #expect(encoded == "")
    }
}
