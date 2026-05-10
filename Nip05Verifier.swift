import Foundation
import Combine

enum Nip05Status: Sendable {
    case unknown
    case checking
    case verified
    case mismatch       // server responded but pubkey doesn't match
    case error          // network or parse failure
}

@MainActor
final class Nip05Verifier: ObservableObject {
    static let shared = Nip05Verifier()

    @Published private(set) var version: Int = 0
    private var statusByPubkey: [String: Nip05Status] = [:]
    private var inflight: Set<String> = []
    private var lastChecked: [String: Date] = [:]

    private let cacheTTL: TimeInterval = 6 * 3600

    func status(for pubkey: String) -> Nip05Status {
        statusByPubkey[pubkey] ?? .unknown
    }

    /// Idempotent: kicks off verification if not already cached/inflight.
    func checkOrFetch(pubkey: String, nip05: String) {
        guard !nip05.isEmpty else { return }
        if inflight.contains(pubkey) { return }
        if let last = lastChecked[pubkey], Date().timeIntervalSince(last) < cacheTTL,
           let s = statusByPubkey[pubkey], s != .error {
            return
        }
        inflight.insert(pubkey)
        statusByPubkey[pubkey] = .checking
        version &+= 1

        Task { [weak self] in
            let result = await Nip05Verifier.verify(identifier: nip05, pubkeyHex: pubkey)
            await self?.applyResult(pubkey: pubkey, status: result)
        }
    }

    func retry(pubkey: String, nip05: String) {
        lastChecked.removeValue(forKey: pubkey)
        statusByPubkey.removeValue(forKey: pubkey)
        checkOrFetch(pubkey: pubkey, nip05: nip05)
    }

    private func applyResult(pubkey: String, status: Nip05Status) {
        statusByPubkey[pubkey] = status
        lastChecked[pubkey] = Date()
        inflight.remove(pubkey)
        version &+= 1
    }

    // MARK: - Network

    /// Resolve a NIP-05 identifier to a hex pubkey without requiring a known pubkey.
    /// Returns `nil` on network error, malformed identifier, or name not found.
    static func lookup(identifier: String) async -> String? {
        let parts = identifier.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let local = parts.first.map(String.init),
              let domain = parts.last.map(String.init),
              !local.isEmpty, !domain.isEmpty else { return nil }
        guard let encodedLocal = local.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://\(domain)/.well-known/nostr.json?name=\(encodedLocal)") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("Mozilla/5.0 (compatible; Wisp/1.0)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) != false,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let names = obj["names"] as? [String: Any]
        else { return nil }

        if let exact = names[local] as? String { return exact.lowercased() }
        return (names.first { $0.key.caseInsensitiveCompare(local) == .orderedSame }?.value as? String)?.lowercased()
    }

    private static func verify(identifier: String, pubkeyHex: String) async -> Nip05Status {
        let parts = identifier.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let local = parts.first.map(String.init),
              let domain = parts.last.map(String.init),
              !local.isEmpty, !domain.isEmpty else { return .error }

        guard let encodedLocal = local.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://\(domain)/.well-known/nostr.json?name=\(encodedLocal)") else {
            return .error
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("Mozilla/5.0 (compatible; Wisp/1.0)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .error
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let names = obj["names"] as? [String: Any] else {
                return .mismatch
            }
            // Spec says case-insensitive lookup
            let registered: String?
            if let exact = names[local] as? String { registered = exact }
            else {
                registered = names.first(where: { $0.key.caseInsensitiveCompare(local) == .orderedSame })?.value as? String
            }
            guard let registered else { return .mismatch }
            return registered.caseInsensitiveCompare(pubkeyHex) == .orderedSame ? .verified : .mismatch
        } catch {
            return .error
        }
    }
}
