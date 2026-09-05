import SwiftUI

/// Settings screen for the user's NIP-A3 payment targets (kind 10133).
///
/// Lives under Settings rather than the Wallet tab: targets are Nostr profile
/// metadata published as a replaceable event, and publishing them never requires
/// a connected Lightning wallet.
///
/// Edits are staged locally and only reach relays on "Save & Publish" — the whole
/// list travels in one replaceable event, so there is nothing to publish per row.
///
/// Ported from Dark Wisp Android's `PaymentTargetsScreen` + the payment-target
/// half of its `WalletViewModel`.
struct PaymentTargetsSettingsView: View {
    let keypair: Keypair

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var repo = PaymentTargetRepository.shared

    /// Locally staged list. Seeded from the cache, refreshed from relays on
    /// appear, and diffed against `publishedTargets` to drive the Save button.
    @State private var targets: [NipA3.PaymentTarget] = []
    /// Last list known to be on relays — the baseline for "dirty".
    @State private var publishedTargets: [NipA3.PaymentTarget] = []

    @State private var isLoading = false
    @State private var isPublishing = false
    @State private var errorMessage: String?

    @State private var selectedType: String = ""
    @State private var customType = false
    @State private var authorityInput = ""
    @State private var showScanner = false

    @FocusState private var customTypeFocused: Bool

    private var isDirty: Bool { targets != publishedTargets }

    private var usedTypes: Set<String> { Set(targets.map(\.type)) }

    private var normalizedSelectedType: String? { NipA3.normalizeType(selectedType) }

    private var typeAlreadyUsed: Bool {
        guard let type = normalizedSelectedType else { return false }
        return usedTypes.contains(type)
    }

    /// The profile's kind-0 `lud16`, if set. Used to warn that a Lightning payto
    /// target duplicates the zap address NIP-57 clients already use.
    private var profileLightningAddress: String? {
        let lud16 = ProfileRepository.shared.get(keypair.pubkey)?.lud16 ?? ""
        return lud16.isEmpty ? nil : lud16
    }

    private var canAdd: Bool {
        normalizedSelectedType != nil
            && !authorityInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !typeAlreadyUsed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if keypair.isWatchOnly {
                    watchOnlyBanner
                }

                Text("Publish addresses for other cryptocurrencies and payment apps so people can pay you beyond Lightning zaps.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.palette.onSurfaceVariant)

                Group {
                    targetsSection
                    addTargetSection
                    saveButton
                }
                .disabled(keypair.isWatchOnly)
                .opacity(keypair.isWatchOnly ? 0.4 : 1)

                Spacer(minLength: 32)
            }
            .padding(20)
        }
        .background(theme.palette.background.ignoresSafeArea())
        .navigationTitle("Payment Targets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            QRCodeScannerView(
                onScanned: { raw in
                    applyScan(raw)
                    showScanner = false
                },
                onCancel: { showScanner = false }
            )
            .ignoresSafeArea()
        }
        .task { await load() }
    }

    // MARK: - Current targets

    private var targetsSection: some View {
        section(
            title: "Your targets",
            footer: "One address per network. To change an address, remove it and add the new one."
        ) {
            if isLoading && targets.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if targets.isEmpty {
                Text("No payment targets yet. Add one below.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.palette.onSurfaceVariant)
            } else {
                ForEach(targets) { target in
                    targetRow(target)
                    if target != targets.last {
                        Divider().overlay(theme.palette.outline.opacity(0.3))
                    }
                }
            }
        }
    }

    private func targetRow(_ target: NipA3.PaymentTarget) -> some View {
        HStack(spacing: 10) {
            PaymentTargetGlyph(type: target.type, size: 18, tint: Color.wispZapColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(NipA3.displayName(target.type))
                    .font(.system(size: 15))
                    .foregroundStyle(theme.palette.onSurface)
                Text(target.authority)
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(theme.palette.onSurfaceVariant)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                remove(target)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(NipA3.displayName(target.type)) payment target")
        }
        .padding(.vertical, 4)
    }

    // MARK: - Add target

    private var addTargetSection: some View {
        section(title: "Add target") {
            typePicker

            if let hint = typeHint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(typeAlreadyUsed ? Color.red : theme.palette.onSurfaceVariant)
            }

            addressField

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            Button {
                add()
            } label: {
                Label("Add", systemImage: "plus.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(theme.palette.surfaceVariant, in: Capsule())
                    .foregroundStyle(canAdd ? theme.primary : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
        }
    }

    @ViewBuilder
    private var typePicker: some View {
        if customType {
            HStack(spacing: 8) {
                // The clearing lives in the binding's setter, not an
                // `.onChange`, so it only fires on user edits — a QR scan sets
                // the type and address together and must not have the address
                // wiped by its own type assignment.
                TextField("iban", text: Binding(
                    get: { selectedType },
                    set: { newValue in
                        guard newValue != selectedType else { return }
                        // An address is type-specific, so a leftover one is
                        // wrong the moment the type changes.
                        selectedType = newValue
                        authorityInput = ""
                        errorMessage = nil
                    }
                ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($customTypeFocused)
                Button("Cancel") {
                    customType = false
                    selectedType = ""
                    authorityInput = ""
                }
                .font(.system(size: 13))
                .buttonStyle(.plain)
                .foregroundStyle(theme.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.palette.surfaceVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        } else {
            Menu {
                ForEach(NipA3.recognizedOrder, id: \.self) { type in
                    Button {
                        select(type)
                    } label: {
                        Label {
                            Text(usedTypes.contains(type)
                                 ? "\(NipA3.displayName(type)) — already added"
                                 : NipA3.displayName(type))
                        } icon: {
                            if let asset = PaymentTargetGlyph.assetName(for: type) {
                                Image(asset)
                            } else if let symbol = PaymentTargetGlyph.symbolName(for: type) {
                                Image(systemName: symbol)
                            }
                        }
                    }
                    .disabled(usedTypes.contains(type))
                }
                Divider()
                Button("Custom…") {
                    selectedType = ""
                    authorityInput = ""
                    errorMessage = nil
                    customType = true
                    customTypeFocused = true
                }
            } label: {
                HStack(spacing: 10) {
                    if let type = normalizedSelectedType {
                        PaymentTargetGlyph(type: type, size: 18, tint: Color.wispZapColor)
                        Text(NipA3.displayName(type))
                            .foregroundStyle(theme.palette.onSurface)
                    } else {
                        Text("Network type")
                            .foregroundStyle(theme.palette.onSurfaceVariant)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 15))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(theme.palette.surfaceVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
        }
    }

    private var typeHint: String? {
        if typeAlreadyUsed {
            return "Already added — remove the existing one first to change its address."
        }
        if normalizedSelectedType == "lightning", let ln = profileLightningAddress {
            return "Your profile already advertises \(ln) for zaps — keep them identical so they can't drift apart."
        }
        if customType {
            return "Any lowercase type works — letters, digits and hyphens."
        }
        return nil
    }

    private var addressField: some View {
        HStack(spacing: 8) {
            TextField("bc1q…", text: $authorityInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14).monospaced())
            Button {
                showScanner = true
            } label: {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Scan address QR code")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.palette.surfaceVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Save

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            HStack(spacing: 8) {
                if isPublishing {
                    ProgressView().controlSize(.small).tint(.white)
                }
                Text(isPublishing ? "Publishing…" : "Save & Publish")
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isDirty && !isPublishing ? theme.primary : theme.palette.surfaceVariant, in: Capsule())
            .foregroundStyle(isDirty && !isPublishing ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!isDirty || isPublishing)
    }

    private var watchOnlyBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "eye")
                .foregroundStyle(Color.wispPrimary)
                .font(.subheadline)
                .padding(.top, 2)
            Text("Watch-only mode — payment targets can be viewed but not published.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Actions

    /// Seed from the local cache, then read back the newest kind 10133 from the
    /// network before editing — it's a replaceable event, so saving on top of a
    /// stale copy would clobber targets added from another client.
    private func load() async {
        let cached = repo.targets(for: keypair.pubkey) ?? []
        targets = cached
        publishedTargets = cached
        isLoading = true
        defer { isLoading = false }
        let fresh = await repo.refreshOwn(pubkey: keypair.pubkey)
        // A user who started editing while the fetch was in flight keeps their
        // edits; only the untouched baseline is replaced.
        guard !isDirty else {
            publishedTargets = fresh
            return
        }
        targets = fresh
        publishedTargets = fresh
    }

    private func select(_ type: String) {
        if selectedType != type { authorityInput = "" }
        selectedType = type
        customType = false
        errorMessage = nil
        // Seed from the profile's zap address so a Lightning target starts out
        // matching lud16 instead of diverging from it.
        if type == "lightning", authorityInput.isEmpty, let ln = profileLightningAddress {
            authorityInput = ln
        }
    }

    private func add() {
        guard let type = normalizedSelectedType else {
            errorMessage = "Type may only contain a-z, 0-9 and hyphens"
            return
        }
        let authority = authorityInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NipA3.isValidAuthority(authority) else {
            errorMessage = "Enter a valid address"
            return
        }
        if type == "lightning" && !NipA3.isReusableLightningTarget(authority) {
            errorMessage = "Enter a Lightning address like you@example.com — invoices and LNURL expire or aren't reusable."
            return
        }
        // One address per type: replacing an address means removing the existing
        // entry first, so a stale address can never linger alongside its successor.
        guard !usedTypes.contains(type) else {
            errorMessage = "You already have a \(NipA3.displayName(type)) address. Remove it before adding another."
            return
        }
        targets.append(NipA3.PaymentTarget(type: type, authority: authority))
        errorMessage = nil
        selectedType = ""
        authorityInput = ""
        customType = false
    }

    private func remove(_ target: NipA3.PaymentTarget) {
        targets.removeAll { $0 == target }
        errorMessage = nil
    }

    private func save() async {
        isPublishing = true
        defer { isPublishing = false }
        do {
            try await repo.publish(targets: targets, keypair: keypair)
            publishedTargets = targets
            errorMessage = nil
            QuickFollowToast.shared.show("Payment targets published")
        } catch PaymentTargetRepository.PublishError.noRelayConfirmed {
            errorMessage = "No relay confirmed the update. Try again."
        } catch PaymentTargetRepository.PublishError.watchOnly {
            errorMessage = "Watch-only accounts can't publish."
        } catch {
            errorMessage = "Could not publish payment targets."
        }
    }

    private func applyScan(_ raw: String) {
        let scan = NipA3.parseScannedUri(raw)
        // A bare address carries no scheme, so keep whatever type is selected.
        if let type = scan.type {
            selectedType = type
            // An unrecognized scanned type (payto://iban/…) has no menu entry,
            // so drop into custom mode to keep it editable.
            customType = NipA3.recognized[type] == nil
        }
        authorityInput = scan.authority
        errorMessage = nil
    }

    // MARK: - Layout helper

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.onSurfaceVariant)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.onSurfaceVariant)
            }
        }
    }
}
