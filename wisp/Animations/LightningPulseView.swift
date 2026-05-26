import SwiftUI

/// Pulsing zap icon shown on the action-bar zap button while a zap is in
/// flight. Draws the lightning bolt as a true vector `Shape` and uses
/// `.stroke(lineWidth:)` for the outer halo + `.fill` for the body, so
/// the outline is crisp at every size and free of the aliasing that an
/// image-offset stack produces.
///
/// Mirrors Wisp Android's `LightningAnimation`: same bolt geometry, same
/// `stroke` width / fill / white-hot core composition, same pulse +
/// breath envelope.
///
/// The bolt `Shape` is used regardless of the user's chosen zap-icon
/// style (`bolt.fill` vs `bitcoinsign`) — the in-flight pulse is always
/// the bolt as the universal "zap is happening" iconography. The static
/// post-card icon outside the in-flight state still respects the
/// user's symbol preference via `AppSettings.zapImage`.
///
/// Three ingredients ride a single sin-eased oscillator:
///
///   * scale breath (0.92 → 1.08, matches Android's `LightningAnimation`)
///   * stroke + white-core opacity (Android-equivalent ramps)
///   * 0.5pt vertical bounce centered on the icon's baseline (iOS flourish)
///
/// See LIGHT_MODE_COLOR_PARITY.md (Wisp Android repo) for the
/// cross-platform contract on which color this animation consumes.
struct LightningPulseView: View {
    /// Defaulted for source-compat with both call patterns: the post
    /// action bar's `LightningPulseView()` bare call (on main) and the
    /// `LightningPulseView(image: settings.zapImage)` form introduced
    /// on `feat/one-tap-zap`. The animation always renders the bolt
    /// vector regardless of which symbol the user picked — the
    /// in-flight pulse is iconic, not skinnable. Static icon
    /// elsewhere still honors `zapImage`.
    var image: Image = Image(systemName: "bolt.fill")
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
            // Scale breath 0.92 → 1.08, matches Android exactly.
            let breath = 0.92 + 0.16 * frame.phase
            // Stroke opacity 0.7 → 1.0. Higher than Android's 0.15-0.3
            // because the iOS stroke needs to read clearly at the
            // action-bar size; Android's path stroke benefits from a
            // dedicated `Canvas` render that anti-aliases at the full
            // device pixel ratio.
            let strokeAlpha = 0.7 + 0.3 * frame.phase
            // iOS-only flourish — a sub-pixel vertical bounce that
            // keeps the bolt feeling alive at all pulse phases.
            let dy = -0.5 * frame.sine

            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height)
                // Stroke width scales with the view size, matching
                // Android's `Stroke(width = w * 0.14f)` on the bolt
                // path. Half of this width sits inside the silhouette
                // (covered by the fill) and half outside (the visible
                // outer halo).
                let strokeWidth = size * 0.22

                ZStack {
                    // 1. Outer halo — wide stroke on the bolt path,
                    //    drawn before the fill so the inside half of
                    //    the stroke gets covered. The visible orange
                    //    is the outside half of the stroke.
                    BoltGlyph()
                        .stroke(
                            Color.wispZapAnimationColor.opacity(strokeAlpha),
                            style: StrokeStyle(
                                lineWidth: strokeWidth,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )

                    // 2. White bolt body. Fills the silhouette + covers
                    //    the inside half of the stroke, leaving only
                    //    the outside half visible as the outer halo.
                    BoltGlyph()
                        .fill(.white)
                }
                .frame(width: size, height: size)
                // Centre the square render area inside whatever rect
                // the parent gave us.
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .scaleEffect(breath)
            .offset(y: dy)
        }
    }

    // MARK: - Frame math

    private struct Frame {
        /// -1 … 1, raw sin oscillator. Drives the centered bounce.
        let sine: Double
        /// 0 … 1, normalised from sine. Drives the one-way stroke
        /// opacity ramp and the scale-breath envelope.
        let phase: Double
    }

    private func frame(at date: Date) -> Frame {
        let elapsed = date.timeIntervalSince(start)
        let sine = sin(elapsed / 0.9 * 2 * .pi)
        let phase = (sine + 1) / 2
        return Frame(sine: sine, phase: phase)
    }
}

/// Hand-built lightning-bolt `Shape`, normalized to its bounding rect.
/// Coordinates trace a standard "Z"-style bolt: top vertex centred,
/// diagonal down-left to the middle, kink right and back, diagonal
/// down to the bottom vertex, then kink up to close the path. Used by
/// `LightningPulseView` because SwiftUI's SF-Symbol `Image` doesn't
/// expose a strokable vector path — and the multi-offset image trick
/// produces aliased bitmap copies, not a clean stroke.
private struct BoltGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height

        // Normalized vertex set tuned to read as a familiar lightning
        // bolt at action-bar size. Approximates Wisp Android's
        // `icBoltPath` (viewBox 55×94) — same proportions, simplified
        // for a hand-walkable SwiftUI Path build.
        var path = Path()
        path.move(to:  CGPoint(x: 0.62 * w, y: 0.02 * h))      // top vertex
        path.addLine(to: CGPoint(x: 0.18 * w, y: 0.55 * h))    // diag down-left
        path.addLine(to: CGPoint(x: 0.42 * w, y: 0.55 * h))    // kink right (inner)
        path.addLine(to: CGPoint(x: 0.30 * w, y: 0.98 * h))    // diag down to bottom
        path.addLine(to: CGPoint(x: 0.82 * w, y: 0.45 * h))    // diag up-right (back side)
        path.addLine(to: CGPoint(x: 0.58 * w, y: 0.45 * h))    // kink left (inner)
        path.closeSubpath()                                     // close to top vertex
        return path
    }
}

#Preview {
    LightningPulseView(image: Image(systemName: "bolt.fill"))
        .frame(width: 28, height: 28)
        .padding()
        .background(Color.black)
}
