import SwiftUI

/// Pulsing lightning bolt shown on the action-bar zap button while a zap is
/// in flight. Three layers (outer glow, fill, white-hot core) modulate alpha
/// 0.5→1.0 and scale 0.92→1.08 on a 600 ms cycle.
///
/// Mirrors Android `ActionBar.kt`'s `LightningAnimation` — same path
/// (`icBoltPath` viewBox 55×94), same cycle, same three-layer stack.
struct LightningPulseView: View {
    /// Continuous time anchor so the sin-curve phase doesn't reset each time
    /// SwiftUI rebuilds the view.
    private let start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let phase = currentPhase(at: context.date)
            let alpha = 0.5 + 0.5 * phase
            let scale = 0.92 + 0.16 * phase
            BoltCanvas(alpha: alpha, scale: scale)
        }
    }

    /// 600 ms cycle, sin-eased so it accelerates into both extrema —
    /// close enough to Android's reverse-repeating FastOutSlowInEasing tween
    /// that it reads as the same animation.
    private func currentPhase(at date: Date) -> CGFloat {
        let elapsed = date.timeIntervalSince(start)
        let twoPi = 2 * Double.pi
        let raw = sin(elapsed / 0.6 * twoPi - .pi / 2)
        return CGFloat((raw + 1) / 2)
    }
}

private struct BoltCanvas: View {
    let alpha: CGFloat
    let scale: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let path = boltPath(in: size, scale: scale)
            let zap = Color.wispZapColor

            // 1. Soft outer glow — wide round-capped stroke. Stroke width
            //    scales with view size to keep the glow proportional on every
            //    frame (matches `w * 0.14` on Android).
            ctx.stroke(
                path,
                with: .color(zap.opacity(alpha * 0.3)),
                style: StrokeStyle(
                    lineWidth: size.width * 0.14,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            // 2. Solid bolt fill.
            ctx.fill(path, with: .color(zap))
            // 3. White-hot core — semi-transparent white over the fill.
            ctx.fill(path, with: .color(.white.opacity(alpha * 0.4)))
        }
    }

    private func boltPath(in size: CGSize, scale: CGFloat) -> Path {
        let sx = size.width / 55 * scale
        let sy = size.height / 94 * scale
        let ox = size.width * (1 - scale) / 2
        let oy = size.height * (1 - scale) / 2

        var p = Path()
        p.move(to: CGPoint(x: ox + 35.563 * sx, y: oy))
        p.addLine(to: CGPoint(x: ox + 35.563 * sx, y: oy + 40.406 * sy))
        p.addLine(to: CGPoint(x: ox + 54.969 * sx, y: oy + 40.406 * sy))
        p.addLine(to: CGPoint(x: ox + 21.016 * sx, y: oy + 93.75 * sy))
        p.addLine(to: CGPoint(x: ox + 21.016 * sx, y: oy + 51.719 * sy))
        p.addLine(to: CGPoint(x: ox, y: oy + 51.719 * sy))
        p.closeSubpath()
        return p
    }
}

#Preview {
    LightningPulseView()
        .frame(width: 60, height: 60)
        .padding()
        .background(Color.black)
}
