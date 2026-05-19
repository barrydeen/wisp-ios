import SwiftUI
import LocalAuthentication

/// Sidebar → Settings → Keys. Shows the active account's bech32 public key (`npub`)
/// always. For local accounts the private key (`nsec`) is shown behind a Reveal
/// toggle. For remote-signer accounts the nsec section is replaced with the
/// remote-signer status (connection health, signer pubkey, relays).
struct KeysSettingsView: View {
    let keypair: Keypair

    @Environment(\.dismiss) private var dismiss
    @State private var revealNsec = false
    @State private var qrPayload: QrPayload?
    @State private var signerHealth: SignerHealth = .checking
    @State private var signerStatusDetail: String?

    private enum SignerHealth {
        case checking, connected, offline
    }

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
                if keypair.isWatchOnly {
                    watchOnlySection
                } else if keypair.isRemote {
                    remoteSignerSection
                } else {
                    privateKeySection
                }
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
        .task(id: keypair.pubkey) {
            if keypair.isRemote { await pingSigner() }
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
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                } else {
                    Button {
                        Task { await authenticateAndRevealNsec() }
                    } label: {
                        Label("Reveal Private Key", systemImage: "eye")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
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

    // MARK: - Watch-only

    private var watchOnlySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Private Key")
                .font(.subheadline.weight(.semibold))

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "eye")
                    .foregroundStyle(Color.wispPrimary)
                    .font(.subheadline)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Watch-only account")
                        .font(.subheadline.weight(.semibold))
                    Text("No private key is stored on this device. You can browse public content but can\u{2019}t post, react, or zap.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.wispSurface, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Remote signer

    private var remoteSignerSection: some View {
        let session = Nip46Manager.shared.activeSession
            ?? Nip46SessionStore.load(pubkey: keypair.pubkey)
        // Only surface the signer's npub when it's a *different* key from the
        // user's. Some signers (e.g. Primal mobile) sign with the user's own
        // key — in which case it'd just be a second copy of the npub already
        // shown in the Public Key section above. Delegated-key signers
        // (Amber-style) have a distinct signer pubkey worth seeing.
        let signerNpub: String? = {
            guard let session,
                  session.signerPubkey.lowercased() != keypair.pubkey.lowercased(),
                  let bytes = Hex.decode(session.signerPubkey) else { return nil }
            return Nip19.npubEncode(pubkey: Array(bytes))
        }()

        return VStack(alignment: .leading, spacing: 10) {
            Text("Remote Signer")
                .font(.subheadline.weight(.semibold))
            Text("Your private key lives in a separate signer app and never leaves it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Status pill.
            HStack(spacing: 10) {
                Circle()
                    .fill(healthColor)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(healthColor.opacity(0.35), lineWidth: 4)
                            .scaleEffect(signerHealth == .checking ? 1.4 : 1.0)
                            .opacity(signerHealth == .checking ? 0.0 : 1.0)
                            .animation(.easeOut(duration: 0.9).repeatForever(autoreverses: false),
                                       value: signerHealth)
                    )
                Text(healthLabel)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    Task { await pingSigner() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.wispSurfaceVariant, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(signerHealth == .checking)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.wispSurface, in: RoundedRectangle(cornerRadius: 12))

            if let detail = signerStatusDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            // Signer identity.
            if let signerNpub {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Signer Pubkey")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    // Reference-only — the signer's identity is for display
                    // and isn't something the user shares to receive zaps
                    // or mentions, so no Copy / QR affordance.
                    keyCard(value: signerNpub)
                }
                .padding(.top, 4)
            }

            // Relays + connected-since.
            if let session {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Signer Relays")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(session.relays, id: \.self) { relay in
                            Text(relay)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                    .background(Color.wispSurface, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.top, 4)

                HStack {
                    Text("Connected since")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Self.formatTimestamp(session.createdAt))
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 4)
                .padding(.top, 4)
            }
        }
    }

    private var healthColor: Color {
        switch signerHealth {
        case .checking: return Color.wispZapColor
        case .connected: return .green
        case .offline: return .red
        }
    }

    private var healthLabel: String {
        switch signerHealth {
        case .checking: return "Checking…"
        case .connected: return "Connected"
        case .offline: return "Offline"
        }
    }

    @MainActor
    private func pingSigner() async {
        signerHealth = .checking
        signerStatusDetail = nil
        let manager = Nip46Manager.shared
        if manager.activeClient == nil {
            _ = await manager.restoreSession(pubkey: keypair.pubkey)
        }
        guard let client = manager.activeClient else {
            signerHealth = .offline
            signerStatusDetail = "No active signer session for this account."
            return
        }
        do {
            _ = try await client.ping()
            signerHealth = .connected
        } catch Nip46.NipError.rpcError {
            // Signer responded but doesn't implement `ping` (some signers
            // don't). Any response means the relay round-trip works.
            signerHealth = .connected
        } catch {
            signerHealth = .offline
            signerStatusDetail = "Signer did not respond. The signer app may be closed or offline."
        }
    }

    @MainActor
    private func authenticateAndRevealNsec() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode or biometry configured — reveal directly.
            withAnimation(.easeInOut(duration: 0.15)) { revealNsec = true }
            return
        }
        do {
            let granted = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Authenticate to reveal your private key"
            )
            if granted {
                withAnimation(.easeInOut(duration: 0.15)) { revealNsec = true }
            }
        } catch {
            // User cancelled or authentication failed — do nothing.
        }
    }

    private static func formatTimestamp(_ ts: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
                QuickFollowToast.shared.show("Copied")
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
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
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.wispSurfaceVariant, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func keyRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                UIPasteboard.general.string = value
                QuickFollowToast.shared.show("Copied")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.wispSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func keyQrSheet(payload: QrPayload) -> some View {
        let avatarUrl: String? = ProfileRepository.shared.get(keypair.pubkey)?.picture

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


            if payload.label == "nsec" {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.wispZapColor)
                        .font(.caption)
                        .padding(.top, 2)
                    Text("Anyone who scans this QR code gains full control of your account. Only share it with apps you trust.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.wispZapColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
            } else {
                VStack(spacing: 8) {
                    keyRow(label: "npub", value: npub)
                    keyRow(label: "hex", value: keypair.pubkey)
                }
                .padding(.horizontal, 24)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.wispBackground)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }
}
