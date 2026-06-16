import Foundation

extension Data {
    /// Returns a Base64URL encoded string without padding, as mandated by RFC 4648.
    func base64URLEncodedString() -> String {
        var b64url = self.base64EncodedString()
        b64url = b64url.replacingOccurrences(of: "+", with: "-")
        b64url = b64url.replacingOccurrences(of: "/", with: "_")
        b64url = b64url.replacingOccurrences(of: "=", with: "")
        return b64url
    }
}
