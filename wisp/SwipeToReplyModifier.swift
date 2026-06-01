import SwiftUI

/// Right-swipe-to-reply gesture for chat bubbles. Mirrors Android's ~72pt threshold,
/// spring snap-back, and reply-icon reveal that fades in with drag progress. Uses a
/// `simultaneousGesture` + horizontal-dominance guard so vertical scrolling still works.
struct SwipeToReplyModifier: ViewModifier {
    let onReply: () -> Void

    @State private var offset: CGFloat = 0
    @State private var triggered = false

    private let threshold: CGFloat = 72
    private var maxOffset: CGFloat { threshold * 1.3 }

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .overlay(alignment: .leading) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.wispPrimary)
                    .opacity(Double(min(max(offset, 0) / threshold, 1)))
                    .scaleEffect(min(max(offset, 0) / threshold, 1))
                    .padding(.leading, 8)
                    .allowsHitTesting(false)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        // Only a horizontal-dominant rightward drag moves the bubble; a
                        // vertical drag is left entirely to the ScrollView.
                        guard value.translation.width > 0,
                              abs(value.translation.width) > abs(value.translation.height) else { return }
                        offset = min(value.translation.width, maxOffset)
                        if offset >= threshold, !triggered {
                            triggered = true
                            Haptics.shared.pulse()
                            onReply()
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { offset = 0 }
                        triggered = false
                    }
            )
    }
}

extension View {
    /// Attach a right-swipe-to-reply gesture (fires `onReply` once past the threshold).
    func swipeToReply(_ onReply: @escaping () -> Void) -> some View {
        modifier(SwipeToReplyModifier(onReply: onReply))
    }
}
