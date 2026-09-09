import SwiftUI

/// "Withdraw on-chain" — drain the whole Spark balance to a Bitcoin address.
///
/// Exists mostly for a user who believes their wallet is broken: it is the
/// escape hatch that gets their money somewhere they already trust. So it
/// leads with what will happen, quotes a real fee from the SDK before
/// anything is signed, and never claims more than it can deliver.
struct WithdrawOnchainSheet: View {
    @Environment(WalletStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var speed: WithdrawOnchainSpeed = .medium
    @State private var quote: WithdrawOnchainQuote?
    @State private var isQuoting = false
    @State private var isSending = false
    @State private var error: String?
    @State private var sentPaymentId: String?
    @State private var showConfirm = false
    @State private var showScanner = false

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let sentPaymentId {
                        sentState(paymentId: sentPaymentId)
                    } else {
                        warning
                        addressField
                        speedPicker
                        quoteBlock
                        if let error {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.wispBackground)
            .navigationTitle("Withdraw on-chain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(sentPaymentId == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if sentPaymentId == nil { actionBar }
            }
            .fullScreenCover(isPresented: $showScanner) {
                QRCodeScannerView(
                    onScanned: { code in
                        address = Self.normalizeBitcoinAddress(code)
                        quote = nil
                        error = nil
                        showScanner = false
                    },
                    onCancel: { showScanner = false }
                )
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Warning

    private var warning: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("This empties your wallet", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            Text("""
            Everything spendable is sent to the Bitcoin address you enter. \
            On-chain fees are deducted from the amount, so you receive less \
            than the balance shown.

            This is a best effort at recovering your funds. Bitcoin sent \
            on-chain cannot be undone, and a wrong address means the money \
            is gone — check it carefully.
            """)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Inputs

    private var addressField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bitcoin address")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                TextField("bc1…", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.footnote, design: .monospaced))
                    .onChange(of: address) { _, _ in
                        // Any edit invalidates the quote — it was priced for
                        // a different destination.
                        quote = nil
                        error = nil
                    }
                Button {
                    if let pasted = UIPasteboard.general.string {
                        address = Self.normalizeBitcoinAddress(pasted)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.wispPrimary)

                // Scanning beats pasting for an irreversible send: no
                // truncation, no clipboard-hijack malware, no transcription.
                Button {
                    showScanner = true
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.wispPrimary)
            }
        }
    }

    private var speedPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Confirmation speed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(WithdrawOnchainSpeed.allCases, id: \.self) { option in
                Button {
                    speed = option
                    quote = nil
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: speed == option ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(speed == option ? Color.wispPrimary : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label).font(.subheadline)
                            Text(option.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Quote

    @ViewBuilder
    private var quoteBlock: some View {
        if isQuoting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Getting a fee quote…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let quote {
            VStack(spacing: 8) {
                row("Wallet balance", "\(CurrencyFormatter.formatNumber(quote.spendSats)) sats")
                row("On-chain fee", "− \(CurrencyFormatter.formatNumber(quote.feeSats)) sats")
                Divider().overlay(Color.wispSurfaceVariant)
                row("You receive", "\(CurrencyFormatter.formatNumber(quote.netSats)) sats", emphasis: true)

                if quote.isUneconomical {
                    Text("The fee is larger than the balance, so there would be nothing left to send. Try Economy speed, or wait until the balance is higher.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if quote.feePercent >= 10 {
                    // Draining a small balance can cost a large share of it.
                    // Better seen before confirming than discovered after.
                    Text("Fees take \(Int(quote.feePercent.rounded()))% of this balance.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(14)
            .background(Color.wispSurfaceVariant.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func row(_ label: String, _ value: String, emphasis: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(emphasis ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(emphasis ? .primary : .secondary)
            Spacer()
            Text(value)
                .font((emphasis ? Font.subheadline.weight(.semibold) : Font.subheadline).monospacedDigit())
        }
    }

    // MARK: - Sent

    private func sentState(paymentId: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Sent", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.wispRepostColor)
            Text("Your funds are on their way. On-chain transactions take time to confirm — the wallet will show the payment as pending until it does.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    UIPasteboard.general.string = paymentId
                    QuickFollowToast.shared.show("Copied")
                } label: {
                    Label("Copy payment ID", systemImage: "doc.on.doc")
                        .font(.footnote)
                }
                .buttonStyle(.plain)

                // Sparkscan, not mempool.space: this is Spark's payment
                // identifier, not a Bitcoin txid, so a mempool lookup would
                // 404. The on-chain txid only exists once Spark registers the
                // withdraw — see the note in `TransactionDetailPanel`.
                if let url = Self.sparkscanURL(paymentId: paymentId) {
                    Link(destination: url) {
                        Label("View on Sparkscan", systemImage: "arrow.up.right.square")
                            .font(.footnote)
                    }
                }
            }
            .foregroundStyle(Color.wispPrimary)
        }
    }

    /// Pull a bare address out of whatever a wallet's QR actually encodes.
    ///
    /// Bitcoin QRs are usually BIP-21 URIs — `bitcoin:bc1q…?amount=0.01&label=x`
    /// — and the SDK's parser wants the address alone. The amount is
    /// deliberately discarded: this screen always sends the whole balance, so
    /// honoring a requested amount would contradict what the button says.
    static func normalizeBitcoinAddress(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Case-insensitive: some wallets emit "BITCOIN:".
        if let range = value.range(of: "bitcoin:", options: [.caseInsensitive, .anchored]) {
            value = String(value[range.upperBound...])
        }
        if let query = value.firstIndex(of: "?") {
            value = String(value[value.startIndex..<query])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sparkscan link for a Spark payment id.
    ///
    /// Path follows Sparkscan's own API convention (`/v1/tx/{txid}`). Percent-
    /// encoded because the id comes from the SDK rather than a fixed format.
    static func sparkscanURL(paymentId: String) -> URL? {
        let trimmed = paymentId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return nil }
        return URL(string: "https://sparkscan.io/tx/\(encoded)")
    }

    // MARK: - Action

    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.wispSurfaceVariant)
            Button {
                if quote == nil { Task { await getQuote() } } else { showConfirm = true }
            } label: {
                Group {
                    if isSending {
                        ProgressView().tint(.white)
                    } else {
                        Text(quote == nil ? "Get quote" : "Withdraw on-chain")
                            .font(.body.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(quote == nil ? Color.wispPrimary : .red)
            .disabled(trimmedAddress.isEmpty || isQuoting || isSending
                      || (quote?.isUneconomical ?? false))
            .padding(16)
        }
        .background(Color.wispBackground)
        .confirmationDialog(
            "Withdraw everything on-chain?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Send \(CurrencyFormatter.formatNumber(quote?.netSats ?? 0)) sats", role: .destructive) {
                Task { await send() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Funds go to \(trimmedAddress).")
        }
    }

    private func getQuote() async {
        isQuoting = true
        error = nil
        defer { isQuoting = false }
        switch await store.prepareWithdrawOnchain(address: trimmedAddress, speed: speed) {
        case .success(let q): quote = q
        case .failure(let e): error = e.errorDescription ?? "Something went wrong."
        }
    }

    private func send() async {
        guard let quote else { return }
        isSending = true
        error = nil
        defer { isSending = false }
        switch await store.executeWithdrawOnchain(quote: quote) {
        case .success(let id): sentPaymentId = id
        case .failure(let e): error = e.errorDescription ?? "Something went wrong."
        }
    }
}
