import SwiftUI
import UIKit

/// Lightweight pay/receive sheet for a profile's Lightning address (lud16).
/// Shown when tapping a lightning address and either no in-app wallet is
/// connected (pay another user via QR / copy / external wallet) or it's the
/// user's own address (`allowOpenInWallet == false` → receive QR, no pay
/// affordance). When a wallet *is* connected, callers route to `ZapSheet`
/// instead — this sheet is the no-wallet / self fallback. Mirrors Dark Wisp
/// PR #39's `PaymentTargetSheet`.
struct LightningPaySheet: View {
    let lud16: String
    var avatarUrl: String? = nil
    /// Pay context (someone else, no wallet) shows "Open in wallet"; receive
    /// context (your own address) hides it — opening an external wallet to pay
    /// yourself is nonsensical.
    var allowOpenInWallet: Bool = true

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var lightningURL: URL? { URL(string: "lightning:\(lud16)") }

    /// Only offer "Open in wallet" when an external Lightning wallet app is
    /// actually installed to handle the `lightning:` scheme — otherwise the
    /// button taps into nothing. `lightning` is whitelisted in
    /// `LSApplicationQueriesSchemes` so `canOpenURL` can answer truthfully.
    private var canOpenExternalWallet: Bool {
        guard allowOpenInWallet, let lightningURL else { return false }
        return UIApplication.shared.canOpenURL(lightningURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 40)
                .padding(.horizontal, 20)

            VStack(spacing: 16) {
                qrWithCenterAvatar(payload: lud16)
                copyableRow

                if canOpenExternalWallet {
                    Button {
                        if let lightningURL {
                            openURL(lightningURL)
                        }
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
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(Color.wispZapColor)
            Text("Lightning")
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
    }

    /// QR of the lightning address with a center-overlaid avatar (or Wisp logo
    /// fallback). Error-correction "H" keeps it scannable through the occlusion.
    private func qrWithCenterAvatar(payload: String) -> some View {
        ZStack {
            QRCodeImage(payload: payload, sideLength: 240, correctionLevel: "H")

            ZStack {
                Circle().fill(Color.white)
                if let avatarUrl, !avatarUrl.isEmpty {
                    CachedAvatarView(url: avatarUrl, size: 40)
                        .clipShape(Circle())
                } else {
                    Image("WispLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 36, height: 36)
                }
            }
            .frame(width: 48, height: 48)
        }
        .padding(20)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
    }

    private var copyableRow: some View {
        HStack(spacing: 8) {
            Text(lud16)
                .font(.caption.monospaced())
                .foregroundStyle(Color.wispZapColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                UIPasteboard.general.string = lud16
                QuickFollowToast.shared.show("Copied")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.wispSurfaceVariant.opacity(0.4), in: Capsule())
    }
}
