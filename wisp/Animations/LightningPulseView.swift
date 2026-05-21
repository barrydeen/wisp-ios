import SwiftUI

/// Pulsing zap icon shown on the action-bar zap button while a zap is in
/// flight. Renders the user's configured `zapImage` (bolt in bitcoin mode,
/// fiat-coin glyph in fiat mode) as an always-white silhouette with three
/// stacked zap-color shadows behind it. Three ingredients run off a single
/// sin-eased oscillator:
///
///   * scale breath, centered at 1.0 (0.90 → 1.10 on either side)
///   * 0.5pt vertical bounce centered on the icon's baseline
///   * shadow opacity + radius modulated by the cycle phase
///
/// White silhouette + breathing warm halo reads as a luminous core
/// brightening and dimming — sharper than tinting the icon directly,
/// which the eye reads as the bolt fading.
struct LightningPulseView: View {
    let image: Image
    /// Must be `@State` rather than `let`. SwiftUI re-instantiates the view
    /// struct on every parent re-render — and the action bar re-renders
    /// repeatedly during a zap flight (zap state changes, repost count
    /// updates, etc.). With `let`, `start` snaps to "now" on each re-init,
    /// `elapsed` jumps back to ~0, and the sine wave restarts mid-cycle —
    /// the visible read is "the pulse speed is inconsistent / stutters".
    /// `@State` is owned by SwiftUI's storage and survives view-struct
    /// rebuilds, so `elapsed` keeps climbing monotonically.
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let frame = frame(at: context.date)
            let scale = 1.0 + 0.10 * frame.sine
            let dy = -0.5 * frame.sine

            image
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                // Halo radii reduced from the original 1.5 / 4-7 / 8-14pt
                // spec — at action-bar size the original outer glow was
                // wider than the bolt itself and read as a hot amber
                // smear. Inner halo bumped back up to 2.0pt so the bolt
                // keeps a visible warm border at rest (without it, the
                // glyph reads smaller on iOS than on Android even though
                // the asset is the same size). See
                // /Users/daniel/GitHub/wisp/ZAP_BOLT_PULSE_NOTES.md for
                // the rationale.
                .shadow(color: Color.wispZapColor.opacity(0.95), radius: 2.0)
                .shadow(color: Color.wispZapColor.opacity(0.55 + 0.45 * frame.phase),
                        radius: 3 + 2 * frame.phase)
                .shadow(color: Color.wispZapColor.opacity(0.3 + 0.5 * frame.phase),
                        radius: 5 + 3 * frame.phase)
                .scaleEffect(scale)
                .offset(y: dy)
        }
    }

    // MARK: - Frame math

    private struct Frame {
        /// -1 … 1, raw sin oscillator. Drives the centered scale + bounce.
        let sine: Double
        /// 0 … 1, normalised from sine. Drives the one-way shadow growth.
        let phase: Double
    }

    private func frame(at date: Date) -> Frame {
        let elapsed = date.timeIntervalSince(start)
        let sine = sin(elapsed / 0.9 * 2 * .pi)
        let phase = (sine + 1) / 2
        return Frame(sine: sine, phase: phase)
    }
}

#Preview {
    LightningPulseView(image: Image(systemName: "bolt.fill"))
        .frame(width: 28, height: 28)
        .padding()
        .background(Color.black)
}
