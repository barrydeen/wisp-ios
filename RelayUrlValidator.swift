import Foundation

/// Structural validation for NIP-65 / NIP-51 relay URLs. Mirrors Android's
/// `RelayConfig.isValidUrl` / `isConnectableUrl` (see
/// `wisp/app/src/main/kotlin/com/wisp/app/relay/RelayConfig.kt`).
///
/// Many users have garbage in their kind:10002 lists (`http://`, `localhost`,
/// raw IPs, `wss://host:port`, `.onion`). Connecting to those wastes sockets
/// and blocks waiting for handshakes that will never complete. Filter early.
enum RelayUrlValidator {

    static func isOnion(_ url: String) -> Bool { url.contains(".onion") }

    /// Can this URL be stored in a relay list at all?
    /// Allows `.onion` (with `ws://` or `wss://`) regardless of Tor state.
    /// Rejects: `localhost`, IP literals, hosts with explicit ports.
    static func isValid(_ url: String) -> Bool {
        if isOnion(url) {
            return url.hasPrefix("wss://") || url.hasPrefix("ws://")
        }
        guard url.hasPrefix("wss://"),
              let parsed = URL(string: url),
              let host = parsed.host?.lowercased(),
              !host.isEmpty,
              parsed.port == nil
        else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        if isIpLiteral(host) { return false }
        return true
    }

    /// Can we connect to this URL right now? `.onion` is unreachable on iOS
    /// (no Tor integration), so it's valid-to-store but not connectable.
    static func isConnectable(_ url: String) -> Bool {
        guard isValid(url) else { return false }
        if isOnion(url) { return false }
        return true
    }

    private static func isIpLiteral(_ host: String) -> Bool {
        if host.hasPrefix("[") && host.hasSuffix("]") { return true } // IPv6 bracketed
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        for part in parts {
            guard let n = Int(part), n >= 0, n <= 255 else { return false }
        }
        return true
    }
}
