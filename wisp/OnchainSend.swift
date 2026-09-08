import Foundation

/// What an on-chain send would cost, quoted before anything is signed.
///
/// Fees are added on top of the amount — the SDK's default `feesExcluded` — so
/// the recipient gets exactly `amountSats` and the wallet spends `totalSats`.
/// That's the opposite of draining, where the fee comes out of the amount, and
/// it's why the balance check is against the total rather than the amount.
struct OnchainSendQuote: Equatable, Sendable {
    let address: String
    /// What actually lands at the destination.
    let amountSats: Int64
    /// Service fee plus the L1 broadcast fee, both real cost to the user.
    let feeSats: Int64
    let speed: OnchainSpeed
    /// Set when emptying the wallet would leave a token balance behind.
    ///
    /// `balanceSats` is bitcoin only — tokens sit in a separate balance the
    /// send doesn't touch. Draining therefore empties the sats and strands
    /// any stablecoin, and Wisp doesn't convert tokens, so the user would be
    /// left with a wallet that looks empty and isn't. Worth saying before
    /// they sign, not after.
    var leavesTokensBehind: Bool = false

    /// What leaves the wallet.
    var totalSats: Int64 { amountSats + feeSats }

    /// Fee as a share of the amount being sent. On-chain fees don't scale with
    /// amount, so a small send can cost more in fees than it delivers — worth
    /// saying out loud before the user signs.
    var feeShare: Double {
        guard amountSats > 0 else { return 0 }
        return Double(feeSats) / Double(amountSats)
    }

    /// True when the fee is a large enough share of the send to be worth a
    /// warning rather than a line item.
    var isFeeDisproportionate: Bool { feeShare >= 0.10 }
}
