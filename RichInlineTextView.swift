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

    /// Compiled once at module load. Was `try!` inside `appendNameWithEmojis`,
    /// recompiling on every mention render.
    private static let mentionEmojiRegex = try! NSRegularExpression(pattern: #":([a-zA-Z0-9_-]+):"#)

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Cheap hash of segment kinds + identifying values; stable across
    /// re-renders of the same content. Used by `Coordinator` to skip
    /// `ensureLoaded` and attributed-string rebuild when nothing changed.
    fileprivate var segmentSignature: Int {
        var hasher = Hasher()
        hasher.combine(segments.count)
        for seg in segments {
            switch seg {
            case .text(let s):                hasher.combine(0); hasher.combine(s)
            case .hashtag(let t):             hasher.combine(1); hasher.combine(t)
            case .nostrProfile(let pk, _):    hasher.combine(2); hasher.combine(pk)
            case .inlineLink(let u):          hasher.combine(3); hasher.combine(u)
            case .customEmoji(let s, let u):  hasher.combine(4); hasher.combine(s); hasher.combine(u)
            default:                          hasher.combine(99)
            }
        }
        return hasher.finalize()
    }

    /// Full key including the bits of state that affect the rendered string:
    /// resolved profile names for mentions, emoji-loaded state, and font size
    /// class. Two updates with the same key produce identical attributed
    /// strings, so we can skip the rebuild.
    fileprivate func cacheKey(segmentSig: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(segmentSig)
        hasher.combine(linksEnabled)
        hasher.combine(UIFont.preferredFont(forTextStyle: .callout).pointSize)
        for seg in segments {
            switch seg {
            case .nostrProfile(let pk, _):
                let resolved = profiles[pk] ?? ProfileRepository.shared.get(pk)
                hasher.combine(resolved?.displayString ?? "")
                if let map = resolved?.emojiMap, !map.isEmpty {
                    for (k, v) in map { hasher.combine(k); hasher.combine(v) }
                }
            case .customEmoji(_, let url):
                hasher.combine(EmojiImageCache.shared.image(for: url) != nil)
            default:
                break
            }
        }
        return hasher.finalize()
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
        context.coordinator.parent = self

        let segSig = segmentSignature
        // Schedule emoji loads once per segment-set change, not on every
        // SwiftUI body re-evaluation. The cache itself is in-memory and
        // already deduplicates, but the call still hits an actor hop.
        if segSig != context.coordinator.lastSegmentSignature {
            context.coordinator.lastSegmentSignature = segSig
            for case let .customEmoji(_, url) in segments {
                emojiCache.ensureLoaded(url)
            }
        }

        // Skip rebuild when nothing that affects the attributed output has
        // changed. SwiftUI calls updateUIView on every body re-evaluation,
        // even when our `segments` / `profiles` are byte-identical.
        let key = cacheKey(segmentSig: segSig)
        if key == context.coordinator.lastBuiltKey, let cached = context.coordinator.lastBuiltAttributed {
            if uiView.attributedText !== cached {
                uiView.attributedText = cached
            }
            return
        }

        let attributed = buildAttributedString()
        uiView.attributedText = attributed
        uiView.invalidateIntrinsicContentSize()
        context.coordinator.lastBuiltKey = key
        context.coordinator.lastBuiltAttributed = attributed
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
                // Unresolved mentions fall back to a short npub instead of a
                // bare ellipsis: a stable identifier the reader can match
                // against other surfaces, and which never exposes hex.
                let name = resolvedProfile?.displayString ?? Nip19.shortNpub(hex: pubkey)
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
        let ns = name as NSString
        let matches = Self.mentionEmojiRegex.matches(in: name, range: NSRange(location: 0, length: ns.length))
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
        var lastBuiltKey: Int = 0
        var lastBuiltAttributed: NSAttributedString?
        var lastSegmentSignature: Int = -1

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

    /// Only claim hit-test ownership over characters that carry a `.link`
    /// attribute. Without this, UITextView's tap / selection gesture
    /// recognizers absorb taps on plain body text and defer them while they
    /// disambiguate against double-tap and long-press, which is what made
    /// note cards in the feed need 2–3 taps before navigation fired. Returning
    /// `false` here lets the touch fall through to the enclosing SwiftUI
    /// `.onTapGesture` immediately, while taps on real links still reach
    /// `textView(_:shouldInteractWith:)`.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        guard let attr = attributedText, attr.length > 0 else { return false }
        guard let position = closestPosition(to: point) else { return false }
        let index = offset(from: beginningOfDocument, to: position)
        guard index >= 0, index < attr.length else { return false }

        // Verify the tap actually landed on the glyph (not just the closest
        // position in trailing whitespace at line-end). `firstRect(for:)`
        // returns the visual rect for the single character; a small slop
        // keeps edge taps usable.
        if let next = self.position(from: position, offset: 1),
           let range = textRange(from: position, to: next) {
            let rect = firstRect(for: range)
            if !rect.isNull, !rect.isInfinite,
               !rect.insetBy(dx: -2, dy: -2).contains(point) {
                return false
            }
        }

        return attr.attributes(at: index, effectiveRange: nil)[.link] != nil
    }
}
