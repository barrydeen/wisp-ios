import SwiftUI

/// Spark wallet setup: pick from Create / Restore-from-seed / Restore-from-relays.
/// Restore-from-relays runs automatically on appear and shows results inline.
struct SparkSetupView: View {
    @Bindable var store: WalletStore
    var dismiss: () -> Void
    @State private var mode: PickerMode = .pick
    @State private var newMnemonic: String?
    @State private var restoreEntry: String = ""
    @State private var restoreError: String?
    @State private var inFlight = false

    enum PickerMode { case pick, create, restoreSeed, restoreRelays }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color.wispBackground.ignoresSafeArea())
        .navigationTitle(mode == .pick ? "" : subModeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Close", action: dismiss) }
            if mode != .pick {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        mode = .pick
                        restoreEntry = ""
                        newMnemonic = nil
                        store.resetRelayBackupSearch()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                    }
                }
            }
        }
    }

    private var subModeTitle: String {
        switch mode {
        case .pick: return "Spark Wallet"
        case .create: return "New Wallet"
        case .restoreSeed: return "Restore Wallet"
        case .restoreRelays: return "Restore from Relays"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .pick:           pickSection
        case .create:         createSection
        case .restoreSeed:    restoreFromSeedSection
        case .restoreRelays:  restoreFromRelaysSection
        }
    }

    // MARK: - Pick

    private var pickSection: some View {
        VStack(spacing: 24) {
            // Logo header
            VStack(spacing: 12) {
                Image("SparkBreezLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 22)
                Text("Self-custodial Lightning,\npowered by Spark and Breez.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            // Option rows
            VStack(spacing: 12) {
                optionRow(
                    icon: "plus.circle.fill",
                    title: "Create new wallet",
                    subtitle: "Generate a fresh 12-word seed phrase",
                    action: { startCreate() }
                )
                optionRow(
                    icon: "arrow.uturn.backward.circle.fill",
                    title: "Restore from seed phrase",
                    subtitle: "12 words from a Spark-based wallet",
                    action: { mode = .restoreSeed }
                )
                optionRow(
                    icon: "icloud.and.arrow.down.fill",
                    title: "Restore from relays",
                    subtitle: "Encrypted backup from another device",
                    action: { mode = .restoreRelays; Task { await store.searchRelayBackup() } }
                )
            }
        }
    }

    private func optionRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.wispZapColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Create

    private func startCreate() {
        do {
            newMnemonic = try Bip39.newMnemonic()
            mode = .create
        } catch {
            restoreError = "Failed to generate mnemonic: \(error.localizedDescription)"
        }
    }

    private var createSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Warning card
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.wispZapColor)
                    .font(.system(size: 16))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Write this down")
                        .font(.subheadline.weight(.semibold))
                    Text("Anyone with these 12 words controls your funds. Store them somewhere safe before continuing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.wispZapColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            // Mnemonic display
            if let mnemonic = newMnemonic {
                let words = mnemonic.split(separator: " ").map(String.init)
                let columns = [GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 20, alignment: .trailing)
                            Text(word)
                                .font(.system(.subheadline, design: .monospaced).weight(.medium))
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(16)
                .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                .textSelection(.enabled)
            }

            if let err = restoreError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            // Continue button
            Button {
                guard let mnemonic = newMnemonic else { return }
                Task { await connect(with: mnemonic) }
            } label: {
                Group {
                    if inFlight { ProgressView().tint(.white) } else {
                        Text("I've backed this up — continue")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.wispZapColor, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(inFlight || newMnemonic == nil)
            .buttonStyle(.plain)
        }
    }

    // MARK: - Restore from seed

    private var restoreFromSeedSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Enter your recovery phrase, separated by spaces.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextEditor(text: $restoreEntry)
                .frame(minHeight: 120)
                .font(.system(.subheadline, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .scrollContentBackground(.hidden)
                .padding(14)
                .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))

            if let err = restoreError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                }
            }

            Button {
                let trimmed = restoreEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                if let err = Bip39.validate(trimmed) {
                    restoreError = err; return
                }
                restoreError = nil
                Task { await connect(with: trimmed) }
            } label: {
                Group {
                    if inFlight { ProgressView().tint(.white) } else {
                        Text("Restore wallet")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    restoreEntry.isEmpty ? Color.wispSurfaceVariant : Color.wispZapColor,
                    in: RoundedRectangle(cornerRadius: 14)
                )
            }
            .disabled(restoreEntry.isEmpty || inFlight)
            .buttonStyle(.plain)
        }
    }

    // MARK: - Restore from relays

    private var restoreFromRelaysSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Searching your write relays for an encrypted seed backup.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            relayBackupBody

            if let err = restoreError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var relayBackupBody: some View {
        switch store.relayBackupSearchState {
        case .idle:
            primaryButton("Search relays", action: { Task { await store.searchRelayBackup() } })

        case .searching:
            HStack(spacing: 12) {
                ProgressView()
                Text("Searching relays…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))

        case .notFound:
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text("No backup found on your relays.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))

                Button("Search again") { Task { await store.searchRelayBackup() } }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.wispZapColor)
            }

        case .found(let entry):
            foundCard(entry: entry)

        case .multiple(let entries):
            VStack(spacing: 12) {
                ForEach(entries) { entry in
                    Button { store.selectBackupToRestore(entry) } label: {
                        foundCard(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
            }

        case .error(let message):
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))

                Button("Retry") { Task { await store.searchRelayBackup() } }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.wispZapColor)
            }
        }
    }

    @ViewBuilder
    private func foundCard(entry: BackupEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.wispRepostColor)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Backup found")
                        .font(.subheadline.weight(.semibold))
                    Text("Created \(relativeTime(from: entry.createdAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // Full walletId (first 16 hex of SHA256(mnemonic)) so the
                    // user can tell distinct backups apart in the `.multiple`
                    // state and confirm "yes this is the wallet I just backed
                    // up" in the `.found` state. The right-edge truncated
                    // chip was visually too quiet to register.
                    if let id = entry.walletId {
                        Text("ID \(id)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("Legacy backup (no wallet id)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }

            Button {
                Task { await connect(with: entry.mnemonic) }
            } label: {
                Group {
                    if inFlight { ProgressView().tint(.white) } else {
                        Text("Restore this wallet")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.wispZapColor, in: RoundedRectangle(cornerRadius: 10))
            }
            .disabled(inFlight)
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Helpers

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.wispZapColor, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Connect

    private func connect(with mnemonic: String) async {
        inFlight = true
        defer { inFlight = false }
        let ok = await store.connectSpark(mnemonic: mnemonic)
        if ok {
            dismiss()
        } else {
            restoreError = store.lastStatus ?? "Failed to initialize wallet"
        }
    }
}
