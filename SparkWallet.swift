import Foundation
import BreezSdkSpark
import BigNumber

/// Embedded self-custodial Lightning wallet via the Breez Spark SDK.
/// Mirrors the Android `SparkRepository` semantics: the mnemonic is the source of truth
/// (stored in Keychain), the SDK is reconnected each launch, and balance / payments
/// are surfaced via async streams.
@MainActor
final class SparkWallet: Wallet {
    private let pubkey: String
    private var sdk: BreezSdk?
    private var listenerId: String?

    private(set) var balanceMsats: Int64?
    private(set) var isConnected: Bool = false

    let statusLog: AsyncStream<String>
    let paymentReceived: AsyncStream<Int64>
    let balanceUpdates: AsyncStream<Int64>
    private let statusContinuation: AsyncStream<String>.Continuation
    private let paymentContinuation: AsyncStream<Int64>.Continuation
    private let balanceContinuation: AsyncStream<Int64>.Continuation

    init(pubkey: String) {
        self.pubkey = pubkey
        var sCont: AsyncStream<String>.Continuation!
        self.statusLog = AsyncStream { c in sCont = c }
        self.statusContinuation = sCont
        var pCont: AsyncStream<Int64>.Continuation!
        self.paymentReceived = AsyncStream { c in pCont = c }
        self.paymentContinuation = pCont
        var bCont: AsyncStream<Int64>.Continuation!
        self.balanceUpdates = AsyncStream { c in bCont = c }
        self.balanceContinuation = bCont
    }

    // MARK: - Mnemonic management

    func hasConnection() -> Bool {
        WalletKeychain.loadSparkMnemonic(for: pubkey) != nil
    }

    func loadMnemonic() -> String? {
        WalletKeychain.loadSparkMnemonic(for: pubkey)
    }

    func saveMnemonic(_ mnemonic: String) {
        WalletKeychain.saveSparkMnemonic(Nip78Backup.normalizeMnemonic(mnemonic), for: pubkey)
        UserDefaults.standard.removeObject(forKey: "spark_seed_acked_\(pubkey)")
    }

    func clearMnemonic() {
        WalletKeychain.deleteSparkMnemonic(for: pubkey)
        UserDefaults.standard.removeObject(forKey: "spark_seed_acked_\(pubkey)")
        balanceMsats = nil
        isConnected = false
    }

    func isSeedBackupAcknowledged() -> Bool {
        UserDefaults.standard.bool(forKey: "spark_seed_acked_\(pubkey)")
    }

    func setSeedBackupAcknowledged(_ acked: Bool) {
        UserDefaults.standard.set(acked, forKey: "spark_seed_acked_\(pubkey)")
    }

    // MARK: - Lifecycle

    private var storageDir: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("spark_data", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    func connect() async {
        guard let mnemonic = loadMnemonic() else {
            emit("No mnemonic configured")
            return
        }
        guard BreezConfig.hasApiKey else {
            emit("Breez API key missing — set BREEZ_API_KEY in Secrets.xcconfig")
            return
        }

        emit("Initializing Spark SDK…")

        do {
            let seed = Seed.mnemonic(mnemonic: mnemonic, passphrase: nil)
            var config = defaultConfig(network: Network.mainnet)
            config.apiKey = BreezConfig.apiKey

            let sdk = try await BreezSdkSpark.connect(
                request: ConnectRequest(
                    config: config,
                    seed: seed,
                    storageDir: storageDir
                )
            )
            self.sdk = sdk

            let listener = SparkEventBridge { [weak self] event in
                Task { @MainActor in self?.handle(event: event) }
            }
            self.listenerId = await sdk.addEventListener(listener: listener)

            isConnected = true
            emit("Connected to Spark")
            // Fire-and-forget — don't block connect() on a slow first sync. The SDK's
            // own `.synced` event will trigger another refreshBalance once the wallet
            // has caught up. Until then, the dashboard renders the cached balance from
            // UserDefaults so the user isn't staring at a spinner.
            Task { await self.refreshBalance() }
        } catch {
            emit("Connection failed: \(error.localizedDescription)")
            isConnected = false
        }
    }

    func disconnect() {
        let captured = sdk
        let captuedListener = listenerId
        sdk = nil
        listenerId = nil
        isConnected = false
        guard let captured else { return }
        Task.detached {
            if let id = captuedListener {
                await captured.removeEventListener(id: id)
            }
            try? await captured.disconnect()
        }
    }

    private func handle(event: SdkEvent) {
        switch event {
        case .synced:
            emit("Synced")
            Task { await self.refreshBalance() }
        case .paymentSucceeded(let payment):
            emit("Payment succeeded")
            let amountSats = Int64(payment.amount.description) ?? 0
            if payment.paymentType == .receive {
                paymentContinuation.yield(amountSats * 1000)
            }
            Task { await self.refreshBalance() }
        case .paymentFailed:
            emit("Payment failed")
        case .paymentPending:
            emit("Payment pending")
        default:
            break
        }
    }

    private func refreshBalance() async {
        guard let sdk else { return }
        do {
            // Always read the SDK's cached balance — never block on a network sync.
            // Fresh data arrives via `.synced` events which trigger another call here.
            let info = try await sdk.getInfo(request: GetInfoRequest(ensureSynced: false))
            let msats = Int64(info.balanceSats) * 1000
            balanceMsats = msats
            balanceContinuation.yield(msats)
        } catch {
            emit("Balance refresh failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Lightning address

    func fetchLightningAddress() async -> String? {
        guard let sdk else { return nil }
        return try? await sdk.getLightningAddress()?.lightningAddress
    }

    func checkLightningAddressAvailable(username: String) async -> Bool {
        guard let sdk else { return false }
        return (try? await sdk.checkLightningAddressAvailable(
            req: CheckLightningAddressRequest(username: username)
        )) ?? false
    }

    func registerLightningAddress(username: String) async throws -> String {
        guard let sdk else { throw WalletError.notConnected }
        let info = try await sdk.registerLightningAddress(
            request: RegisterLightningAddressRequest(username: username)
        )
        return info.lightningAddress
    }

    func deleteLightningAddress() async throws {
        guard let sdk else { throw WalletError.notConnected }
        try await sdk.deleteLightningAddress()
    }

    // MARK: - Wallet ops

    func fetchBalance() async -> Result<Int64, WalletError> {
        guard let sdk else { return .failure(.notConnected) }
        do {
            let info = try await sdk.getInfo(request: GetInfoRequest(ensureSynced: false))
            let msats = Int64(info.balanceSats) * 1000
            balanceMsats = msats
            balanceContinuation.yield(msats)
            return .success(msats)
        } catch {
            return .failure(.other(error.localizedDescription))
        }
    }

    func payInvoice(_ bolt11: String) async -> Result<String, WalletError> {
        guard let sdk else { return .failure(.notConnected) }
        do {
            emit("Preparing payment…")
            let prepare = try await sdk.prepareSendPayment(
                request: PrepareSendPaymentRequest(
                    paymentRequest: bolt11,
                    amount: nil,
                    tokenIdentifier: nil,
                    conversionOptions: nil,
                    feePolicy: nil
                )
            )
            emit("Sending payment…")
            let response = try await sdk.sendPayment(
                request: SendPaymentRequest(
                    prepareResponse: prepare,
                    options: SendPaymentOptions.bolt11Invoice(preferSpark: false, completionTimeoutSecs: 30),
                    idempotencyKey: nil
                )
            )
            return .success(response.payment.id)
        } catch {
            emit("Payment failed: \(error.localizedDescription)")
            return .failure(.other(error.localizedDescription))
        }
    }

    func makeInvoice(amountMsats: Int64, description: String) async -> Result<String, WalletError> {
        guard let sdk else { return .failure(.notConnected) }
        do {
            let amountSats = UInt64(max(amountMsats / 1000, 1))
            let response = try await sdk.receivePayment(
                request: ReceivePaymentRequest(
                    paymentMethod: ReceivePaymentMethod.bolt11Invoice(
                        description: description.isEmpty ? "Wisp wallet" : description,
                        amountSats: amountSats,
                        expirySecs: 3600,
                        paymentHash: nil
                    )
                )
            )
            return .success(response.paymentRequest)
        } catch {
            return .failure(.other(error.localizedDescription))
        }
    }

    func listTransactions(limit: Int, offset: Int) async -> Result<[WalletTransaction], WalletError> {
        guard let sdk else { return .failure(.notConnected) }
        do {
            let response = try await sdk.listPayments(
                request: ListPaymentsRequest(
                    offset: UInt32(offset),
                    limit: UInt32(limit),
                    sortAscending: false
                )
            )
            let txs: [WalletTransaction] = response.payments.map { payment in
                let amountSats = Int64(payment.amount.description) ?? 0
                let feeSats = Int64(payment.fees.description) ?? 0
                let lightning = payment.details.flatMap { details -> (invoice: String, description: String?)? in
                    if case .lightning(let description, let invoice, _, _, _, _, _) = details {
                        return (invoice, description)
                    }
                    return nil
                }
                let decoded = lightning.flatMap { Bolt11.decode($0.invoice) }
                let paymentHash = decoded?.paymentHash ?? payment.id
                let description = lightning?.description ?? decoded?.description
                return WalletTransaction(
                    type: payment.paymentType == .send ? .outgoing : .incoming,
                    description: description,
                    paymentHash: paymentHash,
                    amountMsats: amountSats * 1000,
                    feeMsats: feeSats * 1000,
                    createdAt: Int64(payment.timestamp),
                    settledAt: Int64(payment.timestamp),
                    counterpartyPubkey: nil
                )
            }
            return .success(txs)
        } catch {
            return .failure(.other(error.localizedDescription))
        }
    }

    private func emit(_ message: String) {
        statusContinuation.yield(message)
    }
}

// Bridge struct so the SDK's non-Sendable `EventListener` protocol can be implemented
// without forcing `SparkWallet` itself into a non-isolated context.
private final class SparkEventBridge: EventListener {
    private let onEvent: (SdkEvent) -> Void
    init(onEvent: @escaping (SdkEvent) -> Void) { self.onEvent = onEvent }
    func onEvent(event: SdkEvent) async { onEvent(event) }
}

