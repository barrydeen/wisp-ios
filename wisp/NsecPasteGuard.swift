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

/// Global guard that intercepts paste events on every UITextField and UITextView
/// and blocks any paste whose clipboard contents match an nsec private key.
///
/// Fields that legitimately accept an nsec (e.g. the login key-import screen)
/// opt out by setting `.accessibilityIdentifier("nsecInput")`.
@Observable
@MainActor
final class NsecPasteGuard {
    static let shared = NsecPasteGuard()
    private init() {}

    var warningMessage: String?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    /// Floating UIWindow that sits above sheets and modals so the pill is always
    /// visible regardless of presentation depth.
    @ObservationIgnored private var warningWindow: UIWindow?

    /// Call once at app startup (before any views are created).
    nonisolated static func setUp() {
        guard !nsecPasteGuardInstalled else { return }
        nsecPasteGuardInstalled = true
        swizzle(UITextField.self,
                original: #selector(UITextField.paste(_:)),
                replacement: #selector(UITextField.wisp_guardedPaste(_:)))
        swizzle(UITextView.self,
                original: #selector(UITextView.paste(_:)),
                replacement: #selector(UITextView.wisp_guardedPaste(_:)))
    }

    nonisolated static func pasteboardContainsNsec() -> Bool {
        guard let text = UIPasteboard.general.string else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return nsecRegex.firstMatch(in: text, range: range) != nil
    }

    func showWarning() {
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

    /// Creates (once) a transparent UIWindow above the sheet level so the pill
    /// renders over any presented sheet or navigation stack.
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
    }

    private nonisolated static func swizzle(
        _ cls: AnyClass,
        original: Selector,
        replacement: Selector
    ) {
        guard
            let orig = class_getInstanceMethod(cls, original),
            let repl = class_getInstanceMethod(cls, replacement)
        else { return }
        method_exchangeImplementations(orig, repl)
    }
}

// MARK: - UITextField swizzle

extension UITextField {
    @objc func wisp_guardedPaste(_ sender: Any?) {
        if NsecPasteGuard.pasteboardContainsNsec(), !nsecPasteAllowed {
            Task { @MainActor in NsecPasteGuard.shared.showWarning() }
            return
        }
        wisp_guardedPaste(sender)
    }
}

// MARK: - UITextView swizzle

extension UITextView {
    @objc func wisp_guardedPaste(_ sender: Any?) {
        if NsecPasteGuard.pasteboardContainsNsec(), !nsecPasteAllowed {
            Task { @MainActor in NsecPasteGuard.shared.showWarning() }
            return
        }
        wisp_guardedPaste(sender)
    }
}

// MARK: - Warning overlay

/// Red pill hosted in a floating UIWindow (above all sheets).
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
                .padding(.bottom, 96)
                .padding(.horizontal, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
