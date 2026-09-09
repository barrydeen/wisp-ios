import Foundation
import Testing
@testable import wisp

/// The arithmetic behind the Withdraw on-chain confirmation screen. Pure, and
/// worth pinning: these numbers are what a user reads before irreversibly
/// emptying their wallet.
struct WithdrawOnchainQuoteTests {

    private func quote(spend: Int64, fee: Int64, speed: WithdrawOnchainSpeed = .medium) -> WithdrawOnchainQuote {
        WithdrawOnchainQuote(address: "bc1qexample", spendSats: spend, feeSats: fee, speed: speed)
    }

    /// The fee comes OUT of the balance (`FeePolicy.feesIncluded`), so the
    /// destination receives less than the wallet held.
    @Test func netIsBalanceMinusFee() {
        #expect(quote(spend: 100_000, fee: 2_500).netSats == 97_500)
    }

    /// Never advertise a negative amount — a fee above the balance means
    /// nothing arrives, not that the user owes sats.
    @Test func netClampsAtZero() {
        #expect(quote(spend: 1_000, fee: 5_000).netSats == 0)
    }

    @Test func aFeeThatEatsEverythingIsUneconomical() {
        #expect(quote(spend: 1_000, fee: 5_000).isUneconomical)
        #expect(quote(spend: 1_000, fee: 1_000).isUneconomical)
    }

    @Test func anOrdinaryDrainIsEconomical() {
        #expect(!quote(spend: 100_000, fee: 2_500).isUneconomical)
    }

    /// Drives the "fees take N% of this balance" warning. Draining a small
    /// balance can cost a large share of it, and that should be visible
    /// before confirming rather than discovered afterwards.
    @Test func feePercentIsShareOfBalance() {
        #expect(quote(spend: 100_000, fee: 10_000).feePercent == 10)
        #expect(quote(spend: 20_000, fee: 5_000).feePercent == 25)
    }

    /// No division by zero on an empty wallet.
    @Test func feePercentOnAnEmptyBalanceIsZero() {
        #expect(quote(spend: 0, fee: 500).feePercent == 0)
    }

    /// Equality gates execution: `executeWithdrawOnchain` refuses unless the held
    /// quote matches the one the user confirmed, so a drifted screen can't
    /// send a different amount or destination than was signed off.
    @Test func quotesDifferingInAnyFieldAreNotEqual() {
        let base = quote(spend: 100_000, fee: 2_500)
        #expect(base != quote(spend: 100_001, fee: 2_500))
        #expect(base != quote(spend: 100_000, fee: 2_600))
        #expect(base != quote(spend: 100_000, fee: 2_500, speed: .fast))
        #expect(base != WithdrawOnchainQuote(address: "bc1qother", spendSats: 100_000,
                                         feeSats: 2_500, speed: .medium))
        #expect(base == quote(spend: 100_000, fee: 2_500))
    }

    @Test func everySpeedIsLabelledAndExplained() {
        for speed in WithdrawOnchainSpeed.allCases {
            #expect(!speed.label.isEmpty)
            #expect(!speed.detail.isEmpty)
        }
    }
}

struct WithdrawOnchainRemainderTests {

    @Test func nothingStrandedIsEmpty() {
        #expect(WithdrawOnchainRemainder().isEmpty)
    }

    /// Tokens under the conversion floor can't be moved at any price, so the
    /// remainder has to be representable rather than implied away.
    @Test func strandedTokensAreNotEmpty() {
        var remainder = WithdrawOnchainRemainder()
        remainder.strandedTokens["USDB"] = "0.34"
        #expect(!remainder.isEmpty)
    }

    @Test func strandedSatsAreNotEmpty() {
        var remainder = WithdrawOnchainRemainder()
        remainder.strandedSats = 120
        #expect(!remainder.isEmpty)
    }
}

/// Bitcoin QRs are usually BIP-21 URIs, not bare addresses, and the SDK's
/// parser wants the address alone.
struct BitcoinAddressNormalizationTests {

    @Test func abareAddressPassesThrough() {
        #expect(WithdrawOnchainSheet.normalizeBitcoinAddress("bc1qexample") == "bc1qexample")
    }

    @Test func stripsTheBip21Scheme() {
        #expect(WithdrawOnchainSheet.normalizeBitcoinAddress("bitcoin:bc1qexample") == "bc1qexample")
    }

    /// Some wallets emit an uppercase scheme.
    @Test func schemeMatchIsCaseInsensitive() {
        #expect(WithdrawOnchainSheet.normalizeBitcoinAddress("BITCOIN:bc1qexample") == "bc1qexample")
    }

    /// The amount is discarded on purpose: this screen always sends the whole
    /// balance, so honoring a requested amount would contradict the button.
    @Test func dropsQueryParameters() {
        #expect(WithdrawOnchainSheet.normalizeBitcoinAddress("bitcoin:bc1qexample?amount=0.01&label=x")
                == "bc1qexample")
    }

    @Test func trimsWhitespaceAndNewlines() {
        #expect(WithdrawOnchainSheet.normalizeBitcoinAddress("  bc1qexample\n") == "bc1qexample")
    }

    /// "bitcoin" appearing mid-string is not a scheme — only an anchored
    /// match counts, so an address is never mangled.
    @Test func onlyAnAnchoredSchemeIsStripped() {
        #expect(WithdrawOnchainSheet.normalizeBitcoinAddress("bc1qbitcoin:x") == "bc1qbitcoin:x")
    }
}

struct SparkscanLinkTests {

    /// Follows Sparkscan's own API convention (`/v1/tx/{txid}`). Verified
    /// against the live explorer with a real payment id.
    @Test func buildsATxPath() {
        let url = WithdrawOnchainSheet.sparkscanURL(paymentId: "abc123")
        #expect(url?.absoluteString == "https://sparkscan.io/tx/abc123")
    }

    @Test func trimsSurroundingWhitespace() {
        let url = WithdrawOnchainSheet.sparkscanURL(paymentId: "  abc123\n")
        #expect(url?.absoluteString == "https://sparkscan.io/tx/abc123")
    }

    @Test func refusesAnEmptyId() {
        #expect(WithdrawOnchainSheet.sparkscanURL(paymentId: "") == nil)
        #expect(WithdrawOnchainSheet.sparkscanURL(paymentId: "   ") == nil)
    }
}
