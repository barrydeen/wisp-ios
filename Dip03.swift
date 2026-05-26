import Foundation
import CryptoKit

/// Damus DIP-03 private zap envelope.
/// Spec: https://github.com/damus-io/dips/blob/master/03.md
///
/// Two privacy layers:
/// 1. Sender anonymity: the kind-9734 outer zap request is signed by a deterministic
///    ephemeral key (`sha256(senderPrivkeyHex || eventIdHex || createdAtString)`), not
///    the user's identity key. The real sender's identity travels encrypted inside
///    the `anon` tag.
/// 2. Amount + recipient privacy: the outer relays list points to DM-only relays so
///    public infrastructure (LNURL operator, indexers) can't correlate the receipt
///    back to the recipient/note pair.
///
/// `anon` tag format: `pzap1<bech32-ciphertext>_iv1<bech32-iv>`
/// Inner kind-9733 event signs by real sender; AES-CBC encrypted under
/// ECDH(ephemeralPriv, recipientPub).
///
/// Deterministic ephemeral derivation lets the sender re-derive their ephemeral
/// privkey later to decrypt the inner event from their own outgoing receipts —
/// without it, a sender couldn't see their own transaction history.
nonisolated enum Dip03 {

    enum Error: Swift.Error {
        case malformedAnonTag
        case wrongHrp
        case decryptFailed
        case innerParseFailed
        case ephemeralMismatch
    }

    /// Inner kind-9733 zap_request kind. Outer is kind-9734 like a public zap.
    static let kindPrivateZapRequest = 9733

    /// Derive the deterministic ephemeral private key for a private zap.
    /// Same `(senderPriv, eventId, createdAt)` always produces the same ephemeral
    /// key — so the sender can decrypt their own outgoing receipts.
    ///
    /// `senderPrivkey32`: raw 32-byte privkey.
    /// `targetEventId`: hex-encoded 32-byte event id of the note being zapped.
    /// `createdAt`: outer kind-9734 `created_at` (and the inner kind-9733's
    /// timestamp — both share this value to keep the derivation reproducible).
    static func deriveEphemeralPrivkey(
        senderPrivkey32: Data,
        targetEventId: String,
        createdAt: Int
    ) -> Data {
        var input = Data()
        input.append(Data(Hex.encode(senderPrivkey32).utf8))
        input.append(Data(targetEventId.lowercased().utf8))
        input.append(Data(String(createdAt).utf8))
        return Data(SHA256.hash(data: input))
    }

    /// Encrypt the inner kind-9733 (already-signed) JSON for `recipientPubkey32`
    /// using ECDH(ephemeralPriv, recipientPub) → raw AES-256-CBC. Returns the
    /// bech32-packed anon-tag value (no `["anon", ...]` framing — caller appends
    /// that to the outer event).
    static func encryptInner(
        innerJSON: String,
        ephemeralPrivkey32: Data,
        recipientPubkey32: Data
    ) throws -> String {
        let shared = try Nip04.sharedSecret(
            privkey32: ephemeralPrivkey32,
            peerXonlyPubkey32: recipientPubkey32
        )
        let (ct, iv) = try Nip04.encryptRaw(innerJSON, sharedSecret: shared)
        let ctBech = Bech32.encode(hrp: "pzap", data: ct)
        let ivBech = Bech32.encode(hrp: "iv", data: iv)
        return "\(ctBech)_\(ivBech)"
    }

    /// Recipient-side decrypt: given the receipt's `anon` value, the receiver's
    /// privkey, and the ephemeral pubkey (which is the outer kind-9734 author),
    /// recover the signed inner kind-9733 event. The caller still needs to
    /// verify the inner Schnorr signature — `anon` tag is otherwise
    /// unauthenticated (a malicious LNURL operator could re-pack a fake inner).
    static func decryptInner(
        anonValue: String,
        recipientPrivkey32: Data,
        ephemeralPubkey32: Data
    ) throws -> NostrEvent {
        let (ct, iv) = try unpackAnonTag(anonValue)
        let shared = try Nip04.sharedSecret(
            privkey32: recipientPrivkey32,
            peerXonlyPubkey32: ephemeralPubkey32
        )
        let json: String
        do { json = try Nip04.decryptRaw(ciphertext: ct, iv: iv, sharedSecret: shared) }
        catch { throw Error.decryptFailed }
        guard let event = NostrEvent.fromJSON(json), event.kind == kindPrivateZapRequest else {
            throw Error.innerParseFailed
        }
        return event
    }

    /// Self-attribution decrypt: given the receipt's `anon` value and the
    /// *sender's* privkey + target event metadata, recover the inner kind-9733
    /// that we sent. Used by sender's transaction history + engagement
    /// processor to attribute the zap back to ourselves without exposing the
    /// real sender on the outer kind-9734.
    ///
    /// Verifies the receipt's outer pubkey matches the re-derived ephemeral
    /// pubkey — without that check, anyone could trick us into decoding a
    /// random anon tag as if it were our outgoing zap.
    static func decryptInnerSelfAttribution(
        anonValue: String,
        senderPrivkey32: Data,
        targetEventId: String,
        createdAt: Int,
        receiptOuterPubkey32: Data,
        recipientPubkey32: Data
    ) throws -> NostrEvent {
        let ephemeralPriv = deriveEphemeralPrivkey(
            senderPrivkey32: senderPrivkey32,
            targetEventId: targetEventId,
            createdAt: createdAt
        )
        let ephemeralPub = try Schnorr.xonlyPubkey(privkey32: ephemeralPriv)
        guard ephemeralPub == receiptOuterPubkey32 else { throw Error.ephemeralMismatch }
        // We had the privkey; the recipient's pubkey is what we encrypted to.
        let shared = try Nip04.sharedSecret(
            privkey32: ephemeralPriv,
            peerXonlyPubkey32: recipientPubkey32
        )
        let (ct, iv) = try unpackAnonTag(anonValue)
        let json: String
        do { json = try Nip04.decryptRaw(ciphertext: ct, iv: iv, sharedSecret: shared) }
        catch { throw Error.decryptFailed }
        guard let event = NostrEvent.fromJSON(json), event.kind == kindPrivateZapRequest else {
            throw Error.innerParseFailed
        }
        return event
    }

    /// True when `anonValue` looks like a DIP-03 packed `pzap1..._iv1...`
    /// envelope. Cheap structural check — no decryption attempted. Used by
    /// classifyZap to decide whether to attempt DIP-03 decode vs render as
    /// public.
    static func isDip03AnonValue(_ anonValue: String) -> Bool {
        guard let underscore = anonValue.firstIndex(of: "_") else { return false }
        let ct = anonValue[..<underscore]
        let ivStart = anonValue.index(after: underscore)
        let iv = anonValue[ivStart...]
        return ct.hasPrefix("pzap1") && iv.hasPrefix("iv1")
    }

    // MARK: - Private

    private static func unpackAnonTag(_ value: String) throws -> (Data, Data) {
        guard let underscore = value.firstIndex(of: "_") else { throw Error.malformedAnonTag }
        let ctStr = String(value[..<underscore])
        let ivStart = value.index(after: underscore)
        let ivStr = String(value[ivStart...])

        guard let (ctHrp, ct) = Bech32.decode(ctStr) else { throw Error.malformedAnonTag }
        guard ctHrp == "pzap" else { throw Error.wrongHrp }
        guard let (ivHrp, iv) = Bech32.decode(ivStr) else { throw Error.malformedAnonTag }
        guard ivHrp == "iv" else { throw Error.wrongHrp }
        guard iv.count == 16 else { throw Error.malformedAnonTag }
        return (ct, iv)
    }
}
