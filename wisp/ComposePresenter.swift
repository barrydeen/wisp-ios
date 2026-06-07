import SwiftUI

/// App-level router for the keyboard-raising sheets (reply / quote / emoji
/// reaction composers, and the zap sheet) triggered from a `PostCardView`
/// action bar.
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

    /// The zap sheet raises the keyboard too (deferred `amountFocused` in
    /// `ZapSheet.onAppear`), so it must be hosted from the stable root like
    /// the composers. Leaving it on the card's own `.sheet` was the cause
    /// of the residual drawer loop: a diagnostic trace (2026-06-07) showed
    /// keyboard willShow → presenting row recycled ~2ms later → sheet torn
    /// down → the card's surviving `@State` re-presents → keyboard rises
    /// again, looping at ~0.5s per cycle with the model state never
    /// changing.
    func openZap(_ zap: ZapSheetRequest) {
        request = .zap(zap)
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
    case zap(ZapSheetRequest)

    var id: String {
        switch self {
        case .reply(let parent, _): return "reply-\(parent.id)"
        case .quote(let event):     return "quote-\(event.id)"
        case .emoji(let id, _):     return "emoji-\(id.uuidString)"
        case .zap(let zap):         return "zap-\(zap.eventId ?? zap.recipientPubkey)"
        }
    }
}

/// Everything `ZapSheet` needs, captured at tap time on the card. The
/// `onSuccess` closure (poll-vote optimistic apply) rides inline like the
/// emoji case's `onPick`, so its lifetime is bound to the presentation. The
/// wallet store itself is NOT carried here — `MainView` owns it and passes
/// it at the host `.sheet`; callers gate on wallet readiness before opening.
struct ZapSheetRequest {
    let recipientPubkey: String
    let recipientLud16: String?
    let recipientName: String?
    let eventId: String?
    var relayHints: [String] = []
    var extraTags: [[String]] = []
    var forcePrivate: Bool = false
    var onSuccess: ((Int64) -> Void)? = nil
}
