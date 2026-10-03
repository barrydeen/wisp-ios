import Foundation
import Testing
@testable import wisp

/// The Sidecar-style kind header shown in the details drawer
/// ("KIND 1111 · COMMENT"): the number is always present, known kinds add a
/// human word, unknown kinds degrade to the bare number.
struct EventKindLabelTests {

    @Test func commentKind() {
        #expect(EventKindLabel.label(for: 1111) == "KIND 1111 · COMMENT")
    }

    @Test func commonKinds() {
        #expect(EventKindLabel.label(for: 1) == "KIND 1 · NOTE")
        #expect(EventKindLabel.label(for: 6) == "KIND 6 · REPOST")
        #expect(EventKindLabel.label(for: 7) == "KIND 7 · REACTION")
        #expect(EventKindLabel.label(for: 1068) == "KIND 1068 · POLL")
        #expect(EventKindLabel.label(for: 30023) == "KIND 30023 · ARTICLE")
    }

    @Test func unknownKindKeepsJustTheNumber() {
        #expect(EventKindLabel.label(for: 42) == "KIND 42")
        #expect(EventKindLabel.label(for: 99999) == "KIND 99999")
    }
}
