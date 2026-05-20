import SwiftUI

/// Bottom sheet showing a Nostr identity QR (bech32 npub) and, when the profile has a
/// lud16, a Lightning address QR. Mirrors Android's `ProfileQrSheet` — single pane when
/// no Lightning address is set, two-tab segmented control otherwise.
struct ProfileQrSheet: View {
    let pubkey: String
    let displayName: String
    let avatarUrl: String?
    let lud16: String?

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .nostr

    private enum Tab: Hashable { case nostr, lightning }

    private var npub: String? {
        guard let bytes = Hex.decode(pubkey) else { return nil }
        return Nip19.npubEncode(pubkey: Array(bytes))
    }

    private var hasLightning: Bool {
        guard let lud16 else { return false }
        return !lud16.isEmpty
    }

    private var subtitle: String {
        switch tab {
        case .nostr: return "Scan to follow on Nostr"
        case .lightning: return "Scan to send money"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 24)
                .padding(.horizontal, 20)

            if hasLightning {
                tabBar
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }

            switch tab {
            case .nostr:
                nostrPane
            case .lightning:
                lightningPane
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.wispBackground)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            CachedAvatarView(url: avatarUrl, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
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

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(.nostr, label: "Nostr")
            tabButton(.lightning, label: "Lightning")
        }
        .padding(4)
        .background(Color.wispSurfaceVariant.opacity(0.4), in: Capsule())
    }

    private func tabButton(_ target: Tab, label: String) -> some View {
        Button {
            tab = target
        } label: {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundStyle(tab == target ? Color.primary : .secondary)
                .background {
                    if tab == target {
                        Capsule().fill(Color.wispSurfaceVariant)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Panes

    private var nostrPane: some View {
        VStack(spacing: 16) {
            if let npub {
                qrWithCenterAvatar(payload: npub)
                copyableRow(label: "npub", value: npub)
            } else {
                Text("Could not encode npub")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 24)
        .padding(.horizontal, 20)
    }

    private var lightningPane: some View {
        VStack(spacing: 16) {
            if let lud16, !lud16.isEmpty {
                qrWithCenterAvatar(payload: lud16)
                copyableRow(label: "Lightning address", value: lud16, tint: Color.wispZapColor)
            }
        }
        .padding(.top, 24)
        .padding(.horizontal, 20)
    }

    /// QR with a center-overlaid avatar (or Wisp logo as fallback). Uses error correction
    /// level "H" so the symbol still scans through the occlusion.
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

    // MARK: - Copyable row

    private func copyableRow(label: String, value: String, tint: Color? = nil) -> some View {
        VStack(spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(value)
                    .font(.caption.monospaced())
                    .foregroundStyle(tint ?? .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    UIPasteboard.general.string = value
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
}
