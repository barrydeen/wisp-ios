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

struct WalletTransaction: Identifiable, Codable {
    var id: String { paymentHash }
    let type: TransactionType
    let description: String?
    let paymentHash: String
    let amountMsats: Int64
    let feeMsats: Int64
    let createdAt: Int64
    let settledAt: Int64?
    let counterpartyPubkey: String?

    enum TransactionType: String, Codable {
        case incoming
        case outgoing
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
