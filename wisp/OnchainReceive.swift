import Foundation

/// A Bitcoin transaction sent to the wallet's Spark deposit address that has
/// not yet been pulled into the spendable balance.
///
/// This type exists because on-chain receive has a second half people don't
/// expect: bitcoin sent to the deposit address confirms on-chain but does
/// **not** appear in the Spark balance until it is claimed. A wallet that only
/// showed the address would leave users watching a confirmed transaction that
/// their balance never reflects.
struct OnchainDeposit: Identifiable, Equatable, Sendable {
    let txid: String
    let vout: UInt32
    let amountSats: Int64
    /// Whether the deposit has enough confirmations to be claimable yet.
    let isMature: Bool
    /// Outcome of an instant (0-conf) claim, once one has been attempted.
    /// Nil when none has been — the deposit is simply waiting for its three
    /// confirmations.
    let instantClaim: InstantClaim?
    /// Set when a previous claim attempt failed. Claiming is retried by the
    /// user, so the reason has to survive to be shown.
    let failure: Failure?

    /// `txid:vout` — a transaction can pay the deposit address more than once.
    var id: String { "\(txid):\(vout)" }

    enum Failure: Equatable, Sendable {
        /// On-chain fees rose above the cap the claim was willing to pay.
        /// Recoverable: retry when fees fall, or accept the higher fee.
        case feeExceeded(requiredSats: Int64)
        /// The output the SDK expected is no longer there — typically an
        /// unconfirmed parent that got replaced.
        case missingUtxo
        case other(String)

        var message: String {
            switch self {
            case .feeExceeded(let sats):
                return "On-chain fees rose above the limit. Claiming this now would cost about \(sats) sats."
            case .missingUtxo:
                return "The transaction this deposit came from is no longer on-chain."
            case .other(let message):
                return message
            }
        }

        /// Whether waiting is likely to help. A fee spike passes; a missing
        /// output does not come back.
        var isWorthRetrying: Bool {
            switch self {
            case .feeExceeded: return true
            case .missingUtxo: return false
            case .other: return true
            }
        }
    }

    /// Status of an instant (0-conf) claim, in which the SSP fronts the
    /// confirmation risk for a spread.
    ///
    /// Wisp never asks for one. The SSP sells that risk at broadcast time,
    /// but the SDK doesn't report a deposit until it already has a
    /// confirmation — by which point there is no risk left to sell, and the
    /// request is declined with `noPlan`. Reading the status is still worth
    /// it: if the SDK ever claims a deposit this way on its own, the UI needs
    /// to know not to touch it while it settles.
    enum InstantClaim: Equatable, Sendable {
        /// Submitted and settling. The SDK requires that a deposit in this
        /// state not be re-claimed, so the UI must not offer an action.
        case submitted
        case declined(Decline)

        enum Decline: Equatable, Sendable {
            /// The SSP offered no 0-conf plan for this deposit.
            case noPlan
            /// The quoted spread was above the ceiling that was offered.
            case feeExceeded(quotedSats: Int64, quotedBps: Int)
            case submissionFailed
        }
    }

    /// An instant claim is submitted and settling.
    var isClaimInFlight: Bool { instantClaim == .submitted }

    /// Claimable right now: confirmed enough, no claim already in flight,
    /// and not blocked by a failure that retrying won't fix.
    var isClaimable: Bool {
        guard isMature, !isClaimInFlight else { return false }
        guard let failure else { return true }
        return failure.isWorthRetrying
    }
}

/// Everything the on-chain receive screen needs about pending deposits.
struct OnchainDepositSummary: Equatable, Sendable {
    var deposits: [OnchainDeposit] = []

    var isEmpty: Bool { deposits.isEmpty }

    /// Total still waiting to be claimed — the number a user compares against
    /// what they sent.
    var pendingSats: Int64 { deposits.reduce(0) { $0 + $1.amountSats } }

    /// Deposits that can be claimed right now.
    var claimable: [OnchainDeposit] { deposits.filter(\.isClaimable) }

}

