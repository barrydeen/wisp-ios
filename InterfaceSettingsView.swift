import SwiftUI

struct InterfaceSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var showAccentPicker = false
    @State private var showCurrencyPicker = false
    @State private var rateUpdatedAt: Date? = nil
    @State private var themesExpanded = false
    @State private var emojiRepo = EmojiRepository.shared

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section(title: "Text") {
                    Toggle("Large text", isOn: $settings.largeText)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                        .padding(.vertical, 4)
                }

                section(title: "Appearance") {
                    HStack(spacing: 12) {
                        ForEach(AppSettings.ColorSchemePreference.allCases, id: \.self) { mode in
                            Button {
                                settings.colorScheme = mode
                            } label: {
                                Text(mode.rawValue.capitalized)
                                    .font(.system(size: 14, weight: .semibold))
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity)
                                    .foregroundStyle(settings.colorScheme == mode ? .white : theme.palette.onSurface)
                                    .background(settings.colorScheme == mode ? theme.primary : theme.palette.surfaceVariant)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }

                section(title: "Themes") {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { themesExpanded.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Text(currentThemeDisplayName)
                                .foregroundStyle(theme.palette.onSurface)
                            Spacer()
                            Image(systemName: themesExpanded ? "chevron.up" : "chevron.down")
                                .foregroundStyle(theme.palette.onSurfaceVariant)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if themesExpanded {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                            ForEach(Themes.all) { preset in
                                themeCard(preset)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                if settings.themeName == "custom" {
                    section(title: "Accent color") {
                        Button { showAccentPicker = true } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(argb: settings.accentColorARGB))
                                    .frame(width: 36, height: 36)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.outline, lineWidth: 1))
                                Text("Pick a color")
                                    .foregroundStyle(theme.palette.onSurface)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(theme.palette.onSurfaceVariant)
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }

                section(title: "Media") {
                    Toggle("Auto-download media", isOn: $settings.autoLoadMedia)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                    Text("When off, images and link previews show a tap-to-load placeholder.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                        .padding(.bottom, 4)
                    Toggle("Auto-play videos", isOn: $settings.videoAutoplay)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                        .disabled(!settings.autoLoadMedia)
                        .opacity(settings.autoLoadMedia ? 1.0 : 0.5)
                    Toggle("Loop videos", isOn: $settings.videoLoop)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                    Text("Replays timeline and gallery videos from the beginning when they finish.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                        .padding(.bottom, 4)
                    Toggle("Animate avatars", isOn: $settings.animateAvatars)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                    Text("Plays animated GIF / WebP profile pictures inline.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)

                    HStack {
                        Text("Multi-image layout")
                            .foregroundStyle(theme.palette.onSurface)
                        Spacer()
                        Picker("", selection: $settings.mediaLayoutStyle) {
                            Text("Gallery").tag(AppSettings.MediaLayoutStyle.grid)
                            Text("Stack").tag(AppSettings.MediaLayoutStyle.stack)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    .padding(.top, 4)
                    Text("Gallery: horizontal swipe through every photo and video. Stack: each item full-width below the next.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                }

                section(title: "Posting") {
                    Toggle("Wisp client tag", isOn: $settings.clientTagEnabled)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                    Text("Adds a [\"client\", \"Wisp\"] tag so others can see you're posting from Wisp.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                        .padding(.bottom, 4)

                    Toggle("Undo countdown", isOn: $settings.postUndoTimerEnabled)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                    Text("Holds new posts for a few seconds before publishing so you can cancel.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)

                    if settings.postUndoTimerEnabled {
                        HStack {
                            Text("Duration")
                                .foregroundStyle(theme.palette.onSurface)
                            Spacer()
                            Picker("", selection: $settings.postUndoTimerSeconds) {
                                ForEach(AppSettings.postUndoTimerOptions, id: \.self) { secs in
                                    Text("\(secs)s").tag(secs)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                        }
                        .padding(.top, 4)

                        Toggle("Include replies", isOn: $settings.postUndoTimerForReplies)
                            .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                            .padding(.top, 4)
                        Text("Off by default — replies send immediately. Turn on to apply the same countdown to replies.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.palette.onSurfaceVariant)
                    }
                }

                // Label and amount input flip with fiat mode so the user
                // always configures the value in the denomination they
                // think in. Both values persist independently — flipping
                // fiat mode preserves the user's bitcoin amount and vice
                // versa.
                section(title: settings.fiatModeEnabled ? "Payments" : "Zaps") {
                    Toggle(settings.fiatModeEnabled ? "Instant payments" : "Instant zaps",
                           isOn: $settings.quickZapEnabled)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                    Text(settings.fiatModeEnabled
                        ? "When on, long-pressing the pay button on a post immediately sends your chosen amount. Tap still opens the payment composer."
                        : "When on, long-pressing the zap button on a post immediately sends your chosen amount. Tap still opens the zap composer.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                        .padding(.bottom, 4)

                    if settings.quickZapEnabled {
                        if settings.fiatModeEnabled {
                            HStack {
                                Text("Amount (\(settings.fiatCurrency))")
                                    .foregroundStyle(theme.palette.onSurface)
                                Spacer()
                                TextField(
                                    "0.10",
                                    value: Binding(
                                        get: { settings.quickZapAmountFiat },
                                        set: { newValue in
                                            // Mirror the sats cap so a one-tap can't
                                            // exceed 10k sats equivalent. Convert
                                            // the entered fiat to sats via the cached
                                            // rate; if it's over 10k, snap the fiat
                                            // value back to the 10k-sats equivalent.
                                            let clamped = max(0.01, newValue)
                                            let cap = ExchangeRateCache.shared.satsToFiat(
                                                10_000,
                                                currency: settings.fiatCurrency
                                            ) ?? Double.greatestFiniteMagnitude
                                            settings.quickZapAmountFiat = min(clamped, cap)
                                        }
                                    ),
                                    format: .number.precision(.fractionLength(2))
                                )
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 120)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(theme.palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 8))
                            }
                        } else {
                            HStack {
                                Text("Amount (sats)")
                                    .foregroundStyle(theme.palette.onSurface)
                                Spacer()
                                TextField(
                                    "100",
                                    value: Binding(
                                        get: { settings.quickZapAmountSats },
                                        set: { settings.quickZapAmountSats = min(10_000, max(1, $0)) }
                                    ),
                                    format: .number
                                )
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 120)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(theme.palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Message (optional)")
                                .foregroundStyle(theme.palette.onSurface)
                            TextField("Add a default note…", text: $settings.quickZapMessage, axis: .vertical)
                                .textFieldStyle(.plain)
                                .lineLimit(1...3)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(theme.palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .padding(.top, 4)
                    }
                }

                section(title: "Currency") {
                    Toggle("Fiat mode", isOn: $settings.fiatModeEnabled)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                    if settings.fiatModeEnabled {
                        Button { showCurrencyPicker = true } label: {
                            HStack {
                                Text("Currency")
                                    .foregroundStyle(theme.palette.onSurface)
                                Spacer()
                                Text(settings.fiatCurrency)
                                    .foregroundStyle(theme.palette.onSurfaceVariant)
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(theme.palette.onSurfaceVariant)
                            }
                            .padding(.vertical, 8)
                        }
                        HStack {
                            if let updated = rateUpdatedAt {
                                Text("Last updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.palette.onSurfaceVariant)
                            } else {
                                Text("No exchange rate cached yet")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.palette.onSurfaceVariant)
                            }
                            Spacer()
                            Button("Refresh") {
                                Task {
                                    await ExchangeRateService.shared.refresh()
                                    await ExchangeRateCache.shared.updateFromService()
                                    rateUpdatedAt = ExchangeRateCache.shared.updatedAt
                                }
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.primary)
                        }
                    }

                    if !settings.fiatModeEnabled {
                        Divider()
                            .padding(.vertical, 4)
                        HStack {
                            Text("Zap icon")
                                .foregroundStyle(theme.palette.onSurface)
                            Spacer()
                            HStack(spacing: 12) {
                                Button {
                                    settings.zapIconStyle = .bitcoin
                                } label: {
                                    Image(systemName: "bitcoinsign")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(settings.zapIconStyle == .bitcoin
                                                         ? theme.primary
                                                         : theme.palette.onSurfaceVariant.opacity(0.7))
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    settings.zapIconStyle = .bolt
                                } label: {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(settings.zapIconStyle == .bolt
                                                         ? theme.primary
                                                         : theme.palette.onSurfaceVariant.opacity(0.7))
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                section(title: "Cross-device sync") {
                    Toggle("Sync settings via relays", isOn: $settings.syncSettingsToRelays)
                        .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                    Text("Publishes an encrypted NIP-78 backup of your \(settings.fiatModeEnabled ? "payment" : "zap") settings and quick reactions so they follow your account to other devices.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                    if settings.syncSettingsToRelays, let status = syncStatusLine {
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.palette.onSurfaceVariant)
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 40)
            }
            .padding(20)
        }
        .background(theme.palette.background.ignoresSafeArea())
        .navigationTitle("Interface")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAccentPicker) {
            NavigationStack {
                AccentColorPickerView()
                    .navigationTitle("Accent color")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showCurrencyPicker) {
            NavigationStack {
                CurrencyPickerView()
                    .navigationTitle("Currency")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            await ExchangeRateCache.shared.updateFromService()
            rateUpdatedAt = ExchangeRateCache.shared.updatedAt
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
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
        }
    }

    private var currentThemeDisplayName: String {
        Themes.all.first(where: { $0.id == settings.themeName })?.displayName ?? "Custom"
    }

    /// Passive indicator for the NIP-78 publish lifecycle. Returns nil when
    /// there's neither a pending publish nor a prior success, so the row
    /// stays clean on first launch before the user has changed anything.
    private var syncStatusLine: String? {
        if emojiRepo.isSettingsSyncPending { return "Sync pending\u{2026}" }
        guard let at = emojiRepo.lastSettingsSyncAt else { return nil }
        let seconds = Int(Date().timeIntervalSince(at))
        if seconds < 5 { return "Last synced just now" }
        if seconds < 60 { return "Last synced \(seconds)s ago" }
        if seconds < 3600 { return "Last synced \(seconds / 60)m ago" }
        if seconds < 86_400 { return "Last synced \(seconds / 3600)h ago" }
        return "Last synced \(seconds / 86_400)d ago"
    }

    @ViewBuilder
    private func themeCard(_ preset: ThemePreset) -> some View {
        let palette = theme.isDark ? preset.dark : preset.light
        let primary: Color = preset.id == "custom" ? Color(argb: settings.accentColorARGB) : palette.primary
        let isSelected = settings.themeName == preset.id
        Button {
            settings.themeName = preset.id
            withAnimation(.easeInOut(duration: 0.2)) { themesExpanded = false }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    swatch(palette.background)
                    swatch(palette.surface)
                    swatch(primary)
                    swatch(palette.zap)
                }
                Text(preset.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.palette.onSurface)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? theme.primary : theme.palette.outline,
                            lineWidth: isSelected ? 2 : 1)
            )
        }
    }

    private func swatch(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color)
            .frame(width: 22, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.palette.outline.opacity(0.3), lineWidth: 0.5))
    }
}

private struct CurrencyPickerView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(ExchangeRateService.supported) { currency in
            Button {
                settings.fiatCurrency = currency.code
                dismiss()
            } label: {
                HStack {
                    Text(currency.symbol)
                        .frame(width: 32, alignment: .leading)
                        .foregroundStyle(theme.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currency.code)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.palette.onSurface)
                        Text(currency.name)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.palette.onSurfaceVariant)
                    }
                    Spacer()
                    if settings.fiatCurrency == currency.code {
                        Image(systemName: "checkmark")
                            .foregroundStyle(theme.primary)
                    }
                }
            }
        }
    }
}
