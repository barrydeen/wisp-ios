import Foundation
import Testing
@testable import wisp

/// The muted-content visibility setting and its session-scoped reveal store.
///
/// The rendering itself lives in SwiftUI views, but the two decisions those
/// views branch on — "does a placeholder render at all" and "may this one post
/// be revealed" — are pure and pinned here.
struct MutedContentDisplayTests {

    // MARK: - Mode semantics

    @Test func hiddenModeShowsNothingAndOffersNoReveal() {
        let mode = MutedContentDisplay.hidden
        #expect(!mode.showsPlaceholder)
        #expect(!mode.allowsReveal)
    }

    @Test func placeholderModeShowsTheRowButCannotBeSeenThrough() {
        let mode = MutedContentDisplay.placeholder
        #expect(mode.showsPlaceholder)
        #expect(!mode.allowsReveal)
    }

    @Test func revealModeShowsTheRowAndOffersReveal() {
        let mode = MutedContentDisplay.placeholderWithReveal
        #expect(mode.showsPlaceholder)
        #expect(mode.allowsReveal)
    }

    /// Reveal is only ever offered on top of a placeholder — a mode that hides
    /// the row entirely must never expose a way through it.
    @Test func revealIsNeverOfferedWithoutAPlaceholder() {
        for mode in MutedContentDisplay.allCases where mode.allowsReveal {
            #expect(mode.showsPlaceholder)
        }
    }

    @Test func everyModeIsLabelledAndExplained() {
        for mode in MutedContentDisplay.allCases {
            #expect(!mode.label.isEmpty)
            #expect(!mode.detail.isEmpty)
        }
    }

    /// The raw values are the persisted UserDefaults representation — changing
    /// one silently resets that account's choice back to the default.
    @Test func rawValuesAreStableAcrossLaunches() {
        #expect(MutedContentDisplay(rawValue: "hidden") == .hidden)
        #expect(MutedContentDisplay(rawValue: "placeholder") == .placeholder)
        #expect(MutedContentDisplay(rawValue: "placeholderWithReveal") == .placeholderWithReveal)
        #expect(MutedContentDisplay(rawValue: "nonsense") == nil)
    }
}

@MainActor
struct MutedRevealStoreTests {

    /// Shared singleton — leave it as found so test order can't matter.
    private func withCleanStore(_ body: (MutedRevealStore) -> Void) {
        let store = MutedRevealStore.shared
        store.clear()
        body(store)
        store.clear()
    }

    @Test func revealingMarksOnlyThatPost() {
        withCleanStore { store in
            store.reveal("a")
            #expect(store.isRevealed("a"))
            #expect(!store.isRevealed("b"))
        }
    }

    @Test func hidingUndoesASingleReveal() {
        withCleanStore { store in
            store.reveal("a")
            store.reveal("b")
            store.hide(["a"])
            #expect(!store.isRevealed("a"))
            #expect(store.isRevealed("b"))
        }
    }

    /// Account switch and data wipe both call this: one identity's reveals
    /// must never carry into another's session.
    @Test func clearDropsEveryReveal() {
        withCleanStore { store in
            store.reveal("a")
            store.reveal("b")
            store.clear()
            #expect(!store.isRevealed("a"))
            #expect(!store.isRevealed("b"))
            #expect(store.revealedEventIds.isEmpty)
        }
    }

    @Test func revealingTwiceIsHarmless() {
        withCleanStore { store in
            store.reveal("a")
            store.reveal("a")
            #expect(store.revealedEventIds.count == 1)
        }
    }

    /// A thread drops its own reveals on the way out, so reopening it starts
    /// from hidden again.
    @Test func scopedHideDropsOnlyThatScope() {
        withCleanStore { store in
            store.reveal("threadPost1")
            store.reveal("threadPost2")
            store.reveal("feedQuote")
            store.hide(["threadPost1", "threadPost2"])
            #expect(!store.isRevealed("threadPost1"))
            #expect(!store.isRevealed("threadPost2"))
            // A reveal on another surface must survive leaving the thread.
            #expect(store.isRevealed("feedQuote"))
        }
    }

    @Test func scopedHideIgnoresIdsItDoesNotHold() {
        withCleanStore { store in
            store.reveal("a")
            store.hide(["b", "c"])
            #expect(store.isRevealed("a"))
        }
    }

    @Test func scopedHideOnAnEmptyStoreIsHarmless() {
        withCleanStore { store in
            store.hide(["a", "b"])
            #expect(store.revealedEventIds.isEmpty)
        }
    }

    @Test func nothingIsRevealedByDefault() {
        withCleanStore { store in
            #expect(store.revealedEventIds.isEmpty)
            #expect(!store.isRevealed("anything"))
        }
    }
}
