import SwiftUI

/// Sidebar → Settings → Keys. Shows the active account's bech32 public key (`npub`)
/// always, and the private key (`nsec`) behind a Reveal toggle with copy/QR actions.
struct KeysSettingsView: View {
    let keypair: Keypair

    @Environment(\.dismiss) private var dismiss
    @State private var revealNsec = false
    @State private var qrPayload: QrPayload?

    private struct QrPayload: Identifiable {
        let id = UUID()
        let label: String
        let value: String
    }

    private var npub: String {
        guard let bytes = Hex.decode(keypair.pubkey),
              let s = Nip19.npubEncode(pubkey: Array(bytes)) else { return keypair.pubkey }
        return s
    }

    private var nsec: String? {
        guard let bytes = Hex.decode(keypair.privkey) else { return nil }
        return Nip19.nsecEncode(privkey: Array(bytes))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                publicKeySection
                privateKeySection
            }
            .padding(20)
        }
        .background(Color.wispBackground.ignoresSafeArea())
        .navigationTitle("Keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(item: $qrPayload) { payload in
            keyQrSheet(payload: payload)
        }
    }

    // MARK: - Public key

    private var publicKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Public Key")
                .font(.subheadline.weight(.semibold))
            Text("Share this freely — it's your Nostr identifier.")
                .font(.caption)
                .foregroundStyle(.secondary)

            keyCard(value: npub)
            keyActionRow(value: npub, qrLabel: "npub")
        }
    }

    // MARK: - Private key

    private var privateKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Private Key")
                .font(.subheadline.weight(.semibold))

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.wispZapColor)
                    .font(.caption)
                    .padding(.top, 2)
                Text("Anyone with your nsec controls your account. Never paste it into an untrusted app or share it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.wispZapColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            if let nsec {
                if revealNsec {
                    keyCard(value: nsec)
                    keyActionRow(value: nsec, qrLabel: "nsec")
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { revealNsec = false }
                    } label: {
                        Label("Hide", systemImage: "eye.slash")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.top, 4)
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { revealNsec = true }
                    } label: {
                        Label("Reveal Private Key", systemImage: "eye")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.wispSurface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Could not encode private key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Pieces

    private func keyCard(value: String) -> some View {
        Text(value)
            .font(.system(size: 13, design: .monospaced))
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.wispSurface, in: RoundedRectangle(cornerRadius: 12))
            .textSelection(.enabled)
    }

    private func keyActionRow(value: String, qrLabel: String) -> some View {
        HStack(spacing: 10) {
            Button {
                UIPasteboard.general.string = value
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.wispSurfaceVariant, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                qrPayload = QrPayload(label: qrLabel, value: value)
            } label: {
                Label("QR", systemImage: "qrcode")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.wispSurfaceVariant, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func keyQrSheet(payload: QrPayload) -> some View {
        // Brand the npub QR with the user's avatar (it's an identity QR). Don't put the
        // avatar on the nsec QR — that QR carries the private key and shouldn't be visually
        // tied to a recognizable face; show the Wisp logo instead.
        let avatarUrl: String? = payload.label == "npub"
            ? ProfileRepository.shared.get(keypair.pubkey)?.picture
            : nil

        return VStack(spacing: 16) {
            Text(payload.label.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 24)

            ZStack {
                QRCodeImage(payload: payload.value, sideLength: 260, correctionLevel: "H")

                ZStack {
                    Circle().fill(Color.white)
                    if let url = avatarUrl, !url.isEmpty {
                        CachedAvatarView(url: url, size: 44)
                            .clipShape(Circle())
                    } else {
                        Image("WispLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                    }
                }
                .frame(width: 52, height: 52)
            }
            .padding(20)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16))

            Text(payload.value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.wispBackground)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
