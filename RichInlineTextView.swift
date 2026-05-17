import SwiftUI
import UIKit

extension NSAttributedString.Key {
    /// Tap-target attribute for `@mentions`, `#hashtags`, and inline URLs. We
    /// avoid the system `.link` attribute because UITextView paints any range
    /// carrying it in `tintColor` (system blue) regardless of the explicit
    /// `.foregroundColor` we set in the attributed string — `linkTextAttributes`
    /// would normally override that, but it only applies when `isSelectable` is
    /// true, and we keep selection off so our custom tap recognizer doesn't
    /// have to fight UITextView's selection / long-press gestures.
    static let wispLinkURL = NSAttributedString.Key("wispLinkURL")
}

/// A UITextView wrapped in SwiftUI that renders inline content segments
/// (text, hashtags, mentions, links, custom emoji images) with
/// per-range link tap handling.
struct RichInlineTextView: UIViewRepresentable {
    let segments: [ContentSegment]
    let profiles: [String: ProfileData]
    /// When true, taps on `@mention` / `#hashtag` / inline-URL ranges fire the
    /// matching closure. Default is false because feed cards wrap the whole
    /// content in a NavigationLink and need taps to fall through. Profile bios
    /// (no enclosing link) opt in.
    var linksEnabled: Bool = false
    var onProfileTap: ((String) -> Void)? = nil
    var onNoteTap: ((String) -> Void)? = nil
    var onHashtagTap: ((String) -> Void)? = nil
    var onPlainTextTap: (() -> Void)? = nil

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
            case .link(let u):                hasher.combine(7); hasher.combine(u)
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
        // Selection is on so long-press places a cursor and brings up the
        // standard Copy menu. Single-tap routing for `@mention` / inline
        // URLs / hashtags still goes through our custom `linkTapRecognizer`;
        // UITextView's own link gesture stays off because
        // `linkTextAttributes` and `dataDetectorTypes` are unset.
        tv.isSelectable = true
        tv.dataDetectorTypes = []
        // 2pt of bottom inset reserves space for the last line's descender
        // depth + font leading. With a flat zero inset, posts whose last
        // line ends in glyphs with deep descenders ("p", "y", "Z") sat
        // hard against the next sibling in the RichContentView VStack —
        // typically an inline image — and the descenders visibly clipped
        // into the top edge of the image's placeholder. The 2pt buffer
        // lifts the text frame just enough that the 8pt VStack spacing
        // reads as a real gap regardless of the trailing glyphs.
        tv.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 2, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.lineBreakMode = .byWordWrapping
        tv.adjustsFontForContentSizeCategory = true
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        tv.setContentHuggingPriority(.required, for: .vertical)
        let coordinator = context.coordinator
        tv.onLinkTap = { [weak coordinator] url in
            guard coordinator?.parent.linksEnabled == true else { return }
            coordinator?.dispatchLink(url)
        }
        tv.onPlainTextTap = { [weak coordinator] in
            guard coordinator?.parent.linksEnabled == true else { return }
            coordinator?.parent.onPlainTextTap?()
        }
        tv.linksEnabled = linksEnabled
        return tv
    }

    func updateUIView(_ uiView: ContentSizingTextView, context: Context) {
        context.coordinator.parent = self
        uiView.linksEnabled = linksEnabled

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
        // Resolve the width SwiftUI proposed. Async re-layout passes (a quoted
        // note finishing its load, an OG link preview image arriving, an
        // inline image's bytes resolving) can briefly propose `nil` /
        // `.infinity`. Returning `nil` in that window made SwiftUI fall back
        // to the UITextView's natural size — which for an unconstrained
        // text container is the entire body rendered as a single infinite
        // line. That single-line frame then propagated up the stack and
        // bursted the parent card past both screen edges. Cap to the
        // screen content width so the text always wraps to a sane line.
        let proposedWidth = proposal.width
        let resolvedWidth: CGFloat
        if let w = proposedWidth, w.isFinite, w > 0 {
            resolvedWidth = w
        } else {
            resolvedWidth = max(1, UIScreen.main.bounds.width - 32)
        }
        // Constrain the text container so wrapping happens at the resolved width.
        uiView.textContainer.size = CGSize(width: resolvedWidth, height: .greatestFiniteMagnitude)
        let target = CGSize(width: resolvedWidth, height: .greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(target)
        return CGSize(width: resolvedWidth, height: ceil(size.height))
    }

    @MainActor
    private func buildAttributedString() -> NSAttributedString {
        let baseFont = UIFont.preferredFont(forTextStyle: .callout)
        let baseColor = UIColor.label
        let primaryColor = UIColor(Color.wispPrimary)
        // URLs paint with the same accent as @mentions / #hashtags. Used to
        // be `UIColor.systemBlue` (relying on UITextView's linkTextAttributes
        // override to repaint to `wispPrimary` at render time), but we
        // disabled `isSelectable` to fix @mention tap reliability — that
        // also bypassed the linkTextAttributes pass, so the systemBlue from
        // the attributed string showed through. Set the accent directly here.
        let linkColor = primaryColor

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
                    attrs[.wispLinkURL] = url
                }
                combined.append(NSAttributedString(string: raw, attributes: attrs))

            case .nostrProfile(let pubkey, _):
                let resolvedProfile = profiles[pubkey] ?? ProfileRepository.shared.get(pubkey)
                // Unresolved mentions fall back to a short npub instead of a
                // bare ellipsis: a stable identifier the reader can match
                // against other surfaces, and which never exposes hex.
                // Some users unknowingly save a display name with trailing
                // whitespace; left intact it renders as "@name " and collides
                // with the space that follows the mention in the surrounding
                // text, producing a visible double space.
                let name = (resolvedProfile?.displayString ?? Nip19.shortNpub(hex: pubkey))
                    .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                var attrs = baseAttrs
                attrs[.foregroundColor] = primaryColor
                if let url = URL(string: "wisp-profile://\(pubkey)") {
                    attrs[.wispLinkURL] = url
                }
                let mentionMap = resolvedProfile?.emojiMap ?? [:]
                combined.append(NSAttributedString(string: "@", attributes: attrs))
                appendNameWithEmojis(name, into: combined, attrs: attrs, emojiMap: mentionMap, baseFont: baseFont)

            case .inlineLink(let url), .link(let url):
                // `.link` reaches us when the parent passed
                // `showLinkPreviews: false` and RichContentView folded it
                // into the inline run rather than rendering a card; treat
                // it as a tappable inline URL just like `.inlineLink`.
                var attrs = baseAttrs
                attrs[.foregroundColor] = linkColor
                // NIP-29 invite links (`wss://host'<groupid>`) get routed
                // through the internal `wisp-group://` scheme so the tap
                // opens the chat room in-app instead of falling through to
                // `UIApplication.shared.open` (which would hand a WebSocket
                // URL to Safari, where nothing useful happens).
                let lower = url.lowercased()
                if (lower.hasPrefix("wss://") || lower.hasPrefix("ws://")),
                   let parsed = Nip29.parseInviteLink(url),
                   let internalUrl = Nip29.buildInternalUrl(
                       relayUrl: parsed.relayUrl,
                       groupId: parsed.groupId,
                       code: parsed.code
                   ) {
                    attrs[.wispLinkURL] = internalUrl
                } else if let u = URL(string: url) {
                    attrs[.wispLinkURL] = u
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

    final class Coordinator: NSObject {
        var parent: RichInlineTextView
        var lastBuiltKey: Int = 0
        var lastBuiltAttributed: NSAttributedString?
        var lastSegmentSignature: Int = -1

        init(parent: RichInlineTextView) {
            self.parent = parent
        }

        /// Called by `ContentSizingTextView`'s tap recognizer with the URL
        /// found at (or near) the tap point. Custom `wisp-*` schemes route
        /// to the matching parent closure; everything else opens externally.
        func dispatchLink(_ url: URL) {
            let scheme = url.scheme?.lowercased() ?? ""
            switch scheme {
            case "wisp-profile":
                let pubkey = url.host ?? url.absoluteString.replacingOccurrences(of: "wisp-profile://", with: "")
                parent.onProfileTap?(pubkey)
            case "wisp-note":
                let id = url.host ?? url.absoluteString.replacingOccurrences(of: "wisp-note://", with: "")
                parent.onNoteTap?(id)
            case "wisp-hashtag":
                let raw = url.host ?? url.absoluteString.replacingOccurrences(of: "wisp-hashtag://", with: "")
                let tag = raw.removingPercentEncoding ?? raw
                parent.onHashtagTap?(tag)
            case Nip29.internalScheme:
                guard let parsed = Nip29.parseInternalUrl(url) else { return }
                var info: [String: Any] = [
                    "relay": parsed.relayUrl,
                    "group": parsed.groupId
                ]
                if let code = parsed.code { info["code"] = code }
                NotificationCenter.default.post(
                    name: .openWispChatLink, object: nil, userInfo: info
                )
            default:
                UIApplication.shared.open(url)
            }
        }
    }
}

/// UITextView whose width is owned by SwiftUI's `sizeThatFits` proposal.
/// We don't drive layout from `intrinsicContentSize` here because that races
/// with SwiftUI's proposal and produces a single, unwrapped line.
///
/// Tap dispatch:
/// - `linksEnabled = false` — view is invisible to hit testing; every touch
///   falls through to the enclosing NavigationLink / button. This matches
///   the historical behavior for surfaces that opt out of inline taps.
/// - `linksEnabled = true` — `point(inside:)` returns true only when the
///   tap is at or beside a `.link` character (with horizontal snap), so
///   touches on plain text still fall through. The custom tap recognizer
///   then dispatches the resolved URL via `onLinkTap`.
final class ContentSizingTextView: UITextView {
    var linksEnabled: Bool = false {
        didSet { linkTapRecognizer.isEnabled = linksEnabled }
    }
    var onLinkTap: ((URL) -> Void)?
    var onPlainTextTap: (() -> Void)?

    private lazy var linkTapRecognizer: UITapGestureRecognizer = {
        let r = UITapGestureRecognizer(target: self, action: #selector(handleLinkTap(_:)))
        r.cancelsTouchesInView = true
        r.isEnabled = false
        return r
    }()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        addGestureRecognizer(linkTapRecognizer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addGestureRecognizer(linkTapRecognizer)
    }

    override var intrinsicContentSize: CGSize {
        // Let SwiftUI control width via sizeThatFits; height too.
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    @objc private func handleLinkTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        if let url = nearbyLinkURL(at: point) {
            onLinkTap?(url)
        } else {
            onPlainTextTap?()
        }
    }

    /// Claim every in-bounds touch when links are enabled so long-press
    /// selection (cursor / drag handles / Copy menu) can engage on plain
    /// text. Single-tap on plain text is intercepted by `linkTapRecognizer`
    /// and forwarded to the enclosing tap target via `onPlainTextTap`,
    /// preserving feed tap-to-open-thread.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        return linksEnabled
    }

    /// Resolve a `.link` attribute at or beside the tap point. A short
    /// `@mention` is only a few characters wide, so a fingertip aimed at it
    /// often lands on the trailing space, the punctuation that follows, or
    /// the gap between two lines — `closestPosition(to:)` then returns a
    /// non-link character and the tap is rejected, falling through to the
    /// surrounding card / link-preview and reading as "the URL stole my
    /// link." We first probe the exact point with a generous slop, then
    /// scan a short horizontal radius for nearby link characters so the
    /// effective hit target around any link is closer to a real fingertip.
    private func nearbyLinkURL(at point: CGPoint) -> URL? {
        if let url = linkURL(atExactPoint: point) { return url }
        let scanRadius: CGFloat = 18
        let step: CGFloat = 4
        var dx: CGFloat = step
        while dx <= scanRadius {
            if let url = linkURL(atExactPoint: CGPoint(x: point.x - dx, y: point.y)) { return url }
            if let url = linkURL(atExactPoint: CGPoint(x: point.x + dx, y: point.y)) { return url }
            dx += step
        }
        return nil
    }

    private func linkURL(atExactPoint point: CGPoint) -> URL? {
        guard let attr = attributedText, attr.length > 0 else { return nil }
        guard let position = closestPosition(to: point) else { return nil }
        let index = offset(from: beginningOfDocument, to: position)
        guard index >= 0, index < attr.length else { return nil }
        if let next = self.position(from: position, offset: 1),
           let range = textRange(from: position, to: next) {
            let rect = firstRect(for: range)
            if !rect.isNull, !rect.isInfinite,
               !rect.insetBy(dx: -4, dy: -8).contains(point) {
                return nil
            }
        }
        return attr.attributes(at: index, effectiveRange: nil)[.wispLinkURL] as? URL
    }
}
