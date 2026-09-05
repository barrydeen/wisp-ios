import SwiftUI
import UIKit

/// Sheet for a single NIP-A3 payment target: QR code of the address, a copy
/// button, and a button that hands the target's URI to an installed wallet app.
///
/// Ported from Dark Wisp Android's `PaymentTargetSheet`; the chrome follows
/// `LightningPaySheet` so the two pay surfaces read as one family.
struct PaymentTargetSheet: View {
    let target: NipA3.PaymentTarget

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var walletURL: URL? { URL(string: NipA3.nativeUri(target)) }

    /// Only offer "Open in wallet" when an app is actually registered for the
    /// scheme — otherwise the button taps into nothing. Every scheme `NipA3`
    /// can emit is declared in `LSApplicationQueriesSchemes` so `canOpenURL`
    /// can answer truthfully.
    private var canOpenExternalWallet: Bool {
        guard let walletURL else { return false }
        return UIApplication.shared.canOpenURL(walletURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 40)
                .padding(.horizontal, 20)

            VStack(spacing: 16) {
                QRCodeImage(payload: target.authority, sideLength: 240, correctionLevel: "M")
                    .padding(20)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("\(NipA3.displayName(target.type)) address QR code")

                copyableRow

                if canOpenExternalWallet {
                    Button {
                        if let walletURL { openURL(walletURL) }
                    } label: {
                        Label("Open in wallet", systemImage: "wallet.bifold")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.wispZapColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
            .padding(.top, 24)
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.wispBackground)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(spacing: 8) {
            PaymentTargetGlyph(type: target.type, size: 22, tint: Color.wispZapColor)
            Text(NipA3.displayName(target.type))
                .font(.title3.weight(.semibold))
            if let ticker = NipA3.ticker(target.type) {
                Text(ticker)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color.wispSurfaceVariant.opacity(0.5), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var copyableRow: some View {
        HStack(spacing: 8) {
            // Addresses run long (a Monero string is 95 characters), so this
            // truncates in the middle — the head and tail are what a person
            // eyeballs against their wallet.
            Text(target.authority)
                .font(.caption.monospaced())
                .foregroundStyle(Color.wispZapColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                UIPasteboard.general.string = target.authority
                QuickFollowToast.shared.show("Copied")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Copy address")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.wispSurfaceVariant.opacity(0.4), in: Capsule())
    }
}

/// Wrapping row of payment-target chips. Used wherever a set of targets is
/// offered as alternatives — the zap sheet's "Other ways to pay" row and the
/// no-wallet pay sheet below.
struct PaymentTargetChipFlow: View {
    let targets: [NipA3.PaymentTarget]
    let onSelect: (NipA3.PaymentTarget) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(targets) { target in
                Button {
                    onSelect(target)
                } label: {
                    HStack(spacing: 6) {
                        PaymentTargetGlyph(type: target.type, size: 14, tint: Color.wispZapColor)
                        Text(NipA3.displayName(target.type))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.wispSurfaceVariant.opacity(0.6), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shown instead of the zap composer when lightning zapping isn't possible —
/// no wallet connected here, or the recipient published no lightning address.
/// Lists whatever NIP-A3 targets the recipient does publish so the tap isn't a
/// dead end, and falls back to the wallet-setup call to action when they have
/// none.
///
/// Ported from Dark Wisp Android's `PaymentTargetsOnlyDialog`.
struct PaymentTargetsOnlySheet: View {
    let recipientPubkey: String
    var recipientName: String?
    /// Hidden when the reason zapping is unavailable isn't a missing wallet
    /// (e.g. the recipient simply has no lightning address).
    var showWalletSetup: Bool = true

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    @State private var targets: [NipA3.PaymentTarget] = []
    @State private var isLoading = true
    @State private var selected: NipA3.PaymentTarget?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(targets.isEmpty && !isLoading ? walletSetupTitle : "Other ways to pay")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.wispSurfaceVariant.opacity(0.5), in: Circle())
                }
                .buttonStyle(.plain)
            }

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else if targets.isEmpty {
                Text(walletSetupMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if let recipientName {
                    Text("\(recipientName) also accepts:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                PaymentTargetChipFlow(targets: targets) { selected = $0 }
            }

            if showWalletSetup {
                Button {
                    dismiss()
                    NotificationCenter.default.post(name: .openWalletTab, object: nil)
                } label: {
                    Text("Set Up Wallet")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.wispZapColor, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.wispBackground)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .sheet(item: $selected) { target in
            PaymentTargetSheet(target: target)
        }
        .task {
            targets = await PaymentTargetRepository.shared.fetch(pubkey: recipientPubkey)
            isLoading = false
        }
    }

    private var walletSetupTitle: String {
        settings.fiatModeEnabled ? "Set up a wallet to send money" : "Set up a wallet to send zaps"
    }

    private var walletSetupMessage: String {
        settings.fiatModeEnabled
            ? "Connect a Lightning wallet (Spark or NWC) from the Wallet tab to send money. This user hasn't published any other payment addresses."
            : "Connect a Lightning wallet (Spark or NWC) from the Wallet tab to send zaps. This user hasn't published any other payment addresses."
    }
}
