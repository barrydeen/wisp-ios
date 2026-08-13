import Foundation
import Testing
@testable import wisp

/// Covers `String.nip05DisplayString`, the presentation form of a NIP-05
/// identifier. The spec reserves the local part `_` for "this domain is the
/// whole identity", so `_@sidecar.top` should read as `@sidecar.top` rather
/// than leaking the placeholder underscore into the UI.
///
/// The rule is deliberately narrow — a literal `_@` prefix — because anything
/// looser would start rewriting ordinary identifiers, which is why the
/// near-miss cases below are pinned as unchanged.
struct Nip05DisplayTests {

    @Test func underscoreLocalPartBecomesABareHandle() {
        #expect("_@sidecar.top".nip05DisplayString == "@sidecar.top")
        #expect("_@example.com".nip05DisplayString == "@example.com")
    }

    // The `@` is kept. An earlier version in Nip05Badge stripped `_@` outright,
    // rendering "sidecar.top", which reads as a domain rather than a handle.
    @Test func theAtSignSurvives() {
        #expect("_@sidecar.top".nip05DisplayString.hasPrefix("@"))
    }

    @Test func ordinaryIdentifiersAreUntouched() {
        #expect("alice@example.com".nip05DisplayString == "alice@example.com")
        #expect("_alice@example.com".nip05DisplayString == "_alice@example.com")
        #expect("alice_@example.com".nip05DisplayString == "alice_@example.com")
        #expect("__@example.com".nip05DisplayString == "__@example.com")
    }

    // A bare "_" is not a NIP-05 identifier and has no `@` to keep, so it is
    // left alone rather than being emptied out.
    @Test func degenerateInputsAreLeftAlone() {
        #expect("".nip05DisplayString == "")
        #expect("_".nip05DisplayString == "_")
        #expect("@example.com".nip05DisplayString == "@example.com")
    }

    // Domains are case-insensitive but this helper is presentation only — it
    // must not normalize case, or a profile's own spelling would be rewritten.
    @Test func casingIsPreserved() {
        #expect("_@SideCar.Top".nip05DisplayString == "@SideCar.Top")
        #expect("Alice@Example.com".nip05DisplayString == "Alice@Example.com")
    }

    // Verification uses the raw identifier; only display goes through here.
    // Guards against someone later "simplifying" this into the resolver path.
    @Test func helperIsPurePresentationAndIdempotentOnItsOwnOutput() {
        let once = "_@sidecar.top".nip05DisplayString
        #expect(once.nip05DisplayString == once)
    }
}
