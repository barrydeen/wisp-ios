import Foundation

/// Confirmation speed for an on-chain withdrawal, mapped to the SDK's three fee
/// tiers. Kept SDK-free so the view layer and tests don't import the SDK.
enum WithdrawOnchainSpeed: String, CaseIterable, Sendable {
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

/// What a withdrawal would cost and deliver, quoted before anything is signed.
///
/// `spendSats` is the wallet's entire spendable balance and `feeSats` comes
/// out of it — the SDK's `FeePolicy.feesIncluded` — so `netSats` is what
/// actually lands at the destination. Quoting this way is the only honest way
/// to drain: with fees added on top, a send of the full balance can never
/// succeed.
struct WithdrawOnchainQuote: Equatable, Sendable {
    let address: String
    let spendSats: Int64
    let feeSats: Int64
    let speed: WithdrawOnchainSpeed

    var netSats: Int64 { max(0, spendSats - feeSats) }

    /// True when the fee would consume everything. Spark's own dust and fee
    /// floors mean a small balance can be genuinely unspendable on-chain —
    /// better to say so than to broadcast a transaction that delivers zero.
    var isUneconomical: Bool { netSats <= 0 }

    /// Share of the balance eaten by fees, for the warning copy. A drain of a
    /// small balance can be a large percentage, and the user should see that
    /// before confirming rather than after.
    var feePercent: Double {
        guard spendSats > 0 else { return 0 }
        return (Double(feeSats) / Double(spendSats)) * 100
    }
}

/// Funds a withdrawal cannot move, reported after the fact.
///
/// "Recover everything" is not literally achievable: tokens below the
/// provider's conversion floor can't be converted at any price, and Spark
/// leaves worth less than their own exit cost aren't worth spending (that
/// per-leaf floor is Spark's, and applies to a unilateral exit too). Naming
/// the remainder is more useful than implying it doesn't exist.
struct WithdrawOnchainRemainder: Equatable, Sendable {
    /// Ticker → human-readable amount left behind, e.g. "USDB" → "0.34".
    var strandedTokens: [String: String] = [:]
    var strandedSats: Int64 = 0

    var isEmpty: Bool { strandedTokens.isEmpty && strandedSats == 0 }
}
