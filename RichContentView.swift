import SwiftUI
import UIKit

struct RichContentView: View {
    let content: String
    let tags: [[String]]
    let profiles: [String: ProfileData]
    var onProfileTap: ((String) -> Void)? = nil
    var onNoteTap: ((String) -> Void)? = nil
    var onHashtagTap: ((String) -> Void)? = nil
    var showLinkPreviews: Bool = true
    /// When true, inline links / mentions / hashtags inside the rendered text
    /// fire on tap. Default false because feed cards wrap the whole content in a
    /// NavigationLink and need the tap to fall through; surfaces with no
    /// enclosing tap target (profile bio, composer preview) opt in.
    var linksEnabled: Bool = false

    var body: some View {
        let segments = ContentParser.parse(
            content: content,
            tags: tags,
            emojiMap: ContentParser.parseEmojiTags(tags)
        )
        let groups = groupSegments(segments)

        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                renderGroup(group)
            }
        }
    }

    // MARK: - Grouping

    private enum SegmentGroup {
        case inline([ContentSegment])
        case block(ContentSegment)
    }

    private func groupSegments(_ segments: [ContentSegment]) -> [SegmentGroup] {
        var groups: [SegmentGroup] = []
        var inlineBuffer: [ContentSegment] = []

        func flush() {
            if !inlineBuffer.isEmpty {
                groups.append(.inline(inlineBuffer))
                inlineBuffer.removeAll()
            }
        }

        for seg in segments {
            switch seg {
            case .text, .hashtag, .nostrProfile, .inlineLink, .customEmoji:
                inlineBuffer.append(seg)
            default:
                flush()
                groups.append(.block(seg))
            }
        }
        flush()
        return groups
    }

    // MARK: - Group Rendering

    @ViewBuilder
    private func renderGroup(_ group: SegmentGroup) -> some View {
        switch group {
        case .inline(let segs):
            inlineText(segs)
        case .block(let seg):
            renderBlock(seg)
        }
    }

    @ViewBuilder
    private func renderBlock(_ seg: ContentSegment) -> some View {
        switch seg {
        case .image(let meta), .unknownMedia(let meta):
            InlineImageView(meta: meta)
        case .video(let meta):
            InlineVideoView(meta: meta)
        case .audio(let meta):
            InlineAudioView(meta: meta)
        case .link(let url):
            if showLinkPreviews {
                LinkPreviewView(url: url)
            } else {
                fallbackLink(url)
            }
        case .nostrNote(let eventId, let relayHints):
            QuotedNoteView(
                eventId: eventId,
                relayHints: relayHints,
                profiles: profiles,
                onProfileTap: onProfileTap,
                onNoteTap: onNoteTap,
                onHashtagTap: onHashtagTap
            )
        case .nostrAddressable(let dTag, _, let author, let kind):
            addressablePlaceholder(dTag: dTag, author: author, kind: kind)
        case .lightningInvoice(let invoice, let amount, let summary):
            LightningInvoiceView(invoice: invoice, amountSats: amount, summary: summary)
        default:
            EmptyView()
        }
    }

    private func fallbackLink(_ url: String) -> some View {
        Button {
            if let u = URL(string: url) { UIApplication.shared.open(u) }
        } label: {
            Text(shortDisplayUrl(url))
                .font(.callout)
                .foregroundStyle(.blue)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
    }

    private func shortDisplayUrl(_ url: String) -> String {
        var clean = url
        if clean.hasPrefix("https://") { clean = String(clean.dropFirst(8)) }
        else if clean.hasPrefix("http://") { clean = String(clean.dropFirst(7)) }
        if clean.hasPrefix("www.") { clean = String(clean.dropFirst(4)) }
        if clean.count > 50 { clean = String(clean.prefix(47)) + "\u{2026}" }
        return clean
    }

    private func addressablePlaceholder(dTag: String, author: String?, kind: Int?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(addressableTitle(kind: kind))
                    .font(.caption.weight(.semibold))
                Text(dTag)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispSurfaceVariant.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.wispSurfaceVariant, lineWidth: 1)
        )
    }

    private func addressableTitle(kind: Int?) -> String {
        switch kind {
        case 30023: return "Long-form article"
        case 30311: return "Live stream"
        case 30030: return "Emoji pack"
        case 34550: return "Community"
        default: return "Addressable event"
        }
    }

    // MARK: - Inline Text

    private func inlineText(_ segs: [ContentSegment]) -> some View {
        RichInlineTextView(
            segments: segs,
            profiles: profiles,
            linksEnabled: linksEnabled,
            onProfileTap: onProfileTap,
            onNoteTap: onNoteTap,
            onHashtagTap: onHashtagTap
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
