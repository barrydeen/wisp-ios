import SwiftUI

/// Compact reaction picker shown as a popover when the user taps the heart on a
/// post card.
///
/// Renders the user's frequency-sorted **quick-reactions** list as a 6-column
/// grid of size-32 cells, followed by a trailing "+" tile that opens the full
/// `EmojiLibrarySheet`. Long-press a cell to remove that emoji from the quick
/// list. Tapping a cell invokes `onSelect(_:)`; the `+` tile fires `onPlus()`.
/// The parent owns dismissal in both cases.
struct EmojiReactionPicker: View {
    @State private var emojiRepo = EmojiRepository.shared
    @ObservedObject private var emojiCache = EmojiImageCache.shared

    let onSelect: (PickedEmoji) -> Void
    let onPlus: () -> Void

    private let cellSize: CGFloat = 36
    private let columns: Int = 6

    var body: some View {
        let entries = emojiRepo.sortedQuickReactions
        let grid = Array(repeating: GridItem(.fixed(cellSize), spacing: 8), count: columns)
        VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: grid, spacing: 8) {
                ForEach(entries, id: \.self) { key in
                    cell(for: key)
                }
                plusCell
            }
            .padding(12)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .frame(width: CGFloat(columns) * cellSize + CGFloat(columns - 1) * 8 + 24)
        .onAppear {
            for key in entries {
                if key.hasPrefix(":") && key.hasSuffix(":") {
                    let sc = String(key.dropFirst().dropLast())
                    if let url = emojiRepo.resolvedCustomMap[sc] {
                        emojiCache.ensureLoaded(url)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(for key: String) -> some View {
        Button {
            if let picked = pickedEmoji(for: key) {
                onSelect(picked)
            }
        } label: {
            ZStack {
                if key.hasPrefix(":") && key.hasSuffix(":") {
                    customCell(shortcode: String(key.dropFirst().dropLast()))
                } else {
                    Text(key)
                        .font(.system(size: 26))
                }
            }
            .frame(width: cellSize, height: cellSize)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                emojiRepo.removeFromQuickList(key)
            } label: {
                Label("Remove from quick reactions", systemImage: "minus.circle")
            }
        }
    }

    @ViewBuilder
    private func customCell(shortcode: String) -> some View {
        if let url = emojiRepo.resolvedCustomMap[shortcode],
           let img = emojiCache.image(for: url) {
            Image(uiImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: cellSize - 4, height: cellSize - 4)
        } else if let url = emojiRepo.resolvedCustomMap[shortcode] {
            Color.clear
                .frame(width: cellSize - 4, height: cellSize - 4)
                .onAppear { emojiCache.ensureLoaded(url) }
        } else {
            Text(":\(shortcode):")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var plusCell: some View {
        Button {
            onPlus()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.06))
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: cellSize, height: cellSize)
        }
        .buttonStyle(.plain)
    }

    private func pickedEmoji(for key: String) -> PickedEmoji? {
        if key.hasPrefix(":") && key.hasSuffix(":") {
            let sc = String(key.dropFirst().dropLast())
            guard let url = emojiRepo.resolvedCustomMap[sc] else { return nil }
            return .custom(shortcode: sc, url: url)
        }
        return .unicode(key)
    }
}
