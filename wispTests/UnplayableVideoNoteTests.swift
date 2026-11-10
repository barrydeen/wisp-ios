import Testing
@testable import wisp

/// Fixture from a real feed note whose only media is a VP9/Opus MP4 — codecs
/// AVFoundation cannot decode on iOS at all (see `VideoPlayability`). Pins
/// that such a note still classifies as a `.video` segment so
/// `InlineVideoView` — and its unsupported-format card — is the surface that
/// renders, rather than a bare link card.
@Suite struct UnplayableVideoNoteTests {

    private static let content =
        "https://v.nostr.build/Hn6IkN7f87P8jTC9OYwBPE.mp4\n\n"
        + "nostr:nevent1qvzqqqqqqypzpmnw5yatnljuff5w47d35d87q99xddqpzlzsac4xzn6vm22ekmn5q"
        + "ythwumn8ghj7un9d3shjtnp0faxzmt09ehx2ap0qythwumn8ghj7un9d3shjtnswf5k6ctv9ehx2ap"
        + "0qqsqqqq9988u2z8xas9mhhgpnp5xfa2hp2gnsrvrfcsg0u9j58jrv9gt2924e"

    private static let tags: [[String]] = [
        ["client", "Sidecar"],
        ["p", "ee6ea13ab9fe5c4a68eaf9b1a34fe014a66b40117c50ee2a614f4cda959b6e74"],
        ["q", "00000529cfc508e6ec0bbbdd01986864f5570a91380d834e2087f0b2a1e43615",
         "wss://relay.azzamo.net/",
         "ee6ea13ab9fe5c4a68eaf9b1a34fe014a66b40117c50ee2a614f4cda959b6e74"],
        ["imeta",
         "url https://v.nostr.build/Hn6IkN7f87P8jTC9OYwBPE.mp4",
         "alt I Picked the Wrong Week to Stop Sniffing Glue - Airplane!"],
        ["nonce", "5271", "20"],
    ]

    @Test func vp9NoteClassifiesAsSingleVideoSegment() {
        let segments = ContentParser.parse(content: Self.content, tags: Self.tags)

        let videoUrls = segments.compactMap { seg -> String? in
            if case .video(let meta) = seg { return meta.url }
            return nil
        }
        #expect(videoUrls == ["https://v.nostr.build/Hn6IkN7f87P8jTC9OYwBPE.mp4"])
    }
}
