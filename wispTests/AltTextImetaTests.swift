import Foundation
import CoreGraphics
import Testing
@testable import wisp

/// Alt text via NIP-92 `imeta`. The read-path wire vector is the
/// Amethyst-published event locked into the web's `imeta.test.ts`; read-path
/// tests pin it verbatim so the interop contract can't drift.
@MainActor
struct AltTextImetaTests {

    // MARK: - §1 wire format (read path)

    /// The real test vector from §1: url first, alt last, other slots
    /// between. `alt` must survive every other slot and keep its spaces.
    @Test func parsesHandoffVector() throws {
        let tags = [[
            "imeta",
            "url https://npub1sjvt6lzmhj66gc3tjc5l4g3uhxz5lhaf4tqe2c0n5m92a0amffxq7veejj.blossom.band/ae8469f64b830b6eed6b1040cbfc4aaedb463c05cb2535fde0a062b652f2bd8f.jpg",
            "x ae8469f64b830b6eed6b1040cbfc4aaedb463c05cb2535fde0a062b652f2bd8f",
            "size 78925",
            "m image/jpeg",
            "dim 1080x2340",
            "blurhash [57nB:~pR*0oL-;M{t7M{t7M{t7M{t7M{t7M{t7M{t7M{t7M{t7",
            "ox ae8469f64b830b6eed6b1040cbfc4aaedb463c05cb2535fde0a062b652f2bd8f",
            "alt TV test pattern",
        ]]
        let map = ContentParser.parseImetaTags(tags)
        let url = "https://npub1sjvt6lzmhj66gc3tjc5l4g3uhxz5lhaf4tqe2c0n5m92a0amffxq7veejj.blossom.band/ae8469f64b830b6eed6b1040cbfc4aaedb463c05cb2535fde0a062b652f2bd8f.jpg"
        #expect(map[url]?.alt == "TV test pattern")
        // The other slots are orthogonal and must survive the parse too.
        #expect(map[url]?.mime == "image/jpeg")
        #expect(map[url]?.dimension == "1080x2340")
    }

    /// `imetaAltByUrl` is the kind-agnostic `url → alt` lookup (§2.1): only
    /// described URLs appear, and the event kind is irrelevant — these are
    /// bare tag arrays.
    @Test func altByUrlMapSkipsUndescribedTags() {
        let tags: [[String]] = [
            ["imeta", "url https://host/described.jpg", "m image/jpeg", "alt A plate of dumplings"],
            ["imeta", "url https://host/undescribed.jpg", "m image/jpeg"],
            ["client", "Amethyst"],
        ]
        let map = ContentParser.imetaAltByUrl(tags)
        #expect(map == ["https://host/described.jpg": "A plate of dumplings"])
    }

    /// §1 rules: trim the value; an empty (or whitespace) `alt` slot reads as
    /// no description at all.
    @Test func altIsTrimmedAndEmptyOmitted() {
        let tags: [[String]] = [
            ["imeta", "url https://host/a.jpg", "alt  padded description  "],
            ["imeta", "url https://host/b.jpg", "alt   "],
            ["imeta", "url https://host/c.jpg"],
        ]
        let map = ContentParser.imetaAltByUrl(tags)
        #expect(map["https://host/a.jpg"] == "padded description")
        #expect(map["https://host/b.jpg"] == nil)
        #expect(map["https://host/c.jpg"] == nil)
    }

    /// Kind-1 shape: the URL in `content` matches the imeta `url` exactly, so
    /// the classified image segment carries the description.
    @Test func imageSegmentFromContentUrlCarriesAlt() {
        let tags: [[String]] = [
            ["imeta", "url https://host/ae8469.jpg", "m image/jpeg", "alt TV test pattern"],
        ]
        let segments = ContentParser.parse(
            content: "test image with alt text\nhttps://host/ae8469.jpg",
            tags: tags
        )
        let alts = segments.compactMap { seg -> String? in
            if case .image(let meta) = seg { return meta.alt }
            return nil
        }
        #expect(alts == ["TV test pattern"])
    }

    /// The exact kind-1 event the on-device smoke test published (id
    /// 0ab89253…): relay-verified JSON pasted back into the repo. Proves the
    /// real-world shape — long blossom hostname, `dim` + `x` slots, `client`
    /// tag after the imeta — parses to an image segment carrying its alt.
    @Test func parsesTheOnDeviceSmokeTestEvent() {
        let content = "Scrubby need coffee!\nhttps://npub1sjvt6lzmhj66gc3tjc5l4g3uhxz5lhaf4tqe2c0n5m92a0amffxq7veejj.blossom.band/6810bff768069f4c466bf247cf8e6a6dad75fe54816bf4a594f0badc4ce187ca.jpg"
        let tags: [[String]] = [
            ["imeta",
             "url https://npub1sjvt6lzmhj66gc3tjc5l4g3uhxz5lhaf4tqe2c0n5m92a0amffxq7veejj.blossom.band/6810bff768069f4c466bf247cf8e6a6dad75fe54816bf4a594f0badc4ce187ca.jpg",
             "m image/jpeg",
             "dim 2048x1536",
             "x e36ae0fa78659eed8cb4d0efdaf9a5b5240720a885b33a824c0c63ad87fefa14",
             "alt Coffee coffee!"],
            ["client", "Zap Cooking"],
        ]
        let segments = ContentParser.parse(content: content, tags: tags)
        let alts = segments.compactMap { seg -> String? in
            if case .image(let meta) = seg { return meta.alt }
            return nil
        }
        #expect(alts == ["Coffee coffee!"])
    }

    /// Gallery shape (kind 20/21/22): the body is caption-only and the imeta
    /// list is the authoritative media — the appended segment still carries
    /// the description.
    @Test func imageSegmentFromGalleryFallbackCarriesAlt() {
        let tags: [[String]] = [
            ["imeta", "url https://host/gallery.jpg", "m image/jpeg", "alt Sourdough crumb shot"],
        ]
        let segments = ContentParser.parse(content: "fresh loaf", tags: tags)
        let alts = segments.compactMap { seg -> String? in
            if case .image(let meta) = seg { return meta.alt }
            return nil
        }
        #expect(alts == ["Sourdough crumb shot"])
    }

    /// No imeta at all → `alt` stays nil, and MediaMeta construction without
    /// one keeps compiling (call sites that predate the field).
    @Test func mediaMetaWithoutImetaHasNilAlt() {
        let segments = ContentParser.parse(
            content: "https://host/plain.jpg",
            tags: []
        )
        let alts = segments.compactMap { seg -> String?? in
            if case .image(let meta) = seg { return meta.alt }
            return nil
        }
        #expect(alts == [nil])
    }

    // MARK: - §1 wire format (write path)

    /// Gallery publish: `url` stays the first slot, `alt` lands last, and a
    /// blank description emits no slot at all.
    @Test func nip68EmitsAltLastUrlFirst() {
        let media = [
            Nip68.ImetaEntry(url: "https://host/one.jpg", mimeType: "image/jpeg", dim: "100x100", hash: "aa", alt: "Sliced fruit"),
            Nip68.ImetaEntry(url: "https://host/two.jpg", mimeType: "image/jpeg", alt: "   "),
        ]
        let tags = Nip68.buildPictureTags(title: nil, media: media)
        #expect(tags[0] == ["imeta", "url https://host/one.jpg", "m image/jpeg", "dim 100x100", "x aa", "alt Sliced fruit"])
        // Undescribed image → a tag without an alt slot (gallery always
        // emits imeta per image; only the described slot comes and goes).
        #expect(tags[1] == ["imeta", "url https://host/two.jpg", "m image/jpeg"])
    }

    @Test func nip71EmitsAlt() {
        let media = [Nip71.VideoMeta(url: "https://host/v.mp4", mimeType: "video/mp4", duration: 12, alt: "Steam rising off rice")]
        let tags = Nip71.buildVideoTags(title: nil, media: media)
        #expect(tags[0] == ["imeta", "url https://host/v.mp4", "m video/mp4", "duration 12", "alt Steam rising off rice"])
    }

    /// Text-note publish: one imeta per **described** attachment only —
    /// undescribed attachments emit no tag (§3, no empty metadata).
    @Test func describedAttachmentsEmitImeta() {
        let described = ComposeAttachment(
            id: UUID(), url: "https://host/with.jpg", mime: "image/jpeg",
            dim: CGSize(width: 100, height: 50), durationSec: nil, sha256Hex: "cc",
            localBytes: nil, altText: "  Two eggs on rice  "
        )
        let undescribed = ComposeAttachment(
            id: UUID(), url: "https://host/without.jpg", mime: "image/jpeg",
            dim: .zero, durationSec: nil, sha256Hex: nil, localBytes: nil
        )
        let tags = ComposeViewModel.imetaTagsForDescribedAttachments([described, undescribed])
        #expect(tags == [["imeta", "url https://host/with.jpg", "m image/jpeg", "dim 100x50", "x cc", "alt Two eggs on rice"]])
    }

    /// Full tag build in text mode: the described attachment's imeta rides
    /// alongside the normal `t`/`p` tags.
    @Test func buildBaseTagsTextModeCarriesImeta() throws {
        let vm = ComposeViewModel(keypair: keypair)
        vm.content = "lunch"
        vm.attachments = [describedAttachment()]
        let tags = vm.buildBaseTags(kind: 1, materializedContent: "lunch\nhttps://host/with.jpg")
        let imetas = tags.filter { $0.first == "imeta" }
        #expect(imetas.count == 1)
        #expect(imetas[0].contains("alt Two eggs on rice"))
        // URL splicing into the body still happens (publish path adds it);
        // buildBaseTags doesn't own the body.
        #expect(tags.filter { $0.first == "t" }.isEmpty)
    }

    @Test func buildBaseTagsTextModeWithoutAltEmitsNoImeta() {
        let vm = ComposeViewModel(keypair: keypair)
        vm.content = "no description here"
        vm.attachments = [undescribedAttachment()]
        let tags = vm.buildBaseTags(kind: 1, materializedContent: "no description here")
        #expect(tags.filter { $0.first == "imeta" }.isEmpty)
    }

    @Test func buildBaseTagsGalleryCarriesAlt() {
        let vm = ComposeViewModel(keypair: keypair)
        vm.galleryMode = true
        vm.attachments = [describedAttachment()]
        let tags = vm.buildBaseTags(kind: Nip68.kindPicture, materializedContent: "caption")
        let imetas = tags.filter { $0.first == "imeta" }
        #expect(imetas.count == 1)
        #expect(imetas[0].contains("alt Two eggs on rice"))
    }

    // MARK: - Drafts round-trip (§3: persist alt keyed by URL)

    @Test func draftImetaRoundTripsAlt() throws {
        let draftTags: [[String]] = [
            ["imeta", "url https://host/with.jpg", "m image/jpeg", "dim 100x50", "alt TV test pattern"],
        ]
        let restored = ComposeViewModel.parseImetaAttachments(tags: draftTags)
        #expect(restored.count == 1)
        #expect(restored[0].url == "https://host/with.jpg")
        #expect(restored[0].trimmedAltText == "TV test pattern")

        // And back out through the builder the draft path uses.
        let rebuilt = ComposeViewModel.imetaTagsForDescribedAttachments(restored)
        #expect(rebuilt.count == 1)
        #expect(rebuilt[0].contains("alt TV test pattern"))
    }

    /// Local autosave regression: a description saved in the composer must
    /// survive the composer closing and reopening (the second instance
    /// replays the autosave bucket in its init). Before the fix the payload
    /// never serialized `alt`, so a reopen silently dropped it.
    @Test func autosaveRoundTripsAltText() {
        let kp = Keypair(privkey: String(repeating: "2", count: 64),
                         pubkey: String(repeating: "b", count: 64))
        let writer = ComposeViewModel(keypair: kp)
        writer.content = "with alt"
        writer.attachments = [ComposeAttachment(
            id: UUID(), url: "https://host/x.jpg", mime: "image/jpeg",
            dim: .zero, durationSec: nil, sha256Hex: nil,
            localBytes: nil, altText: "TV test pattern"
        )]
        writer.writeLocalAutosave()
        defer { writer.clearLocalAutosave() }

        let reader = ComposeViewModel(keypair: kp)
        #expect(reader.attachments.count == 1)
        #expect(reader.attachments.first?.trimmedAltText == "TV test pattern")
    }

    /// Undescribed attachments restore without inventing a description.
    @Test func autosaveRoundTripsMissingAltAsNil() {
        let kp = Keypair(privkey: String(repeating: "3", count: 64),
                         pubkey: String(repeating: "c", count: 64))
        let writer = ComposeViewModel(keypair: kp)
        writer.content = "no alt here"
        writer.attachments = [ComposeAttachment(
            id: UUID(), url: "https://host/y.jpg", mime: "image/jpeg",
            dim: .zero, durationSec: nil, sha256Hex: nil, localBytes: nil
        )]
        writer.writeLocalAutosave()
        defer { writer.clearLocalAutosave() }

        let reader = ComposeViewModel(keypair: kp)
        #expect(reader.attachments.first?.trimmedAltText == nil)
    }

    // MARK: - Line breaks (imeta alt linebreak contract)

    /// The reference normalization vectors: single breaks survive, runs cap
    /// at one paragraph gap, CRLF/CR normalizes, lines and ends trim.
    @Test func normalizeAltBreaksVectors() {
        #expect(ContentParser.normalizeAltBreaks("two\nlines") == "two\nlines")
        #expect(ContentParser.normalizeAltBreaks("a\n\n\n\n\nb") == "a\n\nb")
        #expect(ContentParser.normalizeAltBreaks("a\r\nb") == "a\nb")
        #expect(ContentParser.normalizeAltBreaks("a\rb") == "a\nb")
        #expect(ContentParser.normalizeAltBreaks("  first \n\n  second  ") == "first\n\nsecond")
        #expect(ContentParser.normalizeAltBreaks("   ") == "")
    }

    /// Publish path: a multiline description rides as real `\n` inside the
    /// tag string — never flattened to spaces.
    @Test func publishPreservesLineBreaksInAlt() {
        let described = ComposeAttachment(
            id: UUID(), url: "https://host/multi.jpg", mime: "image/jpeg",
            dim: .zero, durationSec: nil, sha256Hex: nil,
            localBytes: nil, altText: "A screenshot.\n\nBelow it, a quoted post."
        )
        let tags = ComposeViewModel.imetaTagsForDescribedAttachments([described])
        #expect(tags.count == 1)
        #expect(tags[0].last == "alt A screenshot.\n\nBelow it, a quoted post.")
    }

    /// Publish path: runaway break runs collapse to one paragraph gap and
    /// CRLF normalizes — authored structure survives, bloat doesn't.
    @Test func publishCapsBreakRunsAndNormalizesCRLF() {
        let described = ComposeAttachment(
            id: UUID(), url: "https://host/capped.jpg", mime: "image/jpeg",
            dim: .zero, durationSec: nil, sha256Hex: nil,
            localBytes: nil, altText: "a\r\n\n\n\n\nb"
        )
        let tags = ComposeViewModel.imetaTagsForDescribedAttachments([described])
        #expect(tags.count == 1)
        #expect(tags[0].last == "alt a\n\nb")
    }

    /// Read path: the slot splits on the first space only, so interior
    /// breaks survive the parse and reach every render surface.
    @Test func parseKeepsInteriorLineBreaks() {
        let tags: [[String]] = [
            ["imeta", "url https://host/multi.jpg", "m image/jpeg",
             "alt First paragraph\n\nSecond paragraph"],
        ]
        let segments = ContentParser.parse(content: "https://host/multi.jpg", tags: tags)
        let alts = segments.compactMap { seg -> String? in
            if case .image(let meta) = seg { return meta.alt }
            return nil
        }
        #expect(alts == ["First paragraph\n\nSecond paragraph"])
    }

    /// Read path: third-party alt with runaway break runs is capped at
    /// extraction too, so remote events can't balloon the layout.
    @Test func parseCapsRunawayBreakRuns() {
        let tags: [[String]] = [
            ["imeta", "url https://host/ballooning.jpg", "m image/jpeg",
             "alt a\n\n\n\n\n\nb"],
        ]
        let map = ContentParser.imetaAltByUrl(tags)
        #expect(map["https://host/ballooning.jpg"] == "a\n\nb")
    }

    // MARK: - Fixtures

    private let keypair = Keypair(privkey: String(repeating: "1", count: 64),
                                  pubkey: String(repeating: "a", count: 64))

    private func describedAttachment() -> ComposeAttachment {
        ComposeAttachment(
            id: UUID(), url: "https://host/with.jpg", mime: "image/jpeg",
            dim: CGSize(width: 100, height: 50), durationSec: nil, sha256Hex: "cc",
            localBytes: nil, altText: "  Two eggs on rice  "
        )
    }

    private func undescribedAttachment() -> ComposeAttachment {
        ComposeAttachment(
            id: UUID(), url: "https://host/without.jpg", mime: "image/jpeg",
            dim: .zero, durationSec: nil, sha256Hex: nil, localBytes: nil
        )
    }
}
