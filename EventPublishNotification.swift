import Foundation

extension Notification.Name {
    /// Posted by `ComposeViewModel` after a freshly-signed event has been persisted to the
    /// `EventStore`. `userInfo["event"]` carries the published `NostrEvent`.
    ///
    /// Open thread / notification view models observe this so the user's reply / repost shows
    /// up in their tree immediately, instead of waiting for the live relay subscription to
    /// reflect the event back (which often doesn't happen at all when publish writes go to a
    /// different relay set than the read subscription).
    static let nostrEventPublished = Notification.Name("NostrEventPublished")

    /// Posted when a deeply-nested view needs `MainView` to switch to the
    /// wallet tab — typically the "Set Up Wallet" affordance shown when
    /// the user tries to zap without a configured wallet.
    static let openWalletTab = Notification.Name("WispOpenWalletTab")

    /// Posted when the user taps a NIP-29 chat invite link (e.g.
    /// `wss://chat.wisp.talk'<groupid>`) embedded in note content. Carries
    /// `userInfo["relay"]`, `["group"]`, and optionally `["code"]`.
    /// `MainView` switches to the messages tab and `MessagesView` joins
    /// the group + navigates to the chat room.
    static let openWispChatLink = Notification.Name("WispOpenChatLink")
}
