import SwiftUI

struct RecoveryPhraseView: View {
    @Bindable var store: WalletStore
    @Environment(\.dismiss) private var dismiss

    @State private var revealed = false
    @State private var copied = false

    private var words: [String] {
        store.sparkMnemonic?.split(separator: " ").map(String.init) ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))
            ScrollView {
                VStack(spacing: 24) {
                    warningCard
                    phraseSection
                    if revealed {
                        actionButtons
                    }
                    if !store.seedBackupAcknowledged {
                        acknowledgeButton
                    }
                }
                .padding(20)
            }
        }
        .background(Color.wispBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        ZStack {
            Text("Recovery Phrase")
                .font(.subheadline.weight(.semibold))
            HStack {
                BackChevronButton { dismiss() }
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Warning card

    private var warningCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.wispZapColor)
                .font(.system(size: 16))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep this phrase secret")
                    .font(.subheadline.weight(.semibold))
                Text("Anyone with these words can access your wallet. Never share it or enter it anywhere other than a wallet restore screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispZapColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Phrase section

    private var phraseSection: some View {
        ZStack {
            wordGrid
                .blur(radius: revealed ? 0 : 10)
                .animation(.easeInOut(duration: 0.2), value: revealed)

            if !revealed {
                revealButton
            }
        }
        .padding(16)
        .background(Color.wispSurfaceVariant.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
    }

    private var wordGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, alignment: .trailing)
                    Text(word)
                        .font(.system(.subheadline, design: .monospaced).weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var revealButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { revealed = true }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.wispZapColor)
                Text("Tap to reveal")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Action buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                UIPasteboard.general.string = store.sparkMnemonic
                withAnimation { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { copied = false }
                }
            } label: {
                Label(copied ? "Copied ✓" : "Copy to clipboard",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.wispSurfaceVariant.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.15), value: copied)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { revealed = false }
            } label: {
                Label("Hide", systemImage: "eye.slash")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.wispSurfaceVariant.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Acknowledge button

    private var acknowledgeButton: some View {
        Button {
            store.acknowledgeSeedBackup()
            dismiss()
        } label: {
            Text("I've backed this up")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.wispZapColor, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!revealed)
        .opacity(revealed ? 1 : 0.4)
    }
}
