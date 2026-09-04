import Foundation
import Testing
@testable import wisp

/// The pure model behind sending to a Bitcoin address: what leaves the wallet
/// versus what lands, and when a fee is large enough to warn about. The SDK
/// quote/execute path needs a connected wallet, so it stays out of these tests.
struct OnchainSendTests {

    private let address = "bc1p6m4waffms2qszpvg6fxvp406hw368t5huu80pwe8sdfjdkzp9zpqmz57y3"

    private func quote(
        amountSats: Int64 = 100_000,
        feeSats: Int64 = 500,
        speed: OnchainSendSpeed = .medium,
        leavesTokensBehind: Bool = false
    ) -> OnchainSendQuote {
        OnchainSendQuote(
            address: address,
            amountSats: amountSats,
            feeSats: feeSats,
            speed: speed,
            leavesTokensBehind: leavesTokensBehind
        )
    }

    // MARK: - Totals

    /// Fees are added on top, so the recipient gets the amount and the wallet
    /// spends more than it. The inverse of draining, where the fee comes out.
    @Test func feesAreAddedOnTop() {
        let q = quote(amountSats: 100_000, feeSats: 500)
        #expect(q.totalSats == 100_500)
        #expect(q.amountSats == 100_000)
    }

    @Test func zeroFeeStillTotalsTheAmount() {
        #expect(quote(amountSats: 7_000, feeSats: 0).totalSats == 7_000)
    }

    // MARK: - Fee proportion

    @Test func ordinaryFeeIsNotFlagged() {
        #expect(!quote(amountSats: 100_000, feeSats: 500).isFeeDisproportionate)
    }

    /// A fee that eats a large share of a small send is worth saying out loud
    /// before it's signed, not after it's spent.
    @Test func feeEatingSmallSendIsFlagged() {
        let q = quote(amountSats: 2_000, feeSats: 800)
        #expect(q.isFeeDisproportionate)
        #expect(q.feeShare == 0.4)
    }

    @Test func warningThresholdIsTenPercent() {
        #expect(quote(amountSats: 10_000, feeSats: 1_000).isFeeDisproportionate)
        #expect(!quote(amountSats: 10_000, feeSats: 999).isFeeDisproportionate)
    }

    /// Guard the divide rather than trapping on a zero amount.
    @Test func zeroAmountHasNoShare() {
        #expect(quote(amountSats: 0, feeSats: 300).feeShare == 0)
    }

    // MARK: - Quote identity

    /// Execution refuses anything but the exact quote that was confirmed, so
    /// every field has to participate in equality.
    @Test func quotesDifferOnEveryField() {
        let base = quote()
        #expect(base != quote(amountSats: 100_001))
        #expect(base != quote(feeSats: 501))
        #expect(base != quote(speed: .fast))
        #expect(base == quote())
    }

    // MARK: - Token balances

    /// Emptying the wallet moves bitcoin only. A wallet imported from an app
    /// that holds stablecoins would look drained while still holding tokens,
    /// so the quote has to carry that fact to the confirmation.
    @Test func drainCanFlagStrandedTokens() {
        #expect(quote(leavesTokensBehind: true).leavesTokensBehind)
        #expect(!quote().leavesTokensBehind)
    }

    /// The flag is part of what the user agreed to, so it can't be swapped
    /// between quoting and sending.
    @Test func tokenFlagParticipatesInEquality() {
        #expect(quote(leavesTokensBehind: true) != quote(leavesTokensBehind: false))
    }

    // MARK: - Speed tiers

    @Test func everySpeedIsLabeled() {
        for speed in OnchainSendSpeed.allCases {
            #expect(!speed.label.isEmpty)
            #expect(!speed.detail.isEmpty)
        }
        #expect(OnchainSendSpeed.allCases.count == 3)
    }
}
