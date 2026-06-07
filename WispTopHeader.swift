import SwiftUI

/// Unified top-header treatment for full-screen views that hide the system
/// navigation bar and supply their own back-button + title row. Attached via
/// `.safeAreaInset(edge: .top)` so the screen's scroll content slides *under*
/// the header with a translucent `wispBackground.opacity(0.92)` seam — the
/// same pattern `ProfileView` uses for its banner header. Without this, each
/// screen rendered its custom header as a sibling above the ScrollView, which
/// produced an opaque hard-edged bar.
extension View {
    /// Attach `content` as a translucent top safe-area inset with the standard
    /// divider below it. The inset background extends through the status-bar
    /// region so the bar reads as one continuous piece of glass, not bare
    /// scroll content peeking out behind the header.
    func wispTopHeader<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let header = content()
        return self.safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))
            }
            .background(
                Color.wispBackground.opacity(0.92)
                    .ignoresSafeArea(edges: .top)
            )
        }
    }
}
