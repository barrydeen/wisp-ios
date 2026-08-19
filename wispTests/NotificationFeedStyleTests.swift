import Foundation
import Testing
@testable import wisp

/// Covers `NotificationsViewModel`'s per-row expansion resolution against the
/// two list styles, plus the `AppSettings` round-trip behind them.
///
/// The two styles invert each other's storage: `.expanded` tracks the rows the
/// user folded *shut* (`collapsedItemIds`, no accordion — folding one leaves the
/// rest open), `.compact` tracks the single row they opened (`expandedItemId`).
/// Getting that inversion wrong reads as rows randomly ignoring taps, which is
/// exactly the kind of thing a test pins down cheaply.
@MainActor
struct NotificationFeedStyleTests {

    /// `feedStyle` reads the `AppSettings` singleton, which persists to
    /// UserDefaults, so each test restores whatever the host had.
    private func withStyle(
        _ style: AppSettings.NotificationFeedStyle,
        _ body: (NotificationsViewModel) -> Void
    ) {
        let original = AppSettings.shared.notificationFeedStyle
        defer { AppSettings.shared.notificationFeedStyle = original }
        AppSettings.shared.notificationFeedStyle = style
        let vm = NotificationsViewModel(
            keypair: Keypair(privkey: String(repeating: "1", count: 64),
                             pubkey: String(repeating: "a", count: 64))
        )
        body(vm)
    }

    @Test func expandedOpensEveryRowByDefault() {
        withStyle(.expanded) { vm in
            #expect(vm.isRowExpanded("row-a"))
            #expect(vm.isRowExpanded("never-seen-before"))
        }
    }

    @Test func compactOpensNothingByDefault() {
        withStyle(.compact) { vm in
            #expect(!vm.isRowExpanded("row-a"))
        }
    }

    // Folding one row in the expanded feed must not disturb the others — that
    // is the whole difference from the accordion.
    @Test func expandedFoldsOneRowWithoutClosingTheRest() {
        withStyle(.expanded) { vm in
            vm.toggleRowExpansion("row-a")
            #expect(!vm.isRowExpanded("row-a"))
            #expect(vm.isRowExpanded("row-b"))
            vm.toggleRowExpansion("row-a")
            #expect(vm.isRowExpanded("row-a"))
        }
    }

    @Test func compactKeepsOnlyOneRowOpen() {
        withStyle(.compact) { vm in
            vm.toggleRowExpansion("row-a")
            #expect(vm.isRowExpanded("row-a"))
            vm.toggleRowExpansion("row-b")
            #expect(vm.isRowExpanded("row-b"))
            #expect(!vm.isRowExpanded("row-a"), "opening a second row must close the first")
            vm.toggleRowExpansion("row-b")
            #expect(!vm.isRowExpanded("row-b"), "tapping the open row closes it")
        }
    }

    // Overrides accumulated under one style are meaningless under the other:
    // a row folded shut in expanded shouldn't come back as the compact
    // accordion's open row, and vice versa.
    @Test func switchingStyleResetsPerRowOverrides() {
        withStyle(.expanded) { vm in
            vm.toggleRowExpansion("row-a")          // folded shut
            #expect(!vm.isRowExpanded("row-a"))
            vm.setFeedStyle(.compact)
            #expect(vm.collapsedItemIds.isEmpty)
            #expect(vm.expandedItemId == nil)
            #expect(!vm.isRowExpanded("row-a"))    // compact baseline: all shut

            vm.toggleRowExpansion("row-a")          // opened
            vm.setFeedStyle(.expanded)
            #expect(vm.expandedItemId == nil)
            #expect(vm.collapsedItemIds.isEmpty)
            #expect(vm.isRowExpanded("row-a"))     // expanded baseline: all open
        }
    }

    @Test func setFeedStylePersistsToSettings() {
        withStyle(.expanded) { vm in
            vm.setFeedStyle(.compact)
            #expect(AppSettings.shared.notificationFeedStyle == .compact)
            #expect(vm.feedStyle == .compact)
        }
    }

    @Test func styleRawValuesRoundTrip() {
        for style in AppSettings.NotificationFeedStyle.allCases {
            #expect(AppSettings.NotificationFeedStyle(rawValue: style.rawValue) == style)
            #expect(!style.label.isEmpty)
        }
        // The default is what the whole change is about.
        #expect(AppSettings.NotificationFeedStyle(rawValue: "nonsense") == nil)
    }
}
