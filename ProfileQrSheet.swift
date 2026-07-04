import SwiftUI

/// Bottom sheet showing a Nostr identity QR (bech32 npub) and, when the profile has them,
/// a Lightning pane carrying a Lightning-address QR and/or a CLINK offer (`noffer1…`) QR.
/// Mirrors Android's `ProfileQrSheet` — single pane when only the npub is available, a
/// Nostr/Lightning segmented control otherwise. Within the Lightning pane, a profile that
/// advertises both an address and an offer gets a secondary Address/Offer toggle.
struct ProfileQrSheet: View {
    let pubkey: String
    let displayName: String
    let avatarUrl: String?
    let lud16: String?
    let clinkOffer: String?
    /// When provided, a scan button appears in the header; scanning another
    /// user's Nostr QR (npub / nprofile / `nostr:` URI) dismisses the sheet and
    /// hands the decoded pubkey here so the host can route to that profile.
    var onOpenProfile: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .nostr
    @State private var payKind: PayKind = .address
    @State private var showScanner = false
    @State private var scanError: String?

    private enum Tab: Hashable { case nostr, lightning }

    /// The two payment artifacts that can live under the Lightning pane.
    private enum PayKind: Hashable {
        case address, offer
        var label: String {
            switch self {
            case .address: return "Address"
            case .offer: return "Offer"
            }
        }
    }

    private var npub: String? {
        guard let bytes = Hex.decode(pubkey) else { return nil }
        return Nip19.npubEncode(pubkey: Array(bytes))
    }

    private var hasLightning: Bool {
        guard let lud16 else { return false }
        return !lud16.isEmpty
    }

    private var hasOffer: Bool {
        Noffer.isNofferString(clinkOffer)
    }

    /// True when the Lightning pane has anything to show.
    private var hasPayment: Bool { hasLightning || hasOffer }

    /// Payment artifacts available, address first.
    private var payKinds: [PayKind] {
        var kinds: [PayKind] = []
        if hasLightning { kinds.append(.address) }
        if hasOffer { kinds.append(.offer) }
        return kinds
    }

    /// The selected pay kind, clamped to what the profile actually advertises so
    /// the default `.address` never renders an empty pane for an offer-only profile.
    private var effectivePayKind: PayKind {
        payKinds.contains(payKind) ? payKind : (payKinds.first ?? .address)
    }

    private var subtitle: String {
        switch tab {
        case .nostr: return "Scan to follow on Nostr"
        case .lightning:
            return "Scan to send money"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 24)
                .padding(.horizontal, 20)

            if hasPayment || onOpenProfile != nil {
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
        .fullScreenCover(isPresented: $showScanner) {
            QRCodeScannerView(
                onScanned: handleScan,
                onCancel: { showScanner = false }
            )
            .ignoresSafeArea()
        }
        .alert(
            "Not a Nostr profile",
            isPresented: Binding(get: { scanError != nil }, set: { if !$0 { scanError = nil } }),
            presenting: scanError
        ) { _ in
            Button("OK", role: .cancel) { scanError = nil }
        } message: { Text($0) }
    }

    /// Decode a scanned payload; route to the profile on success, surface an
    /// alert when it isn't a Nostr profile reference.
    private func handleScan(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .profileRef(let scannedPubkey, _)? = Nip19.decodeNostrUri(trimmed) else {
            showScanner = false
            scanError = "That QR code isn't a Nostr profile."
            return
        }
        showScanner = false
        dismiss()
        onOpenProfile?(scannedPubkey)
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
            if hasLightning {
                tabButton(.lightning, label: "Lightning")
            }
            // Scan is an action, not a content pane — it launches the camera
            // and never shows as the selected segment.
            if onOpenProfile != nil {
                scanSegment
            }
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

    private var scanSegment: some View {
        Button {
            showScanner = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.caption.weight(.semibold))
                Text("Scan")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(.secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scan a Nostr QR code")
    }

    /// Single contextual button shown under the QR when the profile advertises both
    /// a Lightning address and an offer — taps flip to whichever one isn't showing.
    private var payKindSwitchButton: some View {
        let other: PayKind = effectivePayKind == .address ? .offer : .address
        let title = other == .offer ? "Switch to CLINK Offer" : "Switch to Lightning address"
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { payKind = other }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(Color.wispPrimary)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(Color.wispSurfaceVariant.opacity(0.4), in: Capsule())
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
            switch effectivePayKind {
            case .address:
                if let lud16, !lud16.isEmpty {
                    qrWithCenterAvatar(payload: lud16)
                    copyableRow(label: "Lightning address", value: lud16, tint: Color.wispZapColor)
                }
            case .offer:
                if let clinkOffer, !clinkOffer.isEmpty {
                    qrWithCenterAvatar(payload: clinkOffer)
                    copyableRow(label: "CLINK offer", value: clinkOffer, tint: Color.wispZapColor)
                }
            }
            // Only when the profile has both artifacts; a single artifact needs
            // no switch.
            if payKinds.count > 1 {
                payKindSwitchButton
                    .padding(.top, 4)
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
