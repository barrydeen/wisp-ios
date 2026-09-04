import Foundation
import BreezSdkSpark
import BigNumber
import CryptoKit

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

    // MARK: - nsec-derived default wallet

    /// Derive the default Spark wallet deterministically from the user's Nostr
    /// private key so it is recoverable on any device by signing in with the
    /// same key. The mnemonic is HKDF-SHA256(privkey) → 16 bytes entropy →
    /// BIP-39, matching Android `Keys.deriveSparkEntropy` /
    /// `SparkRepository.generateDefaultFromPrivkey`.
    @discardableResult
    func generateDefaultFromPrivkey(_ privkey: Data) throws -> String {
        let entropy = Self.deriveSparkEntropy(privkey: privkey)
        let mnemonic = try Bip39.mnemonic(fromEntropy: entropy)
        saveMnemonic(mnemonic)
        return mnemonic
    }

    /// True when the currently-saved mnemonic matches the deterministic
    /// `Bip39.mnemonic(fromEntropy: deriveSparkEntropy(privkey))` for this
    /// account — i.e. the wallet is recoverable on any device by signing
    /// in with the same key. Computed by comparing the stored mnemonic
    /// against the deterministic derivation rather than reading a sticky
    /// flag, so a wallet restored from a non-default NIP-78 backup
    /// correctly reports `false` even on a device where the user had
    /// previously generated the default wallet (a stale flag was
    /// surfacing the "default wallet" banner over a non-default
    /// restored wallet).
    func isDefaultWallet(privkey: Data) -> Bool {
        guard let current = loadMnemonic() else { return false }
        let entropy = Self.deriveSparkEntropy(privkey: privkey)
        guard let derived = try? Bip39.mnemonic(fromEntropy: entropy) else { return false }
        return Nip78Backup.normalizeMnemonic(current) == Nip78Backup.normalizeMnemonic(derived)
    }

    /// HKDF-SHA256 entropy derivation. Byte-for-byte equivalent to Android
    /// `Keys.deriveSparkEntropy`: PRK = HMAC-SHA256(salt: "wisp-spark-wallet-v1",
    /// ikm: privkey); OKM = HKDF-Expand(PRK, info: "entropy", 16).
    private static func deriveSparkEntropy(privkey: Data) -> Data {
        precondition(privkey.count == 32, "Private key must be 32 bytes")
        let prk = HKDF<SHA256>.extract(
            inputKeyMaterial: SymmetricKey(data: privkey),
            salt: Data("wisp-spark-wallet-v1".utf8)
        )
        let okm = HKDF<SHA256>.expand(
            pseudoRandomKey: prk,
            info: Data("entropy".utf8),
            outputByteCount: 16
        )
        return okm.withUnsafeBytes { Data($0) }
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
            // Claim any on-chain deposits that became claimable while the app was closed.
            Task { await self.claimPendingDeposits() }
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
        case .unclaimedDeposits(let deposits):
            Task { await self.claimDeposits(deposits) }
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

    // MARK: - On-chain deposit claiming

    /// On-chain deposits sit unclaimed (and show as pending in history) until
    /// explicitly claimed once they have enough confirmations. The SDK emits
    /// `.unclaimedDeposits` when deposits become claimable; claim them
    /// automatically so they settle without user action.
    private func claimDeposits(_ deposits: [DepositInfo]) async {
        guard let sdk else { return }
        var claimedAny = false
        for deposit in deposits {
            do {
                _ = try await sdk.claimDeposit(
                    request: ClaimDepositRequest(
                        txid: deposit.txid,
                        vout: deposit.vout,
                        maxFee: .networkRecommended(leewaySatPerVbyte: 5)
                    )
                )
                claimedAny = true
                emit("Claimed on-chain deposit")
            } catch {
                emit("Failed to claim deposit: \(error.localizedDescription)")
            }
        }
        if claimedAny {
            await refreshBalance()
        }
    }

    /// Claim any deposits that became claimable while the app was closed.
    private func claimPendingDeposits() async {
        guard let sdk else { return }
        do {
            let response = try await sdk.listUnclaimedDeposits(request: ListUnclaimedDepositsRequest())
            if !response.deposits.isEmpty {
                await claimDeposits(response.deposits)
            }
        } catch {
            // Best-effort — the SDK will retry via `.unclaimedDeposits` events.
        }
    }

    // MARK: - On-chain send

    /// Quote held between the user seeing a fee and confirming it, so the send
    /// that goes out is the one that was signed off.
    private var preparedOnchainSend: (quote: OnchainSendQuote, prepared: PrepareSendPaymentResponse)?

    /// Quote sending `amountSats` to a Bitcoin address. Fees are added on top,
    /// so the recipient receives exactly the amount and the wallet spends the
    /// quote's total.
    /// `drainAll` empties the wallet: the amount becomes the whole spendable
    /// balance and the fee comes out of it rather than on top. Sending the
    /// full balance any other way can never succeed, because there's nothing
    /// left to pay the fee with.
    func prepareSendOnchain(
        address: String,
        amountSats: Int64,
        speed: OnchainSendSpeed,
        drainAll: Bool = false
    ) async -> Result<OnchainSendQuote, WalletError> {
        guard let sdk else { return .failure(.notConnected) }
        do {
            let requestedSats: Int64
            var strandsTokens = false
            if drainAll {
                // Quote against a synced balance — a stale cached figure
                // produces a fee for an amount that no longer exists.
                let info = try await sdk.getInfo(request: GetInfoRequest(ensureSynced: true))
                requestedSats = Int64(info.balanceSats)
                guard requestedSats > 0 else {
                    return .failure(.other("This wallet has no spendable balance."))
                }
                // Draining moves bitcoin only. A wallet imported from an app
                // that deals in stablecoins can hold a token balance this send
                // won't carry, and Wisp has no way to convert it.
                strandsTokens = info.tokenBalances.values.contains { $0.balance > 0 }
            } else {
                guard amountSats > 0 else { return .failure(.other("Enter an amount to send.")) }
                requestedSats = amountSats
            }

            let prepared = try await sdk.prepareSendPayment(
                request: PrepareSendPaymentRequest(
                    paymentRequest: .input(input: address),
                    amount: BInt(requestedSats),
                    tokenIdentifier: nil,
                    conversionOptions: nil,
                    feePolicy: drainAll ? .feesIncluded : .feesExcluded
                )
            )

            guard case .bitcoinAddress(_, let feeQuote) = prepared.paymentMethod else {
                // The input parsed as something else — a Lightning invoice or
                // Spark address in the address field. Refuse rather than
                // silently sending somewhere the user didn't intend.
                return .failure(.other("That isn't a Bitcoin address."))
            }

            let tier: SendOnchainSpeedFeeQuote
            switch speed {
            case .slow: tier = feeQuote.speedSlow
            case .medium: tier = feeQuote.speedMedium
            case .fast: tier = feeQuote.speedFast
            }
            let feeSats = Int64(tier.userFeeSat) + Int64(tier.l1BroadcastFeeSat)

            // `amountSats` on the quote is always what lands at the
            // destination. Draining spends the balance and the fee comes out
            // of it, so what arrives is the balance minus the fee; otherwise
            // the recipient gets exactly what was asked for.
            let deliveredSats = drainAll ? max(0, requestedSats - feeSats) : requestedSats
            guard deliveredSats > 0 else {
                return .failure(.other("The fee is larger than the balance. Nothing would arrive."))
            }

            let quote = OnchainSendQuote(
                address: address,
                amountSats: deliveredSats,
                feeSats: feeSats,
                speed: speed,
                leavesTokensBehind: strandsTokens
            )
            preparedOnchainSend = (quote, prepared)
            return .success(quote)
        } catch {
            let friendly = Self.friendlyPayError(error)
            emit("Quote failed: \(friendly)")
            return .failure(.other(friendly))
        }
    }

    /// Send the quote the user confirmed. Refuses anything else.
    func executeSendOnchain(quote: OnchainSendQuote) async -> Result<String, WalletError> {
        guard let sdk else { return .failure(.notConnected) }
        // Only ever send the quote that was actually signed off. A mismatch
        // means the screen drifted from what the user agreed to — re-quote
        // rather than send a different amount or destination.
        guard let held = preparedOnchainSend, held.quote == quote else {
            return .failure(.other("This quote expired. Check the amount and try again."))
        }

        let sdkSpeed: OnchainConfirmationSpeed
        switch quote.speed {
        case .slow: sdkSpeed = .slow
        case .medium: sdkSpeed = .medium
        case .fast: sdkSpeed = .fast
        }

        do {
            emit("Sending on-chain…")
            let response = try await sdk.sendPayment(
                request: SendPaymentRequest(
                    prepareResponse: held.prepared,
                    options: .bitcoinAddress(confirmationSpeed: sdkSpeed),
                    idempotencyKey: nil
                )
            )
            preparedOnchainSend = nil
            // A failed payment comes back WITHOUT throwing, so the status has
            // to be inspected rather than trusted — same shape as payInvoice.
            if case .failed = response.payment.status {
                emit("On-chain send failed")
                return .failure(.other("The send failed — your sats were not sent."))
            }
            await refreshBalance()
            return .success(response.payment.id)
        } catch {
            let friendly = Self.friendlyPayError(error)
            emit("On-chain send failed: \(friendly)")
            return .failure(.other(friendly))
        }
    }

    // MARK: - On-chain receive address

    /// Get the Bitcoin deposit address, or rotate to a fresh one. Funds sent
    /// to it confirm on-chain and are then claimed into the spendable balance
    /// by `claimDeposits` above. Rotation never invalidates the previous
    /// address — the SDK keeps old ones working for future deposits.
    func receiveOnchainAddress(newAddress: Bool = false) async -> Result<String, WalletError> {
        guard let sdk else { return .failure(.notConnected) }
        do {
            let response = try await sdk.receivePayment(
                request: ReceivePaymentRequest(
                    paymentMethod: .bitcoinAddress(newAddress: newAddress ? true : nil)
                )
            )
            return .success(response.paymentRequest)
        } catch {
            return .failure(.other(error.localizedDescription))
        }
    }

    /// Snapshot of deposits waiting to be claimed, for the receive screen.
    /// The auto-claimer handles the routine cases; this surfaces the ones it
    /// can't settle (mostly network fees above the claim cap) so a deposit
    /// is never silently stuck.
    func listOnchainDeposits() async -> OnchainDepositSummary {
        guard let sdk else { return OnchainDepositSummary(deposits: []) }
        do {
            let response = try await sdk.listUnclaimedDeposits(request: ListUnclaimedDepositsRequest())
            return OnchainDepositSummary(deposits: response.deposits.map(Self.onchainDeposit))
        } catch {
            emit("Failed to list deposits: \(error.localizedDescription)")
            return OnchainDepositSummary(deposits: [])
        }
    }

    /// Maps the SDK's deposit type onto the UI model. Kept here so
    /// `OnchainDeposit` stays SDK-free and unit-testable.
    private static func onchainDeposit(_ deposit: DepositInfo) -> OnchainDeposit {
        let failure: OnchainDeposit.Failure?
        if let claimError = deposit.claimError {
            switch claimError {
            case .maxDepositClaimFeeExceeded(_, _, _, let requiredFeeSats, _):
                failure = .feeExceeded(requiredSats: Int64(requiredFeeSats))
            case .missingUtxo:
                failure = .missingUtxo
            case .generic(let message):
                failure = .other(message)
            default:
                failure = .other(String(describing: claimError))
            }
        } else {
            failure = nil
        }
        let instantClaim: OnchainDeposit.InstantClaim?
        switch deposit.instantClaimStatus {
        case .submitted:
            instantClaim = .submitted
        case .declined(let reason):
            switch reason {
            case .noPlan:
                instantClaim = .declined(.noPlan)
            case .feeExceeded(_, let quotedBps, let quotedSats):
                instantClaim = .declined(.feeExceeded(
                    quotedSats: Int64(quotedSats),
                    quotedBps: Int(quotedBps)
                ))
            case .submissionFailed:
                instantClaim = .declined(.submissionFailed)
            }
        case .none:
            instantClaim = nil
        }
        return OnchainDeposit(
            txid: deposit.txid,
            vout: deposit.vout,
            amountSats: Int64(deposit.amountSats),
            isMature: deposit.isMature,
            instantClaim: instantClaim,
            failure: failure
        )
    }

    /// Re-claim a deposit the automatic claimer couldn't settle. `feeSats`
    /// caps the claim fee: pass the SDK-required fee surfaced from
    /// `claimError` to accept a cost above the automatic limit — the UI
    /// confirms that with the user first, so paying more is a deliberate
    /// choice. `nil` retries at the same cap the automatic claimer uses.
    func claimOnchainDeposit(txid: String, vout: UInt32, feeSats: UInt64?) async -> Result<Void, WalletError> {
        guard let sdk else { return .failure(.notConnected) }
        let maxFee: MaxFee
        if let feeSats {
            maxFee = .fixed(amount: feeSats)
        } else {
            maxFee = .networkRecommended(leewaySatPerVbyte: 5)
        }
        do {
            _ = try await sdk.claimDeposit(
                request: ClaimDepositRequest(txid: txid, vout: vout, maxFee: maxFee)
            )
            emit("Claimed on-chain deposit")
            await refreshBalance()
            return .success(())
        } catch {
            emit("Failed to claim deposit: \(error.localizedDescription)")
            return .failure(.other(error.localizedDescription))
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
            // Force the SDK to sync with the network before reading. The
            // cached on-disk balance loaded at init is often stale (whatever
            // the previous session ended on), and `.synced` can take tens of
            // seconds to fire after a cold launch — long enough for the user
            // to wonder why the dashboard is showing the wrong number. This
            // path is hit on initial load + pull-to-refresh, so blocking on
            // a sync here trades latency for correctness exactly where it
            // matters. The reactive refresh via the SDK's `.synced` event
            // still uses `ensureSynced: false` since by definition that
            // path runs *after* a sync has already landed.
            let info = try await sdk.getInfo(request: GetInfoRequest(ensureSynced: true))
            let msats = Int64(info.balanceSats) * 1000
            balanceMsats = msats
            balanceContinuation.yield(msats)
            return .success(msats)
        } catch {
            return .failure(.other(error.localizedDescription))
        }
    }

    /// Parse arbitrary input (bolt11, lightning address, LNURL, …) and return the SDK's
    /// `InputType` so the caller can decide which payment path to use.
    func parseInput(_ input: String) async -> InputType? {
        guard let sdk else { return nil }
        return try? await sdk.parse(input: input)
    }

    /// Parse input and return a `WalletInputType` for the UI layer without exposing SDK types.
    func detectWalletInputType(_ input: String) async -> WalletInputType? {
        guard let parsed = await parseInput(input) else { return nil }
        switch parsed {
        case .bolt11Invoice(let d):
            return .bolt11(amountSats: d.amountMsat.map { Int64($0 / 1000) })
        case .lnurlPay(let d):
            return .sparkLnurl(info: ResolvedLnurlInfo(
                minSats: Int64(d.minSendable / 1000),
                maxSats: Int64(d.maxSendable / 1000),
                label: d.address ?? d.domain
            ))
        case .lightningAddress(let d):
            let pr = d.payRequest
            return .sparkLnurl(info: ResolvedLnurlInfo(
                minSats: Int64(pr.minSendable / 1000),
                maxSats: Int64(pr.maxSendable / 1000),
                label: pr.address ?? pr.domain
            ))
        case .bitcoinAddress(let d):
            return .bitcoinAddress(address: d.address, amountSats: nil)
        case .bip21(let d):
            // A BIP-21 URI can carry several payment methods. Prefer a
            // Lightning invoice when one is offered — it settles instantly and
            // costs less — and fall back to the on-chain address.
            for method in d.paymentMethods {
                if case .bolt11Invoice(let inv) = method {
                    return .bolt11(amountSats: inv.amountMsat.map { Int64($0 / 1000) })
                }
            }
            for method in d.paymentMethods {
                if case .bitcoinAddress(let addr) = method {
                    return .bitcoinAddress(
                        address: addr.address,
                        amountSats: d.amountSat.map(Int64.init)
                    )
                }
            }
            return .unknown
        default:
            return .unknown
        }
    }

    /// Parse input as LNURL/lightning address and pay. Returns nil if the input is not
    /// a LNURL type (caller should fall back to manual resolution).
    func parseAndPayLnurl(_ input: String, amountSats: Int64) async -> Result<String, WalletError>? {
        guard let parsed = await parseInput(input) else { return nil }
        switch parsed {
        case .lnurlPay(let d):
            return await payLnurlPayRequest(d, amountSats: amountSats)
        case .lightningAddress(let d):
            return await payLnurlPayRequest(d.payRequest, amountSats: amountSats)
        default:
            return nil   // not a LNURL input
        }
    }

    /// Pay a resolved LNURL-pay endpoint (from a lightning address or lnurl: URI).
    func payLnurlPayRequest(_ payRequest: LnurlPayRequestDetails, amountSats: Int64) async -> Result<String, WalletError> {
        guard let sdk else { return .failure(.notConnected) }
        do {
            emit("Preparing LNURL payment…")
            let prepare = try await sdk.prepareLnurlPay(request: PrepareLnurlPayRequest(
                amount: BInt(amountSats),
                payRequest: payRequest
            ))
            emit("Sending payment…")
            let response = try await sdk.lnurlPay(request: LnurlPayRequest(prepareResponse: prepare))
            // lnurlPay returns a payment whose status may be FAILED without
            // throwing. Returning .success for it told the user their sats had
            // been sent when they had not.
            switch response.payment.status {
            case .completed:
                emit("Payment completed")
                return .success(response.payment.id)
            case .pending:
                // Accepted but not settled. Reported as success so the caller
                // doesn't show a failure for a payment that may still land —
                // see the note in the PR about surfacing pending distinctly.
                emit("Payment pending")
                return .success(response.payment.id)
            default:
                emit("Payment failed (\(response.payment.status))")
                return .failure(.other("Payment failed — your sats were not sent"))
            }
        } catch {
            let friendly = Self.friendlyPayError(error)
            emit("Payment failed: \(friendly)")
            return .failure(.other(friendly))
        }
    }

    func payInvoice(_ bolt11: String) async -> Result<String, WalletError> {
        guard let sdk else { return .failure(.notConnected) }
        do {
            emit("Preparing payment…")
            let prepare = try await sdk.prepareSendPayment(
                request: PrepareSendPaymentRequest(
                    paymentRequest: .input(input: bolt11),
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
            // sendPayment waits up to completionTimeoutSecs and then returns
            // whatever status it has — a FAILED payment comes back WITHOUT
            // throwing, so it never reaches the catch below. Returning
            // .success for it told the user their sats had been sent when
            // they had not.
            switch response.payment.status {
            case .completed:
                emit("Payment completed")
                return .success(response.payment.id)
            case .pending:
                // Accepted but not settled. Reported as success so the caller
                // doesn't show a failure for a payment that may still land —
                // see the note in the PR about surfacing pending distinctly.
                emit("Payment pending")
                return .success(response.payment.id)
            default:
                emit("Payment failed (\(response.payment.status))")
                return .failure(.other("Payment failed — your sats were not sent"))
            }
        } catch {
            let friendly = Self.friendlyPayError(error)
            emit("Payment failed: \(friendly)")
            return .failure(.other(friendly))
        }
    }

    /// Translates raw Spark SDK errors into user-readable strings. The SDK
    /// surfaces full gRPC envelopes including internal field names and byte
    /// arrays — exposing those in the Send sheet is hostile. Falls back to
    /// `localizedDescription` for unknown errors.
    private static func friendlyPayError(_ error: Error) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("alreadyexists") || lower.contains("preimage request already exists") {
            return "This invoice has already been paid."
        }
        if lower.contains("insufficient") {
            return "Insufficient balance to pay this invoice."
        }
        if lower.contains("expired") {
            return "This invoice has expired."
        }
        if lower.contains("route") && lower.contains("not found") {
            return "Could not find a payment route. Try again in a moment."
        }
        return raw
    }

    func makeInvoice(amountMsats: Int64, description: String, expirySecs: Int64) async -> Result<String, WalletError> {
        guard let sdk else { return .failure(.notConnected) }
        do {
            let amountSats = UInt64(max(amountMsats / 1000, 1))
            let response = try await sdk.receivePayment(
                request: ReceivePaymentRequest(
                    paymentMethod: ReceivePaymentMethod.bolt11Invoice(
                        description: description.isEmpty ? "Wisp wallet" : description,
                        amountSats: amountSats,
                        expirySecs: UInt32(min(expirySecs, Int64(UInt32.max))),
                        paymentHash: nil,
                        receiverIdentityPublicKey: nil
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
                var paymentHash = payment.id
                var description: String? = nil
                var bitcoinTxId: String? = nil

                if let details = payment.details {
                    switch details {
                    case .lightning(let desc, let invoice, _, _, _, _, _, _):
                        if let decoded = Bolt11.decode(invoice) {
                            paymentHash = decoded.paymentHash ?? payment.id
                            description = desc ?? decoded.description
                        } else {
                            description = desc
                        }
                    case .deposit(let txId, _):
                        bitcoinTxId = txId
                    case .withdraw(let txId):
                        bitcoinTxId = txId
                    default:
                        break
                    }
                }

                let isOnchain = bitcoinTxId != nil
                // Settlement state straight from the SDK. `settledAt` used to be
                // stamped with the payment timestamp unconditionally, and the
                // detail sheet derived "Completed" from it being non-nil — so a
                // FAILED payment (and the duplicate a user sends after one) was
                // listed as Completed. Anything that isn't completed or pending
                // is a failure: the sats did not leave.
                let status: TransactionStatus
                switch payment.status {
                case .completed:
                    status = .completed
                case .pending:
                    // On-chain payments made outside this app instance (another
                    // wallet on the same seed) aren't tracked by this SDK session,
                    // so PaymentStatus can stay stuck at .pending long after the
                    // underlying transaction is confirmed. Wisp doesn't initiate
                    // on-chain send/receive itself, so don't trust that flag for
                    // on-chain rows.
                    status = isOnchain ? .completed : .pending
                default:
                    status = .failed
                }
                var tx = WalletTransaction(
                    type: payment.paymentType == .send ? .outgoing : .incoming,
                    description: description,
                    paymentHash: paymentHash,
                    amountMsats: amountSats * 1000,
                    feeMsats: feeSats * 1000,
                    createdAt: Int64(payment.timestamp),
                    // Only a settled payment has a settlement time. Unsettled and
                    // failed rows fall back to `createdAt` for display / sorting.
                    settledAt: status == .completed ? Int64(payment.timestamp) : nil,
                    counterpartyPubkey: nil
                )
                tx.status = status
                tx.bitcoinTxId = bitcoinTxId
                return tx
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
