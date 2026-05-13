import SwiftUI

/// "N new posts" pill that surfaces buffered live events while the user is
/// scrolled away from the feed top. Tap routes to the parent's `onTap`
/// (caller flushes the buffer + scrolls to top); the trailing X dismisses
/// the pill (caller flushes silently).
struct NewPostsPill: View {
    let count: Int
    var onTap: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Tap target for "scroll to top + flush". Sized to hug its
            // content so the pill stays compact even at large counts.
            HStack(spacing: 6) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.leading, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .foregroundStyle(.white)
        .background(Color.wispPrimary, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .fixedSize()
    }

    private var label: String {
        count == 1 ? "1 new post" : "\(count) new posts"
    }
}

#Preview {
    VStack(spacing: 12) {
        NewPostsPill(count: 1, onTap: {}, onDismiss: {})
        NewPostsPill(count: 12, onTap: {}, onDismiss: {})
        NewPostsPill(count: 199, onTap: {}, onDismiss: {})
    }
    .padding()
    .background(Color.wispBackground)
}
