import SwiftUI

/// NWC counterpart of `RecoveryPhraseView`: reveals the raw
/// `nostr+walletconnect://…` URI so the user can move the connection to
/// another client. The string embeds the client secret, so it stays blurred
/// until an explicit tap and the QR code is only offered once revealed.
struct NwcConnectionStringView: View {
    @Bindable var store: WalletStore
    @Environment(\.dismiss) private var dismiss

    @State private var revealed = false
    @State private var copied = false
    @State private var showQr = false

    private var uri: String? { store.nwcConnectionUri }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                warningCard
                if let uri {
                    stringSection(uri)
                    if revealed {
                        actionButtons(uri)
                        if showQr {
                            qrSection(uri)
                        }
                    }
                } else {
                    missingCard
                }
            }
            .padding(20)
        }
        .background(Color.wispBackground.ignoresSafeArea())
        .wispTopHeader { header }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        ZStack {
            Text("Connection String")
                .font(.subheadline.weight(.semibold))
            HStack {
                BackChevronButton { dismiss() }
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Warning card

    private var warningCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.wispZapColor)
                .font(.system(size: 16))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep this string secret")
                    .font(.subheadline.weight(.semibold))
                Text("Anyone with this connection string can spend from your wallet, up to whatever limits your wallet provider set. Only paste it into apps you trust.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispZapColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    private var missingCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No connection string stored")
                .font(.subheadline.weight(.medium))
            Text("Reconnect your wallet to store one on this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color.wispSurfaceVariant.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - String section

    private func stringSection(_ uri: String) -> some View {
        ZStack {
            Text(uri)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .blur(radius: revealed ? 0 : 8)
                .animation(.easeInOut(duration: 0.2), value: revealed)

            if !revealed {
                revealButton
            }
        }
        .padding(16)
        .background(Color.wispSurfaceVariant.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
    }

    private var revealButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { revealed = true }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.wispZapColor)
                Text("Tap to reveal")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Action buttons

    private func actionButtons(_ uri: String) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = uri
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied ✓" : "Copy to clipboard",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.wispSurfaceVariant.opacity(0.4),
                                    in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.15), value: copied)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        revealed = false
                        showQr = false
                    }
                } label: {
                    Label("Hide", systemImage: "eye.slash")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.wispSurfaceVariant.opacity(0.4),
                                    in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showQr.toggle() }
            } label: {
                Label(showQr ? "Hide QR code" : "Show QR code", systemImage: "qrcode")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.wispSurfaceVariant.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - QR

    private func qrSection(_ uri: String) -> some View {
        VStack(spacing: 12) {
            // NWC URIs are long, so error correction stays at the default
            // "M" — "H" would push the symbol past a comfortable module
            // density for on-screen scanning.
            QRCodeImage(payload: uri, sideLength: 240)
                .padding(20)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16))

            Text("Scan from another wallet-connect app to import this connection.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
