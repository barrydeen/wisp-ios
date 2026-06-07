import SwiftUI

/// Horizontal strip of custom-emoji candidates shown above a text input while
/// the user types a `:shortcode`. Extracted from the note composer's inline
/// `emojiPopup` so every compose surface renders the picker identically.
struct EmojiSuggestionBar: View {
    let candidates: [CustomEmoji]
    let onPick: (CustomEmoji) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(candidates) { emoji in
                    Button {
                        onPick(emoji)
                    } label: {
                        HStack(spacing: 4) {
                            AsyncImage(url: URL(string: emoji.url)) { phase in
                                switch phase {
                                case .success(let img): img.resizable()
                                default: Color.clear
                                }
                            }
                            .frame(width: 18, height: 18)
                            Text(":\(emoji.shortcode):")
                                .font(.caption2.weight(.medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.wispSurfaceVariant.opacity(0.6),
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
    }
}
