import Foundation
import Observation

/// Top-level wallet orchestrator. Holds the active `Wallet` instance for the current
/// account, exposes Observation-driven UI state, and runs the relay-backup
/// search/publish flows for the Spark seed.
@Observable
@MainActor
final class WalletStore {
    private(set) var keypair: Keypair
    private(set) var mode: WalletMode?
    private(set) var balanceMsats: Int64?
    private(set) var isConnected: Bool = false
    private(set) var lastStatus: String?
    private(set) var transactions: [WalletTransaction] = []

    /// Backup search/publish progress for the Spark relay-backup flow.
    private(set) var relayBackupSearchState: BackupSearchState = .idle
    private(set) var relayBackupPublishState: BackupPublishState = .idle
    private(set) var lightningAddress: String?

    private var wallet: Wallet?
    private var statusTask: Task<Void, Never>?
    private var paymentTask: Task<Void, Never>?
    private var balanceTask: Task<Void, Never>?

    enum BackupSearchState: Equatable {
        case idle
        case searching
        case found(BackupEntry)
        case multiple([BackupEntry])
        case notFound
        case error(String)

        static func == (lhs: BackupSearchState, rhs: BackupSearchState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.searching, .searching), (.notFound, .notFound): true
            case (.found(let a), .found(let b)): a.id == b.id
            case (.multiple(let a), .multiple(let b)): a.map(\.id) == b.map(\.id)
            case (.error(let a), .error(let b)): a == b
            default: false
            }
        }
    }

    enum BackupPublishState: Equatable {
        case idle
        case publishing
        case success(acceptedRelays: [String])
        case error(String)
    }

    init(keypair: Keypair) {
        self.keypair = keypair
        self.mode = WalletMode.load(for: keypair.pubkey)
        self.balanceMsats = WalletCache.loadBalance(for: keypair.pubkey)
        self.transactions = WalletCache.loadTransactions(for: keypair.pubkey)
        // NWC lud16 is embedded in the stored URI — no connection needed.
        self.lightningAddress = Self.cachedLightningAddress(for: keypair.pubkey)
    }

    // MARK: - Seed backup (Spark mnemonic wallets only)

    /// Whether the user has acknowledged viewing their recovery phrase.
    var seedBackupAcknowledged: Bool {
        (wallet as? SparkWallet)?.isSeedBackupAcknowledged() ?? true
    }

    func acknowledgeSeedBackup() {
        (wallet as? SparkWallet)?.setSeedBackupAcknowledged(true)
    }

    /// Mnemonic for the active Spark wallet, nil for NWC or nsec-derived.
    var sparkMnemonic: String? {
        (wallet as? SparkWallet)?.loadMnemonic()
    }

    // MARK: - Disconnect / delete

    /// Disconnect the wallet, clear all credentials, and reset mode to nil so the
    /// mode-selection screen re-appears. Safe to call from any wallet type.
    func resetToNoWallet() {
        let currentMode = mode
        let currentPubkey = keypair.pubkey
        disconnect()
        switch currentMode {
        case .nwc:
            WalletKeychain.deleteNwcUri(for: currentPubkey)
        case .spark:
            WalletKeychain.deleteSparkMnemonic(for: currentPubkey)
            WalletCache.clear(for: currentPubkey)
        case nil:
            break
        }
        WalletMode.clear(for: currentPubkey)
        mode = nil
        balanceMsats = nil
        transactions = []
        lightningAddress = nil
        relayBackupSearchState = .idle
        relayBackupPublishState = .idle
    }

    // MARK: - Wallet selection

    var activeWallet: Wallet? { wallet }

    func reload(for keypair: Keypair) {
        guard keypair.pubkey != self.keypair.pubkey else { return }
        disconnect()
        self.keypair = keypair
        self.mode = WalletMode.load(for: keypair.pubkey)
        self.balanceMsats = WalletCache.loadBalance(for: keypair.pubkey)
        self.transactions = WalletCache.loadTransactions(for: keypair.pubkey)
        self.lightningAddress = Self.cachedLightningAddress(for: keypair.pubkey)
    }

    /// Synchronously extracts a lightning address from stored credentials without a network
    /// call. For NWC wallets the lud16 is embedded in the URI; for Spark it requires an async
    /// SDK call so we return nil here (refreshLightningAddress() fills it in later).
    private static func cachedLightningAddress(for pubkey: String) -> String? {
        guard WalletMode.load(for: pubkey) == .nwc,
              let uri = WalletKeychain.loadNwcUri(for: pubkey),
              let conn = NwcConnection.parse(uri) else { return nil }
        return conn.lud16
    }

    /// Try to bring up whatever wallet the user previously configured. Safe to call repeatedly.
    /// On a re-call after wallet is already wired up, just refresh balance + transactions
    /// in the background so the user sees fresh data on tab open.
    func startIfConfigured() async {
        guard let mode else { return }
        if wallet == nil {
            try? await switchToMode(mode)
            await refreshLightningAddress()
        } else if isConnected {
            _ = await fetchBalance()
            await refreshTransactions()
            await refreshLightningAddress()
        }
    }

    func refreshLightningAddress() async {
        if let spark = wallet as? SparkWallet {
            lightningAddress = await spark.fetchLightningAddress()
        } else if let nwc = wallet as? NwcWallet {
            lightningAddress = nwc.lud16
        }
    }

    func checkLightningAddressAvailable(username: String) async -> Bool {
        guard let spark = wallet as? SparkWallet else { return false }
        return await spark.checkLightningAddressAvailable(username: username)
    }

    func registerLightningAddress(username: String) async throws {
        guard let spark = wallet as? SparkWallet else { throw WalletError.notConnected }
        lightningAddress = try await spark.registerLightningAddress(username: username)
    }

    func removeLightningAddress() async throws {
        guard let spark = wallet as? SparkWallet else { throw WalletError.notConnected }
        try await spark.deleteLightningAddress()
        lightningAddress = nil
    }

    @discardableResult
    func switchToMode(_ newMode: WalletMode) async throws -> Bool {
        disconnect()
        let newWallet: Wallet = newMode == .nwc
            ? NwcWallet(pubkey: keypair.pubkey)
            : SparkWallet(pubkey: keypair.pubkey)
        guard newWallet.hasConnection() else {
            wallet = newWallet
            mode = newMode
            WalletMode.save(newMode, for: keypair.pubkey)
            return false
        }
        wireUp(newWallet)
        mode = newMode
        WalletMode.save(newMode, for: keypair.pubkey)
        await newWallet.connect()
        isConnected = newWallet.isConnected
        // Fire-and-forget the balance/transactions refresh — the dashboard already
        // renders the cached values from `WalletCache` instantly, and live updates
        // arrive via the wallet's balanceUpdates stream when the SDK syncs.
        if newWallet.isConnected {
            Task { _ = await self.fetchBalance() }
            Task { await self.refreshTransactions() }
            Task { await self.refreshLightningAddress() }
        }
        return newWallet.isConnected
    }

    /// Persist a new NWC URI and connect.
    func connectNwc(uri: String) async -> Bool {
        guard let _ = NwcConnection.parse(uri) else { return false }
        let nwc = NwcWallet(pubkey: keypair.pubkey)
        nwc.saveConnection(uri)
        disconnect()
        wireUp(nwc)
        mode = .nwc
        WalletMode.save(.nwc, for: keypair.pubkey)
        await nwc.connect()
        isConnected = nwc.isConnected
        if isConnected {
            Task { _ = await self.fetchBalance() }
            Task { await self.refreshTransactions() }
        }
        return isConnected
    }

    /// Save a Spark mnemonic and connect.
    @discardableResult
    func connectSpark(mnemonic: String) async -> Bool {
        let spark = SparkWallet(pubkey: keypair.pubkey)
        spark.saveMnemonic(mnemonic)
        disconnect()
        wireUp(spark)
        mode = .spark
        WalletMode.save(.spark, for: keypair.pubkey)
        await spark.connect()
        isConnected = spark.isConnected
        if isConnected {
            Task { _ = await self.fetchBalance() }
            Task { await self.refreshTransactions() }
        }
        return isConnected
    }

    func disconnect() {
        statusTask?.cancel(); statusTask = nil
        paymentTask?.cancel(); paymentTask = nil
        balanceTask?.cancel(); balanceTask = nil
        wallet?.disconnect()
        wallet = nil
        isConnected = false
    }

    private func wireUp(_ wallet: Wallet) {
        self.wallet = wallet
        statusTask = Task { [weak self] in
            for await status in wallet.statusLog {
                self?.lastStatus = status
            }
        }
        paymentTask = Task { [weak self] in
            for await _ in wallet.paymentReceived {
                _ = await self?.fetchBalance()
            }
        }
        balanceTask = Task { [weak self] in
            for await msats in wallet.balanceUpdates {
                guard let self else { return }
                self.balanceMsats = msats
                WalletCache.saveBalance(msats, for: self.keypair.pubkey)
            }
        }
    }

    // MARK: - Wallet ops (proxied)

    @discardableResult
    func fetchBalance() async -> Int64? {
        guard let wallet else { return nil }
        if case .success(let msats) = await wallet.fetchBalance() {
            balanceMsats = msats
            WalletCache.saveBalance(msats, for: keypair.pubkey)
            return msats
        }
        return nil
    }

    func payInvoice(_ bolt11: String) async -> Result<String, WalletError> {
        guard let wallet else { return .failure(.notConnected) }
        return await wallet.payInvoice(bolt11)
    }

    func makeInvoice(amountSats: Int64, description: String) async -> Result<String, WalletError> {
        guard let wallet else { return .failure(.notConnected) }
        return await wallet.makeInvoice(amountMsats: amountSats * 1000, description: description)
    }

    func refreshTransactions() async {
        guard let wallet else { return }
        if case .success(let txs) = await wallet.listTransactions(limit: 50, offset: 0) {
            transactions = txs
            WalletCache.saveTransactions(txs, for: keypair.pubkey)
        }
    }

    // MARK: - Spark relay backup

    /// Search relays for a previously-published encrypted seed backup. Mirrors the Android
    /// `searchRelayBackup`: query top-scored relays for kind 30078 events authored by us,
    /// dedupe by d-tag, decrypt with our own privkey, present results.
    func searchRelayBackup() async {
        relayBackupSearchState = .searching
        guard let privkey32 = Hex.decode(keypair.privkey) else {
            relayBackupSearchState = .error("No signing key available")
            return
        }

        let relays = backupRelays()
        guard !relays.isEmpty else {
            relayBackupSearchState = .error("No relays configured")
            return
        }

        let events = await RelayPool.query(
            relays: relays,
            filter: Nip78Backup.backupFilter(pubkey: keypair.pubkey),
            timeout: 10
        )

        // Filter to spark-wallet-backup d-tag, dedupe by d-tag (newest wins).
        let valid = events.filter { event in
            guard let dTag = Nip78Backup.extractDTag(event) else { return false }
            return dTag.hasPrefix("spark-wallet-backup") && !Nip78Backup.isDeletedBackup(event)
        }
        var newestPerWallet: [String: NostrEvent] = [:]
        for event in valid {
            guard let dTag = Nip78Backup.extractDTag(event) else { continue }
            if let existing = newestPerWallet[dTag], existing.createdAt >= event.createdAt { continue }
            newestPerWallet[dTag] = event
        }

        if newestPerWallet.isEmpty {
            relayBackupSearchState = .notFound
            return
        }

        let entries: [BackupEntry] = newestPerWallet.values.compactMap { event -> BackupEntry? in
            guard let mnemonic = Nip78Backup.decryptBackup(privkey32: privkey32, event: event) else { return nil }
            return BackupEntry(
                mnemonic: mnemonic,
                walletId: Nip78Backup.extractWalletId(event),
                createdAt: event.createdAt
            )
        }.sorted { $0.createdAt > $1.createdAt }

        switch entries.count {
        case 0: relayBackupSearchState = .notFound
        case 1: relayBackupSearchState = .found(entries[0])
        default: relayBackupSearchState = .multiple(entries)
        }
    }

    func selectBackupToRestore(_ entry: BackupEntry) {
        relayBackupSearchState = .found(entry)
    }

    func resetRelayBackupSearch() {
        relayBackupSearchState = .idle
    }

    /// Encrypt the active Spark mnemonic and publish a kind 30078 backup event.
    func publishRelayBackup() async {
        relayBackupPublishState = .publishing
        guard let spark = wallet as? SparkWallet, let mnemonic = spark.loadMnemonic() else {
            relayBackupPublishState = .error("No Spark wallet to back up")
            return
        }
        guard let privkey32 = Hex.decode(keypair.privkey) else {
            relayBackupPublishState = .error("No signing key")
            return
        }
        do {
            let event = try Nip78Backup.createBackupEvent(
                privkey32: privkey32,
                pubkeyHex: keypair.pubkey,
                mnemonic: mnemonic
            )
            let relays = backupRelays()
            let accepted = await RelayPool.publish(event: event, to: relays, timeout: 6)
            if accepted.isEmpty {
                relayBackupPublishState = .error("No relays accepted the backup")
            } else {
                relayBackupPublishState = .success(acceptedRelays: accepted)
            }
        } catch {
            relayBackupPublishState = .error(error.localizedDescription)
        }
    }

    func resetRelayBackupPublish() {
        relayBackupPublishState = .idle
    }

    /// The relay set we use for backup publish/search. Use the user's scored write relays
    /// so we go to the same places as the rest of the app's writes.
    private func backupRelays() -> [String] {
        if let board = RelayScoreBoard.load(pubkey: keypair.pubkey) {
            let top = board.scoredRelays.prefix(20).map(\.url)
            if !top.isEmpty { return top }
        }
        // Fallback: a small set of high-availability public relays.
        return [
            "wss://relay.damus.io",
            "wss://nos.lol",
            "wss://relay.primal.net",
            "wss://nostr.wine"
        ]
    }
}
