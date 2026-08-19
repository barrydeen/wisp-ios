import SwiftUI

/// Block-level card rendered when a note contains a bech32-encoded LNURL
/// (`lnurl1…`). Shows the resolved domain + Copy/Pay actions, matching the
/// style of `LightningInvoiceView`.
struct LnurlPayableView: View {
    let encoded: String

    @Environment(WalletStore.self) private var walletStore: WalletStore?
    @State private var showSendSheet = false
    @State private var showWalletSetupPrompt = false

    /// Decode the bech32 LNURL to extract the host for display.
    private var displayHost: String {
        guard let (_, data) = Bech32.decode(encoded),
              let urlString = String(data: data, encoding: .utf8),
              let url = URL(string: urlString),
              let host = url.host else { return "Lightning" }
        return host
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Color.wispZapColor)
                Text("Lightning Payment")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            Text(displayHost)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 8) {
                Button {
                    UIPasteboard.general.string = encoded
                    QuickFollowToast.shared.show("Copied")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.wispSurfaceVariant, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    payTapped()
                } label: {
                    Label("Pay", systemImage: "bolt.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.wispZapColor.opacity(0.2), in: Capsule())
                        .foregroundStyle(Color.wispZapColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispSurfaceVariant.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.wispZapColor.opacity(0.4), lineWidth: 1)
        )
        .sheet(isPresented: $showSendSheet) {
            if let store = walletStore {
                NavigationStack {
                    SendInvoiceSheet(
                        store: store,
                        dismiss: { showSendSheet = false },
                        initialInvoice: encoded
                    )
                }
            }
        }
        .confirmationDialog(
            "Set up a wallet to pay",
            isPresented: $showWalletSetupPrompt,
            titleVisibility: .visible
        ) {
            Button("Set Up Wallet") {
                NotificationCenter.default.post(name: .openWalletTab, object: nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Connect a Lightning wallet (Spark or NWC) from the Wallet tab to pay via LNURL in-app.")
        }
    }

    private func payTapped() {
        if let store = walletStore, store.mode != nil {
            showSendSheet = true
        } else {
            showWalletSetupPrompt = true
        }
    }
}
