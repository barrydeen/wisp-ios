# Modal presentation from SwiftUI sheets — gotcha + pattern

## TL;DR

If you ever write a `UIViewControllerRepresentable` whose
`updateUIViewController` includes a "dismiss whatever is presented when
SwiftUI says we should be closed" branch — **guard the dismiss on the
controller class**. Otherwise that representable will silently dismiss
any modal another part of the app presents from an ancestor view
controller, including ones it has nothing to do with.

```swift
// WRONG — dismisses any presented modal in the chain, not just our own.
} else if let presented = host.presentedViewController,
          !presented.isBeingDismissed {
    presented.dismiss(animated: true)
}

// RIGHT — only dismiss the controller class this representable owns.
} else if let presented = host.presentedViewController,
          presented is OurOwnModalViewController,
          !presented.isBeingDismissed {
    presented.dismiss(animated: true)
}
```

## Why it bites

Apple's docs on `UIViewController.presentedViewController`:

> Returns the view controller that was presented by this view controller
> **or one of its ancestors in the view controller hierarchy.**

A `.background(SomeRepresentable())` modifier mounts the representable's
host VC as a *child* in SwiftUI's hierarchy of the surrounding view. So
when an ancestor (e.g. the SwiftUI sheet's hosting controller) presents
a modal, `host.presentedViewController` on the representable's bare host
returns that ancestor-presented modal. The representable's
`updateUIViewController` fires on every parent re-render (which inside
a busy SwiftUI sheet is many times per second), sees a non-nil
`presentedViewController`, decides "SwiftUI says I'm closed, so dismiss
it," and tears down a modal it doesn't own.

## The Wisp incident (May 2026)

`feat/one-tap-zap` landed a redesigned compose sheet that hosts a few
helpers via `.background(...)`:

- `GifPickerPresenter` — wraps `GiphyViewController` because the SwiftUI
  modal hosts mangle Giphy's internal layout.
- `PhotosPickerPresenter` — wraps `PHPickerViewController` for the same
  defensive reason.

Both representables had the unguarded dismiss branch above. The
`PhotosPickerPresenter` host always dismissed *itself* (the picker it
just presented), which looked like "picker auto-closes after 1 second."
A long debugging session attributed the failure to:

1. Stale `parent` capture in the coordinator — fix didn't help.
2. Missing `presentationControllerDidDismiss` delegate — fix didn't help.
3. Stealth-dismiss detector in `updateUIViewController` — fix detected
   the disappearance but didn't prevent it.
4. Touch leak from button → sheet — irrelevant.
5. `isModalInPresentation = true` to block swipe — only blocks user
   swipe, doesn't block programmatic dismiss.

The actual cause was found by:

1. Swizzling `UIViewController.dismiss(animated:completion:)` in DEBUG
   to log the Swift call stack on every dismiss.
2. Reading the stack from the device log via `idevicesyslog`.
3. Seeing `wisp.GifPickerPresenter.updateUIViewController(_:context:)`
   at frame `[2]` on the picker's dismiss calls.

The `GifPickerPresenter` (the *other* representable in the same sheet,
not the one being directly debugged) was dismissing the photo picker
because its host saw the photo picker as `presentedViewController` via
the ancestor-chain rule above.

## The pattern we use now

For UIKit modals that need to be presented from inside a SwiftUI sheet,
prefer an **imperative service** over a `.background(SomeRepresentable())`
host. The service walks to the topmost presented view controller and
presents directly from there, so the modal lives in the same
presentation chain as the surrounding sheet — no extra bare host VC
that some other representable can accidentally inspect.

Reference: `wisp/PhotoPickerService.swift`. Call pattern:

```swift
Button {
    PhotoPickerService.present(maxCount: 8) { providers in
        Task { await viewModel.addMediaProviders(providers) }
    }
} label: { ... }
```

When a representable IS the right shape (e.g. `GifPickerPresenter`, which
needs Giphy's lifecycle hooks), keep the existing pattern but apply the
guarded-dismiss fix above.

## Audit checklist

When adding a new `UIViewControllerRepresentable` to the app, especially
one hosted inside a SwiftUI sheet via `.background()`:

- [ ] Does `updateUIViewController` ever call `dismiss` on
      `host.presentedViewController`? If yes, **guard on the controller
      class** so it can only dismiss its own modal.
- [ ] If the representable presents a system extension picker (PHPicker,
      Giphy, etc.), prefer an imperative service like
      `PhotoPickerService` over the `.background(host)` pattern when the
      caller is inside a SwiftUI sheet. Far fewer moving parts.
- [ ] `isModalInPresentation = true` blocks swipe-down but not
      programmatic dismiss. Don't rely on it to prevent loops caused by
      other code calling dismiss.

## If this bug shows up again

Symptoms: a modal presented from inside a SwiftUI sheet (compose,
profile edit, settings sub-sheet, etc.) appears briefly then dismisses
itself, with no user input, and no `delegate` callback fires. The
modal's owning code never asked for the dismiss.

1. Add the dismiss swizzle (search git history for `DismissSwizzle.swift`)
   to `wisp/` under a `#if DEBUG` guard and install from `wispApp.init`.
2. Filter the swizzle to your modal's class so the log isn't noisy.
3. Run on device via `idevicesyslog` and reproduce.
4. Frame `[2]` of the call stack is your caller. If it's another
   `UIViewControllerRepresentable.updateUIViewController(_:context:)`,
   you've hit this same gotcha — fix it the same way.
