import Foundation

enum Nip71 {
    static let kindVideoHorizontal = 21
    static let kindVideoVertical = 22

    struct VideoMeta {
        let url: String
        let mimeType: String?
        let dim: String?
        let duration: Int?
        let hash: String?
        /// NIP-92 imeta `alt` slot — the video's accessibility description.
        let alt: String?

        init(url: String, mimeType: String? = nil, dim: String? = nil, duration: Int? = nil, hash: String? = nil, alt: String? = nil) {
            self.url = url
            self.mimeType = mimeType
            self.dim = dim
            self.duration = duration
            self.hash = hash
            self.alt = alt
        }
    }

    static func buildVideoTags(
        title: String?,
        media: [VideoMeta],
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
            if let dur = entry.duration { imeta.append("duration \(dur)") }
            if let h = entry.hash { imeta.append("x \(h)") }
            if let alt = entry.alt.map(ContentParser.normalizeAltBreaks),
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

    /// Determine the right video kind from dimensions: vertical (kind 22) when
    /// height > width, else horizontal (kind 21).
    static func kindFor(width: Int, height: Int) -> Int {
        return height > width ? kindVideoVertical : kindVideoHorizontal
    }
}
