import Foundation
import Testing
@testable import wisp

/// The same NIP-22 handling, exercised against real relay bytes rather than
/// a hand-built fixture.
///
/// `Resources/nip22/sidecar-thread.json` is the tail of the conversation
/// Sidecar documented in dmnyc/sidecar#326, re-fetched from public relays on
/// 2026-09-22 — four kind-1111 comments, signatures as published. The two
/// kind-1 events that root the thread had already been dropped by every
/// relay queried, which is its own argument for reading comments properly:
/// the comments outlived the notes they hang off.
struct Nip22RealThreadTests {

    /// Chronological, oldest first.
    private static let events: [NostrEvent] = {
        // Synchronized folders can flatten or preserve the subdirectory, and
        // the resource may land in either bundle — try both, as NSpamTests
        // does for its model files.
        let candidates = [Bundle(for: BundleToken.self), Bundle.main].flatMap { bundle in
            [bundle.url(forResource: "sidecar-thread", withExtension: "json", subdirectory: "nip22"),
             bundle.url(forResource: "sidecar-thread", withExtension: "json")]
        }
        guard let url = candidates.compactMap({ $0 }).first,
              let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return raw.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let pubkey = dict["pubkey"] as? String,
                  let kind = dict["kind"] as? Int,
                  let createdAt = dict["created_at"] as? Int,
                  let tags = dict["tags"] as? [[String]],
                  let content = dict["content"] as? String,
                  let sig = dict["sig"] as? String else { return nil }
            return NostrEvent(id: id, pubkey: pubkey, kind: kind,
                              createdAt: createdAt, tags: tags, content: content, sig: sig)
        }.sorted { $0.createdAt < $1.createdAt }
    }()

    private final class BundleToken {}

    /// First value of the first tag with this exact name — mirrors
    /// `Nip22.tagValue`, which is private.
    private static func tagValue(_ event: NostrEvent, _ name: String) -> String? {
        event.tags.first(where: { $0.count >= 2 && $0[0] == name })?[1]
    }

    @Test func fixture_loaded() {
        #expect(Self.events.count == 4, "fixture did not load")
        #expect(Self.events.allSatisfy { $0.kind == Nip22.kindComment })
    }

    /// Every comment is rooted on a **kind-1** note. This is the case the
    /// external-only `I` reader could not see at all — and the reason these
    /// were invisible to counting.
    @Test func everyComment_isRootedOnAKind1Note() {
        for e in Self.events {
            #expect(Self.tagValue(e, "K") == "1", "\(e.id.prefix(8))")
            #expect(Nip22.rootEventId(of: e) != nil, "\(e.id.prefix(8))")
            // Rooted on an event, so the external accessors stay quiet.
            #expect(Nip22.externalRoot(of: e) == nil, "\(e.id.prefix(8))")
        }
        // All four hang off the same root.
        #expect(Set(Self.events.compactMap { Nip22.rootEventId(of: $0) }).count == 1)
    }

    /// The parent chain walks back one event at a time, and `k` flips from
    /// 1 to 1111 at the switch — which is exactly the signal the caption
    /// reads.
    @Test func parentChain_walksBackAndFlipsKind() {
        let ids = Self.events.map(\.id)
        let parents = Self.events.map { Nip22.parentEventId(of: $0) }
        // Each comment after the first names its predecessor.
        for i in 1..<Self.events.count {
            #expect(parents[i] == ids[i - 1],
                    "comment \(i) should answer \(ids[i - 1].prefix(8)), got \(parents[i]?.prefix(8) ?? "nil")")
        }
        // The first answered a note; the rest answered comments.
        #expect(Self.tagValue(Self.events[0], "k") == "1")
        for e in Self.events.dropFirst() {
            #expect(Self.tagValue(e, "k") == String(Nip22.kindComment), "\(e.id.prefix(8))")
        }
    }

    // MARK: - Thread display (the `#e`-only subscription gap)

    /// Every comment in the chain belongs on the thread screen through its
    /// uppercase `E` root — including the nested ones a lowercase-`e` check
    /// rejects, because their `e` names the parent comment, not the root.
    /// This is the ingest guard `ThreadViewModel`'s live stream now uses;
    /// before it existed, everything below the first reply never rendered.
    @Test func realChain_threadsOffRootAtEveryDepth() throws {
        let root = try #require(Nip22.rootEventId(of: Self.events[0]))
        let targets: Set<String> = [root]
        for e in Self.events {
            #expect(Nip22.threadsOffRoot(e, targets: targets), "\(e.id.prefix(8))")
        }
        // A stranger's comment naming none of the thread's ids stays out.
        let unrelated = NostrEvent(
            id: "x", pubkey: "pk", kind: Nip22.kindComment, createdAt: 0,
            tags: [["E", "other-root", "", "pk"], ["e", "other-parent", "", "pk"]],
            content: "", sig: ""
        )
        #expect(!Nip22.threadsOffRoot(unrelated, targets: targets))
    }

    /// A thread opened on a nested comment must re-root at the conversation
    /// root (uppercase `E`), not at the comment's immediate parent —
    /// `Nip10.rootId` is what `ThreadViewModel.seedFromCache` and
    /// `fetchRoot` consult, and it used to read only lowercase `e`.
    @Test func realChain_nip10RootResolvesToTheConversationRoot() throws {
        let root = try #require(Nip22.rootEventId(of: Self.events[0]))
        for e in Self.events {
            #expect(Nip10.rootId(of: e) == root, "\(e.id.prefix(8))")
        }
    }

    /// Replying to the deepest comment: kind 1111 with the root scope carried
    /// verbatim and the lowercase side pointing at that comment. This is what
    /// the composer now publishes where it used to publish a kind-1.
    @Test func replyToDeepestComment_carriesRootScopeForward() throws {
        let deepest = Self.events[3]
        let root = try #require(Nip22.rootEventId(of: deepest))
        let tags = try #require(Nip22.buildReplyTags(to: deepest))
        #expect(tags.contains { $0.count >= 2 && $0[0] == "E" && $0[1] == root })
        #expect(tags.contains { $0.count >= 2 && $0[0] == "K" && $0[1] == "1" })
        #expect(tags.contains(["e", deepest.id, "", deepest.pubkey]))
        #expect(tags.contains(["k", String(Nip22.kindComment)]))
        #expect(tags.contains(["p", deepest.pubkey]))
        #expect(!tags.contains { $0.count >= 4 && $0[0] == "e" && ($0[3] == "root" || $0[3] == "reply") })
    }
}
