import SwiftUI

enum ZapType: String, CaseIterable, Identifiable {
    case `public`   = "Public"
    case anonymous  = "Anonymous"
    case `private`  = "Private"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .public:    "eye"
        case .anonymous: "eye.slash"
        case .private:   "lock"
        }
    }
}

/// Modal for sending a zap. Presented from the post card's bolt icon button.
struct ZapSheet: View {
    @Bindable var store: WalletStore
    @Environment(AppSettings.self) private var settings
    let recipientPubkey: String
    let recipientLud16: String?
    let recipientName: String?
    let eventId: String?
    /// Optional preferred relays for the zap-request `relays` tag (e.g. live stream chat relays).
    var relayHints: [String] = []
    /// Optional extra zap-request tags (e.g. `["a", "30311:host:dTag"]` for stream zaps).
    var extraTags: [[String]] = []
    /// Fires after a successful zap, with the chosen sats amount.
    var onSuccess: ((Int64) -> Void)? = nil
    var dismiss: () -> Void

    @State private var amountSats: Int64 = 21
    @State private var customAmountText: String = ""
    @State private var isCustom = false
    @State private var message: String = ""
    @State private var zapType: ZapType = .public
    @State private var showEditPresets = false
    @FocusState private var amountFocused: Bool

    // Persisted preset amounts as a comma-separated string
    @AppStorage("zapPresetAmounts") private var presetsRaw: String = "21,100,500,1000,5000"

    private static let maxPresets = 8

    private var presets: [Int64] {
        presetsRaw.split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }

    private var canSaveAsPreset: Bool {
        isCustom && amountSats > 0 && !presets.contains(amountSats)
    }

    private var canZap: Bool {
        recipientLud16 != nil && store.activeWallet != nil && amountSats > 0
    }

    /// Big amount shown in the hero. While typing custom in fiat mode the
    /// digit string is interpreted register-style (rightmost two digits are
    /// cents), e.g. "21" → "$0.21", "2100" → "$21.00". Outside fiat mode it
    /// mirrors the raw input. When not typing: fiat-rendered in fiat mode,
    /// grouped sats in non-fiat mode.
    private var heroAmountText: String {
        if isCustom && !customAmountText.isEmpty {
            if settings.fiatModeEnabled {
                return ZapSheet.formatRegisterCents(
                    digits: customAmountText,
                    currencyCode: settings.fiatCurrency
                )
            }
            return customAmountText
        }
        if settings.fiatModeEnabled { return CurrencyFormatter.short(sats: amountSats) }
        return CurrencyFormatter.formatNumber(amountSats)
    }

    /// Format a digit-only string as `$X.XX` register-style — last two
    /// digits are cents, everything before them is whole dollars. Used by
    /// the hero (live preview) and by the seed function so a previously
    /// chosen preset's sat value seeds back as the equivalent cents string
    /// on hero tap.
    private static func formatRegisterCents(digits: String, currencyCode: String) -> String {
        let cents = Int64(digits) ?? 0
        let dollars = Double(cents) / 100.0
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        let body = formatter.string(from: NSNumber(value: dollars)) ?? String(format: "%.2f", dollars)
        let currency = ExchangeRateService.currency(for: currencyCode)
        return "\(currency.symbol)\(body)"
    }

    /// Cents-as-digits seed for the custom amount field. Converts the
    /// current sats amount through the cached rate, rounds to the nearest
    /// cent, and returns the digit string with no separator (e.g. 1234
    /// cents → "1234"). Empty for zero or when no rate is cached.
    private static func seedCustomText(
        amountSats: Int64,
        fiatMode: Bool,
        fiatCurrency: String
    ) -> String {
        guard fiatMode else { return amountSats > 0 ? String(amountSats) : "" }
        guard amountSats > 0,
              let dollars = ExchangeRateCache.shared.satsToFiat(amountSats, currency: fiatCurrency)
        else { return "" }
        let cents = Int64((dollars * 100.0).rounded())
        return cents > 0 ? String(cents) : ""
    }

    /// Register-style sanitiser: digits only. Decimals are dropped because
    /// the field is interpreted as integer cents — the user types `2100`
    /// to mean `$21.00` rather than typing the decimal themselves.
    private static func sanitizeFiatInput(_ text: String) -> String {
        text.filter(\.isNumber)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    // Hero
                    VStack(spacing: 8) {
                        settings.zapImage
                            .resizable()
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                            .foregroundStyle(Color.wispZapColor)

                        Text(settings.fiatModeEnabled ? "Send Money" : "Send Zap")
                            .font(.title2.weight(.bold))

                        // Big amount display — tap to edit. Seed the field
                        // with the unit the user is typing in: cents for fiat
                        // mode, integer sats otherwise.
                        Button {
                            isCustom = true
                            if customAmountText.isEmpty {
                                customAmountText = ZapSheet.seedCustomText(
                                    amountSats: amountSats,
                                    fiatMode: settings.fiatModeEnabled,
                                    fiatCurrency: settings.fiatCurrency
                                )
                            }
                            amountFocused = true
                        } label: {
                            VStack(spacing: 2) {
                                Text(heroAmountText)
                                    .font(.system(size: 48, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.wispZapColor)
                                    .contentTransition(.numericText(value: Double(amountSats)))
                                    .animation(.easeInOut(duration: 0.15), value: amountSats)
                                if !settings.fiatModeEnabled {
                                    Text("sats")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Color.wispZapColor.opacity(0.8))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                    // Recipient
                    if let lud16 = recipientLud16 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Recipient")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(0.5)
                            VStack(alignment: .leading, spacing: 2) {
                                if let name = recipientName {
                                    Text(name).font(.subheadline.weight(.semibold))
                                }
                                Text(lud16).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Recipient has no lightning address — they cannot receive zaps.")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    // Quick amounts
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Quick Amounts")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(0.5)
                            Spacer()
                            Button("Edit") { showEditPresets = true }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.wispZapColor)
                        }

                        FlowLayout(spacing: 10) {
                            ForEach(presets, id: \.self) { sats in
                                Button {
                                    amountSats = sats
                                    customAmountText = ""
                                    isCustom = false
                                } label: {
                                    Text(CurrencyFormatter.short(sats: sats))
                                        .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(
                                        amountSats == sats && !isCustom
                                            ? Color.wispZapColor
                                            : Color.wispSurfaceVariant.opacity(0.5),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(amountSats == sats && !isCustom ? .white : .primary)
                                }
                                .buttonStyle(.plain)
                            }

                            // Custom pill
                            Button {
                                isCustom = true
                            } label: {
                                Text(isCustom && amountSats > 0
                                     ? CurrencyFormatter.short(sats: amountSats)
                                     : "Custom")
                                    .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(isCustom ? Color.wispZapColor : Color.wispSurfaceVariant.opacity(0.5), in: Capsule())
                                .foregroundStyle(isCustom ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }

                        // Custom amount input — shown when Custom is selected.
                        // Fiat mode types in the currency's major unit (dollars,
                        // euros, etc.) with up to 2 decimal places; non-fiat is
                        // plain integer sats. Sanitisation runs inside the
                        // Binding setter so the canonical value is committed
                        // BEFORE SwiftUI propagates the change — the previous
                        // re-entrant `onChange { customAmountText = clean }`
                        // pattern triggered a navigation pop on some screens
                        // (search → thread → zap) by feeding SwiftUI a state
                        // mutation mid-diff.
                        if isCustom {
                            if settings.fiatModeEnabled {
                                let fiatBinding = Binding<String>(
                                    get: {
                                        // Display the field as the formatted dollar
                                        // value so the user reads "$0.21" while
                                        // typing rather than the raw digit string.
                                        customAmountText.isEmpty
                                            ? ""
                                            : ZapSheet.formatRegisterCents(
                                                digits: customAmountText,
                                                currencyCode: settings.fiatCurrency
                                            )
                                    },
                                    set: { newValue in
                                        // Strip everything but digits — the
                                        // currency symbol, comma separator, and
                                        // decimal point in the displayed string
                                        // are presentation-only; the canonical
                                        // value is the cents digit string.
                                        let digits = ZapSheet.sanitizeFiatInput(newValue)
                                        customAmountText = digits
                                        let cents = Int64(digits) ?? 0
                                        if cents > 0 {
                                            amountSats = ExchangeRateCache.shared
                                                .fiatToSats(Double(cents) / 100.0, currency: settings.fiatCurrency) ?? 0
                                        } else {
                                            amountSats = 0
                                        }
                                    }
                                )
                                TextField("Amount", text: fiatBinding)
                                    .keyboardType(.numberPad)
                                    .font(.subheadline)
                                    .padding(12)
                                    .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                                    .focused($amountFocused)
                            } else {
                                let satsBinding = Binding<String>(
                                    get: { customAmountText },
                                    set: { newValue in
                                        let digits = newValue.filter(\.isNumber)
                                        customAmountText = digits
                                        amountSats = Int64(digits) ?? 0
                                    }
                                )
                                TextField("Amount in sats", text: satsBinding)
                                    .keyboardType(.numberPad)
                                    .font(.subheadline)
                                    .padding(12)
                                    .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                                    .focused($amountFocused)
                            }

                            if canSaveAsPreset {
                                let atMax = presets.count >= ZapSheet.maxPresets
                                HStack {
                                    Button {
                                        presetsRaw = (presets + [amountSats])
                                            .sorted()
                                            .map { String($0) }
                                            .joined(separator: ",")
                                    } label: {
                                        Label("Save as Preset", systemImage: "star")
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(atMax ? .secondary : Color.wispZapColor)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(atMax)
                                    if atMax {
                                        Text("(\(ZapSheet.maxPresets) max)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Message
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Message (optional)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)
                        TextField("Message (optional)", text: $message)
                            .font(.subheadline)
                            .padding(12)
                            .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Zap type
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Type")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)
                        Picker("Zap type", selection: $zapType) {
                            ForEach(ZapType.allCases) { type in
                                Label(type.rawValue, systemImage: type.icon).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                        if zapType != .public {
                            Text(zapType == .anonymous
                                 ? "Your identity is hidden from the lightning provider."
                                 : "Hidden identity, receipt routed to your DM inbox relays.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .safeAreaInset(edge: .bottom) {
                // Pinned send button — always visible above the keyboard / tab bar.
                // The sheet dismisses the moment the user taps Send; the in-flight
                // pulse + success burst run on the post card via ZapAnimationStore.
                Button {
                    send()
                } label: {
                    HStack(spacing: 6) {
                        settings.zapImage
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                        Text(settings.fiatModeEnabled
                             ? "Send \(CurrencyFormatter.short(sats: amountSats))"
                             : "Zap \(CurrencyFormatter.formatNumber(amountSats)) sats")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        canZap ? Color.wispZapColor : Color.wispSurfaceVariant.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!canZap)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: dismiss)
                }
            }
            .sheet(isPresented: $showEditPresets) {
                EditPresetsSheet(presetsRaw: $presetsRaw)
            }
        }
    }

    private func send() {
        guard let key = NostrKey.load() else { return }
        // Hand off to the global store so the in-flight Task survives sheet
        // dismissal. The store fires the success haptic + thunder sound, marks
        // the eventId as bursting, and routes errors back via `errors[eventId]`.
        ZapAnimationStore.shared.send(
            keypair: key,
            wallet: store,
            recipientPubkey: recipientPubkey,
            recipientLud16: recipientLud16,
            eventId: eventId,
            amountSats: amountSats,
            message: message,
            relayHints: relayHints,
            extraTags: extraTags,
            isAnonymous: zapType == .anonymous || zapType == .private,
            isPrivate: zapType == .private,
            onSuccessSats: onSuccess
        )
        dismiss()
    }
}

// MARK: - Edit presets sheet

private struct EditPresetsSheet: View {
    @Binding var presetsRaw: String
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [String] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(drafts.indices, id: \.self) { i in
                    TextField("Amount (sats)", text: $drafts[i])
                        .keyboardType(.numberPad)
                }
                .onMove { from, to in drafts.move(fromOffsets: from, toOffset: to) }
                .onDelete { drafts.remove(atOffsets: $0) }

                Button {
                    drafts.append("")
                } label: {
                    Label("Add preset", systemImage: "plus")
                }
            }
            .navigationTitle("Edit Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let valid = drafts.compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 }
                        if !valid.isEmpty {
                            presetsRaw = valid.map { String($0) }.joined(separator: ",")
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                drafts = presetsRaw.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
            }
        }
    }
}

