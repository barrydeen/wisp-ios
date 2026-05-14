import SwiftUI

struct ProofOfWorkSettingsView: View {
    @Environment(PowPreferences.self) private var prefs
    @Environment(\.theme) private var theme

    private var isWatchOnly: Bool {
        guard let kp = NostrKey.load() else { return false }
        return kp.isWatchOnly
    }

    var body: some View {
        @Bindable var prefs = prefs
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if isWatchOnly {
                    watchOnlyBanner
                }
                Group {
                    Text("Proof of Work mines a hash prefix on your events, acting as a spam deterrent. Higher difficulty takes longer but signals more effort.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                        .padding(.horizontal, 4)

                    section(title: "Notes") {
                        toggleRow(
                            title: "Enable PoW for notes",
                            subtitle: "Mine proof of work before publishing notes",
                            isOn: $prefs.notePowEnabled
                        )
                        difficultyRow(
                            bits: $prefs.noteDifficulty,
                            enabled: prefs.notePowEnabled
                        )
                    }

                    section(title: "Reactions") {
                        toggleRow(
                            title: "Enable PoW for reactions",
                            subtitle: "Mine proof of work on reactions (sub-second at low difficulty)",
                            isOn: $prefs.reactionPowEnabled
                        )
                        difficultyRow(
                            bits: $prefs.reactionDifficulty,
                            enabled: prefs.reactionPowEnabled
                        )
                    }

                    section(title: "DMs") {
                        toggleRow(
                            title: "Enable PoW for DMs",
                            subtitle: "Mine proof of work on gift wraps before sending DMs",
                            isOn: $prefs.dmPowEnabled
                        )
                        difficultyRow(
                            bits: $prefs.dmDifficulty,
                            enabled: prefs.dmPowEnabled
                        )
                    }
                }
                .disabled(isWatchOnly)
                .opacity(isWatchOnly ? 0.4 : 1)

                Spacer(minLength: 40)
            }
            .padding(20)
        }
        .background(theme.palette.background.ignoresSafeArea())
        .navigationTitle("Proof of Work")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.onSurfaceVariant)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
                .toggleStyle(SwitchToggleStyle(tint: theme.primary))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.onSurfaceVariant)
        }
    }

    @ViewBuilder
    private func difficultyRow(bits: Binding<Int>, enabled: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                let next = max(PowPreferences.minDifficulty, bits.wrappedValue - 1)
                bits.wrappedValue = next
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(enabled ? theme.palette.onSurface : theme.palette.onSurfaceVariant)
                    .background(theme.palette.surfaceVariant)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled || bits.wrappedValue <= PowPreferences.minDifficulty)

            Spacer()

            Text("\(bits.wrappedValue) bits")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(enabled ? theme.palette.onSurface : theme.palette.onSurfaceVariant)

            Spacer()

            Button {
                let next = min(PowPreferences.maxDifficulty, bits.wrappedValue + 1)
                bits.wrappedValue = next
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(enabled ? theme.palette.onSurface : theme.palette.onSurfaceVariant)
                    .background(theme.palette.surfaceVariant)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled || bits.wrappedValue >= PowPreferences.maxDifficulty)
        }
        .opacity(enabled ? 1.0 : 0.5)
    }

    private var watchOnlyBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "eye")
                .foregroundStyle(Color.wispPrimary)
                .font(.subheadline)
                .padding(.top, 2)
            Text("Watch-only mode")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
