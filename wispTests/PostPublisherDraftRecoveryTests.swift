import Foundation
import Testing
@testable import wisp

/// Covers the draft-recovery rules `PostPublisher` applies when a post is
/// rejected by every relay, or when the user stops mining: the composer's
/// autosave bucket is refilled from the draft's snapshot, and a later success
/// only clears the bucket while it still holds that same draft.
@MainActor
struct PostPublisherDraftRecoveryTests {

    private static let key = "compose_autosave_new_testpubkey"

    private func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeDraft(
        content: String,
        key: String? = PostPublisherDraftRecoveryTests.key,
        snapshot: Bool = true
    ) -> PreparedDraft {
        PreparedDraft(
            kind: 1,
            tags: [],
            createdAt: 1_800_000_000,
            content: content,
            signingKeypair: Keypair(privkey: String(repeating: "1", count: 64),
                                    pubkey: String(repeating: "2", count: 64)),
            powEnabled: false,
            powDifficulty: 0,
            relays: ["wss://relay.example"],
            autosaveKey: key,
            autosaveSnapshot: snapshot
                ? ComposeAutosaveSnapshot(payload: ["content": content, "explicit": false, "powEnabled": false])
                : nil,
            draftIdToClear: nil
        )
    }

    // MARK: - Restore

    @Test func restoreRefillsAnEmptyBucket() {
        let defaults = makeDefaults()
        let draft = makeDraft(content: "the post that never landed")

        #expect(PostPublisher.restoreDraftForEditing(draft, defaults: defaults))
        #expect(defaults.dictionary(forKey: Self.key)?["content"] as? String == "the post that never landed")
    }

    /// The pill can sit on a failure long enough for the user to start typing
    /// something else in the same composer slot. Restoring over that would trade
    /// one lost draft for another — Retry still holds the publisher's own copy.
    @Test func restoreLeavesANewerDraftAlone() {
        let defaults = makeDefaults()
        defaults.set(["content": "something else entirely"], forKey: Self.key)

        #expect(PostPublisher.restoreDraftForEditing(makeDraft(content: "old"), defaults: defaults) == false)
        #expect(defaults.dictionary(forKey: Self.key)?["content"] as? String == "something else entirely")
    }

    /// Composers that never autosave (private replies, draft-backed composers)
    /// hand over a nil snapshot and must not materialize a bucket.
    @Test func restoreIsANoOpWithoutASnapshot() {
        let defaults = makeDefaults()

        #expect(PostPublisher.restoreDraftForEditing(makeDraft(content: "x", snapshot: false), defaults: defaults) == false)
        #expect(defaults.dictionary(forKey: Self.key) == nil)
    }

    // MARK: - Clear on success

    @Test func successClearsTheRestoredDraft() {
        let defaults = makeDefaults()
        let draft = makeDraft(content: "retried and landed")
        #expect(PostPublisher.restoreDraftForEditing(draft, defaults: defaults))

        #expect(PostPublisher.clearAutosaveIfStillThisDraft(draft, defaults: defaults))
        #expect(defaults.dictionary(forKey: Self.key) == nil)
    }

    /// A retry that succeeds after the user has moved on must leave their newer
    /// draft in place.
    @Test func successKeepsANewerDraft() {
        let defaults = makeDefaults()
        defaults.set(["content": "a different post"], forKey: Self.key)

        #expect(PostPublisher.clearAutosaveIfStillThisDraft(makeDraft(content: "old"), defaults: defaults) == false)
        #expect(defaults.dictionary(forKey: Self.key)?["content"] as? String == "a different post")
    }

    /// The common path: the composer already emptied the bucket at hand-off, so
    /// there is nothing left to clear.
    @Test func successOnAnEmptyBucketIsANoOp() {
        let defaults = makeDefaults()

        #expect(PostPublisher.clearAutosaveIfStillThisDraft(makeDraft(content: "x"), defaults: defaults) == false)
    }

    @Test func draftWithoutAnAutosaveKeyIsSkippedBothWays() {
        let defaults = makeDefaults()
        let draft = makeDraft(content: "x", key: nil)

        #expect(PostPublisher.restoreDraftForEditing(draft, defaults: defaults) == false)
        #expect(PostPublisher.clearAutosaveIfStillThisDraft(draft, defaults: defaults) == false)
    }
}
