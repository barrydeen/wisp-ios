import SwiftUI
import Observation

extension Animation {
    /// Shared motion signature for the success toasts. A soft spring with
    /// gentle overshoot so the pill family reads as one consistent gesture
    /// rather than a hard snap.
    static let pillDrop = Animation.spring(response: 0.38, dampingFraction: 0.68)

    /// Same bounce character as `pillDrop` (identical damping → identical
    /// overshoot) but a shorter response, so the new-posts pill — a "tap me
    /// now" affordance — snaps in quicker while staying visually in-family.
    static let pillDropFast = Animation.spring(response: 0.30, dampingFraction: 0.68)
}

/// Single ephemeral "success" pill that drops in from the top.
///
/// One `@Observable` surface, one overlay mounted at `MainView` root, so any
/// feature — publish, draft autosave, repost, DM send, zap — confirms its
/// action through the same pill without threading a callback up to the tab
/// root. "Latest wins": a new `show` immediately replaces whatever pill is
/// on screen rather than queuing behind it.
@MainActor
@Observable
final class SuccessToast {
    static let shared = SuccessToast()
    private init() {}

    struct Content: Equatable {
        var message: String
        var icon: String
        var accent: Color
    }

    private(set) var content: Content?

    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var tapAction: (() -> Void)?

    /// Show a success pill. When `action` is non-nil the pill becomes
    /// tappable (e.g. "Draft saved" → reopen the draft); the action also
    /// dismisses the pill. Replaces any pill already on screen.
    func show(
        _ message: String,
        icon: String = "checkmark.circle.fill",
        accent: Color = .wispPrimary,
        duration: TimeInterval = 2.4,
        action: (() -> Void)? = nil
    ) {
        dismissTask?.cancel()
        tapAction = action
        withAnimation(.pillDrop) {
            content = Content(message: message, icon: icon, accent: accent)
        }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func handleTap() {
        let action = tapAction
        dismiss()
        action?()
    }

    func dismiss() {
        dismissTask?.cancel()
        tapAction = nil
        // Clean fade-up on exit — the bounce belongs to the entrance; a
        // springy retreat reads as the pill being yanked away.
        withAnimation(.easeOut(duration: 0.2)) {
            content = nil
        }
    }
}

/// Pill rendered at the top of the screen while `SuccessToast.shared` has
/// content. Mounted as a top-level overlay on `MainView` so it sits above
/// pushed destinations and sheets. Hit testing is enabled only while a pill
/// is visible so an empty toast surface never swallows touches.
struct SuccessToastOverlay: View {
    @Bindable private var store = SuccessToast.shared

    var body: some View {
        VStack {
            if let content = store.content {
                Button {
                    store.handleTap()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: content.icon)
                            .font(.system(size: 12, weight: .semibold))
                        Text(content.message)
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(content.accent, in: Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 2)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .allowsHitTesting(store.content != nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

#Preview {
    ZStack {
        Color.wispBackground.ignoresSafeArea()
        SuccessToastOverlay()
            .task {
                SuccessToast.shared.show("Posted")
            }
    }
}
