import Foundation

enum Nip68 {
    static let kindPicture = 20

    struct ImetaEntry {
        let url: String
        let mimeType: String?
        let dim: String?
        let hash: String?
        /// NIP-92 imeta `alt` slot — the image's accessibility description.
        /// Emitted only when non-empty; never breaks an undescribed image.
        let alt: String?

        init(url: String, mimeType: String? = nil, dim: String? = nil, hash: String? = nil, alt: String? = nil) {
            self.url = url
            self.mimeType = mimeType
            self.dim = dim
            self.hash = hash
            self.alt = alt
        }
    }

    /// Build kind-20 picture event tags. Caller is responsible for picking a non-empty
    /// `media` array; an empty media list still produces a valid (but oddly empty) event.
    static func buildPictureTags(
        title: String?,
        media: [ImetaEntry],
        hashtags: [String] = [],
        contentWarning: String? = nil
    ) -> [[String]] {
        var tags: [[String]] = []
        if let title, !title.isEmpty {
            tags.append(["title", title])
        }
        for entry in media {
            var imeta: [String] = ["imeta", "url \(entry.url)"]
            if let m = entry.mimeType { imeta.append("m \(m)") }
            if let d = entry.dim { imeta.append("dim \(d)") }
            if let h = entry.hash { imeta.append("x \(h)") }
            if let alt = entry.alt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !alt.isEmpty { imeta.append("alt \(alt)") }
            tags.append(imeta)
        }
        for tag in hashtags {
            tags.append(["t", tag])
        }
        if let cw = contentWarning {
            tags.append(["content-warning", cw])
        }
        return tags
    }
}
