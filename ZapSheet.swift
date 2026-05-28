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
    /// When true, the picker is hidden and `zapType` is locked to `.private` —
    /// caller (typically a thread row whose focal is a private rumor) is
    /// asserting that any zap here must stay in the encrypted chain. The
    /// caller is responsible for ensuring `privateZapAvailable` is true; the
    /// sheet doesn't presented if it isn't.
    var forcePrivate: Bool = false
    /// Fires after a successful zap, with the chosen sats amount.
    var onSuccess: ((Int64) -> Void)? = nil
    var dismiss: () -> Void

    @State private var amountSats: Int64 = 21
    @State private var customAmountText: String = ""
    @State private var isCustom = false
    @State private var message: String = ""
    @State private var zapType: ZapType = .public
    @State private var showEditPresets = false
    /// Local mirror of the active user's preset CSV. Loaded from the
    /// per-pubkey UserDefaults key on appear, and written back any time
    /// the EditPresetsSheet commits. Siloed per signed-in account so
    /// switching accounts swaps the preset row to that user's set.
    @State private var presetsRaw: String = ""
    /// Flips true the first time the user types a non-empty value into the
    /// amount field. Until then, an empty value from the field binding is
    /// SwiftUI's initial bind commit and is ignored so the seeded default
    /// survives. Once true, empty means "user backspaced to clear" and
    /// amountSats follows to 0 — disabling the Zap button.
    @State private var hasTypedAmount = false
    @State private var showLargeZapConfirm = false
    /// Local "copied" pill so we don't poke the shared `SuccessToast.shared`
    /// — that store also drives the MainView overlay sitting behind this
    /// sheet, and firing it produces two pills: one peeking behind the
    /// sheet's top edge, one on the sheet itself. Local pill = one pill.
    @State private var copiedToastVisible = false
    @State private var copiedToastTask: Task<Void, Never>?
    @FocusState private var amountFocused: Bool

    private static let maxPresets = 8
    private static let defaultPresetsCSV = "21,100,500,1000,5000"
    /// Per-user UserDefaults key. Each signed-in account keeps its own
    /// preset row, so switching accounts swaps the presets cleanly.
    private static func presetsKey(forPubkey pubkey: String) -> String {
        "zapPresetAmounts_\(pubkey)"
    }
    /// Legacy single-account key that pre-dated the per-pubkey split. We
    /// read it once as a migration source for the active user, then leave
    /// it in place so older builds still see something if they roll back.
    private static let legacyPresetsKey = "zapPresetAmounts"

    private var activePubkey: String? {
        NostrKey.load()?.pubkey
    }

    /// Read the active user's presets, falling back to the legacy global
    /// key (so existing users don't lose their preset row on upgrade), and
    /// finally to the default set.
    private func loadPresetsCSV() -> String {
        guard let pubkey = activePubkey else { return Self.defaultPresetsCSV }
        let defaults = UserDefaults.standard
        if let csv = defaults.string(forKey: Self.presetsKey(forPubkey: pubkey)),
           !csv.isEmpty {
            return csv
        }
        if let legacy = defaults.string(forKey: Self.legacyPresetsKey), !legacy.isEmpty {
            // One-time migration: copy the global value into this user's
            // slot so future reads stay local to the account.
            defaults.set(legacy, forKey: Self.presetsKey(forPubkey: pubkey))
            return legacy
        }
        return Self.defaultPresetsCSV
    }

    private func writePresetsCSV(_ csv: String) {
        guard let pubkey = activePubkey else { return }
        UserDefaults.standard.set(csv, forKey: Self.presetsKey(forPubkey: pubkey))
    }

    /// Preset entry. `presetsRaw` stores entries as either `"<sats>"` or
    /// `"<sats>:<message>"` separated by commas — the optional message is a
    /// default zap note (e.g. "Thanks ☕") that auto-fills the message field
    /// when this preset is tapped. Legacy integer-only entries still parse.
    private struct Preset: Hashable, Identifiable {
        let sats: Int64
        let message: String?
        var id: String { "\(sats):\(message ?? "")" }
        /// The pill label — the sats amount itself. We don't render the
        /// message text on the pill; it surfaces when the user taps the
        /// preset and fills the message field instead.
        var displayText: String {
            CurrencyFormatter.short(sats: sats)
        }
    }

    private var parsedPresets: [Preset] {
        presetsRaw.split(separator: ",").compactMap { raw -> Preset? in
            let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let satsPart = parts.first,
                  let sats = Int64(satsPart.trimmingCharacters(in: .whitespaces)) else { return nil }
            let trimmedMessage = parts.count > 1
                ? String(parts[1]).trimmingCharacters(in: .whitespaces)
                : ""
            return Preset(sats: sats, message: trimmedMessage.isEmpty ? nil : trimmedMessage)
        }
    }

    /// Legacy convenience for the save-as-preset logic — just the sats.
    private var presets: [Int64] { parsedPresets.map(\.sats) }

    private var canSaveAsPreset: Bool {
        isCustom && amountSats > 0 && !presets.contains(amountSats)
    }

    /// Above this, lightning providers reliably reject the invoice and the
    /// zap never lands. Treat as a hard cap so the user doesn't waste a
    /// publish on something that will fail downstream.
    private static let maxZapSats: Int64 = 1_000_000
    /// Threshold for the "confirm large zap" prompt. Below this, Send fires
    /// immediately; above, the user gets one tap of "Are you sure?" so a
    /// typo'd extra zero doesn't wire 100k sats by accident.
    private static let largeZapThresholdSats: Int64 = 10_000

    private var canZap: Bool {
        recipientLud16 != nil
            && store.activeWallet != nil
            && amountSats > 0
            && amountSats <= Self.maxZapSats
    }

    private var exceedsMax: Bool {
        amountSats > Self.maxZapSats
    }

    /// DIP-03 private zaps need (a) a target event id for the deterministic
    /// ephemeral derivation, (b) the user's real privkey to sign the inner
    /// kind-9733 and derive the ephemeral, and (c) at least one own kind-10050
    /// DM relay to route the receipt through. Recipient DM relays are checked
    /// inside `ZapSender.sendZap` since they require an async lookup.
    private var privateZapAvailable: Bool {
        if eventId == nil { return false }
        guard let key = NostrKey.load() else { return false }
        if Hex.decode(key.privkey) == nil { return false }   // remote signer / watch-only
        if RelaySettingsRepository.shared.dmRelays.isEmpty { return false }
        return true
    }

    /// `ZapType` cases available for this recipient. `.private` is filtered
    /// out when DIP-03 prerequisites aren't met so the user never selects an
    /// option that's guaranteed to fail at send time.
    private var availableZapTypes: [ZapType] {
        if privateZapAvailable { return ZapType.allCases }
        return ZapType.allCases.filter { $0 != .private }
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
            // ScrollView holds the scrollable form rows; the Zap button
            // lives in a sibling row pinned below the scroll view so it
            // stays in the visible area even when the keyboard is up.
            // SwiftUI's keyboard avoidance lifts the whole VStack, and
            // because bottomBar is the bottom-most child it ends up
            // sitting just above the keyboard rather than scrolling off
            // with the form content.
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16) {
                        recipientRow

                        amountHero

                        presetStrip

                        // Hidden TextField anchored to the focus state so
                        // tapping the hero (or onAppear) raises the keyboard.
                        // Fiat mode reads the register-style cents digits;
                        // non-fiat reads raw sats. The field has no visible
                        // footprint — it lives outside the visible layer at
                        // zero size.
                        hiddenAmountField
                            .frame(width: 0, height: 0)
                            .opacity(0)
                            .accessibilityHidden(true)

                        messageField

                        privacyRow

                        instantZapRow
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                }
                // `.immediately` not `.interactively`. With
                // `.interactively`, the keyboard moves with the scroll
                // position — but the keyboard rising in response to
                // `amountFocused = true` on appear nudges the scroll
                // position too, which the interactive mode reads as a
                // partial-dismiss gesture, and a moment later
                // `@FocusState` re-raises the keyboard. That fight
                // produces a perceived "infinite loop" — the keyboard
                // pumping in and out repeatedly with the sheet still
                // mounted. `.immediately` only dismisses on an explicit
                // scroll gesture, which is what we actually want — the
                // drag-down sheet dismiss is a sheet gesture, not a
                // scroll one, and still works.
                .scrollDismissesKeyboard(.immediately)
                .scrollBounceBehavior(.basedOnSize)

                bottomBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .background(Color(.systemBackground))
            }
            // Local copied-pill overlay. Uses a sheet-local @State rather
            // than `SuccessToast.shared` so it doesn't also fire on the
            // MainView overlay behind this sheet (which would render a
            // second pill peeking behind the sheet's top edge).
            .overlay(alignment: .top) { copiedPill }
            // Persist any preset edit (from EditPresetsSheet or the inline
            // save-as-preset chip) to the active user's slot so the change
            // survives sheet dismissal and account switches read clean.
            .onChange(of: presetsRaw) { _, new in
                writePresetsCSV(new)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: dismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Presets") {
                        // Drop focus + defer presentation so the amount-field
                        // keyboard collapses before the Presets sheet mounts.
                        // The two-sheet stack flips closed when a keyboard
                        // dismiss races a sheet present (same shape as the
                        // drafts/GIF picker race).
                        amountFocused = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            showEditPresets = true
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.wispZapColor)
                }
            }
            .sheet(isPresented: $showEditPresets) {
                EditPresetsSheet(presetsRaw: $presetsRaw)
            }
            .confirmationDialog(
                settings.fiatModeEnabled
                    ? "Send \(CurrencyFormatter.short(sats: amountSats))?"
                    : "Zap \(CurrencyFormatter.formatNumber(amountSats)) sats?",
                isPresented: $showLargeZapConfirm,
                titleVisibility: .visible
            ) {
                Button(
                    settings.fiatModeEnabled
                        ? "Send \(CurrencyFormatter.short(sats: amountSats))"
                        : "Zap \(CurrencyFormatter.formatNumber(amountSats)) sats"
                ) {
                    performSend()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This is a large amount — double-check before sending.")
            }
            .onAppear {
                // Pull presets for the active account. Per-pubkey storage
                // keeps each signed-in user's preset row siloed; the
                // migration in `loadPresetsCSV` carries forward any global
                // value from prior builds.
                presetsRaw = loadPresetsCSV()
                // Seed the hero from the configured one-tap default amount
                // (treated as the user's preferred zap default even when
                // instant zaps are disabled — they still represent
                // "what should the sheet open to"). The hidden field
                // starts empty, so heroAmountText falls through to the
                // formatted `amountSats` value and the keyboard is up;
                // the first keystroke replaces the seed because
                // customAmountText is "" at that point.
                if settings.fiatModeEnabled {
                    if let sats = ExchangeRateCache.shared
                        .fiatToSats(settings.quickZapAmountFiat, currency: settings.fiatCurrency),
                       sats > 0 {
                        amountSats = sats
                    }
                } else if settings.quickZapAmountSats > 0 {
                    amountSats = settings.quickZapAmountSats
                }
                isCustom = true
                customAmountText = ""
                // Defer focus by one tick so the sheet finishes its
                // mount + transition before the keyboard raises. Without
                // the hop the keyboard rising during the mount changes
                // the parent LazyVStack row's layout (PostCardView lives
                // in a lazy feed), the row recycles, the `.sheet` binding
                // tied to it unmounts, the sheet dismisses, and SwiftUI
                // immediately re-presents — looping until the user
                // manages to interact.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    amountFocused = true
                }
            }
        }
    }

    // MARK: - Copied pill

    @ViewBuilder
    private var copiedPill: some View {
        if copiedToastVisible {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Lightning address copied")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.wispZapColor, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func showCopiedPill() {
        copiedToastTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            copiedToastVisible = true
        }
        copiedToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                copiedToastVisible = false
            }
        }
    }

    // MARK: - Recipient row

    private var recipientRow: some View {
        HStack(spacing: 10) {
            CachedAvatarView(url: ProfileRepository.shared.get(recipientPubkey)?.picture, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(recipientName ?? Nip19.shortNpub(hex: recipientPubkey))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let lud16 = recipientLud16 {
                    Text(lud16)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("No lightning address")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 0)
            if let lud16 = recipientLud16 {
                Button {
                    UIPasteboard.general.string = lud16
                    showCopiedPill()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy Lightning Address")
            }
        }
    }

    // MARK: - Amount hero

    private var amountHero: some View {
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
            VStack(spacing: 0) {
                Text(heroAmountText.isEmpty ? "0" : heroAmountText)
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.wispZapColor)
                    .contentTransition(.numericText(value: Double(amountSats)))
                    .animation(.easeInOut(duration: 0.15), value: amountSats)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if !settings.fiatModeEnabled {
                    Text("sats")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.wispZapColor.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Preset strip

    private var presetStrip: some View {
        // Wrap rather than scroll so the user can see every preset at once.
        // `FlowLayout` lays out pills left-to-right and breaks to a new line
        // when the row is full.
        FlowLayout(spacing: 8) {
            ForEach(parsedPresets, id: \.id) { preset in
                presetPill(label: preset.displayText,
                           selected: amountSats == preset.sats && !isCustom) {
                    amountSats = preset.sats
                    customAmountText = ""
                    hasTypedAmount = false
                    // Apply the preset's message verbatim — tapping a preset
                    // means "use this saved combination of amount + note", so
                    // the message field should reflect this preset's note
                    // rather than whatever happens to be in it (a previous
                    // preset's note, or a default seeded elsewhere). Presets
                    // without a configured message leave the field as-is so a
                    // user mid-type into a message isn't punished for picking
                    // an amount-only preset.
                    if let presetMessage = preset.message {
                        message = presetMessage
                    }
                    withAnimation(.easeInOut(duration: 0.15)) { isCustom = false }
                    amountFocused = false
                }
            }
            customPill
        }
    }

    @ViewBuilder
    private func presetPill(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? Color.wispZapColor : Color.wispSurfaceVariant.opacity(0.5), in: Capsule())
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var customPill: some View {
        let label = isCustom && amountSats > 0
            ? CurrencyFormatter.short(sats: amountSats)
            : "Custom"
        HStack(spacing: 4) {
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
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .padding(.leading, 14)
                    .padding(.trailing, canSaveAsPreset ? 6 : 14)
                    .padding(.vertical, 8)
                    .foregroundStyle(isCustom ? .white : .primary)
            }
            .buttonStyle(.plain)

            if canSaveAsPreset {
                let atMax = presets.count >= ZapSheet.maxPresets
                Button {
                    guard !atMax else { return }
                    let next = (presets + [amountSats])
                        .sorted()
                        .map { String($0) }
                        .joined(separator: ",")
                    presetsRaw = next
                    writePresetsCSV(next)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(atMax ? Color.white.opacity(0.4) : Color.white)
                        .padding(.trailing, 8)
                }
                .buttonStyle(.plain)
                .disabled(atMax)
            }
        }
        .background(isCustom ? Color.wispZapColor : Color.wispSurfaceVariant.opacity(0.5), in: Capsule())
    }

    // MARK: - Hidden amount field

    @ViewBuilder
    private var hiddenAmountField: some View {
        if settings.fiatModeEnabled {
            let fiatBinding = Binding<String>(
                get: { customAmountText },
                set: { newValue in
                    let digits = ZapSheet.sanitizeFiatInput(newValue)
                    customAmountText = digits
                    if let cents = Int64(digits), cents > 0 {
                        amountSats = ExchangeRateCache.shared
                            .fiatToSats(Double(cents) / 100.0, currency: settings.fiatCurrency) ?? amountSats
                        hasTypedAmount = true
                    } else if hasTypedAmount {
                        // User backspaced the field after typing — collapse
                        // to zero so the Zap button disables and the hero
                        // reads "0", matching what's on screen.
                        amountSats = 0
                    }
                    // Pre-typing empty values are SwiftUI's initial bind
                    // commit on focus; leave amountSats at its seed.
                }
            )
            TextField("Amount", text: fiatBinding)
                .keyboardType(.numberPad)
                .focused($amountFocused)
        } else {
            let satsBinding = Binding<String>(
                get: { customAmountText },
                set: { newValue in
                    let digits = newValue.filter(\.isNumber)
                    customAmountText = digits
                    if let n = Int64(digits), n > 0 {
                        amountSats = n
                        hasTypedAmount = true
                    } else if hasTypedAmount {
                        amountSats = 0
                    }
                }
            )
            TextField("Amount in sats", text: satsBinding)
                .keyboardType(.numberPad)
                .focused($amountFocused)
        }
    }

    // MARK: - Message field

    private var messageField: some View {
        TextField("Message (optional)", text: $message)
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .submitLabel(.done)
    }

    // MARK: - Privacy row (between message and send)

    private var privacyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: forcePrivate ? ZapType.private.icon : zapType.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            if forcePrivate {
                HStack(spacing: 4) {
                    Text(ZapType.private.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.wispPrimary)
                }
            } else {
                Menu {
                    ForEach(ZapType.allCases) { type in
                        Button {
                            zapType = type
                        } label: {
                            Label(type.rawValue, systemImage: type.icon)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(zapType.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if forcePrivate {
                Text("Replying to a private thread — encrypted via DIP-03")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if zapType != .public {
                Text(zapType == .anonymous
                     ? "Identity hidden from the lightning provider"
                     : "Hidden identity, receipt to your DM inbox")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Instant zap toggle

    @ViewBuilder
    private var instantZapRow: some View {
        @Bindable var settingsBindable = settings
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(settings.fiatModeEnabled ? "Instant payments" : "Instant zaps")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Toggle("", isOn: $settingsBindable.quickZapEnabled)
                .labelsHidden()
                .tint(Color.wispZapColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Bottom bar (full-width Zap button)

    private var bottomBar: some View {
        VStack(spacing: 6) {
            if exceedsMax {
                Text("Max \(CurrencyFormatter.formatNumber(Self.maxZapSats)) sats per zap")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
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
                .frame(height: 54)
                .background(
                    canZap ? Color.wispZapColor : Color.wispSurfaceVariant.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!canZap)
        }
        .padding(.vertical, 10)
    }

    private func send() {
        if amountSats > Self.largeZapThresholdSats {
            showLargeZapConfirm = true
            return
        }
        performSend()
    }

    private func performSend() {
        guard let key = NostrKey.load() else { return }
        // Force-private overrides whatever zapType the user might have left
        // in state — the caller asserts the encrypted chain invariant.
        let effectiveType: ZapType = forcePrivate ? .private : zapType
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
            isAnonymous: effectiveType == .anonymous || effectiveType == .private,
            isPrivate: effectiveType == .private,
            onSuccessSats: onSuccess
        )
        dismiss()
    }
}

// MARK: - Edit presets sheet

private struct EditPresetsSheet: View {
    @Binding var presetsRaw: String
    @Environment(\.dismiss) private var dismiss

    /// Editable preset draft. `message` is optional — empty means no default
    /// message is associated with this preset. Each draft has its own
    /// identity so SwiftUI can keep TextField cursors stable across
    /// swipe-to-deletes of other rows.
    private struct Draft: Identifiable {
        let id = UUID()
        var amount: String
        var message: String
    }

    @State private var drafts: [Draft] = []

    /// One blank preset at a time so the Add button can't pile up empty
    /// rows. A blank is any draft with no digits in the amount field.
    private var hasBlankDraft: Bool {
        drafts.contains { $0.amount.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                // Swipe-left-to-delete a row. We deliberately do NOT expose
                // an `EditButton()` here — the red minus circles iOS shows
                // in edit mode sit right under the amount TextField and
                // were too easy to tap accidentally while editing. Standard
                // iOS swipe (reveal Delete on the trailing edge → tap to
                // confirm) is the right destructive UX for this list.
                ForEach($drafts) { $draft in
                    HStack(spacing: 8) {
                        TextField("Amount (sats)", text: $draft.amount)
                            .keyboardType(.numberPad)
                            .frame(maxWidth: 120)
                        Divider()
                        TextField("Message (optional)", text: $draft.message)
                    }
                }
                .onDelete { drafts.remove(atOffsets: $0) }

                Button {
                    drafts.append(Draft(amount: "", message: ""))
                } label: {
                    Label("Add preset", systemImage: "plus")
                        .foregroundStyle(hasBlankDraft ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.wispZapColor))
                }
                .disabled(hasBlankDraft)
            }
            .navigationTitle("Edit Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let encoded: [String] = drafts.compactMap { d in
                            guard let sats = Int64(d.amount.trimmingCharacters(in: .whitespaces)),
                                  sats > 0 else { return nil }
                            let trimmedMessage = d.message.trimmingCharacters(in: .whitespaces)
                            // Strip commas / colons — they're the delimiters in
                            // the CSV format and would corrupt the parser.
                            let safeMessage = trimmedMessage
                                .replacingOccurrences(of: ",", with: " ")
                                .replacingOccurrences(of: ":", with: " ")
                            return safeMessage.isEmpty ? "\(sats)" : "\(sats):\(safeMessage)"
                        }
                        if !encoded.isEmpty {
                            presetsRaw = encoded.joined(separator: ",")
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                drafts = presetsRaw.split(separator: ",").map { raw in
                    let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    let amount = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                    let message = parts.count > 1
                        ? String(parts[1]).trimmingCharacters(in: .whitespaces)
                        : ""
                    return Draft(amount: amount, message: message)
                }
            }
        }
        // Wisp's zap accent — overrides the system blue applied by default
        // to toolbar Edit / Done buttons and the inline Add-preset button.
        .tint(Color.wispZapColor)
    }
}

