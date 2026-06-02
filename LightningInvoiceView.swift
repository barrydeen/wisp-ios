import SwiftUI
import UIKit
import Combine

struct LightningInvoiceView: View {
    let invoice: String
    let amountSats: Int64?
    let summary: String?
    var isPreview: Bool = false

    @Environment(WalletStore.self) private var walletStore: WalletStore?
    @State private var showSendSheet = false
    @State private var showWalletSetupPrompt = false
    @State private var showQR = false
    @State private var now = Date()

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let decoded: Bolt11.DecodedInvoice?

    init(invoice: String, amountSats: Int64?, summary: String?, isPreview: Bool = false) {
        self.invoice = invoice
        self.amountSats = amountSats
        self.summary = summary
        self.isPreview = isPreview
        self.decoded = Bolt11.decode(invoice)
    }

    private var secondsRemaining: Int64 {
        guard let d = decoded else { return Int64.max }
        return d.timestamp + d.expiry - Int64(now.timeIntervalSince1970)
    }

    private var isExpired: Bool { secondsRemaining <= 0 }

    private var expiryText: String {
        if secondsRemaining <= 0 { return "Expired" }
        if secondsRemaining < 60 { return "< 1m left" }
        if secondsRemaining < 3600 { return "\(secondsRemaining / 60)m left" }
        let h = secondsRemaining / 3600
        if h < 24 { return "\(h)h left" }
        return "\(h / 24)d left"
    }

    private var expiryColor: Color {
        if secondsRemaining <= 300 { return .red }
        if secondsRemaining < 3600 { return .orange }
        return Color(uiColor: .secondaryLabel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Color.wispZapColor)
                Text("Lightning Invoice")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if decoded != nil {
                    Text(expiryText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(expiryColor)
                }
            }

            // Amount — large, centred
            if let sats = amountSats {
                Text(CurrencyFormatter.full(sats: sats))
                    .font(.title.weight(.bold))
                    .foregroundStyle(Color.wispZapColor)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            // Description
            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
            }

            // Buttons
            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = invoice
                    QuickFollowToast.shared.show("Copied")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .background(Color.wispSurfaceVariant, in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    payTapped()
                } label: {
                    Label("Pay", systemImage: "bolt.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            (isExpired || isPreview) ? Color.wispZapColor.opacity(0.3) : Color.wispZapColor,
                            in: Capsule()
                        )
                        .foregroundStyle((isExpired || isPreview) ? Color.white.opacity(0.5) : .white)
                }
                .buttonStyle(.plain)
                .disabled(isExpired || isPreview)

                Button {
                    showQR = true
                } label: {
                    Image(systemName: "qrcode")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .background(Color.wispSurfaceVariant, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispSurfaceVariant.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.wispZapColor.opacity(0.4), lineWidth: 1)
        )
        .onReceive(timer) { _ in now = Date() }
        .sheet(isPresented: $showQR) {
            VStack(spacing: 20) {
                Text("Lightning Invoice")
                    .font(.headline)
                QRCodeImage(payload: invoice.uppercased(), sideLength: 260)
                if let sats = amountSats {
                    Text(CurrencyFormatter.full(sats: sats))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.wispZapColor)
                }
                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .presentationDetents([.medium])
        }
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

    private func payTapped() {
        if let store = walletStore, store.mode != nil {
            showSendSheet = true
        } else {
            showWalletSetupPrompt = true
        }
    }
}
