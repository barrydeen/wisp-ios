import SwiftUI

struct NwcSetupView: View {
    @Bindable var store: WalletStore
    var dismiss: () -> Void
    @State private var uri: String = ""
    @State private var status: String?
    @State private var inFlight = false
    @State private var showScanner = false
    @State private var restoring = false

    private var isValidUri: Bool {
        uri.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("nostr+walletconnect://")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                // Logo + header
                VStack(spacing: 14) {
                    Image("NwcLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 40)
                    Text("Nostr Wallet Connect")
                        .font(.title2.weight(.semibold))
                    Text("Paste the connection string\nfrom your NWC-compatible wallet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)

                // Restore-from-backup
                backupSection

                // Input card
                VStack(alignment: .leading, spacing: 0) {
                    TextEditor(text: $uri)
                        .frame(minHeight: 120)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .scrollContentBackground(.hidden)
                        .padding(14)

                    Divider().opacity(0.3)

                    HStack(spacing: 0) {
                        Button {
                            if let s = UIPasteboard.general.string { uri = s }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.wispZapColor)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)

                        Divider().frame(height: 24)

                        Button {
                            showScanner = true
                        } label: {
                            Label("Scan QR", systemImage: "qrcode.viewfinder")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.wispZapColor)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))

                // Hint
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                    Text("Connection string starts with nostr+walletconnect://")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if store.isRelayBackupSupported {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.icloud")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                        Text("Connecting saves an encrypted backup to your Nostr relays so you can restore this connection on other devices.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Status
                if let status {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(status)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Connect button
                Button {
                    Task { await connect() }
                } label: {
                    Group {
                        if inFlight {
                            ProgressView().tint(.white)
                        } else {
                            Text("Connect")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        isValidUri ? Color.wispZapColor : Color.wispSurfaceVariant,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!isValidUri || inFlight)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(Color.wispBackground.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Close", action: dismiss) }
        }
        .task { await store.searchNwcBackup() }
        .fullScreenCover(isPresented: $showScanner) {
            QRCodeScannerView(
                onScanned: { code in
                    uri = code.trimmingCharacters(in: .whitespacesAndNewlines)
                    showScanner = false
                },
                onCancel: { showScanner = false }
            )
            .ignoresSafeArea()
        }
    }

    private func connect() async {
        inFlight = true
        defer { inFlight = false }
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = await store.connectNwc(uri: trimmed)
        if ok {
            dismiss()
        } else {
            status = store.lastStatus ?? "Could not connect — check the connection string"
        }
    }

    // MARK: - Restore from backup

    @ViewBuilder
    private var backupSection: some View {
        switch store.nwcBackupSearchState {
        case .searching:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text("Checking for a saved connection…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)

        case .found(let backupUri, let createdAt):
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.icloud")
                        .foregroundStyle(Color.wispZapColor)
                    Text("Backup found")
                        .font(.subheadline.weight(.semibold))
                }
                Text("A connection backed up \(backupDateText(createdAt)) is available. Restore it to reconnect without pasting a string.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await restore(backupUri) }
                } label: {
                    Group {
                        if restoring {
                            ProgressView().tint(.white)
                        } else {
                            Text("Restore connection")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.wispZapColor, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(restoring || inFlight)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.wispZapColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))

        case .idle, .notFound, .error:
            EmptyView()
        }
    }

    private func restore(_ backupUri: String) async {
        restoring = true
        defer { restoring = false }
        let ok = await store.connectNwc(uri: backupUri)
        if ok {
            dismiss()
        } else {
            status = store.lastStatus ?? "Couldn't restore the backed-up connection"
        }
    }

    private func backupDateText(_ unix: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "on " + formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }
}
