import Foundation
import Testing
@testable import wisp

/// End-to-end cover for the recovery path. `PostPublisherDraftRecoveryTests`
/// exercises the restore / clear rules in isolation; these drive the real
/// `PostPublisher.shared` against an unreachable relay so a future refactor
/// can't leave those helpers correct but unwired. Serialized: the publisher is
/// a process-global singleton.
@MainActor
@Suite(.serialized)
struct PostPublisherPublishPathTests {

    private func makeDraft(content: String, key: String, pow: Bool) -> PreparedDraft {
        PreparedDraft(
            kind: 1,
            tags: [],
            createdAt: Int(Date().timeIntervalSince1970),
            content: content,
            signingKeypair: Keypair(privkey: String(repeating: "1", count: 64),
                                    pubkey: String(repeating: "2", count: 64)),
            powEnabled: pow,
            powDifficulty: pow ? 32 : 0,
            relays: ["wss://127.0.0.1:1"],
            autosaveKey: key,
            autosaveSnapshot: ComposeAutosaveSnapshot(
                payload: ["content": content, "explicit": false, "powEnabled": pow]),
            draftIdToClear: nil
        )
    }

    private func waitFor(_ timeout: TimeInterval, _ cond: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return cond()
    }

    @Test func rejectedPostLandsBackInTheComposerBucket() async {
        let key = "compose_autosave_new_smoke_\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let publisher = PostPublisher.shared

        publisher.submit(makeDraft(content: "rejected post body", key: key, pow: false))

        let failed = await waitFor(20) {
            if case .failed = publisher.phase { return true }
            return false
        }
        #expect(failed, "expected .failed, got \(publisher.phase)")
        let restored = UserDefaults.standard.dictionary(forKey: key)
        #expect(restored?["content"] as? String == "rejected post body")
        #expect(publisher.canRetry)
        publisher.dismiss()
    }

    @Test func stoppingMiningLandsBackInTheComposerBucket() async {
        let key = "compose_autosave_new_smoke_\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let publisher = PostPublisher.shared

        publisher.submit(makeDraft(content: "mining post body", key: key, pow: true))

        let mining = await waitFor(20) {
            if case .mining = publisher.phase { return true }
            return false
        }
        #expect(mining, "expected .mining, got \(publisher.phase)")
        publisher.cancel()

        #expect(publisher.phase == .stopped)
        let restored = UserDefaults.standard.dictionary(forKey: key)
        #expect(restored?["content"] as? String == "mining post body")
        #expect(publisher.canRetry)
        publisher.dismiss()
    }
}
