import UIKit
import PhotosUI

/// Imperative photo picker. Replaces the SwiftUI `UIViewControllerRepresentable`
/// + `.background()` host approach that was unreliable on iPhone 13 Pro
/// Max — modals presented from a bare host inside a SwiftUI sheet were
/// torn down silently within ~1s of appearing.
///
/// Call `PhotoPickerService.present(...)` from any button action. The
/// service walks up to the topmost presented view controller and asks
/// it to present the picker, so the picker lives in the same
/// presentation chain as the compose sheet itself — no extra host, no
/// representable lifecycle interactions.
///
/// **Important.** Other `UIViewControllerRepresentable`s in the same
/// sheet that call `host.presentedViewController?.dismiss(animated:)`
/// in their `else` branch MUST guard on the controller type — see
/// `docs/MODAL_PRESENTATION_FROM_SWIFTUI_SHEETS.md` for the rationale.
/// Failing to guard caused the very issue this service was rebuilt to
/// fix.
@MainActor
enum PhotoPickerService {
    /// Present a system PHPicker for images + videos. The delegate
    /// retention is handled via an associated object on the picker so
    /// the caller doesn't have to hold a reference.
    static func present(
        maxCount: Int,
        onPicked: @escaping ([NSItemProvider]) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        guard let presenter = topmostPresenter() else { return }

        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = maxCount
        config.filter = .any(of: [.images, .videos])
        config.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: config)
        // Block swipe-down dismiss — Add / Cancel remain as explicit
        // exits. Does not block programmatic dismiss, which is what
        // the GifPickerPresenter ancestor-dismiss bug was triggering;
        // that bug is fixed at the source.
        picker.isModalInPresentation = true

        let delegate = PickerDelegate(onPicked: onPicked, onCancel: onCancel)
        picker.delegate = delegate
        // Retain the delegate for the lifetime of the picker so the
        // caller doesn't have to hold it.
        objc_setAssociatedObject(picker, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)

        presenter.present(picker, animated: true)
    }

    private static var delegateKey: UInt8 = 0

    /// Walk the current key window's VC chain to the topmost presented
    /// controller. Presenting from there ensures the picker is stacked
    /// on top of whatever sheet / fullScreenCover is already up.
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

private final class PickerDelegate: NSObject, PHPickerViewControllerDelegate {
    let onPicked: ([NSItemProvider]) -> Void
    let onCancel: () -> Void

    init(onPicked: @escaping ([NSItemProvider]) -> Void,
         onCancel: @escaping () -> Void) {
        self.onPicked = onPicked
        self.onCancel = onCancel
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let providers = results.map(\.itemProvider)
        picker.dismiss(animated: true) { [weak self] in
            if providers.isEmpty {
                self?.onCancel()
            } else {
                self?.onPicked(providers)
            }
        }
    }
}
