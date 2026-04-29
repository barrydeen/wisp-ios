import SwiftUI
import UIKit

/// A UITextView wrapped in SwiftUI that renders inline content segments
/// (text, hashtags, mentions, links, custom emoji images) with
/// per-range link tap handling.
struct RichInlineTextView: UIViewRepresentable {
    let segments: [ContentSegment]
    let profiles: [String: ProfileData]
    /// When true, the underlying UITextView is `isSelectable = true`, which is
    /// what UIKit requires for link / mention / hashtag taps to fire. Default
    /// is false because feed cards wrap the whole content in a NavigationLink
    /// and need taps to fall through. Profile bios (no enclosing link) opt in.
    var linksEnabled: Bool = false
    var onProfileTap: ((String) -> Void)? = nil
    var onNoteTap: ((String) -> Void)? = nil
    var onHashtagTap: ((String) -> Void)? = nil

    @ObservedObject private var emojiCache = EmojiImageCache.shared

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ContentSizingTextView {
        let tv = ContentSizingTextView()
        tv.backgroundColor = .clear
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = linksEnabled
        tv.dataDetectorTypes = []
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.lineBreakMode = .byWordWrapping
        tv.adjustsFontForContentSizeCategory = true
        tv.delegate = context.coordinator
        tv.linkTextAttributes = [
            .foregroundColor: UIColor(Color.wispPrimary)
        ]
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        tv.setContentHuggingPriority(.required, for: .vertical)
        return tv
    }

    func updateUIView(_ uiView: ContentSizingTextView, context: Context) {
        // ensure all referenced emojis are scheduled to load
        for case let .customEmoji(_, url) in segments {
            emojiCache.ensureLoaded(url)
        }

        context.coordinator.parent = self
        let attributed = buildAttributedString()
        uiView.attributedText = attributed
        uiView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ContentSizingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? .infinity
        guard width.isFinite, width > 0 else { return nil }
        // Constrain the text container so wrapping happens at the proposed width.
        uiView.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        let target = CGSize(width: width, height: .greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(target)
        return CGSize(width: width, height: ceil(size.height))
    }

    @MainActor
    private func buildAttributedString() -> NSAttributedString {
        let baseFont = UIFont.preferredFont(forTextStyle: .callout)
        let baseColor = UIColor.label
        let primaryColor = UIColor(Color.wispPrimary)
        let linkColor = UIColor.systemBlue

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.lineBreakMode = .byWordWrapping

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: baseColor,
            .paragraphStyle: style
        ]

        let combined = NSMutableAttributedString()

        for seg in segments {
            switch seg {
            case .text(let text):
                combined.append(NSAttributedString(string: text, attributes: baseAttrs))

            case .hashtag(let tag):
                let raw = "#\(tag)"
                var attrs = baseAttrs
                attrs[.foregroundColor] = primaryColor
                let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
                if let url = URL(string: "wisp-hashtag://\(encoded)") {
                    attrs[.link] = url
                }
                combined.append(NSAttributedString(string: raw, attributes: attrs))

            case .nostrProfile(let pubkey, _):
                let resolvedProfile = profiles[pubkey] ?? ProfileRepository.shared.get(pubkey)
                // Unresolved mentions render as `@…` rather than `@<8-hex>…`.
                // The hex prefix was hard to read and visibly mutated to a real
                // handle a second later when the lazy profile fetch landed; an
                // ellipsis is calmer and reads as a clear "loading" state.
                let name = resolvedProfile?.displayString ?? "\u{2026}"
                var attrs = baseAttrs
                attrs[.foregroundColor] = primaryColor
                if let url = URL(string: "wisp-profile://\(pubkey)") {
                    attrs[.link] = url
                }
                let mentionMap = resolvedProfile?.emojiMap ?? [:]
                combined.append(NSAttributedString(string: "@", attributes: attrs))
                appendNameWithEmojis(name, into: combined, attrs: attrs, emojiMap: mentionMap, baseFont: baseFont)

            case .inlineLink(let url):
                var attrs = baseAttrs
                attrs[.foregroundColor] = linkColor
                if let u = URL(string: url) {
                    attrs[.link] = u
                }
                combined.append(NSAttributedString(string: shortenUrl(url), attributes: attrs))

            case .customEmoji(let shortcode, let url):
                if let image = EmojiImageCache.shared.image(for: url) {
                    let attachment = NSTextAttachment()
                    let target = baseFont.lineHeight * 1.15
                    let aspect = image.size.width > 0 && image.size.height > 0
                        ? image.size.width / image.size.height
                        : 1.0
                    let h = target
                    let w = target * aspect
                    let bounds = CGRect(x: 0, y: baseFont.descender, width: w, height: h)
                    attachment.image = image
                    attachment.bounds = bounds
                    let attachString = NSMutableAttributedString(attachment: attachment)
                    attachString.addAttributes(baseAttrs, range: NSRange(location: 0, length: attachString.length))
                    combined.append(attachString)
                } else {
                    // fallback while loading: render :shortcode: text
                    combined.append(NSAttributedString(string: ":\(shortcode):", attributes: baseAttrs))
                }

            default:
                break
            }
        }

        return combined
    }

    /// Append `name` to `combined`, splitting on `:shortcode:` runs that resolve in
    /// `emojiMap` and rendering them as inline image attachments. Used for `@mention`
    /// names — body text emojis are split upstream by `ContentParser` and arrive as
    /// distinct `.customEmoji` segments.
    private func appendNameWithEmojis(
        _ name: String,
        into combined: NSMutableAttributedString,
        attrs: [NSAttributedString.Key: Any],
        emojiMap: [String: String],
        baseFont: UIFont
    ) {
        guard !emojiMap.isEmpty, name.contains(":") else {
            combined.append(NSAttributedString(string: name, attributes: attrs))
            return
        }
        let regex = try! NSRegularExpression(pattern: #":([a-zA-Z0-9_-]+):"#)
        let ns = name as NSString
        let matches = regex.matches(in: name, range: NSRange(location: 0, length: ns.length))
        var lastEnd = 0
        for m in matches where m.numberOfRanges >= 2 {
            let r = m.range
            let scR = m.range(at: 1)
            guard scR.location != NSNotFound else { continue }
            let shortcode = ns.substring(with: scR)
            guard let url = emojiMap[shortcode] else { continue }
            if r.location > lastEnd {
                combined.append(NSAttributedString(
                    string: ns.substring(with: NSRange(location: lastEnd, length: r.location - lastEnd)),
                    attributes: attrs
                ))
            }
            EmojiImageCache.shared.ensureLoaded(url)
            if let image = EmojiImageCache.shared.image(for: url) {
                let attachment = NSTextAttachment()
                let target = baseFont.lineHeight * 1.05
                let aspect = image.size.width > 0 && image.size.height > 0
                    ? image.size.width / image.size.height
                    : 1.0
                attachment.image = image
                attachment.bounds = CGRect(x: 0, y: baseFont.descender, width: target * aspect, height: target)
                let attach = NSMutableAttributedString(attachment: attachment)
                attach.addAttributes(attrs, range: NSRange(location: 0, length: attach.length))
                combined.append(attach)
            } else {
                combined.append(NSAttributedString(string: ":\(shortcode):", attributes: attrs))
            }
            lastEnd = r.location + r.length
        }
        if lastEnd < ns.length {
            combined.append(NSAttributedString(string: ns.substring(from: lastEnd), attributes: attrs))
        }
    }

    private func shortenUrl(_ url: String) -> String {
        var clean = url
        if clean.hasPrefix("https://") { clean = String(clean.dropFirst(8)) }
        else if clean.hasPrefix("http://") { clean = String(clean.dropFirst(7)) }
        if clean.hasPrefix("www.") { clean = String(clean.dropFirst(4)) }
        if clean.count > 50 { clean = String(clean.prefix(47)) + "\u{2026}" }
        return clean
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichInlineTextView

        init(parent: RichInlineTextView) {
            self.parent = parent
        }

        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            guard interaction == .invokeDefaultAction else { return true }
            let scheme = URL.scheme?.lowercased() ?? ""
            switch scheme {
            case "wisp-profile":
                let pubkey = URL.host ?? URL.absoluteString.replacingOccurrences(of: "wisp-profile://", with: "")
                parent.onProfileTap?(pubkey)
                return false
            case "wisp-note":
                let id = URL.host ?? URL.absoluteString.replacingOccurrences(of: "wisp-note://", with: "")
                parent.onNoteTap?(id)
                return false
            case "wisp-hashtag":
                let raw = URL.host ?? URL.absoluteString.replacingOccurrences(of: "wisp-hashtag://", with: "")
                let tag = raw.removingPercentEncoding ?? raw
                parent.onHashtagTap?(tag)
                return false
            default:
                return true   // let system handle http/https/lightning/etc.
            }
        }
    }
}

/// UITextView whose width is owned by SwiftUI's `sizeThatFits` proposal.
/// We don't drive layout from `intrinsicContentSize` here because that races
/// with SwiftUI's proposal and produces a single, unwrapped line.
final class ContentSizingTextView: UITextView {
    override var intrinsicContentSize: CGSize {
        // Let SwiftUI control width via sizeThatFits; height too.
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }
}
