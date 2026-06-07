import SwiftUI

/// App-level router for the keyboard-raising composers (reply / quote / emoji
/// reaction) triggered from a `PostCardView` action bar.
///
/// **Why this exists.** `PostCardView` lives inside a feed `LazyVStack`. When a
/// composer is presented from the card's own `.sheet(item:)` and `ComposeView`
/// raises the keyboard, the keyboard's safe-area inset shrinks the feed, the
/// `LazyVStack` re-windows its rows, and the presenting row's `.sheet` modifier
/// is torn down on the recycle — but the card's `@State` survives (it's keyed to
/// the stable `ForEach` identity), so SwiftUI immediately re-presents. That
/// re-raises the keyboard, and the sheet flips open/closed in a loop until the
/// app is force-quit. See `PostCardView`'s comments and
/// `docs/MODAL_PRESENTATION_FROM_SWIFTUI_SHEETS.md`.
///
/// The cure is to host these sheets from a view that is **never** inside a lazy
/// container and **never** recycled. A single `ComposePresenter` is injected
/// into the environment at `MainView`'s root ZStack; any card in any tab reads
/// it and routes its composer there, so the actual `.sheet` lives on the stable
/// app root rather than on the recyclable row.
@MainActor
@Observable
final class ComposePresenter {
    /// The single in-flight composer request. One value (rather than three
    /// separate bindings) means there is no sibling-sheet race to guard
    /// against — mirrors the single `.sheet(item:)` consolidation in
    /// `PostCardView`.
    var request: ComposeRequest?

    func openReply(parent: NostrEvent, root: NostrEvent?) {
        request = .reply(parent: parent, root: root)
    }

    func openQuote(_ event: NostrEvent) {
        request = .quote(event)
    }

    func openEmojiReaction(onPick: @escaping (PickedEmoji) -> Void) {
        request = .emoji(id: UUID(), onPick: onPick)
    }
}

/// Identifiable so it can drive `.sheet(item:)`. The emoji case carries its
/// per-card pick closure inline, so the closure's lifetime is bound to the
/// sheet's presentation (released when `request` goes back to nil) rather than
/// living in a separate, manually-cleared `@State`.
enum ComposeRequest: Identifiable {
    case reply(parent: NostrEvent, root: NostrEvent?)
    case quote(NostrEvent)
    case emoji(id: UUID, onPick: (PickedEmoji) -> Void)

    var id: String {
        switch self {
        case .reply(let parent, _): return "reply-\(parent.id)"
        case .quote(let event):     return "quote-\(event.id)"
        case .emoji(let id, _):     return "emoji-\(id.uuidString)"
        }
    }
}
