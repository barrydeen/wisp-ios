import Foundation

/// Navigation route for opening an `ArticleView` (NIP-23 long-form article,
/// kind 30023) from an embedded article card or a deep link. Mirrors Android's
/// `article/{kind}/{author}/{dTag}` route — `kind` is kept for parity even
/// though it's always 30023 today.
struct ArticleRoute: Hashable {
    let kind: Int
    /// Hex pubkey of the article author.
    let author: String
    /// NIP-33 `d` tag identifier of the addressable event.
    let dTag: String
    let relayHints: [String]

    init(kind: Int = 30023, author: String, dTag: String, relayHints: [String] = []) {
        self.kind = kind
        self.author = author
        self.dTag = dTag
        self.relayHints = relayHints
    }
}
