import SwiftUI

// MARK: - Balance unit

enum WalletBalanceUnit: String, CaseIterable {
    case sats, btc, msats

    var label: String {
        switch self {
        case .sats:  return "sats"
        case .btc:   return "BTC"
        case .msats: return "msat"
        }
    }

    func format(_ sats: Int64) -> String {
        switch self {
        case .sats:  return "\(CurrencyFormatter.formatNumber(sats)) sats"
        case .btc:
            let btc = Double(sats) / 100_000_000.0
            if btc == 0 { return "₿0" }
            if btc < 0.001 { return String(format: "₿%.8f", btc) }
            return String(format: "₿%.5f", btc)
        case .msats: return "\(CurrencyFormatter.formatNumber(sats * 1000)) msat"
        }
    }

    func formatNumber(_ sats: Int64) -> String {
        switch self {
        case .sats:  return CurrencyFormatter.formatNumber(sats)
        case .btc:
            let btc = Double(sats) / 100_000_000.0
            if btc == 0 { return "0" }
            if btc < 0.001 { return String(format: "%.8f", btc) }
            return String(format: "%.5f", btc)
        case .msats: return CurrencyFormatter.formatNumber(sats * 1000)
        }
    }

    var unitLabel: String {
        switch self {
        case .sats:  return "sats"
        case .btc:   return "BTC"
        case .msats: return "msat"
        }
    }

    var pickerLabel: String {
        switch self {
        case .sats:  return "1,000 sats"
        case .btc:   return "₿ 1,000"
        case .msats: return "⚡ 1,000"
        }
    }
}

// MARK: - Settings view

struct WalletSettingsView: View {
    @Bindable var store: WalletStore
    @Environment(\.dismiss) private var dismiss

    @State private var showDisconnectAlert = false
    @State private var showDeleteAlert = false
    @State private var showRemoveAddressAlert = false
    @AppStorage private var balanceHidden: Bool
    @AppStorage("walletBalanceUnit") private var balanceUnitRaw: String = WalletBalanceUnit.sats.rawValue

    // Lightning address management state
    @State private var showAddressSheet = false
    @State private var addressError: String?

    init(store: WalletStore) {
        self.store = store
        _balanceHidden = AppStorage(wrappedValue: false, "balanceHidden_\(store.keypair.pubkey)")
    }

    private var balanceUnit: WalletBalanceUnit {
        WalletBalanceUnit(rawValue: balanceUnitRaw) ?? .sats
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if store.mode == .spark {
                    lightningAddressSection
                }
                displaySection
                if store.mode == .spark {
                    securitySection
                }
                disclaimerCard
                dangerSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .background(Color.wispBackground.ignoresSafeArea())
        .navigationTitle("Wallet Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Disconnect wallet?", isPresented: $showDisconnectAlert) {
            Button("Disconnect", role: .destructive) {
                store.resetToNoWallet()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your NWC connection will be removed. You can reconnect at any time.")
        }
        .alert("Delete wallet?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                store.resetToNoWallet()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete your Spark wallet from this device. Make sure you have your recovery phrase before proceeding.")
        }
        .alert("Remove lightning address?", isPresented: $showRemoveAddressAlert) {
            Button("Remove", role: .destructive) {
                Task {
                    do {
                        try await store.removeLightningAddress()
                    } catch {
                        addressError = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your lightning address will be deleted and you won't be able to receive payments at it.")
        }
        .sheet(isPresented: $showAddressSheet) {
            LightningAddressSetupSheet(store: store)
        }
    }

    // MARK: - Lightning address (Spark only)

    private var lightningAddressSection: some View {
        settingsGroup(header: "Lightning Address") {
            if let addr = store.lightningAddress {
                // Show existing address
                HStack(spacing: 12) {
                    Image(systemName: "at")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.wispZapColor)
                        .frame(width: 22)
                    Text(addr)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = addr
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider().opacity(0.25).padding(.leading, 50)

                // Change / Remove buttons
                HStack(spacing: 0) {
                    Button {
                        showAddressSheet = true
                    } label: {
                        Text("Change")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.wispZapColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)

                    Divider().frame(height: 20)

                    Button {
                        showRemoveAddressAlert = true
                    } label: {
                        Text("Remove")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                // No address yet — invite to set one up
                Button {
                    showAddressSheet = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "at.badge.plus")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.wispZapColor)
                            .frame(width: 22)
                        Text("Set up lightning address")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let err = addressError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        settingsGroup(header: "Display") {
            // Hide balance toggle
            HStack {
                Text("Hide balance")
                    .font(.subheadline)
                Spacer()
                Toggle("", isOn: $balanceHidden)
                    .labelsHidden()
                    .tint(Color.wispZapColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().opacity(0.25).padding(.leading, 16)

            // Balance unit
            VStack(alignment: .leading, spacing: 10) {
                Text("Balance unit")
                    .font(.subheadline)

                HStack(spacing: 8) {
                    ForEach(WalletBalanceUnit.allCases, id: \.rawValue) { unit in
                        let selected = balanceUnit == unit
                        Button {
                            balanceUnitRaw = unit.rawValue
                        } label: {
                            Text(unit.pickerLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(selected ? Color.wispZapColor : .secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 20)
                                        .stroke(selected ? Color.wispZapColor : Color.wispSurfaceVariant, lineWidth: 1.5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 20)
                                                .fill(selected ? Color.wispZapColor.opacity(0.1) : Color.clear)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Security (Spark only)

    private var securitySection: some View {
        settingsGroup(header: "Security") {
            // Recovery phrase
            NavigationLink(value: WalletRoute.recoveryPhrase) {
                HStack(spacing: 12) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.wispZapColor)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recovery phrase")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        if !store.seedBackupAcknowledged {
                            Text("Not acknowledged")
                                .font(.footnote)
                                .foregroundStyle(Color.wispZapColor)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            Divider().opacity(0.25).padding(.leading, 50)

            // Relay backup
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "icloud.and.arrow.up")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    Text("Relay backup")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer()
                }

                relayBackupContent
                    .padding(.leading, 34)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private var relayBackupContent: some View {
        switch store.relayBackupPublishState {
        case .idle:
            Button("Back up seed to relays") {
                Task { await store.publishRelayBackup() }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.wispZapColor)

        case .publishing:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.75)
                Text("Publishing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .success(let relays):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Backed up to \(relays.count) relay\(relays.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Back up again") {
                    store.resetRelayBackupPublish()
                    Task { await store.publishRelayBackup() }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.wispZapColor)
            }

        case .error(let msg):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
                Button("Retry") {
                    store.resetRelayBackupPublish()
                    Task { await store.publishRelayBackup() }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.wispZapColor)
            }
        }
    }

    // MARK: - Disclaimer

    private var disclaimerCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            Text("Wisp never holds user funds. You manage your own wallet and are responsible for securing it properly.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Danger zone

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Danger Zone")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                if store.mode == .nwc {
                    Button {
                        showDisconnectAlert = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 15))
                                .foregroundStyle(.red)
                                .frame(width: 22)
                            Text("Disconnect wallet")
                                .font(.subheadline)
                                .foregroundStyle(.red)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        showDeleteAlert = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "trash")
                                .font(.system(size: 15))
                                .foregroundStyle(.red)
                                .frame(width: 22)
                            Text("Delete wallet")
                                .font(.subheadline)
                                .foregroundStyle(.red)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))

            Text(store.mode == .spark
                 ? "Deleting removes the wallet from this device. You can restore it with your recovery phrase."
                 : "Disconnecting removes the NWC connection string. Your wallet provider is unaffected.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Helper

    private func settingsGroup<Content: View>(header: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                content()
            }
            .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

// MARK: - Lightning address setup sheet

struct LightningAddressSetupSheet: View {
    @Bindable var store: WalletStore
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var availability: AddressAvailability = .idle
    @State private var checkTask: Task<Void, Never>?
    @State private var isRegistering = false
    @State private var registrationError: String?

    enum AddressAvailability {
        case idle, checking, available, taken, error(String)
    }

    private var domain: String { "breez.tips" }
    private var trimmed: String { username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private var isValidUsername: Bool {
        let r = trimmed
        return r.count >= 2 && r.count <= 30 &&
               r.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
    private var canRegister: Bool {
        if case .available = availability { return isValidUsername && !isRegistering }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "at.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.wispZapColor)
                        Text("Lightning Address")
                            .font(.title3.weight(.semibold))
                        Text("Receive payments at a human-readable address.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    // Input
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 0) {
                            TextField("username", text: $username)
                                .font(.system(.body, design: .monospaced))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .onChange(of: username) { _, _ in scheduleAvailabilityCheck() }
                                .padding(.leading, 16)
                                .padding(.vertical, 14)

                            Text("@\(domain)")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.trailing, 16)
                        }
                        .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

                        availabilityStatus
                    }

                    if let err = registrationError {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                            Text(err).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await register() }
                    } label: {
                        Group {
                            if isRegistering {
                                ProgressView().tint(.white)
                            } else {
                                Text("Set Address")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            canRegister ? Color.wispZapColor : Color.wispSurfaceVariant,
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canRegister)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Color.wispBackground.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel", action: { dismiss() })
                }
            }
        }
    }

    @ViewBuilder
    private var availabilityStatus: some View {
        switch availability {
        case .idle:
            Text("Letters, numbers, _ and - only. 2–30 characters.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.75)
                Text("Checking availability…").font(.caption).foregroundStyle(.secondary)
            }
        case .available:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(trimmed)@\(domain) is available").font(.caption).foregroundStyle(.secondary)
            }
        case .taken:
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text("That username is already taken").font(.caption).foregroundStyle(.secondary)
            }
        case .error(let msg):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func scheduleAvailabilityCheck() {
        checkTask?.cancel()
        guard isValidUsername else {
            availability = .idle
            return
        }
        availability = .checking
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let ok = await store.checkLightningAddressAvailable(username: trimmed)
            guard !Task.isCancelled else { return }
            availability = ok ? .available : .taken
        }
    }

    private func register() async {
        isRegistering = true
        registrationError = nil
        defer { isRegistering = false }
        do {
            try await store.registerLightningAddress(username: trimmed)
            dismiss()
        } catch {
            registrationError = error.localizedDescription
        }
    }
}
