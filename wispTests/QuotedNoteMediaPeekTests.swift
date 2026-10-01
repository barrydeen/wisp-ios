//
//  QuotedNoteMediaPeekTests.swift
//  wispTests
//
//  Coverage for the collapsed-media peek on an embedded quote card
//  (`QuotedNoteView.mediaPeekHeight(forContentWidth:)`).
//
//  A quoted note carrying media is always collapsed, so for a SHORT-text
//  quote the peek is the only thing standing between the reader and the
//  image. The flat 80pt this used to inherit from `PostCardView` left a
//  ~48pt strip once the 32pt bottom fade was painted over it — enough to
//  say "there is a picture here", not enough to say what of. These tests
//  pin the peek to the card's own width so it stays a readable top section.
//

import Foundation
import SwiftUI
import Testing
@testable import wisp

@MainActor
struct QuotedNoteMediaPeekTests {

    /// Content width of a quote card embedded in a feed post on a 393pt-wide
    /// phone: the screen less `QuotedNoteView.nestedHorizontalInset`'s
    /// default 56 (16pt card padding + 12pt quoted padding, both doubled).
    private static let feedCardWidth: CGFloat = 393 - 56

    /// Height of the `LinearGradient` drawn over the bottom of the collapsed
    /// media portion. Pixels under it fade to the card background, so they
    /// don't count toward what the reader can actually make out.
    private static let bottomFadeHeight: CGFloat = 32

    /// What the peek was before it was keyed to width — also still
    /// `PostCardView`'s value, where a full text body sits above the strip
    /// and the strip only has to hint that media follows.
    private static let previousFlatPeek: CGFloat = 80

    @Test func peekShowsFarMoreThanTheOldFlatStrip() {
        let peek = QuotedNoteView.mediaPeekHeight(forContentWidth: Self.feedCardWidth)
        #expect(peek > Self.previousFlatPeek)
        // Even after the bottom fade, more is legible than the entire old peek.
        #expect(peek - Self.bottomFadeHeight > Self.previousFlatPeek)
    }

    /// The regression the peek exists to prevent in the other direction: a
    /// landscape photo is the common case for a short-text note, and it
    /// should simply render whole rather than being cropped at all.
    @Test func landscapePhotoClearsTheCapOutright() {
        let peek = QuotedNoteView.mediaPeekHeight(forContentWidth: Self.feedCardWidth)
        let sixteenByNine = Self.feedCardWidth * 9.0 / 16.0
        #expect(peek >= sixteenByNine)
    }

    /// A square photo is taller than the cap, so it gets cropped — but the
    /// surviving slice has to read as the top *section* of the image, not as
    /// a sliver. Anything under half the frame stops carrying the subject;
    /// the peek was raised to 0.8×width so a square shows most of the shot —
    /// the bound here only guards that some collapse remains at all.
    @Test func squarePhotoKeepsAReadableTopSection() {
        let peek = QuotedNoteView.mediaPeekHeight(forContentWidth: Self.feedCardWidth)
        let squareHeight = Self.feedCardWidth          // 1:1 at full card width
        #expect(peek < squareHeight)                   // still collapsed
        #expect(peek / squareHeight > 0.5)
        #expect(peek / squareHeight < 0.9)
    }

    /// A 4:5 portrait — the tall-card aspect `MediaGridView` snaps tiles to —
    /// is the worst case for a height cap. It must still clear the old flat
    /// peek by a wide margin.
    @Test func portraitPhotoStillShowsItsTop() {
        let peek = QuotedNoteView.mediaPeekHeight(forContentWidth: Self.feedCardWidth)
        let portraitHeight = Self.feedCardWidth * 5.0 / 4.0
        #expect(peek < portraitHeight)
        #expect(peek / portraitHeight > 0.4)
        #expect(peek > Self.previousFlatPeek * 2)
    }

    /// `NotificationRowView` indents quote cards further than the feed does
    /// and passes its own wider `nestedHorizontalInset`. The narrower card
    /// shows a proportionally shorter slice of the same photo — the same
    /// fraction of a smaller image, not an arbitrarily different crop.
    @Test func peekTracksTheCardWidthItSitsIn() {
        let wide = QuotedNoteView.mediaPeekHeight(forContentWidth: 337)
        let narrow = QuotedNoteView.mediaPeekHeight(forContentWidth: 280)
        #expect(narrow < wide)
        #expect(abs(narrow / 280 - wide / 337) < 0.0001)
    }

    @Test func peekScalesLinearlyWithWidth() {
        let single = QuotedNoteView.mediaPeekHeight(forContentWidth: 150)
        let double = QuotedNoteView.mediaPeekHeight(forContentWidth: 300)
        #expect(abs(double - single * 2) < 0.0001)
    }

    /// A zero or negative width can only come from chrome wider than the
    /// screen, but a non-positive frame height collapses the media portion
    /// to nothing — the exact symptom this peek is meant to cure — so the
    /// floor has to hold.
    @Test func degenerateWidthsStayPositive() {
        #expect(QuotedNoteView.mediaPeekHeight(forContentWidth: 0) > 0)
        #expect(QuotedNoteView.mediaPeekHeight(forContentWidth: -400) > 0)
    }
}
