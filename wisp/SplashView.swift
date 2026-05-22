import SwiftUI

private let avatarSize: CGFloat = 44
private let avatarGap: CGFloat = 4

struct SplashView: View {
    @State private var viewModel = SplashViewModel()
    /// The bottom action buttons fade in after the splash has had a moment
    /// to settle. Without the delay the layout visibly twitches while the
    /// home indicator's safe-area inset stabilises during the initial
    /// presentation, jumping the buttons before the background is in place.
    @State private var actionsVisible = false
    /// Captured *once* on first layout and held constant thereafter. Using
    /// `UIScreen.main.bounds.height` directly is unreliable across split
    /// screen / iPad multitasking, but freezing the first GeometryReader
    /// reading gives a stable anchor that doesn't react to mid-transition
    /// safe-area inset changes — the cause of the buttons jumping during
    /// launch and sheet animations.
    @State private var lockedHeight: CGFloat?

    var onContinueWithNostr: () -> Void = {}
    var onContinueWithGoogle: () -> Void = {}

    var body: some View {
        GeometryReader { geo in
            let height = lockedHeight ?? geo.size.height
            let cols = max(1, Int((geo.size.width + avatarGap) / (avatarSize + avatarGap)))
            let maxVisibleRows = Int((height + avatarGap) / (avatarSize + avatarGap)) + 1
            let maxVisibleCount = maxVisibleRows * cols
            let pics: [String] = {
                if viewModel.profilePictures.isEmpty {
                    return Array(repeating: "", count: maxVisibleCount)
                }
                return Array(viewModel.profilePictures.prefix(maxVisibleCount))
            }()
            let rows = (pics.count + cols - 1) / cols

            ZStack {
                // Avatar grid pinned to top, clipped to screen bounds
                VStack(spacing: avatarGap) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: avatarGap) {
                            ForEach(0..<cols, id: \.self) { col in
                                let idx = row * cols + col
                                if idx < pics.count {
                                    AvatarCircle(url: pics[idx])
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()

                // Gradient fades the collage into the background
                LinearGradient(
                    colors: [.clear, Color.wispBackground],
                    startPoint: UnitPoint(x: 0.5, y: 0.25),
                    endPoint: UnitPoint(x: 0.5, y: 0.72)
                )

                // Logo, title, and action buttons pinned to bottom.
                //
                // The whole stack is held hidden until `actionsVisible`
                // flips. The home indicator's safe-area inset settles
                // during the first ~400ms of the launch / presentation
                // animation, shifting whatever is anchored to the bottom
                // edge as it does. Hiding everything (not just the
                // buttons) means the user never sees the in-flight shift
                // — only the final, stable layout.
                VStack(spacing: 0) {
                    Spacer()

                    AnimatedLogo()

                    Text("wisp")
                        .font(.system(size: 56, weight: .medium))
                        .foregroundStyle(.white)

                    if let online = viewModel.onlineCount {
                        OnlineCard(count: online)
                            .padding(.top, 16)
                    }

                    Spacer().frame(height: 32)

                    VStack(spacing: 8) {
                        if GoogleAuthConfig.isConfigured {
                            ContinueWithGoogleButton(action: onContinueWithGoogle)
                        }

                        ContinueWithNostrButton(action: onContinueWithNostr)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
                .opacity(actionsVisible ? 1 : 0)
                .allowsHitTesting(actionsVisible)
            }
            // Lock the inner content to the height observed on first
            // layout. After that point, safe-area inset transitions can no
            // longer change the inner frame's bottom edge, so the
            // bottom-anchored content stays put.
            .frame(width: geo.size.width, height: height)
            .onAppear {
                if lockedHeight == nil { lockedHeight = geo.size.height }
            }
        }
        .background(Color.wispBackground)
        .ignoresSafeArea()
        .task {
            // Hold the bottom stack hidden until the screen has fully
            // settled. 1.8s covers the launch animation, the home
            // indicator inset stabilising, and any subsequent safe-area
            // transitions — every shift happens behind a 0-opacity curtain.
            try? await Task.sleep(for: .milliseconds(1800))
            withAnimation(.easeOut(duration: 0.35)) { actionsVisible = true }
        }
        .onDisappear { viewModel.cancel() }
    }
}

/// Matches the Android "Continue with Google" pill from
/// `SplashScreen.kt` (lines 211–238): black background, light-grey text
/// and 1pt grey border, with the Google "G" mark to the left.
private struct ContinueWithGoogleButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                GoogleGIcon()
                    .frame(width: 20, height: 20)
                Text("Continue with Google")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(red: 0xE3/255.0, green: 0xE3/255.0, blue: 0xE3/255.0))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .background(Color(red: 0x13/255.0, green: 0x13/255.0, blue: 0x14/255.0),
                    in: Capsule())
        .overlay(
            Capsule().stroke(Color(red: 0x8E/255.0, green: 0x91/255.0, blue: 0x8F/255.0), lineWidth: 1)
        )
    }
}

/// Matches the Android "Continue with Nostr" pill from `SplashScreen.kt`
/// (lines 242–269): dark-purple background, light-purple text and purple
/// border, with the Nostr ostrich mark to the left.
private struct ContinueWithNostrButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                NostrOstrichIcon()
                    .frame(width: 22, height: 22)
                Text("Continue with Nostr")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(red: 0xE9/255.0, green: 0xDD/255.0, blue: 0xFF/255.0))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .background(Color(red: 0x1A/255.0, green: 0x0E/255.0, blue: 0x2E/255.0),
                    in: Capsule())
        .overlay(
            Capsule().stroke(Color(red: 0x8E/255.0, green: 0x30/255.0, blue: 0xEB/255.0), lineWidth: 1)
        )
    }
}

/// SwiftUI port of `res/drawable/ic_google_g.xml` — Google's four-colour "G"
/// mark drawn from the same 24×24 viewport coordinates so the icon stays
/// pixel-identical to Android.
private struct GoogleGIcon: View {
    private static let blue = Color(red: 0x42 / 255.0, green: 0x85 / 255.0, blue: 0xF4 / 255.0)
    private static let green = Color(red: 0x34 / 255.0, green: 0xA8 / 255.0, blue: 0x53 / 255.0)
    private static let yellow = Color(red: 0xFB / 255.0, green: 0xBC / 255.0, blue: 0x05 / 255.0)
    private static let red = Color(red: 0xEA / 255.0, green: 0x43 / 255.0, blue: 0x35 / 255.0)

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 24.0
            func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

            var blue = Path()
            blue.move(to: P(22.56, 12.25))
            blue.addCurve(to: P(22.36, 10),
                          control1: P(22.56, 11.47),
                          control2: P(22.49, 10.72))
            blue.addLine(to: P(12, 10))
            blue.addLine(to: P(12, 14.26))
            blue.addLine(to: P(17.92, 14.26))
            blue.addCurve(to: P(15.71, 17.57),
                          control1: P(17.66, 15.63),
                          control2: P(16.88, 16.79))
            blue.addLine(to: P(15.71, 20.34))
            blue.addLine(to: P(19.28, 20.34))
            blue.addCurve(to: P(22.56, 12.25),
                          control1: P(21.36, 18.42),
                          control2: P(22.56, 15.60))
            blue.closeSubpath()
            ctx.fill(blue, with: .color(Self.blue))

            var green = Path()
            green.move(to: P(12, 23))
            green.addCurve(to: P(19.28, 20.34),
                           control1: P(14.97, 23),
                           control2: P(17.46, 22.02))
            green.addLine(to: P(15.71, 17.57))
            green.addCurve(to: P(12, 18.63),
                           control1: P(14.73, 18.23),
                           control2: P(13.48, 18.63))
            green.addCurve(to: P(5.84, 14.10),
                           control1: P(9.14, 18.63),
                           control2: P(6.71, 16.70))
            green.addLine(to: P(2.18, 14.10))
            green.addLine(to: P(2.18, 16.94))
            green.addCurve(to: P(12, 23),
                           control1: P(3.99, 20.53),
                           control2: P(7.70, 23))
            green.closeSubpath()
            ctx.fill(green, with: .color(Self.green))

            var yellow = Path()
            yellow.move(to: P(5.84, 14.09))
            yellow.addCurve(to: P(5.49, 12),
                            control1: P(5.62, 13.43),
                            control2: P(5.49, 12.73))
            // Smooth-cubic: first control reflected across current point
            // from the previous segment's second control (5.49, 12.73) →
            // (5.49, 11.27).
            yellow.addCurve(to: P(5.84, 9.91),
                            control1: P(5.49, 11.27),
                            control2: P(5.62, 10.57))
            yellow.addLine(to: P(5.84, 7.07))
            yellow.addLine(to: P(2.18, 7.07))
            yellow.addCurve(to: P(1, 12),
                            control1: P(1.43, 8.55),
                            control2: P(1, 10.22))
            // Smooth-cubic: reflection of (1, 10.22) across (1, 12) → (1, 13.78).
            yellow.addCurve(to: P(2.18, 16.93),
                            control1: P(1, 13.78),
                            control2: P(1.43, 15.45))
            yellow.addLine(to: P(5.03, 14.71))
            yellow.addLine(to: P(5.84, 14.09))
            yellow.closeSubpath()
            ctx.fill(yellow, with: .color(Self.yellow))

            var red = Path()
            red.move(to: P(12, 5.38))
            red.addCurve(to: P(16.21, 7.02),
                         control1: P(13.62, 5.38),
                         control2: P(15.06, 5.94))
            red.addLine(to: P(19.36, 3.87))
            red.addCurve(to: P(12, 1),
                         control1: P(17.45, 2.09),
                         control2: P(14.97, 1))
            red.addCurve(to: P(2.18, 7.07),
                         control1: P(7.70, 1),
                         control2: P(3.99, 3.47))
            red.addLine(to: P(5.84, 9.91))
            red.addCurve(to: P(12, 5.38),
                         control1: P(6.71, 7.31),
                         control2: P(9.14, 5.38))
            red.closeSubpath()
            ctx.fill(red, with: .color(Self.red))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// SwiftUI port of `res/drawable/ic_nostr_ostrich.xml` — two-tone pixel
/// ostrich rendered from the same 240×270 viewport coordinates so the icon
/// stays pixel-identical to Android.
private struct NostrOstrichIcon: View {
    private static let orange = Color(red: 0xFD/255.0, green: 0x96/255.0, blue: 0x2C/255.0)
    private static let purple = Color(red: 0xA2/255.0, green: 0x23/255.0, blue: 0xE9/255.0)

    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 240
            let sy = size.height / 270

            var legs = Path()
            legs.addRect(CGRect(x: 105 * sx, y: 225 * sy, width: 30 * sx, height: 30 * sy))
            legs.addRect(CGRect(x: 165 * sx, y: 225 * sy, width: 30 * sx, height: 30 * sy))
            legs.addRect(CGRect(x: 195 * sx, y: 75 * sy, width: 30 * sx, height: 30 * sy))
            ctx.fill(legs, with: .color(Self.orange))

            let pts: [(CGFloat, CGFloat)] = [
                (165, 45), (165, 15), (135, 15), (135, 45), (135, 75), (135, 105),
                (105, 105), (75, 105), (45, 105), (15, 105), (15, 135), (45, 135),
                (45, 165), (75, 165), (75, 195), (105, 195), (105, 225), (135, 225),
                (135, 195), (165, 195), (165, 225), (195, 225), (195, 195), (195, 165),
                (195, 135), (195, 105), (195, 75), (195, 45)
            ]
            var body = Path()
            body.move(to: CGPoint(x: pts[0].0 * sx, y: pts[0].1 * sy))
            for i in 1..<pts.count {
                body.addLine(to: CGPoint(x: pts[i].0 * sx, y: pts[i].1 * sy))
            }
            body.closeSubpath()
            ctx.fill(body, with: .color(Self.purple))
        }
        .aspectRatio(240.0 / 270.0, contentMode: .fit)
    }
}

private struct AvatarCircle: View {
    let url: String

    var body: some View {
        if url.isEmpty {
            Circle()
                .fill(Color.wispSurfaceVariant)
                .frame(width: avatarSize, height: avatarSize)
        } else {
            AsyncImage(url: URL(string: url)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    Circle().fill(Color.wispSurfaceVariant)
                default:
                    Circle().fill(Color.wispSurfaceVariant)
                }
            }
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(Circle())
        }
    }
}

private struct OnlineCard: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(red: 0x4C/255.0, green: 0xAF/255.0, blue: 0x50/255.0))
                .frame(width: 8, height: 8)
            Text("\(formatCount(count)) people online now")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.wispSurface, in: RoundedRectangle(cornerRadius: 24))
    }

    private func formatCount(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: String(format: "%.1fk", Double(n) / 1_000)
        default: "\(n)"
        }
    }
}

private struct AnimatedLogo: View {
    @State private var bob = false
    @State private var sway = false

    var body: some View {
        Image("WispLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 96, height: 96)
            .offset(y: bob ? -8 : 0)
            .rotationEffect(.degrees(sway ? 3 : -3))
            .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    bob = true
                }
                withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: true)) {
                    sway = true
                }
            }
    }
}

/// Bottom sheet mirroring Android's `NostrLoginSheet` (lines 322–474 of
/// `SplashScreen.kt`): ostrich + title + body, nsec/npub field with
/// show/hide + QR trailing icons, "Log In" primary button, divider,
/// "Create new account" outlined button.
struct NostrLoginSheet: View {
    var onLogin: (Keypair) -> Void
    var onCreateAccount: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nsecInput = ""
    @State private var error: String?
    @State private var isSecure = true
    @State private var isLoading = false
    @State private var showQRScanner = false

    var body: some View {
        VStack(spacing: 0) {
            NostrOstrichIcon()
                .frame(width: 48, height: 48)
                .padding(.top, 24)

            Text("Continue with Nostr")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.top, 12)

            Text("Enter your existing key, or create a new account. Your key never leaves the device.")
                .font(.subheadline)
                .foregroundStyle(Color.wispOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 4)

            HStack(spacing: 8) {
                Group {
                    if isSecure {
                        SecureField("nsec or npub…", text: $nsecInput)
                    } else {
                        TextField("nsec or npub…", text: $nsecInput)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: nsecInput) { _, _ in error = nil }

                Button {
                    isSecure.toggle()
                } label: {
                    Image(systemName: isSecure ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    showQRScanner = true
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 20)

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.top, 8)
            }

            Button(action: login) {
                Group {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Log In").font(.body.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(.wispPrimary)
            .clipShape(Capsule())
            .disabled(nsecInput.isEmpty || isLoading)
            .padding(.top, 12)

            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.wispOutline.opacity(0.5))
                    .frame(height: 1)
            }
            .padding(.vertical, 20)

            Button(action: onCreateAccount) {
                Text("Create new account")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .tint(.wispPrimary)
            .clipShape(Capsule())

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.wispBackground)
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.wispBackground)
        .presentationDragIndicator(.visible)
        .fullScreenCover(isPresented: $showQRScanner) {
            QRCodeScannerView(
                onScanned: { value in handleScanned(value) },
                onCancel: { showQRScanner = false }
            )
            .ignoresSafeArea()
        }
        .onAppear { nsecPasteAllowed = true }
        .onDisappear { nsecPasteAllowed = false }
    }

    private func login() {
        error = nil
        let trimmed = nsecInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if let keypair = NostrKey.parseNsec(trimmed) {
            isLoading = true
            NostrKey.save(keypair)
            onLogin(keypair)
            return
        }
        if let uriData = Nip19.decodeNostrUri(trimmed),
           case .profileRef(let pubkeyHex, _) = uriData {
            isLoading = true
            NostrKey.saveWatchOnly(pubkey: pubkeyHex)
            onLogin(Keypair(privkey: "", pubkey: pubkeyHex))
            return
        }
        error = "Invalid key. Enter an nsec, npub, nprofile, or hex private key."
    }

    private func handleScanned(_ value: String) {
        showQRScanner = false
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let keypair = NostrKey.parseNsec(trimmed) {
            NostrKey.save(keypair)
            onLogin(keypair)
            return
        }
        if let uriData = Nip19.decodeNostrUri(trimmed),
           case .profileRef(let pubkeyHex, _) = uriData {
            NostrKey.saveWatchOnly(pubkey: pubkeyHex)
            onLogin(Keypair(privkey: "", pubkey: pubkeyHex))
            return
        }
        error = "Unrecognized format. Scan an nsec, npub, nprofile, or hex private key."
    }
}

// Legacy palette accessors. Prefer `@Environment(\.theme)` and `theme.palette.*` /
// `theme.primary` directly in new code — these globals reflect the active theme by
// reading `ResolvedThemeProxy.current` synchronously. They live on for the many
// existing call sites that haven't been migrated yet.
//
// `nonisolated` so SwiftUI views, `Sendable` closures, and non-MainActor code
// (`UIViewRepresentable` coordinators, `Task.detached` rendering helpers) can
// read these without needing an actor hop. The underlying `ResolvedThemeProxy`
// is lock-protected.
nonisolated extension Color {
    static var wispBackground: Color { ResolvedThemeProxy.current.palette.background }
    static var wispSurface: Color { ResolvedThemeProxy.current.palette.surface }
    static var wispSurfaceVariant: Color { ResolvedThemeProxy.current.palette.surfaceVariant }
    static var wispPrimary: Color { ResolvedThemeProxy.current.primary }
    /// Zap-tinted surfaces — post bolt icon, zap count text, top-zapper
    /// indicator, wallet zap accents, the Lightning QR icon, etc. Reads
    /// from `ResolvedTheme.zap`, which on the `custom` theme equals
    /// `primary` so a user-picked accent flows through; on every other
    /// preset it stays the curated palette value chosen for hue contrast.
    /// The celebratory in-flight bolt pulse uses `wispZapAnimationColor`
    /// instead — never use this accessor for that animation.
    static var wispZapColor: Color { ResolvedThemeProxy.current.zap }
    /// Vivid variant of `wispZapColor`, reserved for the in-flight bolt
    /// animation (`LightningPulseView`). Plain `wispZapColor` reads muddy
    /// in light mode because the primary is darkened for button contrast;
    /// the burst needs a brightness floor or the animation looks dim on
    /// the near-white surface. Static UI everywhere else stays on the
    /// plain `wispZapColor`.
    static var wispZapAnimationColor: Color { ResolvedThemeProxy.current.zapAnimation }
    static var wispRepostColor: Color { ResolvedThemeProxy.current.palette.repost }
    static var wispBookmarkColor: Color { ResolvedThemeProxy.current.bookmark }
    static var wispPaidColor: Color { ResolvedThemeProxy.current.palette.paid }
    static var wispOnSurface: Color { ResolvedThemeProxy.current.palette.onSurface }
    static var wispOnSurfaceVariant: Color { ResolvedThemeProxy.current.palette.onSurfaceVariant }
    static var wispOutline: Color { ResolvedThemeProxy.current.palette.outline }
}

/// Thread-safe holder for the active resolved theme.
///
/// Reads happen on every `View.body` re-evaluation, including inside
/// `Sendable` closures and `UIViewRepresentable.updateUIView`, so the
/// accessor must not require MainActor. Writes come from the root view's
/// `task` via `update(_:)` whenever `AppSettings` or the system color
/// scheme change. Brief staleness during an update (one frame) is fine —
/// theme transitions are visual, not load-bearing.
nonisolated enum ResolvedThemeProxy {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current: ResolvedTheme = .default

    static var current: ResolvedTheme {
        lock.lock(); defer { lock.unlock() }
        return _current
    }

    static func update(_ theme: ResolvedTheme) {
        lock.lock(); defer { lock.unlock() }
        _current = theme
    }
}

#Preview {
    SplashView()
}
