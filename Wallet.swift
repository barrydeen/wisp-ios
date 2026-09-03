import Foundation

/// Common abstraction over a Lightning wallet backend.
///
/// Implementations:
/// - `NwcWallet` — talks to a remote wallet service over NIP-47.
/// - `SparkWallet` — embedded self-custodial wallet via the Breez Spark SDK.
///
/// All amounts are millisats unless otherwise noted.
@MainActor
protocol Wallet: AnyObject {
    var balanceMsats: Int64? { get }
    var isConnected: Bool { get }
    var statusLog: AsyncStream<String> { get }
    var paymentReceived: AsyncStream<Int64> { get }
    /// Emits whenever the wallet's balance changes internally (e.g. from a Spark `.synced` event
    /// or an NWC notification). Lets `WalletStore` keep its `@Observable` balance in sync without
    /// having to poll.
    var balanceUpdates: AsyncStream<Int64> { get }

    func hasConnection() -> Bool
    func connect() async
    func disconnect()
    func fetchBalance() async -> Result<Int64, WalletError>
    func payInvoice(_ bolt11: String) async -> Result<String, WalletError>
    func makeInvoice(amountMsats: Int64, description: String, expirySecs: Int64) async -> Result<String, WalletError>
    func listTransactions(limit: Int, offset: Int) async -> Result<[WalletTransaction], WalletError>
}

/// Settlement state of a transaction. Mirrors Android's `TransactionStatus`
/// so the two platforms describe the same payment the same way.
enum TransactionStatus: String, Codable {
    case pending
    case completed
    case failed
}

struct WalletTransaction: Identifiable, Codable {
    /// Composite of paymentHash + direction. A self-payment produces an
    /// (incoming, outgoing) pair that share a paymentHash; SwiftUI's
    /// `ForEach` collapses duplicate ids, so without the type suffix both
    /// rows render as whichever direction `ForEach` picked.
    var id: String { "\(paymentHash)|\(type.rawValue)" }
    let type: TransactionType
    let description: String?
    let paymentHash: String
    let amountMsats: Int64
    let feeMsats: Int64
    let createdAt: Int64
    let settledAt: Int64?
    let counterpartyPubkey: String?
    /// Settlement state as reported by the backing wallet. Optional because
    /// NWC (NIP-47) doesn't carry an explicit status, and because rows cached
    /// before status tracking existed must still decode — read it through
    /// `resolvedStatus`, never directly.
    var status: TransactionStatus?

    /// The transaction's settlement state, with a fallback for sources that
    /// don't report one. NIP-47 only sets `settled_at` once a payment has
    /// settled, so its absence means the payment is still in flight — which
    /// is also the right reading for legacy cached rows.
    var resolvedStatus: TransactionStatus {
        if let status { return status }
        return settledAt != nil ? .completed : .pending
    }

    /// True when the payment has not yet settled (on-chain confirmations pending or
    /// Lightning HTLC in flight).
    var pending: Bool { resolvedStatus == .pending }
    /// Real Bitcoin txid for on-chain deposits/withdrawals. Set from
    /// `PaymentDetails.deposit(txId:)` / `.withdraw(txId:)` in listTransactions.
    var bitcoinTxId: String?

    /// Ticker of the asset this row moved, when it wasn't bitcoin — e.g.
    /// "USDB". Nil for every sats payment, which is the overwhelming majority.
    ///
    /// Spark wallets can hold tokens alongside sats, and `Payment.amount` is
    /// documented as "satoshis **or token base units**" depending on the
    /// payment. Wisp doesn't offer token conversion, but a wallet restored
    /// from the same seed in an app that does will hand us those payments
    /// anyway, and rendering their base units as sats turns a $150 stablecoin
    /// transfer into "15,766,673 sats".
    ///
    /// When this is set, `amountMsats` / `feeMsats` are zero: there is no
    /// honest sats value for a token transfer, so nothing sats-denominated —
    /// including fiat conversion — may be derived from this row.
    var assetTicker: String?
    /// Amount already scaled by the token's decimals, at full precision.
    /// Kept as a string because token base units are `U128` and can exceed
    /// `Int64`. The detail sheet shows this; the row shows
    /// `assetAmountCompact`.
    var assetAmount: String?

    /// Row-sized form of `assetAmount`. A 6-decimal stablecoin renders as
    /// "15.766673" at full precision, which is both unreadable at a glance
    /// and wrong for what the number means — USDB is dollars, and dollars get
    /// two places. Dust that would round away to "0.00" keeps its full
    /// precision instead, so a real balance never displays as nothing.
    var assetAmountCompact: String? {
        assetAmount.map { Self.compactTokenAmount($0) }
    }
    /// Fee in the same asset, scaled the same way. Nil when the fee is zero.
    var assetFee: String?

    /// True when this row moved something other than bitcoin.
    var isTokenTransfer: Bool { assetTicker != nil }

    /// Spark surfaces on-chain transactions with a UUID-formatted ID (contains hyphens)
    /// while Lightning payment hashes are always 64-char hex. Also true when a
    /// real Bitcoin txid was extracted from the payment details.
    var isOnchain: Bool {
        if bitcoinTxId != nil { return true }
        // A token transfer's id is its token tx hash, which can carry the same
        // hyphens the UUID heuristic below keys off — it is never on-chain.
        if isTokenTransfer { return false }
        return paymentHash.contains("-")
    }

    enum TransactionType: String, Codable {
        case incoming
        case outgoing
    }

    /// Shift a token's base-unit amount by its decimal places for display.
    ///
    /// Operates on the decimal string rather than a numeric type on purpose:
    /// base units are `U128` and can exceed `Int64`, and `Double` would start
    /// losing cents well before that. Trailing zeros are dropped so a whole
    /// amount reads "150" rather than "150.000000".
    static func scaleTokenAmount(baseUnits: String, decimals: UInt32) -> String {
        let digits = baseUnits.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return baseUnits }
        guard decimals > 0 else { return digits }

        let places = Int(decimals)
        let padded = digits.count > places
            ? digits
            : String(repeating: "0", count: places - digits.count + 1) + digits
        let splitIndex = padded.index(padded.endIndex, offsetBy: -places)
        let whole = String(padded[padded.startIndex..<splitIndex])
        var fraction = String(padded[splitIndex...])

        while fraction.last == "0" { fraction.removeLast() }
        return fraction.isEmpty ? whole : "\(whole).\(fraction)"
    }

    /// Round a scaled token amount to two decimal places for display.
    ///
    /// Uses `Decimal`, not `Double`: these are money-shaped values and binary
    /// floating point starts misrepresenting cents well before the range a
    /// `U128` token can reach. Anything `Decimal` can't parse — or any amount
    /// that would round to zero without being zero — is passed through at full
    /// precision rather than displayed as a number it isn't.
    static func compactTokenAmount(_ scaled: String, places: Int = 2) -> String {
        guard scaled.contains("."), let value = Decimal(string: scaled) else { return scaled }
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, places, .plain)
        if rounded.isZero && !value.isZero { return scaled }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = places
        formatter.maximumFractionDigits = places
        formatter.usesGroupingSeparator = true
        return formatter.string(from: rounded as NSDecimalNumber) ?? scaled
    }
}

/// On-disk cache of last-known wallet state per pubkey. Lets the wallet tab
/// show real numbers instantly on cold launch instead of `?` while the network
/// catches up. Updated by `WalletStore` on every balance/transaction refresh.
enum WalletCache {
    private static func balanceKey(_ pubkey: String) -> String { "wallet_balance_msats_\(pubkey)" }
    private static func txsKey(_ pubkey: String) -> String { "wallet_transactions_\(pubkey)" }

    static func loadBalance(for pubkey: String) -> Int64? {
        let v = UserDefaults.standard.object(forKey: balanceKey(pubkey)) as? NSNumber
        return v?.int64Value
    }

    static func saveBalance(_ msats: Int64, for pubkey: String) {
        UserDefaults.standard.set(NSNumber(value: msats), forKey: balanceKey(pubkey))
    }

    static func loadTransactions(for pubkey: String) -> [WalletTransaction] {
        guard let data = UserDefaults.standard.data(forKey: txsKey(pubkey)),
              let txs = try? JSONDecoder().decode([WalletTransaction].self, from: data) else { return [] }
        return txs
    }

    static func saveTransactions(_ txs: [WalletTransaction], for pubkey: String) {
        // Cap at 50 to keep UserDefaults footprint small.
        let trimmed = Array(txs.prefix(50))
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: txsKey(pubkey))
        }
    }

    static func clear(for pubkey: String) {
        UserDefaults.standard.removeObject(forKey: balanceKey(pubkey))
        UserDefaults.standard.removeObject(forKey: txsKey(pubkey))
    }
}

enum WalletError: Error, LocalizedError {
    case notConnected
    case decodeFailed(String)
    case rpcError(code: String, message: String)
    case timeout
    case unsupportedEncryption
    case insufficientBalance
    case other(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Wallet not connected"
        case .decodeFailed(let m): "Decode failed: \(m)"
        case .rpcError(let code, let m): "\(code): \(m)"
        case .timeout: "Request timed out"
        case .unsupportedEncryption: "Wallet does not support requested encryption"
        case .insufficientBalance: "Insufficient balance"
        case .other(let m): m
        }
    }
}
