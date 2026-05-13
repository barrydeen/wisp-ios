import SwiftUI
import UIKit

/// Interactive left-edge swipe-rightward back gesture, restoring the iOS
/// interactive pop on destinations whose `.toolbar(.hidden, for: .navigationBar)`
/// disables the system one. The hit region is the left third of the screen
/// (matching the feel of common social apps), the view tracks the finger
/// live during the drag, and releasing past ~35% of the screen width commits
/// the pop. A short drag springs back.
///
/// During the swipe we render a snapshot of the previous navigation
/// destination behind the current view, so the user sees the timeline (or
/// whichever screen they came from) slide back into place under their
/// finger — the same visual the native interactive pop provides.
///
/// Apply via `.swipeBackFromLeftEdge()` on any pushed `NavigationStack`
/// destination that hides the nav bar.
struct SwipeBackFromLeftEdgeModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @State private var dragX: CGFloat = 0
    @State private var isActive = false
    @State private var previousSnapshot: UIImage?
    /// Width of the host view at swipe-start. Captured here rather than read
    /// from `UIScreen.main.bounds` so the commit threshold + slide-out target
    /// stay correct under iPad split view / Stage Manager, where the screen
    /// is wider than the destination.
    @State private var hostWidth: CGFloat = 0

    let onCommit: (() -> Void)?

    private static let activationZoneFraction: CGFloat = 1.0 / 3.0
    private static let commitFraction: CGFloat = 0.35

    func body(content: Content) -> some View {
        content
            .offset(x: dragX)
            // Soft shadow along the leading edge of the foreground while
            // the swipe is in progress — gives the impression of a card
            // lifting off the underlying view, the way the system pop does.
            .shadow(
                color: Color.black.opacity(dragX > 0 ? 0.28 : 0),
                radius: 12,
                x: -4,
                y: 0
            )
            // Snapshot + dimming go in `.background` rather than a ZStack so
            // the content's own layout doesn't shift the first time the
            // snapshot becomes non-nil (the ZStack conditional was causing
            // a visible vertical jump at swipe onset).
            .background {
                if let snap = previousSnapshot {
                    GeometryReader { geo in
                        Image(uiImage: snap)
                            .resizable()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .offset(x: -((geo.size.width - dragX) / 3.0))
                            .overlay(
                                Color.black.opacity(
                                    0.25 * (1 - min(1, dragX / geo.size.width))
                                )
                            )
                    }
                    .ignoresSafeArea()
                }
            }
            .background(
                SwipeBackGestureInstaller(
                    activationZoneFraction: Self.activationZoneFraction,
                    onBegan: { width in startSwipe(width: width) },
                    onChanged: { translation in dragX = max(0, translation) },
                    onEnded: { translation in finishSwipe(translation: translation) },
                    onCancelled: { cancelSwipe() }
                )
            )
    }

    private func startSwipe(width: CGFloat) {
        isActive = true
        hostWidth = width > 0 ? width : UIScreen.main.bounds.width
        previousSnapshot = SwipeBackSnapshot.capturePreviousNavigationView()
    }

    private func finishSwipe(translation: CGFloat) {
        guard isActive else { return }
        isActive = false
        let screenWidth = hostWidth > 0 ? hostWidth : UIScreen.main.bounds.width
        let threshold = screenWidth * Self.commitFraction
        if translation > threshold {
            // Finish the slide-out ourselves so the snapshot parallax stays
            // synced with the foreground. Then pop via SwiftUI's `dismiss()`
            // inside a transaction that suppresses the implicit NavigationStack
            // pop animation, so it doesn't run on top of our slide-out (which
            // is what made the transition look like "it happens twice"). Going
            // through `dismiss()` instead of UIKit's `popViewController` keeps
            // SwiftUI's `NavigationStack` in charge of the `path` binding —
            // calling `popViewController` directly leaves SwiftUI to back-sync
            // its path, and any side-channel tied to that path (e.g. the
            // `chain` mirror in ThreadView used for smart-pop) desyncs when
            // the popped destination isn't at the top of the SwiftUI hierarchy.
            let remaining = max(0, screenWidth - translation)
            let duration = 0.18 + Double(remaining / screenWidth) * 0.12
            withAnimation(.easeOut(duration: duration)) {
                dragX = screenWidth
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if let onCommit {
                        onCommit()
                    } else {
                        dismiss()
                    }
                }
            }
        } else {
            withAnimation(.easeOut(duration: 0.22)) { dragX = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                if !isActive { previousSnapshot = nil }
            }
        }
    }

    private func cancelSwipe() {
        guard isActive else { return }
        isActive = false
        withAnimation(.easeOut(duration: 0.18)) { dragX = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if !isActive { previousSnapshot = nil }
        }
    }
}

extension View {
    /// Adds an interactive left-edge swipe-right back gesture that tracks
    /// the finger and pops when released past the commit threshold. The
    /// previous navigation destination is rendered behind the dragging
    /// view so the transition matches the feel of the native interactive
    /// pop.
    func swipeBackFromLeftEdge() -> some View {
        modifier(SwipeBackFromLeftEdgeModifier(onCommit: nil))
    }

    /// Adds the swipe-back gesture with a custom commit action. Use this for
    /// destinations that own a `NavigationPath` binding and can pop it directly,
    /// which avoids SwiftUI replaying an inferred dismiss transition.
    func swipeBackFromLeftEdge(onCommit: @escaping () -> Void) -> some View {
        modifier(SwipeBackFromLeftEdgeModifier(onCommit: onCommit))
    }
}

// MARK: - Snapshot helper

private enum SwipeBackSnapshot {
    /// Walk from the active window scene's key window down to the
    /// frontmost `UINavigationController` (through tab controllers and
    /// presented modals) and render a snapshot of its previous view
    /// controller — the view the user is about to pop back to.
    @MainActor
    static func capturePreviousNavigationView() -> UIImage? {
        guard let nav = activeNavigationController(),
              nav.viewControllers.count >= 2 else { return nil }
        let prev = nav.viewControllers[nav.viewControllers.count - 2]
        let target = prev.view ?? nav.view
        guard let view = target, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = view.window?.screen.scale ?? UIScreen.main.scale
        format.opaque = view.isOpaque
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
        return renderer.image { context in
            // `drawHierarchy(afterScreenUpdates:)` asks UIKit/SwiftUI to perform
            // a fresh render pass. When the previous destination is a covered
            // SwiftUI host, that can re-evaluate views outside the environment
            // they were originally built under and crash on missing environment
            // values. Rendering the existing layer tree snapshots what is
            // already on screen without forcing SwiftUI body evaluation.
            if let presentation = view.layer.presentation() {
                presentation.render(in: context.cgContext)
            } else {
                view.layer.render(in: context.cgContext)
            }
        }
    }

    @MainActor
    static func activeNavigationController() -> UINavigationController? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.activationState == .foregroundActive else { continue }
            for window in windowScene.windows where window.isKeyWindow {
                if let nav = topNavigationController(in: window.rootViewController) {
                    return nav
                }
            }
        }
        return nil
    }

    @MainActor
    private static func topNavigationController(in vc: UIViewController?) -> UINavigationController? {
        guard let vc else { return nil }
        if let presented = vc.presentedViewController,
           let found = topNavigationController(in: presented) { return found }
        if let tab = vc as? UITabBarController {
            return topNavigationController(in: tab.selectedViewController)
        }
        if let nav = vc as? UINavigationController { return nav }
        for child in vc.children.reversed() {
            if let found = topNavigationController(in: child) { return found }
        }
        return nil
    }
}

// MARK: - UIKit pan recognizer installer

/// Installs a `UIPanGestureRecognizer` directly on the host SwiftUI view's
/// parent view controller's view. Going through a `UIViewControllerRepresentable`
/// (rather than `.background(UIViewRepresentable)`) is what makes the
/// recognizer sit in the responder chain ABOVE the SwiftUI content — without
/// that, `.background` sits as a sibling and never sees touches the content
/// consumes.
///
/// Direction-locks via the delegate so vertical scrolling inside the
/// destination's ScrollView stays unaffected: the recognizer fails itself
/// when motion is dominantly vertical, letting the ScrollView take over
/// cleanly. Once horizontal motion is locked in, `cancelsTouchesInView`
/// flips so the scroll view sees the touches as cancelled and stops fighting
/// the drag.
private struct SwipeBackGestureInstaller: UIViewControllerRepresentable {
    let activationZoneFraction: CGFloat
    let onBegan: (CGFloat) -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void
    let onCancelled: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            activationZoneFraction: activationZoneFraction,
            onBegan: onBegan,
            onChanged: onChanged,
            onEnded: onEnded,
            onCancelled: onCancelled
        )
    }

    func makeUIViewController(context: Context) -> InstallerVC {
        InstallerVC(coordinator: context.coordinator)
    }

    func updateUIViewController(_ vc: InstallerVC, context: Context) {
        context.coordinator.activationZoneFraction = activationZoneFraction
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
    }

    final class InstallerVC: UIViewController {
        let coordinator: Coordinator
        private weak var installedOn: UIView?
        private var recognizer: UIPanGestureRecognizer?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError() }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            guard let parent = parent else {
                if let rec = recognizer { installedOn?.removeGestureRecognizer(rec) }
                recognizer = nil
                installedOn = nil
                return
            }
            installRecognizer(on: parent.view)
        }

        private func installRecognizer(on target: UIView) {
            let pan = UIPanGestureRecognizer(
                target: coordinator,
                action: #selector(Coordinator.handle(_:))
            )
            pan.delegate = coordinator
            pan.cancelsTouchesInView = false
            target.addGestureRecognizer(pan)
            recognizer = pan
            installedOn = target
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var activationZoneFraction: CGFloat
        var onBegan: (CGFloat) -> Void
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat) -> Void
        var onCancelled: () -> Void
        private var activated = false

        init(activationZoneFraction: CGFloat,
             onBegan: @escaping (CGFloat) -> Void,
             onChanged: @escaping (CGFloat) -> Void,
             onEnded: @escaping (CGFloat) -> Void,
             onCancelled: @escaping () -> Void) {
            self.activationZoneFraction = activationZoneFraction
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.onCancelled = onCancelled
        }

        @objc func handle(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            switch recognizer.state {
            case .began:
                activated = true
                onBegan(view.bounds.width)
                onChanged(translation.x)
            case .changed:
                guard activated else { return }
                onChanged(max(0, translation.x))
            case .ended:
                if activated {
                    activated = false
                    onEnded(translation.x)
                }
            case .cancelled, .failed:
                if activated {
                    activated = false
                    onCancelled()
                }
            default:
                break
            }
        }

        // Direction-lock at the gate. The recognizer is asked this once before
        // its first .began transition; returning false makes it fail, which
        // releases the touch to the underlying ScrollView so vertical scrolls
        // proceed cleanly. Returning true commits to the swipe-back.
        //
        // The horizontal/vertical comparison uses a 0.6x multiplier on
        // vertical velocity so the gate doesn't reject clean rightward
        // swipes that happen to start with a few pixels of vertical noise
        // — that strict check was reading "user wants to scroll" on every
        // first-frame jitter and yielding the rest of the swipe to the
        // ScrollView (visible as a brief vertical shift before the
        // foreground started moving).
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else { return false }
            let velocity = pan.velocity(in: view)
            let location = pan.location(in: view)
            let activationZone = view.bounds.width * activationZoneFraction
            let startedInZone = location.x <= activationZone
            guard startedInZone, velocity.x > 0 else { return false }
            // Nothing to pop back to — skip activation so a root destination
            // doesn't slide partially off-screen and then no-op on dismiss.
            if let nav = SwipeBackSnapshot.activeNavigationController(),
               nav.viewControllers.count < 2 {
                return false
            }
            // Bail if the touch is on or near a UITextView that has an
            // active selection. iOS renders the selection drag handles
            // in a separate overlay above the text view, so a touch
            // directly on a handle hit-tests into that overlay rather
            // than into the UITextView's subtree. Treating "any touch
            // near the selected text view's bounds" as a yield extends
            // the handle's effective hit area to the whole text view
            // plus a small slop margin — enough to catch a handle
            // sitting flush against the leading edge.
            //
            // Tied to proximity rather than "any selection in the window"
            // so that lifting a finger anywhere outside the text body
            // (avatar gutter, action bar, surrounding space) still
            // activates swipe-back even while iOS keeps the selection
            // visually highlighted. `isFirstResponder` is deliberately
            // *not* checked because it lingers past the Copy menu and
            // would block swipe-back indefinitely.
            if Self.touchIsNearActiveSelection(point: location, in: view) {
                return false
            }
            // Also yield while an attached `UILongPressGestureRecognizer`
            // on a UITextView at the touch point is mid-recognition —
            // the user is engaging selection right now and our pan must
            // not race ahead.
            if let hit = view.hitTest(location, with: nil),
               let tv = Self.enclosingSelectableTextView(hit) {
                for gr in tv.gestureRecognizers ?? [] {
                    if gr is UILongPressGestureRecognizer,
                       gr.state == .began || gr.state == .changed {
                        return false
                    }
                }
            }
            // Either a clearly fast horizontal pull, or horizontal motion
            // that beats vertical by more than the noise floor.
            return abs(velocity.x) >= 120 || abs(velocity.x) > abs(velocity.y) * 0.6
        }

        // Make the enclosing ScrollView's pan wait for ours to commit or
        // fail. Scoped to `UIPanGestureRecognizer` so taps, long-presses,
        // and UITextView's selection recognizers still fire normally in the
        // activation zone — blanket-requiring failure across every gesture
        // type stalled button taps and long-press-to-select until our pan
        // resolved.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            return other is UIPanGestureRecognizer
        }

        // Defer specifically to a selectable UITextView's long-press
        // recognizer so a stationary long-press can engage selection
        // before our pan claims the touch. Scoped to `UILongPressGestureRecognizer`
        // only — UITextView also owns pan / tap recognizers that stay
        // `.possible` for the full touch, and waiting on all of them
        // starved our pan of the chance to recognize on note bodies.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            guard let tv = other.view as? UITextView, tv.isSelectable else { return false }
            return other is UILongPressGestureRecognizer
        }

        /// True when `point` (in `host`'s coordinate space) is inside or
        /// within 22pt of a selectable `UITextView` that has a non-empty
        /// selection. 22pt is roughly the radius of a selection drag
        /// handle's hit target, so a touch grabbing the handle from
        /// flush against the text view's leading or trailing edge still
        /// reads as "selection adjustment" rather than "swipe-back."
        private static let selectionSlop: CGFloat = 22

        private static func touchIsNearActiveSelection(point: CGPoint, in host: UIView) -> Bool {
            guard let window = host.window else { return false }
            return scanForNearbySelection(in: window, point: point, host: host)
        }

        private static func scanForNearbySelection(in view: UIView, point: CGPoint, host: UIView) -> Bool {
            if let tv = view as? UITextView, tv.isSelectable, tv.selectedRange.length > 0 {
                let local = tv.convert(point, from: host)
                let expanded = tv.bounds.insetBy(dx: -selectionSlop, dy: -selectionSlop)
                if expanded.contains(local) { return true }
            }
            for sub in view.subviews where !sub.isHidden && sub.alpha > 0 {
                if scanForNearbySelection(in: sub, point: point, host: host) { return true }
            }
            return false
        }

        private static func enclosingSelectableTextView(_ view: UIView) -> UITextView? {
            var current: UIView? = view
            while let v = current {
                if let tv = v as? UITextView, tv.isSelectable {
                    return tv
                }
                current = v.superview
            }
            return nil
        }
    }
}
