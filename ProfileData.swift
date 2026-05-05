import Foundation

struct ProfileData {
    let pubkey: String
    var name: String?
    var displayName: String?
    var picture: String?
    var banner: String?
    var about: String?
    var nip05: String?
    var lud16: String?
    /// NIP-30 custom emoji shortcodes → image URLs declared on the kind-0
    /// profile event. Used by `EmojiText` to render `:shortcode:` runs in
    /// `name` / `displayName` as inline images.
    var emojiMap: [String: String] = [:]

    var displayString: String {
        if let dn = displayName, !dn.isEmpty { return dn }
        if let n = name, !n.isEmpty { return n }
        return Nip19.shortNpub(hex: pubkey)
    }

    init(pubkey: String, json: [String: Any] = [:], emojiMap: [String: String] = [:]) {
        self.pubkey = pubkey
        self.name = json["name"] as? String
        self.displayName = json["display_name"] as? String
        self.picture = json["picture"] as? String
        self.banner = json["banner"] as? String
        self.about = json["about"] as? String
        self.nip05 = json["nip05"] as? String
        self.lud16 = json["lud16"] as? String
        self.emojiMap = emojiMap
    }
}
