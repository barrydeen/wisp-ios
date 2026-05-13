import Foundation
import Observation
import os.log

private let backupSearchLog = Logger(subsystem: "wisp", category: "wallet-backup")

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
    /// NIP-47 wallet service alias, e.g. the LSP / hub node name. Surfaced
    /// next to the NWC logo when set. Nil for Spark or before the first
    /// `get_info` round-trip lands.
    private(set) var nwcNodeAlias: String?
    /// Method names the NWC wallet service advertised in its last
    /// `get_info` response. Rendered as chips in wallet settings so the
    /// user can see what the connection actually supports.
    private(set) var nwcMethods: [String] = []

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

    /// First 16 hex chars of the SHA-256 of the Spark wallet's mnemonic.
    /// Same format used for the NIP-78 backup d-tag, so the user sees the
    /// same identifier surfaced in their cross-device backup. Nil for NWC.
    var sparkWalletId: String? {
        guard let mnemonic = sparkMnemonic else { return nil }
        return Nip78Backup.computeWalletId(mnemonic)
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
        nwcNodeAlias = nil
        nwcMethods = []
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
        self.nwcNodeAlias = nil
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

    /// Read-only view of the active NWC connection details for the
    /// settings screen. Nil when not in NWC mode or when the URI isn't
    /// parseable. Pulled fresh from the keychain on each call so settings
    /// reflects the current state after a re-connect.
    var nwcConnectionDetails: NwcConnection? {
        guard mode == .nwc,
              let uri = WalletKeychain.loadNwcUri(for: keypair.pubkey) else { return nil }
        return NwcConnection.parse(uri)
    }

    /// Try to bring up whatever wallet the user previously configured. Safe to call repeatedly.
    /// On a re-call after wallet is already wired up, just refresh balance + transactions
    /// in the background so the user sees fresh data on tab open.
    func startIfConfigured() async {
        guard let mode else { return }
        if wallet == nil {
            try? await switchToMode(mode)
            await refreshLightningAddress()
            await refreshNwcNodeAlias()
        } else if isConnected {
            _ = await fetchBalance()
            await refreshTransactions()
            await refreshLightningAddress()
            await refreshNwcNodeAlias()
        }
    }

    func refreshLightningAddress() async {
        if let spark = wallet as? SparkWallet {
            lightningAddress = await spark.fetchLightningAddress()
        } else if let nwc = wallet as? NwcWallet {
            lightningAddress = nwc.lud16
        }
    }

    /// Fetch the NWC wallet service's node alias via NIP-47 `get_info`.
    /// Surfaces immediately from the cache, then upgrades to the live value
    /// when the round-trip lands. No-op for Spark.
    func refreshNwcNodeAlias() async {
        guard let nwc = wallet as? NwcWallet else {
            nwcNodeAlias = nil
            nwcMethods = []
            return
        }
        nwcNodeAlias = nwc.nodeAlias
        nwcMethods = nwc.supportedMethods
        await nwc.fetchNodeAlias()
        nwcNodeAlias = nwc.nodeAlias
        nwcMethods = nwc.supportedMethods
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
            Task { await self.refreshNwcNodeAlias() }
        }
        return newWallet.isConnected
    }

    /// Persist a new NWC URI and connect.
    func connectNwc(uri: String) async -> Bool {
        guard let _ = NwcConnection.parse(uri) else { return false }
        let nwc = NwcWallet(pubkey: keypair.pubkey)
        nwc.saveConnection(uri)
        disconnect()
        // Drop the previous wallet's metadata so the dashboard / settings
        // can't render the old node alias, lud16, balance, or transaction
        // list while the new connection's `get_info` round-trip is still
        // in flight. Without this the user sees the old node's name with
        // a stale balance for several seconds after pasting a new URI.
        clearDisplayState()
        wireUp(nwc)
        mode = .nwc
        WalletMode.save(.nwc, for: keypair.pubkey)
        await nwc.connect()
        isConnected = nwc.isConnected
        if isConnected {
            Task { _ = await self.fetchBalance() }
            Task { await self.refreshTransactions() }
            Task { await self.refreshNwcNodeAlias() }
            Task { await self.refreshLightningAddress() }
        }
        return isConnected
    }

    /// Save a Spark mnemonic and connect.
    @discardableResult
    func connectSpark(mnemonic: String) async -> Bool {
        let spark = SparkWallet(pubkey: keypair.pubkey)
        spark.saveMnemonic(mnemonic)
        disconnect()
        clearDisplayState()
        wireUp(spark)
        mode = .spark
        WalletMode.save(.spark, for: keypair.pubkey)
        await spark.connect()
        isConnected = spark.isConnected
        if isConnected {
            Task { _ = await self.fetchBalance() }
            Task { await self.refreshTransactions() }
            Task { await self.refreshLightningAddress() }
        }
        return isConnected
    }

    /// Wipe every per-wallet UI surface so a swap to a different wallet
    /// (NWC URI or Spark mnemonic) doesn't carry the previous wallet's
    /// node alias / lightning address / balance / transaction list across.
    /// Called from the connect-flows; the app-launch reconnect path goes
    /// through `switchToMode` instead and intentionally keeps cached values
    /// so the user sees their last-known balance immediately.
    private func clearDisplayState() {
        balanceMsats = nil
        transactions = []
        lightningAddress = nil
        nwcNodeAlias = nil
        nwcMethods = []
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

    /// Detect whether the pasted string is a lightning address, LNURL, or bolt11 invoice.
    func detectInputType(_ input: String) async -> WalletInputType {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return .unknown }

        // Spark can parse natively via the SDK.
        if let spark = wallet as? SparkWallet {
            if let walletType = await spark.detectWalletInputType(trimmed) {
                return walletType
            }
        }

        // NWC / fallback: manual detection.
        if let decoded = Bolt11.decode(trimmed) {
            return .bolt11(amountSats: decoded.amountSats)
        }
        if LnurlResolver.isLightningAddress(trimmed) {
            return .lightningAddressNeedsResolve(trimmed, info: nil)
        }
        return .unknown
    }

    /// Pay a lightning address via LNURL-pay. For Spark uses the native SDK path;
    /// for NWC resolves the LNURL manually and pays the resulting bolt11.
    func payLightningAddress(_ address: String, amountSats: Int64) async -> Result<String, WalletError> {
        // Spark: parse + pay via the SDK's native LNURL-pay path.
        if let spark = wallet as? SparkWallet {
            let result = await spark.parseAndPayLnurl(address, amountSats: amountSats)
            if result != nil { return result! }
            // nil means "not a LNURL input" — fall through to manual resolution.
        }
        // NWC / fallback: resolve LNURL manually and pay the resulting bolt11.
        switch await LnurlResolver.resolve(address, amountMsats: amountSats * 1000) {
        case .success(let bolt11): return await payInvoice(bolt11)
        case .failure(let err):   return .failure(err)
        }
    }

    func makeInvoice(amountSats: Int64, description: String) async -> Result<String, WalletError> {
        guard let wallet else { return .failure(.notConnected) }
        return await wallet.makeInvoice(amountMsats: amountSats * 1000, description: description)
    }

    private(set) var hasMoreTransactions: Bool = false
    /// Last failure from `listTransactions`, surfaced in `TransactionHistoryView` so
    /// users (especially NWC) can see why the list is empty — `timeout` (wallet
    /// service unreachable / not listening), `rpcError` (e.g. wallet doesn't
    /// implement `list_transactions`), or a decode/transport failure. Cleared on
    /// the next successful fetch.
    private(set) var lastTransactionError: String?

    func refreshTransactions() async {
        guard let wallet else { return }
        let pageSize = 50
        switch await wallet.listTransactions(limit: pageSize, offset: 0) {
        case .success(let txs):
            transactions = txs
            hasMoreTransactions = txs.count == pageSize
            lastTransactionError = nil
            WalletCache.saveTransactions(txs, for: keypair.pubkey)
        case .failure(let err):
            lastTransactionError = err.errorDescription ?? "Failed to fetch transactions"
        }
    }

    func loadMoreTransactions() async {
        guard let wallet, hasMoreTransactions else { return }
        let pageSize = 50
        let offset = transactions.count
        if case .success(let more) = await wallet.listTransactions(limit: pageSize, offset: offset) {
            transactions.append(contentsOf: more)
            hasMoreTransactions = more.count == pageSize
        }
    }

    // MARK: - Spark relay backup

    /// Search relays for a previously-published encrypted seed backup. Mirrors the Android
    /// `searchRelayBackup`: query top-scored relays for kind 30078 events authored by us,
    /// dedupe by d-tag, decrypt with our own privkey, present results.
    func searchRelayBackup() async {
        relayBackupSearchState = .searching

        let relays = backupRelays()
        guard !relays.isEmpty else {
            relayBackupSearchState = .error("No relays configured")
            return
        }

        // `waitForAllRelays: true` so a slow relay holding the only copy of the
        // backup gets a chance to respond before its task is cancelled. The
        // default fast-path breaks 1.5s after the first EOSE, which is too
        // short for "publish-then-immediately-search" — relays that haven't
        // received-and-indexed the publish yet EOSE empty first and the slow
        // relay carrying it gets cut off before EVENT lands.
        backupSearchLog.notice("searching \(relays.count, privacy: .public) relays for kind-30078 by pubkey \(self.keypair.pubkey, privacy: .public)")
        let events = await RelayPool.query(
            relays: relays,
            filter: Nip78Backup.backupFilter(pubkey: keypair.pubkey),
            timeout: 10,
            waitForAllRelays: true
        )
        let sampleDtags = events.prefix(5).compactMap { Nip78Backup.extractDTag($0) }.joined(separator: ", ")
        backupSearchLog.notice("fetched \(events.count, privacy: .public) total kind-30078 events; sample d-tags: \(sampleDtags, privacy: .public)")

        // Filter to spark-wallet-backup d-tag, dedupe by d-tag (newest wins).
        let valid = events.filter { event in
            guard let dTag = Nip78Backup.extractDTag(event) else { return false }
            return dTag.hasPrefix("spark-wallet-backup") && !Nip78Backup.isDeletedBackup(event)
        }
        backupSearchLog.notice("after spark-wallet-backup d-tag filter: \(valid.count, privacy: .public) events")
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

        // Decrypt every candidate concurrently. For nsec accounts each call
        // resolves in-process and the loop is near-instant either way; for
        // remote-signer accounts each call is a NIP-46 RPC round-trip
        // (relay → bunker → relay → app), so parallelizing N decrypts
        // collapses N × per-call latency into roughly the slowest single
        // round-trip. The signer sees N concurrent requests; modern bunkers
        // handle that fine, and the user sees one auth prompt per backup
        // either way (sequential or parallel — same prompt count).
        let kp = keypair
        struct DecryptResult { let event: NostrEvent; let outcome: Nip78Backup.DecryptOutcome }
        let results: [DecryptResult] = await withTaskGroup(of: DecryptResult.self) { group in
            for event in newestPerWallet.values {
                group.addTask {
                    let outcome = await Nip78Backup.decryptBackup(keypair: kp, event: event)
                    return DecryptResult(event: event, outcome: outcome)
                }
            }
            var collected: [DecryptResult] = []
            for await result in group { collected.append(result) }
            return collected
        }

        var entries: [BackupEntry] = []
        var lastDecryptError: Error?
        var failedDecryptCount = 0
        for result in results {
            switch result.outcome {
            case .ok(let mnemonic):
                entries.append(BackupEntry(
                    mnemonic: mnemonic,
                    walletId: Nip78Backup.extractWalletId(result.event),
                    createdAt: result.event.createdAt
                ))
            case .skip:
                continue
            case .failed(let error):
                lastDecryptError = error
                failedDecryptCount += 1
            }
        }
        entries.sort { $0.createdAt > $1.createdAt }

        // Distinguish "relays returned nothing usable" from "your signer
        // refused to decrypt every backup we found" — the second is a
        // signer-perms / connectivity issue, not actually missing data,
        // and the user needs different next steps.
        if entries.isEmpty {
            if failedDecryptCount > 0, let lastDecryptError {
                relayBackupSearchState = .error(
                    "Found \(failedDecryptCount) backup\(failedDecryptCount == 1 ? "" : "s") but couldn't decrypt — \(lastDecryptError.localizedDescription)"
                )
            } else {
                relayBackupSearchState = .notFound
            }
            return
        }

        switch entries.count {
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

    /// False for NIP-46 remote-signer accounts. Relay backup writes are gated
    /// off as a precaution until cross-client backup decryption is verified for
    /// every remote-signer path the app might be used with. Restore stays
    /// enabled — legacy backups that already decrypt remain usable.
    var isRelayBackupSupported: Bool { !keypair.isRemote }

    /// Encrypt the active Spark mnemonic and publish a kind 30078 backup event.
    /// Disabled for remote-signer (NIP-46) accounts — see `isRelayBackupSupported`.
    func publishRelayBackup() async {
        relayBackupPublishState = .publishing
        guard !keypair.isRemote else {
            relayBackupPublishState = .error("Cloud backup is disabled for remote-signer accounts. Write down your recovery phrase instead.")
            return
        }
        guard let spark = wallet as? SparkWallet, let mnemonic = spark.loadMnemonic() else {
            relayBackupPublishState = .error("No Spark wallet to back up")
            return
        }
        do {
            let event = try await Nip78Backup.createBackupEvent(
                keypair: keypair,
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
