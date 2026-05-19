import UIKit
import SwiftUI
import Observation

// nsec1 + 58 bech32 lowercase alphanum chars
private let nsecRegex = try! NSRegularExpression(
    pattern: "nsec1[a-z0-9]{58}",
    options: .caseInsensitive
)

private var nsecPasteGuardInstalled = false
/// Set to `true` while a view that intentionally accepts nsec input is on screen.
nonisolated(unsafe) var nsecPasteAllowed = false

/// Global guard that intercepts every paste action via `UIApplication.sendAction`,
/// catching all UITextField, UITextView, and any custom subclass in one place.
///
/// The login screen opts out by setting `nsecPasteAllowed = true` on appear and
/// back to `false` on disappear.
@Observable
@MainActor
final class NsecPasteGuard {
    static let shared = NsecPasteGuard()
    private init() {}

    var warningMessage: String?
    /// Bottom inset matching the current keyboard frame so the pill always
    /// floats above the keyboard rather than hiding behind it.
    var keyboardBottomInset: CGFloat = 0
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var warningWindow: UIWindow?
    @ObservationIgnored private var keyboardObserver: NSObjectProtocol?

    /// Call once at app startup (before any views are created).
    nonisolated static func setUp() {
        guard !nsecPasteGuardInstalled else { return }
        nsecPasteGuardInstalled = true
        // Intercept at UIApplication level so every responder — including
        // UITextField subclasses, UITextView subclasses, and any third-party
        // text control — is covered without needing per-class swizzles.
        guard
            let orig = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendAction(_:to:from:for:))),
            let repl = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.wisp_sendAction(_:to:from:for:)))
        else { return }
        method_exchangeImplementations(orig, repl)
    }

    nonisolated static func pasteboardContainsNsec() -> Bool {
        guard let text = UIPasteboard.general.string else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return nsecRegex.firstMatch(in: text, range: range) != nil
    }

    func showWarning() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        ensureWarningWindow()
        dismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) {
            warningMessage = "Paste blocked — your nsec is your private key and must never be shared."
        }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                self?.warningMessage = nil
            }
        }
    }

    /// Creates (once) a transparent UIWindow above the sheet level and starts
    /// tracking keyboard frame so the pill always renders in the visible area.
    private func ensureWarningWindow() {
        guard warningWindow == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .statusBar + 1
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false

        let vc = UIHostingController(rootView: NsecPasteWarningOverlay())
        vc.view.backgroundColor = .clear
        vc.view.isUserInteractionEnabled = false
        window.rootViewController = vc
        window.isHidden = false
        warningWindow = window

        keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
            let screenHeight = UIScreen.main.bounds.height
            let inset = max(0, screenHeight - endFrame.minY)
            Task { @MainActor [weak self] in
                withAnimation(.easeOut(duration: 0.25)) {
                    self?.keyboardBottomInset = inset
                }
            }
        }
    }
}

// MARK: - UIApplication swizzle

extension UIApplication {
    @objc func wisp_sendAction(_ action: Selector, to target: Any?, from sender: Any?, for event: UIEvent?) -> Bool {
        if action == #selector(UIResponder.paste(_:)),
           NsecPasteGuard.pasteboardContainsNsec(),
           !nsecPasteAllowed {
            Task { @MainActor in NsecPasteGuard.shared.showWarning() }
            return false
        }
        return wisp_sendAction(action, to: target, from: sender, for: event)
    }
}

// MARK: - Warning overlay

/// Red pill hosted in a floating UIWindow (above all sheets).
/// Positioned above the keyboard when it is visible.
struct NsecPasteWarningOverlay: View {
    @Bindable private var store = NsecPasteGuard.shared

    var body: some View {
        VStack {
            Spacer()
            if let message = store.warningMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                    Text(message)
                        .multilineTextAlignment(.leading)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color(UIColor.systemRed)))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                .padding(.bottom, store.keyboardBottomInset > 0 ? store.keyboardBottomInset + 12 : 96)
                .padding(.horizontal, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
