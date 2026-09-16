import SwiftUI

/// Inline "Zap" pill rendered for a lightning address (`user@domain.tld`) found
/// in note content. Self-contained (mirrors `NofferButton` from the CLINK offer
/// flow): it grabs the wallet from the environment and presents its own pay
/// sheet, so no tap callback has to be threaded through every content-rendering
/// call site.
///
/// Tap routing mirrors `ProfileView.handleLightningTap`:
/// - wallet connected → in-app `LightningAddressPaySheet` (amount entry + pay)
/// - no wallet → `LightningPaySheet` (QR + copy + open-in-external-wallet)
struct LightningAddressButton: View {
    let address: String

    @Environment(WalletStore.self) private var walletStore: WalletStore?
    @State private var showPaySheet = false
    @State private var showExternalSheet = false

    private var hasWallet: Bool { walletStore?.mode != nil }

    var body: some View {
        Button {
            if hasWallet {
                showPaySheet = true
            } else {
                showExternalSheet = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.wispZapColor)
                Text(address)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.wispZapColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.wispZapColor.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPaySheet) {
            if let store = walletStore {
                NavigationStack {
                    LightningAddressPaySheet(address: address, store: store, dismiss: { showPaySheet = false })
                }
            }
        }
        .sheet(isPresented: $showExternalSheet) {
            LightningPaySheet(lud16: address, allowOpenInWallet: true)
        }
    }
}

/// In-app LNURL-pay flow for a lightning address, shown when a wallet is
/// connected. Enter an amount (+ optional note) and pay via
/// `WalletStore.payLightningAddress`, which resolves the LNURL and settles
/// through the active Spark / NWC wallet.
struct LightningAddressPaySheet: View {
    let address: String
    @Bindable var store: WalletStore
    var dismiss: () -> Void

    @Environment(AppSettings.self) private var settings
    @State private var amountText: String = ""
    @State private var message: String = ""
    @State private var status: String?
    @State private var inFlight = false
    @State private var didSucceed = false

    private var amountSats: Int64? {
        guard let v = Int64(amountText.filter { $0.isNumber }), v > 0 else { return nil }
        return v
    }

    private var canPay: Bool { amountSats != nil && !inFlight && store.activeWallet != nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Recipient
                HStack(spacing: 10) {
                    Image(systemName: "bolt.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.wispZapColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Zap lightning address")
                            .font(.subheadline.weight(.semibold))
                        Text(address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))

                if didSucceed {
                    successView
                } else {
                    form
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(Color.wispBackground.ignoresSafeArea())
        .navigationTitle("Zap")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Close", action: dismiss) }
        }
    }

    private var form: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Amount")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                HStack {
                    Image(systemName: settings.zapSymbolName)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    TextField("Amount in sats", text: $amountText)
                        .keyboardType(.numberPad)
                        .font(.system(.body, design: .rounded))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Note (optional)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                TextField("Say something…", text: $message)
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

            Button {
                Task { await pay() }
            } label: {
                Group {
                    if inFlight { ProgressView().tint(.white) } else {
                        Text(amountSats.map { "Zap \(CurrencyFormatter.formatNumber($0)) sats" } ?? "Zap")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(canPay ? Color.wispZapColor : Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!canPay)
            .buttonStyle(.plain)
        }
    }

    private var successView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.wispRepostColor)
            Text("Zap sent")
                .font(.title3.weight(.semibold))
            Button("Done") { dismiss() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.wispZapColor, in: RoundedRectangle(cornerRadius: 14))
                .buttonStyle(.plain)
        }
        .padding(.top, 24)
    }

    private func pay() async {
        guard let sats = amountSats else { return }
        inFlight = true; status = nil
        defer { inFlight = false }
        let result = await store.payLightningAddress(address, amountSats: sats)
        switch result {
        case .success:
            Haptics.shared.pulse()
            withAnimation(.easeInOut(duration: 0.2)) { didSucceed = true }
        case .failure(let err):
            status = err.localizedDescription
        }
    }
}
