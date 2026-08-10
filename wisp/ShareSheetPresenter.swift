import UIKit

/// Imperative system share sheet.
///
/// `ShareLink` is unreliable inside the post overflow `.popover`: the row's
/// `simultaneousGesture` dismisses the popover on the same tap that the
/// `ShareLink` uses to present, tearing down the presenter before the share
/// sheet appears (so it looks like "share does nothing"). Presenting a
/// `UIActivityViewController` on the window's topmost view controller
/// decouples the sheet from the dismissing popover.
///
/// Mirrors `PhotoPickerService.topmostPresenter()` — the share sheet lives in
/// the same presentation chain as whatever sheet / fullScreenCover is up, and
/// is *not* anchored to a lazy feed row (so it sidesteps the lazy-row sheet
/// teardown that motivated `ComposePresenter`).
@MainActor
enum ShareSheetPresenter {
    /// Present the system share sheet for `url`. Call after dismissing any
    /// presenting popover — defer to the next runloop tick so the popover's
    /// dismissal has registered before we present on the VC beneath it.
    static func present(url: String) {
        guard let presenter = topmostPresenter() else { return }

        // Share as a `URL` when the string parses so iOS offers richer link
        // targets (Messages preview, Safari, copy-as-link); fall back to text.
        let items: [Any] = [URL(string: url) ?? url]
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)

        // iPad requires a popover anchor or this crashes. We're decoupled from
        // the originating ellipsis button, so anchor centered on the presenter.
        if let pop = activityVC.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                    y: presenter.view.bounds.midY,
                                    width: 0, height: 0)
            pop.permittedArrowDirections = []
        }

        presenter.present(activityVC, animated: true)
    }

    /// Present the system share sheet for plain text. Use this instead of
    /// `present(url:)` when the payload is an identifier rather than a web
    /// link — a `nostr:naddr1…` parses as a `URL` with a `nostr` scheme, and
    /// sharing it as one makes iOS offer link-shaped targets that can't open
    /// it, while text shares cleanly into any message or note.
    static func present(text: String) {
        guard let presenter = topmostPresenter() else { return }

        let activityVC = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let pop = activityVC.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                    y: presenter.view.bounds.midY,
                                    width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        presenter.present(activityVC, animated: true)
    }

    /// Walk the key window's VC chain to the topmost presented controller,
    /// skipping any controller mid-dismissal (e.g. the popover we just closed).
    private static func topmostPresenter() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
              ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first,
              let window = scene.windows.first(where: \.isKeyWindow)
              ?? scene.windows.first
        else { return nil }

        var top = window.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        return top
    }
}
