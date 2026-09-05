import Testing
import Foundation
@testable import wisp

/// Covers the NIP-A3 (kind 10133) protocol layer: tag parsing, URI assembly and
/// the QR-payload decoder that feeds the Payment Targets settings screen.
struct NipA3Tests {

    private func event(kind: Int = NipA3.kind, tags: [[String]]) -> NostrEvent {
        NostrEvent(
            id: String(repeating: "a", count: 64),
            pubkey: String(repeating: "b", count: 64),
            kind: kind,
            createdAt: 1_700_000_000,
            tags: tags,
            content: "",
            sig: String(repeating: "c", count: 128)
        )
    }

    // MARK: - parse

    @Test func parsesPaytoTags() {
        let parsed = NipA3.parse(event(tags: [
            ["payto", "bitcoin", "bc1qexample"],
            ["payto", "MONERO", "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge"],
            ["p", "somepubkey"]
        ]))
        #expect(parsed.count == 2)
        #expect(parsed[0] == NipA3.PaymentTarget(type: "bitcoin", authority: "bc1qexample"))
        // Types are normalized to lowercase on the way in.
        #expect(parsed[1].type == "monero")
    }

    @Test func parseIgnoresMalformedAndDuplicateTags() {
        let parsed = NipA3.parse(event(tags: [
            ["payto", "bitcoin"],                  // missing authority
            ["payto", "bit coin", "bc1q"],         // invalid type
            ["payto", "bitcoin", "  "],            // blank authority
            ["payto", "bitcoin", "bc1q with space"], // whitespace in authority
            ["payto", "bitcoin", "bc1qexample"],
            ["payto", "bitcoin", "bc1qexample"]    // duplicate
        ]))
        #expect(parsed == [NipA3.PaymentTarget(type: "bitcoin", authority: "bc1qexample")])
    }

    @Test func parseIgnoresWrongKind() {
        #expect(NipA3.parse(event(kind: 10002, tags: [["payto", "bitcoin", "bc1q"]])).isEmpty)
    }

    @Test func parseIgnoresExtraTagElements() {
        // Elements past index 2 are reserved for future RFC-8905 features.
        let parsed = NipA3.parse(event(tags: [["payto", "bitcoin", "bc1qexample", "future", "stuff"]]))
        #expect(parsed == [NipA3.PaymentTarget(type: "bitcoin", authority: "bc1qexample")])
    }

    @Test func buildTagsRoundTrips() {
        let targets = [
            NipA3.PaymentTarget(type: "bitcoin", authority: "bc1qexample"),
            NipA3.PaymentTarget(type: "venmo", authority: "@alice")
        ]
        #expect(NipA3.buildTags(targets) == [
            ["payto", "bitcoin", "bc1qexample"],
            ["payto", "venmo", "@alice"]
        ])
        #expect(NipA3.parse(event(tags: NipA3.buildTags(targets))) == targets)
    }

    // MARK: - Types

    @Test func normalizeTypeAcceptsLowercaseAlnumAndHyphen() {
        #expect(NipA3.normalizeType("  BitCoin ") == "bitcoin")
        #expect(NipA3.normalizeType("bip-353") == "bip-353")
        #expect(NipA3.normalizeType("iban") == "iban")
        #expect(NipA3.normalizeType("") == nil)
        #expect(NipA3.normalizeType("bit coin") == nil)
        #expect(NipA3.normalizeType("bit_coin") == nil)
    }

    @Test func displayNameFallsBackToCapitalizedType() {
        #expect(NipA3.displayName("bitcoin") == "Bitcoin")
        #expect(NipA3.displayName("bip352") == "Silent Payments")
        #expect(NipA3.displayName("iban") == "Iban")
        #expect(NipA3.ticker("monero") == "XMR")
        #expect(NipA3.ticker("iban") == nil)
    }

    @Test func recognizedOrderMatchesRecognizedKeys() {
        #expect(Set(NipA3.recognizedOrder) == Set(NipA3.recognized.keys))
        #expect(NipA3.recognizedOrder.count == NipA3.recognized.count)
    }

    // MARK: - URIs

    @Test func nativeUriPrefersWalletScheme() {
        #expect(NipA3.nativeUri(NipA3.PaymentTarget(type: "bitcoin", authority: "bc1qexample"))
                == "bitcoin:bc1qexample")
        #expect(NipA3.nativeUri(NipA3.PaymentTarget(type: "lightning", authority: "alice@example.com"))
                == "lightning:alice@example.com")
        // No native scheme → fall back to payto://, with the authority encoded.
        #expect(NipA3.nativeUri(NipA3.PaymentTarget(type: "venmo", authority: "@alice"))
                == "payto://venmo/%40alice")
    }

    @Test func assemblePaytoUriEncodesAuthority() {
        #expect(NipA3.assemblePaytoUri(NipA3.PaymentTarget(type: "iban", authority: "DE75 5121"))
                == "payto://iban/DE75%205121")
    }

    // MARK: - Lightning reusability

    @Test func rejectsInvoicesAndLnurlAsLightningTargets() {
        #expect(!NipA3.isReusableLightningTarget("lnbc1pexample"))
        #expect(!NipA3.isReusableLightningTarget("LNURL1DP68"))
        #expect(!NipA3.isReusableLightningTarget("lntb1pexample"))
        #expect(NipA3.isReusableLightningTarget("alice@example.com"))
    }

    // MARK: - QR scanning

    @Test func scansPaytoUri() {
        let scan = NipA3.parseScannedUri("payto://monero/4AdUndXHHZ6c?amount=1")
        #expect(scan.type == "monero")
        #expect(scan.authority == "4AdUndXHHZ6c")
    }

    @Test func scansPaytoUriWithEncodedAuthority() {
        let scan = NipA3.parseScannedUri("payto://iban/DE75%205121")
        #expect(scan.type == "iban")
        #expect(scan.authority == "DE75 5121")
    }

    @Test func scansNativeWalletScheme() {
        let scan = NipA3.parseScannedUri("bitcoin:bc1qexample?amount=0.1&label=x")
        #expect(scan.type == "bitcoin")
        #expect(scan.authority == "bc1qexample")
    }

    @Test func scansBareAddressWithoutInventingAType() {
        let scan = NipA3.parseScannedUri("  bc1qexample  ")
        #expect(scan.type == nil)
        #expect(scan.authority == "bc1qexample")
    }

    @Test func scanLeavesNonPaymentSchemesAlone() {
        for payload in ["https://example.com/x", "nostr:npub1abc", "mailto:a@b.c"] {
            let scan = NipA3.parseScannedUri(payload)
            #expect(scan.type == nil)
            #expect(scan.authority == payload)
        }
    }

    @Test func scanRecognizesSilentPaymentAddress() {
        // 100 bech32 characters after the "sp1" HRP — well past the 60-char floor.
        let body = String(repeating: "qpzry9x8gf", count: 10)
        let scan = NipA3.parseScannedUri("sp1" + body)
        #expect(scan.type == "bip352")
    }

    @Test func scanDoesNotMistakeShortSp1PrefixForSilentPayment() {
        let scan = NipA3.parseScannedUri("sp1shortaddress")
        #expect(scan.type == nil)
        #expect(scan.authority == "sp1shortaddress")
    }

    @Test func scanRecognizesDnsPaymentInstruction() {
        let scan = NipA3.parseScannedUri("\u{20BF}alice@example.com")
        #expect(scan.type == "bip353")
        #expect(scan.authority == "\u{20BF}alice@example.com")
    }

    @Test func scanRefinesBitcoinSchemeToSilentPayments() {
        let body = String(repeating: "qpzry9x8gf", count: 10)
        let scan = NipA3.parseScannedUri("bitcoin:sp1" + body)
        #expect(scan.type == "bip352")
    }

    @Test func scanKeepsExplicitNonBitcoinType() {
        let scan = NipA3.parseScannedUri("payto://monero/sp1whatever")
        #expect(scan.type == "monero")
    }

    @Test func scanHandlesEmptyPayload() {
        let scan = NipA3.parseScannedUri("   ")
        #expect(scan.type == nil)
        #expect(scan.authority == "")
    }
}
