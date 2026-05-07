import SwiftUI

/// 1.1 s success burst: center flash → expanding ring → 5–8 bolt particles +
/// 12–20 sparks flying outward. Drawn in a single `Canvas` pass for perf;
/// `.allowsHitTesting(false)` lets taps fall through to the underlying card.
///
/// Mirrors Android `LightningOverlay.kt` `ZapBurstEffect` — same particle
/// counts, same per-particle delays, same scale/alpha curves.
///
/// `isActive` mirrors Android's `ZapBurstEffect(isActive: Boolean)` — the view
/// is always mounted in the overlay, animation is driven by a false→true
/// transition. Keeping the view permanently mounted avoids a SwiftUI race
/// where `.task`/`.onAppear` can fire after the parent already removes us
/// when the bursting window is short.
struct ZapBurstView: View {
    var isActive: Bool

    /// Total burst duration (s). Matches Android's 1100 ms tween.
    private let duration: TimeInterval = 1.1
    @State private var particles: Particles?
    @State private var animationStart: Date?

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                guard let particles, let animationStart else { return }
                let now = context.date.timeIntervalSince(animationStart)
                if now < 0 || now >= duration { return }
                let progress = now / duration
                draw(ctx, size: size, particles: particles, progress: CGFloat(progress))
            }
        }
        .onAppear {
            // Belt-and-braces: if the parent flips `isActive` true on the same
            // frame the view first appears, `.onChange` may not see the change
            // (the value is already true).
            if isActive { startAnimation() }
        }
        .onChange(of: isActive) { _, newValue in
            if newValue { startAnimation() }
        }
    }

    private func startAnimation() {
        particles = Particles.generate()
        animationStart = Date()
    }

    // MARK: - Drawing

    private func draw(_ ctx: GraphicsContext, size: CGSize, particles: Particles, progress: CGFloat) {
        let cx = size.width / 2
        let cy = size.height / 2
        let center = CGPoint(x: cx, y: cy)
        let minDim = min(size.width, size.height)
        let zap = Color.wispZapColor

        // 1. Center flash — radial gradient that fills then fades over the
        //    first quarter of the animation.
        if progress < 0.25 {
            let flashP = progress / 0.25
            let flashAlpha = (1 - flashP) * 0.7
            let flashRadius = minDim * 0.4
            let gradientRadius = minDim * 0.4 * (0.5 + flashP * 0.5)
            let gradient = Gradient(stops: [
                .init(color: .white.opacity(flashAlpha), location: 0),
                .init(color: zap.opacity(flashAlpha * 0.6), location: 0.5),
                .init(color: .clear, location: 1),
            ])
            ctx.fill(
                Path(ellipseIn: CGRect(
                    x: cx - flashRadius, y: cy - flashRadius,
                    width: flashRadius * 2, height: flashRadius * 2
                )),
                with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: gradientRadius)
            )
        }

        // 2. Expanding ring — yellow stroke that grows outward over the first
        //    half, fading as it goes.
        if progress < 0.5 {
            let ringP = progress / 0.5
            let ringRadius = 10 + minDim * 0.45 * ringP
            let ringAlpha = (1 - ringP) * 0.5
            let lineWidth = max(1, 4 - 3 * ringP)
            let ringPath = Path(ellipseIn: CGRect(
                x: cx - ringRadius, y: cy - ringRadius,
                width: ringRadius * 2, height: ringRadius * 2
            ))
            ctx.stroke(ringPath, with: .color(zap.opacity(ringAlpha)), lineWidth: lineWidth)
        }

        // 3. Bolt particles — fly outward on a quad-ease-out curve, scale up
        //    then shrink, fade out in the final 40 %.
        for bolt in particles.bolts {
            drawBolt(ctx, center: center, particle: bolt, progress: progress, zap: zap)
        }

        // 4. Spark particles — small white dots with a yellow halo, faster
        //    cubic-ease-out, fade in the second half.
        for spark in particles.sparks {
            drawSpark(ctx, center: center, particle: spark, progress: progress, zap: zap)
        }
    }

    private func drawBolt(_ ctx: GraphicsContext, center: CGPoint, particle: BoltParticle, progress: CGFloat, zap: Color) {
        let localP = max(0, min(1, (progress - particle.delay) / max(0.001, 1 - particle.delay)))
        if localP <= 0 { return }

        // Quadratic ease-out: snaps outward then settles.
        let eased = 1 - (1 - localP) * (1 - localP)
        let dist = particle.distance * eased
        let px = center.x + cos(particle.angle) * dist
        let py = center.y + sin(particle.angle) * dist

        // Scale grows quickly (first 30 %), then shrinks slightly. Alpha holds
        // until 60 %, then fades to zero by 100 %.
        let scale: CGFloat = localP < 0.3
            ? localP / 0.3
            : 1 - (localP - 0.3) / 0.7 * 0.6
        let alpha: CGFloat = localP > 0.6 ? 1 - (localP - 0.6) / 0.4 : 1

        if alpha <= 0 || scale <= 0 { return }

        let boltW = particle.boltSize * scale
        let boltH = boltW * (94.0 / 55.0)
        let path = boltPath(width: boltW, height: boltH)
        let translated = path.applying(CGAffineTransform(translationX: px - boltW / 2, y: py - boltH / 2))

        // Three-layer stack: glow stroke, fill, white core. Same as the
        // pulsing in-flight bolt but with per-particle alpha.
        ctx.stroke(
            translated,
            with: .color(zap.opacity(alpha * 0.5)),
            style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round, lineJoin: .round)
        )
        ctx.fill(translated, with: .color(zap.opacity(alpha * 0.9)))
        ctx.fill(translated, with: .color(.white.opacity(alpha * 0.3)))
    }

    private func drawSpark(_ ctx: GraphicsContext, center: CGPoint, particle: SparkParticle, progress: CGFloat, zap: Color) {
        let localP = max(0, min(1, (progress - particle.delay) / max(0.001, 1 - particle.delay)))
        if localP <= 0 { return }

        // Cubic ease-out: faster initial throw than the bolts.
        let eased = 1 - pow(1 - localP, 3)
        let dist = particle.distance * eased
        let px = center.x + cos(particle.angle) * dist
        let py = center.y + sin(particle.angle) * dist
        let alpha: CGFloat = localP > 0.5 ? 1 - (localP - 0.5) / 0.5 : 1
        let r = particle.sparkSize * (1 - localP * 0.5)

        if alpha <= 0 || r <= 0 { return }

        let halo = Path(ellipseIn: CGRect(x: px - r * 2, y: py - r * 2, width: r * 4, height: r * 4))
        ctx.fill(halo, with: .color(zap.opacity(alpha * 0.4)))
        let dot = Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2))
        ctx.fill(dot, with: .color(.white.opacity(alpha * 0.9)))
    }

    /// Same `icBoltPath` used by `LightningPulseView`, sized for a free-flying
    /// particle (no internal scale parameter — the caller scales via `boltSize`).
    private func boltPath(width: CGFloat, height: CGFloat) -> Path {
        let sx = width / 55
        let sy = height / 94
        var p = Path()
        p.move(to: CGPoint(x: 35.563 * sx, y: 0))
        p.addLine(to: CGPoint(x: 35.563 * sx, y: 40.406 * sy))
        p.addLine(to: CGPoint(x: 54.969 * sx, y: 40.406 * sy))
        p.addLine(to: CGPoint(x: 21.016 * sx, y: 93.75 * sy))
        p.addLine(to: CGPoint(x: 21.016 * sx, y: 51.719 * sy))
        p.addLine(to: CGPoint(x: 0, y: 51.719 * sy))
        p.closeSubpath()
        return p
    }
}

// MARK: - Particle generation

private struct BoltParticle {
    let angle: CGFloat
    let distance: CGFloat
    let boltSize: CGFloat
    let delay: CGFloat
}

private struct SparkParticle {
    let angle: CGFloat
    let distance: CGFloat
    let sparkSize: CGFloat
    let delay: CGFloat
}

private struct Particles {
    let bolts: [BoltParticle]
    let sparks: [SparkParticle]

    static func generate() -> Particles {
        // Bolt count 5–7 (Android: rng.nextInt(5, 8) exclusive upper bound).
        let boltCount = Int.random(in: 5...7)
        let baseStep = 2 * CGFloat.pi / CGFloat(boltCount)
        let bolts: [BoltParticle] = (0..<boltCount).map { i in
            BoltParticle(
                angle: baseStep * CGFloat(i) + (CGFloat.random(in: 0...1) - 0.5) * baseStep * 0.5,
                distance: 30 + CGFloat.random(in: 0...25),
                boltSize: 6 + CGFloat.random(in: 0...5),
                delay: CGFloat.random(in: 0...0.15)
            )
        }
        // Spark count 12–19 (Android: rng.nextInt(12, 20) exclusive).
        let sparkCount = Int.random(in: 12...19)
        let sparks: [SparkParticle] = (0..<sparkCount).map { _ in
            SparkParticle(
                angle: CGFloat.random(in: 0..<(2 * .pi)),
                distance: 40 + CGFloat.random(in: 0...35),
                sparkSize: 1.5 + CGFloat.random(in: 0...2.5),
                delay: CGFloat.random(in: 0...0.15)
            )
        }
        return Particles(bolts: bolts, sparks: sparks)
    }
}

#Preview {
    ZapBurstView(isActive: true)
        .frame(width: 200, height: 200)
        .padding()
        .background(Color.black)
}
