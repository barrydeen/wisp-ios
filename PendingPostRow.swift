import SwiftUI

/// Dimmed feed row shown while `PostPublisher` is mining / broadcasting the
/// user's own post. Wraps `PostCardView` so the placeholder occupies the
/// exact same size, padding, and layout the real card will land in — the
/// row appears to "fill in" rather than reflow when the published event
/// replaces it.
///
/// Visual states (keyed off `PendingPostStore.State`):
///
/// - `.mining` / `.publishing` — 50% opacity, status pill overlaid in the
///   top-right corner ("Mining…" / "Publishing…")
/// - `.failed` — full opacity, red error pill, Dismiss button. The autosaved
///   draft is still on disk so the user can re-open the composer to retry.
///
/// All taps inside the underlying card are blocked while the row is in any
/// pending state — interactions on a placeholder would hit a non-existent
/// event id.
struct PendingPostRow: View {
    let pending: PendingPostStore.PendingPost

    @State private var profile: ProfileData?

    private var isFailed: Bool {
        if case .failed = pending.state { return true }
        return false
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PostCardView(
                event: pending.event,
                profile: profile,
                profiles: profile.map { [pending.event.pubkey: $0] } ?? [:],
                engagement: nil
            )
            // Suppress every tap target the real card exposes (action bar,
            // avatar, inline links, navigation) — the optimistic event id
            // doesn't resolve to anything yet.
            .allowsHitTesting(false)
            .opacity(isFailed ? 1.0 : 0.5)
            .animation(.easeInOut(duration: 0.2), value: isFailed)

            statusOverlay
                .padding(.top, 14)
                .padding(.trailing, 18)
        }
        .task(id: pending.event.pubkey) {
            profile = ProfileRepository.shared.get(pending.event.pubkey)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch pending.state {
        case .mining:
            statusPill(text: "Mining…", color: Color.wispPrimary, showSpinner: true)
        case .publishing:
            statusPill(text: "Publishing…", color: Color.wispPrimary, showSpinner: true)
        case .failed(let message):
            HStack(spacing: 6) {
                statusPill(text: message, color: .red, showSpinner: false)
                Button {
                    PendingPostStore.shared.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss failed post")
            }
        }
    }

    private func statusPill(text: String, color: Color, showSpinner: Bool) -> some View {
        HStack(spacing: 5) {
            if showSpinner {
                ProgressView()
                    .controlSize(.mini)
                    .tint(color)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(color)
            }
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.wispSurfaceVariant.opacity(0.95), in: Capsule())
        .overlay(
            Capsule().stroke(color.opacity(0.4), lineWidth: 0.5)
        )
    }
}
