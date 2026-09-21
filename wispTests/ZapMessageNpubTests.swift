import Foundation
import Testing
@testable import wisp

/// Zap messages are free-form text and some clients embed the sender's npub
/// in them ("From: nostr:npub1…"). The pill and the details panel resolve
/// those references to profile display names — these tests pin the
/// replacement rules: mention-shaped tokens resolve, lookalikes (blossom
/// subdomains, undecodable bech32) pass through untouched.
@MainActor
struct ZapMessageNpubTests {

    private let pubkeyHex = "1111111111111111111111111111111111111111111111111111111111111111"

    private func makeNpub(_ hex: String) -> String {
        let bytes = Array(Hex.decode(hex)!)
        return Nip19.npubEncode(pubkey: bytes)!
    }

    private func makeNprofile(_ hex: String) -> String {
        let bytes = Array(Hex.decode(hex)!)
        return Nip19.nprofileEncode(pubkey32: bytes)!
    }

    private func satoshi(_ hex: String) -> ProfileData {
        ProfileData(pubkey: hex, json: ["display_name": "Satoshi"])
    }

    @Test func nostrNpubInFromMessageBecomesDisplayName() {
        let message = "From: nostr:\(makeNpub(pubkeyHex))"
        let resolved = Nip57.resolvingNpubUsernames(in: message, profiles: [pubkeyHex: satoshi(pubkeyHex)])
        #expect(resolved == "From: Satoshi")
    }

    @Test func bareNpubResolves() {
        let message = "zap from \(makeNpub(pubkeyHex)) enjoy"
        let resolved = Nip57.resolvingNpubUsernames(in: message, profiles: [pubkeyHex: satoshi(pubkeyHex)])
        #expect(resolved == "zap from Satoshi enjoy")
    }

    @Test func nprofileMentionResolves() {
        let message = "hey \(makeNprofile(pubkeyHex))!"
        let resolved = Nip57.resolvingNpubUsernames(in: message, profiles: [pubkeyHex: satoshi(pubkeyHex)])
        #expect(resolved == "hey Satoshi!")
    }

    @Test func unknownNpubFallsBackToShortNpub() {
        let unknownHex = "efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef"
        let npub = makeNpub(unknownHex)
        let resolved = Nip57.resolvingNpubUsernames(in: "From: \(npub)", profiles: [:])
        // Not left as the full bech32, and shaped like Nip19's short form.
        #expect(resolved != "From: \(npub)")
        #expect(resolved.hasPrefix("From: npub1"))
        #expect(resolved.contains("\u{2026}"))
    }

    @Test func blossomHostnameUntouched() {
        let message = "https://\(makeNpub(pubkeyHex)).blossom.band/pic.jpg"
        let resolved = Nip57.resolvingNpubUsernames(in: message, profiles: [pubkeyHex: satoshi(pubkeyHex)])
        #expect(resolved == message)
    }

    @Test func undecodableNpubShapedTokenUntouched() {
        // 60+ base32 chars so the length rule matches, but an invalid
        // checksum — it must pass through instead of crashing the decode.
        let garbage = String(repeating: "z", count: 60)
        let message = "From: npub1\(garbage)"
        let resolved = Nip57.resolvingNpubUsernames(in: message, profiles: [:])
        #expect(resolved == message)
    }

    @Test func multipleMentionsAllResolve() {
        let otherHex = "2222222222222222222222222222222222222222222222222222222222222222"
        let message = "\(makeNpub(pubkeyHex)) zapped \(makeNpub(otherHex))"
        let resolved = Nip57.resolvingNpubUsernames(in: message, profiles: [
            pubkeyHex: satoshi(pubkeyHex),
            otherHex: ProfileData(pubkey: otherHex, json: ["name": "halfin"]),
        ])
        #expect(resolved == "Satoshi zapped halfin")
    }

    @Test func plainMessageFastPath() {
        #expect(Nip57.resolvingNpubUsernames(in: "gm", profiles: [:]) == "gm")
    }
}
