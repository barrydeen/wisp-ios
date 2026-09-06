import Foundation
import Testing
@testable import wisp

/// The pure model behind the receive sheet's Bitcoin tab: deposit identity,
/// which deposits the user can act on, and how failures read. The SDK-facing
/// mapping lives in `SparkWallet` and needs a connected SDK, so it stays out
/// of these tests.
struct OnchainReceiveTests {

    private let txid = String(repeating: "a", count: 64)

    private func deposit(
        txid: String? = nil,
        vout: UInt32 = 0,
        amountSats: Int64 = 50_000,
        isMature: Bool = true,
        instantClaim: OnchainDeposit.InstantClaim? = nil,
        failure: OnchainDeposit.Failure? = nil
    ) -> OnchainDeposit {
        OnchainDeposit(
            txid: txid ?? self.txid,
            vout: vout,
            amountSats: amountSats,
            isMature: isMature,
            instantClaim: instantClaim,
            failure: failure
        )
    }

    // MARK: - Identity

    @Test func idIsTxidAndVout() {
        #expect(deposit().id == "\(txid):0")
        #expect(deposit(vout: 2).id == "\(txid):2")
    }

    /// A transaction can pay the deposit address more than once — each
    /// output is its own row.
    @Test func sameTxidDifferentVoutIsDifferentDeposit() {
        #expect(deposit(vout: 0) != deposit(vout: 1))
    }

    // MARK: - Claimability

    @Test func healthyMatureDepositIsClaimable() {
        #expect(deposit().isClaimable)
    }

    @Test func immatureDepositIsNotClaimable() {
        #expect(!deposit(isMature: false).isClaimable)
    }

    @Test func feeExceededFailureIsRetriable() {
        let d = deposit(failure: .feeExceeded(requiredSats: 900))
        #expect(d.isClaimable)
    }

    @Test func missingUtxoIsNotRetriable() {
        #expect(!deposit(failure: .missingUtxo).isClaimable)
    }

    @Test func otherFailuresAreRetriable() {
        #expect(deposit(failure: .other("something went wrong")).isClaimable)
    }

    /// While an instant claim is settling, the SDK requires that the deposit
    /// not be re-claimed — the UI must not offer a retry even though a
    /// stale failure may still be attached.
    @Test func claimInFlightIsNeverClaimable() {
        #expect(!deposit(instantClaim: .submitted).isClaimable)
        #expect(!deposit(instantClaim: .submitted, failure: .feeExceeded(requiredSats: 900)).isClaimable)
    }

    // MARK: - Instant-claim status (reported by the SDK, never requested)

    @Test func inFlightTracksSubmittedOnly() {
        #expect(deposit(instantClaim: .submitted).isClaimInFlight)
        #expect(!deposit(instantClaim: .declined(.noPlan)).isClaimInFlight)
        #expect(!deposit().isClaimInFlight)
    }

    // MARK: - Failure messages

    @Test func feeExceededMessageShowsRequiredFee() {
        let message = OnchainDeposit.Failure.feeExceeded(requiredSats: 900).message
        #expect(message.contains("900"))
    }

    @Test func otherFailurePassesMessageThrough() {
        #expect(OnchainDeposit.Failure.other("nope").message == "nope")
    }

    @Test func retryWorthiness() {
        #expect(OnchainDeposit.Failure.feeExceeded(requiredSats: 1).isWorthRetrying)
        #expect(OnchainDeposit.Failure.other("x").isWorthRetrying)
        #expect(!OnchainDeposit.Failure.missingUtxo.isWorthRetrying)
    }

    // MARK: - Summary aggregation

    @Test func summaryTotalsAndBuckets() {
        let summary = OnchainDepositSummary(deposits: [
            deposit(vout: 0, amountSats: 10_000),
            deposit(vout: 1, amountSats: 20_000, isMature: false),
            deposit(vout: 2, amountSats: 30_000, failure: .feeExceeded(requiredSats: 900)),
            deposit(vout: 3, amountSats: 40_000, failure: .missingUtxo),
            deposit(vout: 4, amountSats: 50_000, instantClaim: .submitted),
        ])

        #expect(!summary.isEmpty)
        #expect(summary.pendingSats == 150_000)
        #expect(summary.claimable.map(\.vout) == [0, 2])
    }

    @Test func emptySummary() {
        let summary = OnchainDepositSummary(deposits: [])
        #expect(summary.isEmpty)
        #expect(summary.pendingSats == 0)
        #expect(summary.claimable.isEmpty)
    }
}
