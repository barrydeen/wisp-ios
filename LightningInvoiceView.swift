import SwiftUI
import UIKit

struct LightningInvoiceView: View {
    let invoice: String
    let amountSats: Int64?
    let summary: String?

    @Environment(WalletStore.self) private var walletStore: WalletStore?
    @State private var showSendSheet = false
    @State private var showWalletSetupPrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Color.wispZapColor)
                Text("Lightning Invoice")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let amountSats {
                    Text(CurrencyFormatter.full(sats: amountSats))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.wispZapColor)
                }
            }

            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
            }

            HStack(spacing: 8) {
                Button {
                    UIPasteboard.general.string = invoice
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
                        initialInvoice: invoice
                    )
                }
            }
        }
        .confirmationDialog(
            "Set up a wallet to pay invoices",
            isPresented: $showWalletSetupPrompt,
            titleVisibility: .visible
        ) {
            Button("Set Up Wallet") {
                NotificationCenter.default.post(name: .openWalletTab, object: nil)
            }
            Button("Open in External Wallet") {
                if let url = URL(string: "lightning:\(invoice)") {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Connect a Lightning wallet (Spark or NWC) from the Wallet tab to pay invoices in-app, or open this invoice in an external wallet.")
        }
    }

    /// Routes to the in-app wallet's Send sheet (pre-filled with the invoice)
    /// when one is configured. Otherwise prompts the user to set one up,
    /// with a fallback button to hand the invoice off to an external wallet.
    private func payTapped() {
        if let store = walletStore, store.mode != nil {
            showSendSheet = true
        } else {
            showWalletSetupPrompt = true
        }
    }
}
