import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// State machine for the NIP-46 login screen.
///
/// Two paths share one screen:
///   1. **Bunker** — user pastes a `bunker://` URI obtained from their signer
///      (Clave, Primal, Amber). We perform `connect` + `get_public_key`
///      and finish.
///   2. **Nostrconnect** — we generate an ephemeral `nostrconnect://` URI and
///      a QR code; the user scans it (or pastes it into) their signer
///      (Clave, Primal mobile, Amber). We listen on relays for the signer's
///      `connect` response, then `get_public_key`.
@MainActor
@Observable
final class Nip46LoginViewModel {

    enum Mode: String, CaseIterable, Identifiable {
        case bunker
        case nostrconnect
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bunker: return "Paste bunker URI"
            case .nostrconnect: return "Connect via QR"
            }
        }
    }

    enum Status: Equatable {
        case idle
        case connecting(String)         // human-readable progress
        case awaitingApproval           // nostrconnect URI shown
        case error(String)
        case connected(pubkey: String)
    }

    var mode: Mode = .bunker
    var bunkerURIInput: String = ""
    var status: Status = .idle

    /// nostrconnect URI we display as a QR code while waiting for the signer.
    /// Cleared when the handshake finishes or aborts.
    var pendingURI: String?

    private var pendingHandshake: Nip46Manager.NostrConnectPending?
    private var handshakeTask: Task<Void, Never>?

    var isWorking: Bool {
        if case .connecting = status { return true }
        if case .awaitingApproval = status { return true }
        return false
    }

    var displayError: String? {
        if case .error(let s) = status { return s } else { return nil }
    }

    // MARK: - Bunker

    /// Submit the pasted bunker URI. Triggers `connect` + `get_public_key`
    /// against the signer; on success, persists the session, marks the
    /// active account as remote, and sets `status = .connected(pubkey:)`.
    func submitBunker() async {
        let trimmed = bunkerURIInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Nip46.parseBunker(trimmed) != nil else {
            status = .error("Not a valid bunker:// URI")
            return
        }
        status = .connecting("Connecting to signer…")
        do {
            let userPubkey = try await Nip46Manager.shared.connectBunker(uri: trimmed)
            NostrKey.saveRemote(pubkey: userPubkey)
            status = .connected(pubkey: userPubkey)
        } catch {
            status = .error(formatError(error))
        }
    }

    // MARK: - Nostrconnect

    /// Generate the URI and start listening. The view should display
    /// `pendingURI` as a QR + copy button while `isWorking` is true.
    func startNostrConnect() {
        cancelPendingHandshake()
        do {
            let pending = try Nip46Manager.shared.prepareNostrConnect()
            self.pendingHandshake = pending
            self.pendingURI = pending.uri
            self.status = .awaitingApproval

            handshakeTask = Task { [weak self] in
                guard let self else { return }
                await self.runHandshake(pending: pending)
            }
        } catch {
            status = .error(formatError(error))
        }
    }

    private func runHandshake(pending: Nip46Manager.NostrConnectPending) async {
        do {
            let userPubkey = try await Nip46Manager.shared.awaitNostrConnectHandshake(pending)
            // The handshake task may have been cancelled (e.g. user backed out).
            if Task.isCancelled { return }
            NostrKey.saveRemote(pubkey: userPubkey)
            status = .connected(pubkey: userPubkey)
            pendingURI = nil
            pendingHandshake = nil
        } catch {
            if Task.isCancelled { return }
            status = .error(formatError(error))
            pendingURI = nil
            pendingHandshake = nil
        }
    }

    /// Cancel any in-flight handshake (e.g. user dismisses the sheet).
    func cancelPendingHandshake() {
        handshakeTask?.cancel()
        handshakeTask = nil
        pendingHandshake = nil
        pendingURI = nil
    }

    // MARK: - Misc

    func copyURIToPasteboard() {
        guard let uri = pendingURI else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = uri
        #endif
    }

    private func formatError(_ error: Error) -> String {
        if let e = error as? Nip46.NipError { return e.description }
        if let e = error as? Signer.SignerError { return e.description }
        return error.localizedDescription
    }
}
