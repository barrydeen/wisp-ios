import SwiftUI
import Observation

/// Single ephemeral toast surface for quick-follow long-press feedback.
///
/// The follow gesture fires from any avatar in the app and needs to confirm
/// what happened without yanking the user away from the screen they're on.
/// Routing through a shared `@Observable` so all render sites — feed cards,
/// DM bubbles, profile header, etc. — emit through the same overlay,
/// mounted once at `MainView` root.
@Observable
@MainActor
final class QuickFollowToast {
    static let shared = QuickFollowToast()
    private init() {}

    var message: String?

    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func show(_ text: String, duration: TimeInterval = 1.6) {
        dismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) {
            message = text
        }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                self?.message = nil
            }
        }
    }
}

/// Pill rendered above the tab bar when `QuickFollowToast.shared` has an
/// active message. Mounted as a top-level overlay on `MainView` so it sits
/// above pushed destinations and sheets.
struct QuickFollowToastOverlay: View {
    @Bindable private var store = QuickFollowToast.shared

    var body: some View {
        VStack {
            Spacer()
            if let message = store.message {
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(Color.black.opacity(0.82))
                    )
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
