import SwiftUI
import UIKit
import GiphyUISDK

/// SwiftUI bridge to Giphy's `GiphyViewController`.
///
/// `GiphyViewController` is designed to be presented as its own UIKit modal
/// — its internal layout (the bottom search-bar + trending-chips carousel,
/// the GIF grid, the "drag-up" gesture for keyboard) only renders correctly
/// when Giphy IS the modal, not when it's embedded as a child view inside a
/// SwiftUI `.sheet` / `.fullScreenCover` host.
///
/// So this representable is a **headless presenter**: it returns an empty
/// host UIViewController whose view stays hidden, and on `isPresented` flip
/// it asks that host to `present(giphy, animated: true)`. Selection and
/// dismiss flow back through the binding and the `onSelect` callback.
///
/// Caller is expected to attach this view as a `.background` of any visible
/// SwiftUI view in the same window:
///
///     .background(
///         GifPickerPresenter(isPresented: $showGifPicker, onSelect: { url in … })
///     )
struct GifPickerPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        // A zero-size invisible host. Giphy modal pivots on this.
        let host = UIViewController()
        host.view.backgroundColor = .clear
        return host
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        // Refresh the coordinator's view of the parent on every update so its
        // delegate callbacks bind to the *current* `isPresented` storage and
        // `onSelect` closure rather than the stale copy captured at
        // `makeCoordinator` time. Without this, parent body re-renders can
        // leave the coordinator pointing at a stale binding which drives the
        // open/close loop on real devices.
        context.coordinator.parent = self

        if isPresented {
            // Two guards against re-presentation:
            //   1. The presented controller is still attached.
            //   2. We already queued an async present that UIKit hasn't
            //      registered yet — re-presenting in that window would stack
            //      a second modal and force UIKit to flip-flop between them,
            //      which manifests as the open / close loop the user sees.
            guard host.presentedViewController == nil,
                  !context.coordinator.isPresenting else { return }
            context.coordinator.isPresenting = true
            GiphyConfig.bootstrap()
            let giphy = GiphyViewController()
            giphy.mediaTypeConfig = [.gifs, .stickers, .recents]
            giphy.theme = GPHTheme(type: host.traitCollection.userInterfaceStyle == .dark ? .dark : .light)
            giphy.shouldLocalizeSearch = true
            giphy.delegate = context.coordinator
            // Defer one runloop so SwiftUI has finished installing the host
            // in the window hierarchy. Presenting too early raises
            // "view not in window hierarchy" warnings on first launch.
            DispatchQueue.main.async {
                host.present(giphy, animated: true)
            }
        } else if let presented = host.presentedViewController,
                  !presented.isBeingDismissed {
            // SwiftUI side wants us closed. If the modal is already mid-
            // dismiss (e.g. user-initiated swipe-down already fired
            // `didDismiss`), don't call dismiss again — racing dismiss
            // animations are part of what produced the loop.
            presented.dismiss(animated: true)
        }
    }

    final class Coordinator: NSObject, GiphyDelegate {
        var parent: GifPickerPresenter
        /// Set when `updateUIViewController` queues an async present. Cleared
        /// after dismiss completes. Prevents a second present from stacking
        /// while UIKit hasn't yet registered the first one.
        var isPresenting = false

        init(parent: GifPickerPresenter) {
            self.parent = parent
        }

        func didSelectMedia(giphyViewController: GiphyViewController, media: GPHMedia, contentType: GPHContentType) {
            let url = media.url(rendition: .original, fileType: .gif)
                ?? media.url(rendition: .fixedHeight, fileType: .gif)
                ?? media.url(rendition: .downsized, fileType: .gif)
            if let url {
                parent.onSelect(url)
            }
            giphyViewController.dismiss(animated: true) { [weak self] in
                self?.isPresenting = false
                self?.parent.isPresented = false
            }
        }

        func didDismiss(controller: GiphyViewController?) {
            isPresenting = false
            parent.isPresented = false
        }
    }
}
