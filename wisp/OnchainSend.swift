import Foundation

/// Confirmation speed for an on-chain send, mapped to the SDK's three fee
/// tiers. Kept SDK-free so the view layer and tests don't import the SDK.
///
/// Deliberately separate from `WithdrawOnchainSpeed`: draining the wallet and
/// sending a chosen amount quote against opposite fee policies, and the two
/// features are in flight on different branches. Worth collapsing into one
/// type once both have landed.
enum OnchainSendSpeed: String, CaseIterable, Sendable {
    case slow
    case medium
    case fast

    var label: String {
        switch self {
        case .slow: return "Economy"
        case .medium: return "Standard"
        case .fast: return "Priority"
        }
    }

    var detail: String {
        switch self {
        case .slow: return "Cheapest. May take hours to confirm."
        case .medium: return "Balanced fee and confirmation time."
        case .fast: return "Highest fee. Confirms soonest."
        }
    }
}

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
    let speed: OnchainSendSpeed
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
