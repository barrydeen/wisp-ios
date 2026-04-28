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
}
