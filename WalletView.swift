import SwiftUI

// MARK: - Navigation routes

enum WalletRoute: Hashable {
    case settings
    case transactions
    case recoveryPhrase
}

// MARK: - Main wallet view

struct WalletView: View {
    @Bindable var store: WalletStore
    @State private var setupMode: WalletMode? = nil
    @State private var showSend = false
    @State private var showReceive = false
    @AppStorage private var balanceHidden: Bool
    @AppStorage("walletBalanceUnit") private var balanceUnitRaw: String = WalletBalanceUnit.sats.rawValue

    private var hasCachedDataOrConnected: Bool {
        store.balanceMsats != nil || !store.transactions.isEmpty
    }

    init(store: WalletStore) {
        self.store = store
        _balanceHidden = AppStorage(wrappedValue: false, "balanceHidden_\(store.keypair.pubkey)")
    }

    var body: some View {
        Group {
            if store.mode == nil {
                WalletModeSelectionView(onPick: { setupMode = $0 })
            } else if !hasCachedDataOrConnected && !store.isConnected {
                connectingView
            } else {
                walletDashboard
            }
        }
        .background(Color.wispBackground)
        .navigationDestination(for: WalletRoute.self) { route in
            switch route {
            case .settings:   WalletSettingsView(store: store)
            case .transactions: TransactionHistoryView(store: store)
            case .recoveryPhrase: RecoveryPhraseView(store: store)
            }
        }
        .task { await store.startIfConfigured() }
        .sheet(item: $setupMode) { mode in
            NavigationStack {
                if mode == .nwc {
                    NwcSetupView(store: store, dismiss: { setupMode = nil })
                } else {
                    SparkSetupView(store: store, dismiss: { setupMode = nil })
                }
            }
        }
        .sheet(isPresented: $showSend) {
            NavigationStack {
                SendInvoiceSheet(store: store, dismiss: { showSend = false })
            }
        }
        .sheet(isPresented: $showReceive) {
            NavigationStack {
                ReceiveInvoiceSheet(store: store, dismiss: { showReceive = false })
            }
        }
    }

    // MARK: - Connecting

    private var connectingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(store.lastStatus ?? "Connecting…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Reconnect") {
                Task { await store.startIfConfigured() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Dashboard

    private var walletDashboard: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    // Top bar
                    topBar
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    // Seed backup warning (Spark + unacknowledged only)
                    if store.mode == .spark && !store.seedBackupAcknowledged {
                        seedBackupBanner
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }

                    // Balance + actions — vertically centered in available space
                    Spacer(minLength: 0)

                    VStack(spacing: 32) {
                        balanceCard

                        if !store.isConnected {
                            reconnectingBanner
                        }

                        actionRow
                    }
                    .padding(.horizontal, 20)

                    Spacer(minLength: 0)

                    // Recent transactions — anchored at bottom
                    if !store.transactions.isEmpty {
                        recentTransactionsSection
                    }
                }
                .frame(minHeight: geo.size.height)
            }
            .refreshable {
                await refreshWallet()
            }
        }
        .task { await store.refreshTransactions() }
    }

    private func refreshWallet() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await store.fetchBalance()
        await store.refreshTransactions()
        await store.refreshLightningAddress()
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .center) {
            walletLogo
            Spacer()
            HStack(spacing: 4) {
                Button {
                    Task { await refreshWallet() }
                } label: {
                    Group {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16, weight: .medium))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)

                NavigationLink(value: WalletRoute.settings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var walletLogo: some View {
        if store.mode == .spark {
            Image("SparkBreezLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 18)
        } else {
            Image("NwcLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 30)
        }
    }

    // MARK: - Seed backup banner

    private var seedBackupBanner: some View {
        NavigationLink(value: WalletRoute.recoveryPhrase) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.wispZapColor)
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Back up your recovery phrase")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Tap to view and save your seed words")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.wispZapColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Balance

    private var balanceCard: some View {
        let sats = store.balanceMsats.map { $0 / 1000 } ?? 0
        let unit = WalletBalanceUnit(rawValue: balanceUnitRaw) ?? .sats
        let syncing = store.mode != nil && !store.isConnected
        return VStack(spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { balanceHidden.toggle() }
            } label: {
                VStack(spacing: 6) {
                    if balanceHidden {
                        Text("* * * * *")
                            .font(.system(size: 52, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                    } else {
                        Text(unit.formatNumber(sats))
                            .font(.system(size: 52, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText(value: Double(sats)))
                            .animation(.easeInOut(duration: 0.25), value: sats)
                    }
                    Text(unit.unitLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .opacity(syncing ? (syncPulse ? 0.35 : 1.0) : 1.0)
            .animation(
                syncing
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .easeInOut(duration: 0.25),
                value: syncPulse
            )
            .onChange(of: syncing) { _, isSyncing in
                syncPulse = isSyncing
            }
            .onAppear {
                syncPulse = syncing
            }

            // Lightning address
            if let addr = store.lightningAddress {
                lightningAddressPill(addr)
            }
        }
    }

    @State private var addressCopied = false
    @State private var syncPulse = false
    @State private var isRefreshing = false

    private func lightningAddressPill(_ address: String) -> some View {
        Button {
            UIPasteboard.general.string = address
            withAnimation { addressCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { addressCopied = false }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: addressCopied ? "checkmark" : "bolt.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.wispZapColor)
                Text(addressCopied ? "Copied!" : address)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(addressCopied ? Color.wispZapColor : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.wispSurfaceVariant.opacity(0.5), in: Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: addressCopied)
    }

    // MARK: - Reconnecting

    private var reconnectingBanner: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7)
            Text(store.lastStatus ?? "Reconnecting…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.wispSurfaceVariant.opacity(0.4), in: Capsule())
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 40) {
            circularAction(label: "Send", systemImage: "arrow.up", action: { showSend = true })
            circularAction(label: "Receive", systemImage: "arrow.down", action: { showReceive = true })
        }
        .frame(maxWidth: .infinity)
    }

    private func circularAction(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(Color.wispZapColor, in: Circle())
                Text(label)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recent transactions (bottom strip)

    private var recentTransactionsSection: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.15)

            HStack {
                Text("Recent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                NavigationLink(value: WalletRoute.transactions) {
                    Text("All transactions")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.wispZapColor)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 6)

            let recent = Array(store.transactions.prefix(5))
            ForEach(recent) { tx in
                WalletTransactionRow(tx: tx)
                    .padding(.horizontal, 16)
                if tx.id != recent.last?.id {
                    Divider().opacity(0.12).padding(.leading, 68)
                }
            }
        }
        .padding(.bottom, 8)
        .background(Color.wispBackground)
    }
}

// MARK: - Mode selection

struct WalletModeSelectionView: View {
    let onPick: (WalletMode) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color.wispZapColor)

            VStack(spacing: 8) {
                Text("Connect a wallet")
                    .font(.title2.weight(.bold))
                Text("Send and receive Lightning payments,\nand zap anyone on Nostr.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 12) {
                modeCard(
                    title: "Spark wallet",
                    subtitle: "Self-custody, embedded. Create new or restore from seed/relays.",
                    logo: AnyView(
                        Image("SparkIcon")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color.wispZapColor)
                            .frame(width: 28, height: 28)
                    ),
                    action: { onPick(.spark) }
                )
                modeCard(
                    title: "Nostr Wallet Connect",
                    subtitle: "Paste a connection string from Alby, Zeus, Rizful, Minibits, etc.",
                    logo: AnyView(
                        Image("NwcLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 32, height: 32)
                    ),
                    action: { onPick(.nwc) }
                )
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func modeCard(title: String, subtitle: String, logo: AnyView, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                logo.frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(18)
            .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Send sheet

struct SendInvoiceSheet: View {
    @Bindable var store: WalletStore
    var dismiss: () -> Void
    @State private var invoice: String = ""
    @State private var status: String?
    @State private var inFlight = false
    @State private var showScanner = false

    private var decoded: Bolt11.DecodedInvoice? { Bolt11.decode(invoice) }
    private var isReady: Bool { !invoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Input card
                VStack(alignment: .leading, spacing: 0) {
                    TextEditor(text: $invoice)
                        .frame(minHeight: 110)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .scrollContentBackground(.hidden)
                        .padding(14)

                    Divider().opacity(0.25)

                    HStack(spacing: 0) {
                        Button {
                            showScanner = true
                        } label: {
                            Label("Scan QR", systemImage: "qrcode.viewfinder")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.wispZapColor)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)

                        Divider().frame(height: 24)

                        Button {
                            if let s = UIPasteboard.general.string {
                                invoice = normalizeInvoice(s)
                            }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.wispZapColor)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))

                // Decoded preview
                if let d = decoded {
                    VStack(alignment: .leading, spacing: 6) {
                        if let amt = d.amountSats {
                            HStack {
                                Text("Amount")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(CurrencyFormatter.formatNumber(amt)) sats")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        if let desc = d.description, !desc.isEmpty {
                            HStack(alignment: .top) {
                                Text("Note")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(desc)
                                    .font(.subheadline)
                                    .multilineTextAlignment(.trailing)
                                    .lineLimit(3)
                            }
                        }
                    }
                    .padding(14)
                    .background(Color.wispSurfaceVariant.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                }

                // Status
                if let status {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                        Text(status).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Pay button
                Button {
                    Task { await pay() }
                } label: {
                    Group {
                        if inFlight { ProgressView().tint(.white) } else {
                            Text("Pay")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        isReady ? Color.wispZapColor : Color.wispSurfaceVariant,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                }
                .disabled(!isReady || inFlight)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(Color.wispBackground.ignoresSafeArea())
        .navigationTitle("Send")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Close", action: dismiss) }
        }
        .fullScreenCover(isPresented: $showScanner) {
            QRCodeScannerView(
                onScanned: { code in
                    invoice = normalizeInvoice(code)
                    showScanner = false
                },
                onCancel: { showScanner = false }
            )
            .ignoresSafeArea()
        }
    }

    private func pay() async {
        inFlight = true; defer { inFlight = false }
        let trimmed = normalizeInvoice(invoice)
        switch await store.payInvoice(trimmed) {
        case .success: status = "Paid ✓"; dismiss()
        case .failure(let err): status = err.localizedDescription
        }
    }

    private func normalizeInvoice(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = s.range(of: "lightning:", options: .caseInsensitive) {
            s = String(s[range.upperBound...])
        }
        return s
    }
}

// MARK: - Receive sheet

struct ReceiveInvoiceSheet: View {
    @Bindable var store: WalletStore
    var dismiss: () -> Void
    @State private var amount: String = ""
    @State private var description: String = ""
    @State private var invoice: String?
    @State private var status: String?
    @State private var inFlight = false
    @State private var copied = false
    @State private var tab: ReceiveTab = .invoice

    enum ReceiveTab { case invoice, address }

    private var hasLightningAddress: Bool { store.lightningAddress != nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Tab picker — only shown when lightning address is available
                if hasLightningAddress {
                    Picker("Receive via", selection: $tab) {
                        Text("Invoice").tag(ReceiveTab.invoice)
                        Text("Lightning Address").tag(ReceiveTab.address)
                    }
                    .pickerStyle(.segmented)
                }

                if tab == .address, let addr = store.lightningAddress {
                    addressDisplay(addr)
                } else if let inv = invoice {
                    invoiceDisplay(inv)
                } else {
                    invoiceForm
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(Color.wispBackground.ignoresSafeArea())
        .navigationTitle("Receive")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Close", action: dismiss) }
        }
    }

    // MARK: Lightning address display

    private func addressDisplay(_ address: String) -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                QRCodeImage(payload: address, sideLength: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(address)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Color.wispSurfaceVariant.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 0) {
                Button {
                    UIPasteboard.general.string = address
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied ✓" : "Copy address", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.wispZapColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.15), value: copied)

                Divider().frame(height: 24)

                ShareLink(item: address) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.wispZapColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: Invoice display (after creation)

    private func invoiceDisplay(_ inv: String) -> some View {
        VStack(spacing: 20) {
            // QR code
            VStack(spacing: 10) {
                QRCodeImage(payload: inv.uppercased(), sideLength: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text("Show this QR to the sender")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Color.wispSurfaceVariant.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))

            // Invoice string + actions
            VStack(spacing: 0) {
                Text(inv)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)

                Divider().opacity(0.25)

                HStack(spacing: 0) {
                    Button {
                        UIPasteboard.general.string = inv
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { copied = false }
                        }
                    } label: {
                        Label(copied ? "Copied ✓" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.wispZapColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .animation(.easeInOut(duration: 0.15), value: copied)

                    Divider().frame(height: 24)

                    ShareLink(item: inv) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.wispZapColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
            }
            .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))

            // New invoice
            Button {
                invoice = nil; amount = ""; description = ""; copied = false
            } label: {
                Text("New invoice")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.wispSurfaceVariant.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Invoice form (before creation)

    private var invoiceForm: some View {
        VStack(spacing: 16) {
            // Amount
            VStack(alignment: .leading, spacing: 8) {
                Text("Amount")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                HStack {
                    TextField("0", text: $amount)
                        .keyboardType(.numberPad)
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                    Text("sats")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            }

            // Description
            VStack(alignment: .leading, spacing: 8) {
                Text("Note (optional)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                TextField("For coffee, etc.", text: $description)
                    .font(.subheadline)
                    .padding(14)
                    .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            }

            if let status {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(status).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Create button
            Button {
                Task { await create() }
            } label: {
                Group {
                    if inFlight { ProgressView().tint(.white) } else {
                        Text("Create invoice")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    Int64(amount) != nil ? Color.wispZapColor : Color.wispSurfaceVariant,
                    in: RoundedRectangle(cornerRadius: 14)
                )
            }
            .disabled(Int64(amount) == nil || inFlight)
            .buttonStyle(.plain)
        }
    }

    private func create() async {
        guard let sats = Int64(amount) else { return }
        inFlight = true; defer { inFlight = false }
        switch await store.makeInvoice(amountSats: sats, description: description) {
        case .success(let inv): invoice = inv
        case .failure(let err): status = err.localizedDescription
        }
    }
}
