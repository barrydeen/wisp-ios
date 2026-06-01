import SwiftUI

/// Bottom-anchored capsule mirroring Android's `BroadcastStatusBar`. Pure
/// render of `PostPublisher.shared.phase`; the publisher owns dismiss timers
/// so this view has no timer state of its own.
struct PostStatusPill: View {
    let phase: PostPublisher.Phase
    let onCancel: () -> Void
    let onDismissTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            leading
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if case .mining = phase {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(background, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 2)
        .contentShape(Capsule())
        .onTapGesture {
            // Failed state lets the user dismiss immediately. Other states
            // ignore the tap so a stray finger doesn't kill an in-flight post.
            if case .failed = phase { onDismissTap() }
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .mining, .broadcasting:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var label: String {
        switch phase {
        case .idle: return ""
        case .mining(let n):
            // Suppress the number until the miner reports real progress. Low-difficulty
            // PoW returns nearly instantly and the count would otherwise flash "Mining 0"
            // before transitioning straight to broadcasting — matches the rule the old
            // inline compose button used.
            return n > 0 ? "Mining \(Self.formatThousands(n))" : "Mining…"
        case .broadcasting(let a, let s):
            return "Broadcasting \(a)/\(s)"
        case .done(let n):
            return "Posted to \(n) relay\(n == 1 ? "" : "s")"
        case .failed(let message):
            return message
        }
    }

    private var background: Color {
        if case .failed = phase { return .red }
        return .wispPrimary
    }

    private static func formatThousands(_ n: Int) -> String {
        if n < 1_000 { return String(n) }
        let k = Double(n) / 1_000
        return k >= 100 ? "\(Int(k))k" : String(format: "%.1fk", k)
    }
}

/// Overlay mount for `MainView`. Sits above the tab bar via padding; uses the
/// same `pillDrop` spring as `SuccessToast` so the pill family reads as one
/// consistent motion signature.
struct PostStatusPillOverlay: View {
    @Bindable private var publisher = PostPublisher.shared

    var body: some View {
        VStack {
            Spacer()
            if publisher.phase != .idle {
                PostStatusPill(
                    phase: publisher.phase,
                    onCancel: { publisher.cancel() },
                    onDismissTap: { publisher.dismiss() }
                )
                .padding(.bottom, 64)  // clears the tab bar (~50pt + safe area inset)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .allowsHitTesting(publisher.phase != .idle)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.pillDrop, value: publisher.phase)
    }
}

#Preview("Mining") {
    ZStack {
        Color.wispBackground.ignoresSafeArea()
        PostStatusPill(
            phase: .mining(attempts: 23_500),
            onCancel: {},
            onDismissTap: {}
        )
    }
}

#Preview("Broadcasting") {
    ZStack {
        Color.wispBackground.ignoresSafeArea()
        PostStatusPill(
            phase: .broadcasting(accepted: 3, sent: 8),
            onCancel: {},
            onDismissTap: {}
        )
    }
}

#Preview("Done") {
    ZStack {
        Color.wispBackground.ignoresSafeArea()
        PostStatusPill(
            phase: .done(relayCount: 8),
            onCancel: {},
            onDismissTap: {}
        )
    }
}

#Preview("Failed") {
    ZStack {
        Color.wispBackground.ignoresSafeArea()
        PostStatusPill(
            phase: .failed(message: "No relays accepted the post."),
            onCancel: {},
            onDismissTap: {}
        )
    }
}
