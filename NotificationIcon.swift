import SwiftUI

enum NotificationStyle {
    static func actionText(_ kind: NotificationKind) -> String {
        switch kind {
        case .reply:    "replied"
        case .reaction: "reacted"
        case .repost:   "reposted"
        case .zap:      "zapped"
        case .quote:    "quoted"
        case .mention:  "mentioned you"
        case .dm:       "messaged you"
        case .pollVote: "voted on your poll"
        }
    }

    static func formatSats(_ sats: Int64) -> String {
        if sats >= 1_000_000 { return String(format: "%.1fM", Double(sats) / 1_000_000) }
        if sats >= 1_000 { return String(format: "%.1fk", Double(sats) / 1_000) }
        return "\(sats)"
    }
}

/// Lightning-bolt path lifted verbatim from
/// `/Users/barry/Dev/wisp/app/src/main/res/drawable/ic_bolt.xml`. 55×94 viewBox:
/// `M35.563,0V40.406H54.969L21.016,93.75V51.719H0L35.563,0Z`. Renders 1:1 with
/// Android's notification zap glyph.
struct BoltIcon: View {
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width / 55, geo.size.height / 94)
            let dx = (geo.size.width - 55 * s) / 2
            let dy = (geo.size.height - 94 * s) / 2
            Path { p in
                p.move(to: CGPoint(x: dx + 35.563 * s, y: dy + 0))
                p.addLine(to: CGPoint(x: dx + 35.563 * s, y: dy + 40.406 * s))
                p.addLine(to: CGPoint(x: dx + 54.969 * s, y: dy + 40.406 * s))
                p.addLine(to: CGPoint(x: dx + 21.016 * s, y: dy + 93.75 * s))
                p.addLine(to: CGPoint(x: dx + 21.016 * s, y: dy + 51.719 * s))
                p.addLine(to: CGPoint(x: dx + 0,          y: dy + 51.719 * s))
                p.closeSubpath()
            }
            .fill(tint)
        }
    }
}

/// Per-notification-type icon mirroring Android's `NotificationTypeIcon`. Outline
/// glyphs tinted by type; zaps render the ported bolt path with a sats label below.
struct NotificationTypeIcon: View {
    let item: FlatNotificationItem
    var showSats: Bool = true

    var body: some View {
        Group {
            switch item.kind {
            case .zap:
                VStack(spacing: 0) {
                    BoltIcon(tint: .wispZapColor)
                        .frame(width: 22, height: 22)
                    if showSats, item.zapSats > 0 {
                        Text(NotificationStyle.formatSats(item.zapSats))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.wispZapColor)
                            .lineLimit(1)
                    }
                }
            case .reaction:
                if let e = item.emoji, !e.isEmpty {
                    EmojiInlineView(emoji: e, url: item.emojiUrl, height: 22)
                } else {
                    Image(systemName: "heart")
                        .font(.system(size: 18))
                        .foregroundStyle(.pink)
                }
            case .repost:
                Image(systemName: "arrow.2.squarepath")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.wispRepostColor)
            case .reply:
                Image(systemName: "bubble.right")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.wispPrimary)
            case .quote:
                Image(systemName: "quote.bubble")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.wispPrimary)
            case .mention:
                Image(systemName: "at")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.wispPrimary)
            case .dm:
                Image(systemName: "envelope")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.wispPrimary)
            case .pollVote:
                Image(systemName: "chart.bar")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.wispPrimary)
            }
        }
        .frame(width: 28, alignment: .center)
    }
}
