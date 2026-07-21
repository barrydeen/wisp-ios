import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension NSAttributedString.Key {
    /// Carries the pill fill color over a `@mention` run. `WispPillLayoutManager`
    /// reads this to draw a rounded background; the editor's edit interception
    /// reads it to treat the run as an atomic, unbreakable token.
    static let wispMentionPill = NSAttributedString.Key("wispMentionPill")
}

// MARK: - Pill background drawing

/// Draws a rounded "chip" behind any character run tagged with
/// `.wispMentionPill`. A plain `.backgroundColor` attribute only yields a
/// square highlight; tagged usernames need the rounded tag look so they read
/// as atomic pills (see Zap Cooking composer).
final class WispPillLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        textStorage.enumerateAttribute(.wispMentionPill, in: charRange, options: []) { value, range, _ in
            guard let color = value as? UIColor else { return }
            let font = (textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont)
                ?? UIFont.preferredFont(forTextStyle: .body)
            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard let container = self.textContainer(forGlyphAt: glyphRange.location, effectiveRange: nil) else { return }
            self.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, lineGlyphRange, _ in
                let slice = NSIntersectionRange(lineGlyphRange, glyphRange)
                guard slice.length > 0 else { return }
                let glyphRect = self.boundingRect(forGlyphRange: slice, in: container)
                // Horizontal extent comes from the glyphs; height is pinned to
                // the run's font line-height centered on the line's used rect.
                // `boundingRect(forGlyphRange:)` spans the whole line fragment,
                // which includes the paragraph style's `lineSpacing`. Drawing
                // the pill at that height — even at the original `dy: -1`
                // inset — made each chip tall enough to overlap the lines
                // above and below, colliding with mentions on adjacent rows.
                var rect = CGRect(
                    x: glyphRect.minX,
                    y: usedRect.midY - font.lineHeight / 2,
                    width: glyphRect.width,
                    height: font.lineHeight
                )
                rect.origin.x += origin.x
                rect.origin.y += origin.y
                let pill = rect.insetBy(dx: -5, dy: -1)
                let path = UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2)
                color.setFill()
                path.fill()
            }
        }
    }
}

// MARK: - Shared styling

/// Builds / re-applies the composer + preview attributed styling: tagged
/// usernames become colored pills, hyperlinks and hashtags adopt the link
/// color via auto detection.
@MainActor
enum ComposerTextStyling {
    private static let hashtagRegex = try! NSRegularExpression(
        pattern: #"(?<![\w/])#([\p{L}\p{N}_]{1,64})"#
    )
    private static let linkDetector = try! NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    static func baseAttributes(font: UIFont) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.lineBreakMode = .byWordWrapping
        return [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: style
        ]
    }

    static var pillFillColor: UIColor { UIColor(Color.wispPrimary).withAlphaComponent(0.18) }
    static var pillTextColor: UIColor { UIColor(Color.wispPrimary) }
    static var linkColor: UIColor { UIColor(Color.wispPrimary) }

    /// First-occurrence-per-mention ranges, mirroring `materializeMentions` so
    /// the visible pills line up exactly with what gets published. Returns the
    /// range plus the index into `mentions` it maps to (used to drop the right
    /// mention when its pill is deleted).
    static func pillRanges(in text: String, mentions: [InsertedMention]) -> [(range: NSRange, mentionIndex: Int)] {
        let ns = text as NSString
        var consumed: [NSRange] = []
        var result: [(NSRange, Int)] = []
        // Mark *every* occurrence of `@displayName` for each mention so that
        // a copy / paste of a pill within the composer keeps both copies
        // pill-styled. Without this, the first occurrence wins and pasted
        // duplicates render as plain `@displayName` text.
        for (i, m) in mentions.enumerated() {
            let needle = "@\(m.displayName)"
            guard !needle.isEmpty else { continue }
            var from = 0
            while from <= ns.length {
                let scope = NSRange(location: from, length: ns.length - from)
                let r = ns.range(of: needle, options: [], range: scope)
                if r.location == NSNotFound { break }
                if consumed.contains(where: { NSIntersectionRange($0, r).length > 0 }) {
                    from = r.location + 1
                    continue
                }
                consumed.append(r)
                result.append((r, i))
                from = r.location + r.length
            }
        }
        return result
    }

    /// Re-derive every attribute over `storage` without changing its
    /// characters, so the caret/selection is unaffected.
    static func restyle(
        _ storage: NSTextStorage,
        mentions: [InsertedMention],
        font: UIFont
    ) {
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        let base = baseAttributes(font: font)
        storage.beginEditing()
        storage.setAttributes(base, range: full)
        let pills = pillRanges(in: text, mentions: mentions).map(\.range)
        applyLinkColor(to: storage, text: text, avoiding: pills)
        let ns = text as NSString
        for r in pills {
            storage.addAttribute(.foregroundColor, value: pillTextColor, range: r)
            storage.addAttribute(.wispMentionPill, value: pillFillColor, range: r)
            // Widen the space characters immediately before and after the pill by
            // the same amount as the background's dx expansion so the pill's
            // background never visually consumes the surrounding word spaces.
            if r.location > 0 && ns.character(at: r.location - 1) == 0x0020 {
                storage.addAttribute(.kern, value: CGFloat(5), range: NSRange(location: r.location - 1, length: 1))
            }
            let tail = r.location + r.length
            if tail < ns.length && ns.character(at: tail) == 0x0020 {
                storage.addAttribute(.kern, value: CGFloat(5), range: NSRange(location: tail, length: 1))
            }
        }
        storage.endEditing()
    }

    static func attributedString(
        for text: String,
        mentions: [InsertedMention],
        font: UIFont
    ) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: text, attributes: baseAttributes(font: font))
        let storage = NSTextStorage(attributedString: attr)
        restyle(storage, mentions: mentions, font: font)
        return NSAttributedString(attributedString: storage)
    }

    private static func applyLinkColor(to storage: NSTextStorage, text: String, avoiding pills: [NSRange]) {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        func intersectsPill(_ r: NSRange) -> Bool {
            pills.contains { NSIntersectionRange($0, r).length > 0 }
        }
        hashtagRegex.enumerateMatches(in: text, range: full) { m, _, _ in
            guard let r = m?.range, !intersectsPill(r) else { return }
            storage.addAttribute(.foregroundColor, value: linkColor, range: r)
        }
        linkDetector.enumerateMatches(in: text, range: full) { m, _, _ in
            guard let r = m?.range, !intersectsPill(r) else { return }
            storage.addAttribute(.foregroundColor, value: linkColor, range: r)
        }
    }
}

// MARK: - Self-sizing editable text view

final class ComposerSizingTextView: UITextView {
    /// Hooked by `MentionComposerTextView` so the long-press Paste menu can
    /// route image clipboard contents into the composer's upload pipeline.
    /// Without this, `paste(_:)` falls through to UITextView's text-only
    /// implementation and an image on the clipboard silently no-ops.
    var onPasteImageProviders: (([NSItemProvider]) -> Void)?

    convenience init() {
        let storage = NSTextStorage()
        let layout = WispPillLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        backgroundColor = .clear
        isScrollEnabled = false
        // Aligns the first glyph with `ComposeView`'s placeholder overlay
        // (`.padding(.horizontal, 16)` / `.top, 12`) given the surrounding
        // `.padding(.horizontal, 12)`.
        textContainerInset = UIEdgeInsets(top: 12, left: 4, bottom: 8, right: 4)
        textContainer.lineFragmentPadding = 0
        adjustsFontForContentSizeCategory = true
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    /// Make Paste show in the long-press menu whenever the clipboard has
    /// either text (default behavior) or an image. UITextView's stock check
    /// only enables Paste for text — without this override, an image-only
    /// clipboard has no menu entry to surface.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            if UIPasteboard.general.hasStrings { return true }
            if pasteboardImageProviders().isEmpty == false { return true }
            if UIPasteboard.general.image != nil { return true }
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Intercept Paste. Image content goes through the composer's upload
    /// pipeline; text content falls through to UITextView's default.
    override func paste(_ sender: Any?) {
        let providers = pasteboardImageProviders()
        if !providers.isEmpty {
            onPasteImageProviders?(providers)
            return
        }
        if let image = UIPasteboard.general.image, let png = image.pngData() {
            let provider = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
            onPasteImageProviders?([provider])
            return
        }
        super.paste(sender)
    }

    private func pasteboardImageProviders() -> [NSItemProvider] {
        UIPasteboard.general.itemProviders.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
    }
}

/// Editable composer field that renders tagged usernames as atomic,
/// color-coded pills (deleting/typing into one removes the whole tag rather
/// than corrupting the `@name` token) and tints hyperlinks + hashtags with
/// the link color via auto detection.
struct MentionComposerTextView: UIViewRepresentable {
    var viewModel: ComposeViewModel

    var font: UIFont { UIFont.preferredFont(forTextStyle: .body) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerSizingTextView {
        let tv = ComposerSizingTextView()
        tv.delegate = context.coordinator
        tv.font = font
        tv.attributedText = ComposerTextStyling.attributedString(
            for: viewModel.content, mentions: viewModel.mentions, font: font
        )
        tv.typingAttributes = ComposerTextStyling.baseAttributes(font: font)
        // Route long-press Paste of image content into the upload pipeline.
        // Text content still uses UITextView's default paste path.
        let vm = viewModel
        tv.onPasteImageProviders = { providers in
            Task { @MainActor in await vm.addPastedImages(providers) }
        }
        context.coordinator.lastSyncedPlain = viewModel.content
        // Mirror the previous TextEditor behavior: the composer takes focus as
        // soon as it appears.
        DispatchQueue.main.async { tv.becomeFirstResponder() }
        return tv
    }

    func updateUIView(_ uiView: ComposerSizingTextView, context: Context) {
        context.coordinator.parent = self
        let target = viewModel.content
        guard target != context.coordinator.lastSyncedPlain else { return }

        let old = context.coordinator.lastSyncedPlain
        context.coordinator.isProgrammatic = true
        uiView.attributedText = ComposerTextStyling.attributedString(
            for: target, mentions: viewModel.mentions, font: font
        )
        let caret = Coordinator.caretAfterDiff(old: old, new: target)
        uiView.selectedRange = NSRange(location: caret, length: 0)
        uiView.typingAttributes = ComposerTextStyling.baseAttributes(font: font)
        context.coordinator.lastSyncedPlain = target
        context.coordinator.isProgrammatic = false
        uiView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerSizingTextView, context: Context) -> CGSize? {
        let width: CGFloat
        if let w = proposal.width, w.isFinite, w > 0 {
            width = w
        } else {
            width = max(1, UIScreen.main.bounds.width - 24)
        }
        uiView.textContainer.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        let fit = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fit.height))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MentionComposerTextView
        var lastSyncedPlain: String = ""
        var isProgrammatic = false
        /// Previous caret location, used to infer arrow-key direction so
        /// the snap logic can move the caret to the *far* edge of a pill
        /// it lands inside rather than the nearest edge (which on a
        /// single-step forward arrow would just bounce back to the start).
        var lastCaretLocation: Int = 0

        init(_ parent: MentionComposerTextView) {
            self.parent = parent
        }

        private var viewModel: ComposeViewModel { parent.viewModel }

        // MARK: Atomic mention editing

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            let plain = textView.text ?? ""
            let pills = ComposerTextStyling.pillRanges(in: plain, mentions: viewModel.mentions)

            // Block typing strictly inside a pill so a tag can't be split.
            if text.isEmpty == false, range.length == 0,
               pills.contains(where: { range.location > $0.range.location && range.location < $0.range.location + $0.range.length }) {
                return false
            }

            // Decide whether to let UIKit apply the edit natively or to
            // route it through our async path.
            //
            // - If the edit doesn't touch any pill: native.
            // - If the edit's range *fully encompasses* every pill it
            //   touches (the post-snap selection from a Cut / Copy / Paste
            //   over a whole pill): native — going through async would
            //   race with UIKit's pasteboard write and break Cut.
            // - Otherwise (backspace into the last char of a pill,
            //   forward-delete into the first char): manual expansion so
            //   the whole pill is swallowed atomically.
            //
            // We keep the matching `mentions[]` entries around even when
            // a pill is deleted so a subsequent paste of `@displayName`
            // (the system Cut → Paste flow) restores the pill styling.
            // `materializeMentions` is a no-op for entries with no
            // matching `@displayName` in the body, so stale-but-unused
            // mentions cost nothing at publish.
            var expanded = range
            var touchesAny = false
            var fullyEncompasses = true
            for pill in pills where NSIntersectionRange(pill.range, range).length > 0 {
                touchesAny = true
                let pStart = pill.range.location
                let pEnd = pStart + pill.range.length
                if range.location > pStart || (range.location + range.length) < pEnd {
                    fullyEncompasses = false
                }
                let lo = min(expanded.location, pStart)
                let hi = max(expanded.location + expanded.length, pEnd)
                expanded = NSRange(location: lo, length: hi - lo)
            }
            guard touchesAny else { return true }
            if fullyEncompasses { return true }

            // Defer the mutation off the delegate callback so we're not
            // editing the text storage while UITextView is mid-dispatch.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                textView.textStorage.replaceCharacters(in: expanded, with: text)
                let caret = expanded.location + (text as NSString).length
                textView.selectedRange = NSRange(location: caret, length: 0)
                self.synchronize(textView)
            }
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isProgrammatic else { return }
            synchronize(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isProgrammatic else { return }
            snapCaretOutOfPill(textView)
            lastCaretLocation = textView.selectedRange.location
            recomputeTriggers(textView)
        }

        /// A mention rendered as a pill is an atomic token. Caret and
        /// selection inputs are handled differently:
        ///
        /// - **Caret** (zero-length): if it lands strictly inside a pill,
        ///   snap to the nearest pill boundary so the user can't place a
        ///   cursor between letters of the display name.
        /// - **Selection** (non-zero): if either endpoint sits inside a
        ///   pill, expand the selection to encompass the whole pill on
        ///   each side. A selection that lives entirely in the left half
        ///   of a pill would otherwise collapse to a single point — and
        ///   then Copy / Cut would put nothing on the pasteboard.
        private func snapCaretOutOfPill(_ textView: UITextView) {
            let plain = textView.text ?? ""
            let pills = ComposerTextStyling.pillRanges(in: plain, mentions: viewModel.mentions)
            guard !pills.isEmpty else { return }
            let sel = textView.selectedRange

            var lo = sel.location
            var hi = sel.location + sel.length

            if sel.length == 0 {
                let movingForward = lo >= lastCaretLocation
                for pill in pills {
                    let pStart = pill.range.location
                    let pEnd = pStart + pill.range.length
                    if lo > pStart && lo < pEnd {
                        // Move to the far edge in the direction of travel.
                        // Forward arrow: jump past the pill. Backward arrow
                        // (or tap): jump to the leading edge. Without this
                        // an arrow step that would have landed one char
                        // inside the pill bounces back to where it came
                        // from and the caret gets stuck.
                        lo = movingForward ? pEnd : pStart
                        hi = lo
                        break
                    }
                }
            } else {
                for pill in pills {
                    let pStart = pill.range.location
                    let pEnd = pStart + pill.range.length
                    let overlap = NSIntersectionRange(NSRange(location: lo, length: max(0, hi - lo)), pill.range).length
                    let touchesLeftEdge = (lo > pStart && lo < pEnd) || lo == pStart
                    let touchesRightEdge = (hi > pStart && hi < pEnd) || hi == pEnd
                    if overlap > 0 || touchesLeftEdge || touchesRightEdge {
                        // Only expand when the selection actually crosses
                        // into the pill — adjacent zero-overlap selections
                        // (caret just before / after) don't need to grow.
                        if overlap > 0 {
                            lo = min(lo, pStart)
                            hi = max(hi, pEnd)
                        }
                    }
                }
            }

            let next = NSRange(location: lo, length: max(0, hi - lo))
            if next != sel {
                isProgrammatic = true
                textView.selectedRange = next
                isProgrammatic = false
            }
        }

        // MARK: Sync

        private func synchronize(_ textView: UITextView) {
            let plain = textView.text ?? ""
            lastSyncedPlain = plain
            let sel = textView.selectedRange
            ComposerTextStyling.restyle(
                textView.textStorage,
                mentions: viewModel.mentions,
                font: parent.font
            )
            let len = (textView.text as NSString).length
            textView.selectedRange = NSRange(
                location: min(sel.location, len),
                length: min(sel.length, len - min(sel.location, len))
            )
            textView.typingAttributes = ComposerTextStyling.baseAttributes(font: parent.font)
            viewModel.updateContent(plain)
            recomputeTriggers(textView)
        }

        // MARK: Mention / emoji autocomplete triggers

        /// Port of the old `ComposeView.recomputeTriggers`, but driven by the
        /// real caret instead of an end-of-string heuristic — `@mentions`
        /// resolve correctly when editing mid-text.
        private func recomputeTriggers(_ textView: UITextView) {
            let ns = textView.text as NSString
            let caret = max(0, min(textView.selectedRange.location, ns.length))
            let prefix = ns.substring(to: caret)

            // Walk backwards allowing at most one regular space so multi-word
            // display names (e.g. "The Daniel") can be queried as "@the daniel".
            // A second space, a newline, or any other whitespace terminates the scan.
            //
            // `@` and `#` always terminate too — they're the start of a NEW
            // token. Without that condition the one-space allowance lets the
            // walk gobble across a preceding token (e.g. `#test @mish` →
            // token = `#test @mish`, which doesn't start with `@`, so the
            // mention popup never fires). Stop at the trigger character and
            // include it in the token.
            var idx = prefix.endIndex
            var regularSpacesSeen = 0
            while idx > prefix.startIndex {
                let p = prefix.index(before: idx)
                let ch = prefix[p]
                if ch == "\u{00A0}" {
                    // NBSP: always part of the token
                } else if ch.isNewline || (ch.isWhitespace && ch != " ") {
                    break
                } else if ch == "@" || ch == "#" {
                    // Include the trigger character, then stop — anything
                    // earlier in the text belongs to a different token.
                    idx = p
                    break
                } else if ch == " " {
                    regularSpacesSeen += 1
                    if regularSpacesSeen > 1 { break }
                }
                idx = p
            }
            let token = String(prefix[idx..<prefix.endIndex])
            let utf16Offset = prefix.utf16.distance(
                from: prefix.utf16.startIndex,
                to: idx.samePosition(in: prefix.utf16) ?? prefix.utf16.startIndex
            )

            if token.hasPrefix("@") {
                // Trim trailing whitespace so "@the " (cursor right after space)
                // queries "the" rather than "the " with a dangling space.
                let query = String(token.dropFirst()).trimmingCharacters(in: .whitespaces)
                if query.isEmpty {
                    viewModel.updateMentionTrigger(query: nil, atOffsetUtf16: nil, endUtf16: nil)
                } else {
                    viewModel.updateMentionTrigger(query: query, atOffsetUtf16: utf16Offset, endUtf16: caret)
                }
            } else {
                viewModel.updateMentionTrigger(query: nil, atOffsetUtf16: nil, endUtf16: nil)
            }

            // Emoji `:shortcode` uses the shared detector (independent of the
            // mention token walk above) so it fires mid-text after a space too.
            if let (emojiQuery, emojiOffset) = EmojiShortcode.detectTrigger(in: ns as String, caretUtf16: caret) {
                viewModel.updateEmojiTrigger(query: emojiQuery, atOffsetUtf16: emojiOffset)
            } else {
                viewModel.updateEmojiTrigger(query: nil, atOffsetUtf16: nil)
            }
        }

        // MARK: Caret restore after a programmatic content change

        /// Place the caret at the end of the changed region (longest common
        /// prefix/suffix diff). Handles mention/emoji insertion, GIF append,
        /// and bare-bech32 auto-prefixing.
        static func caretAfterDiff(old: String, new: String) -> Int {
            let o = old as NSString
            let n = new as NSString
            let maxPrefix = min(o.length, n.length)
            var prefix = 0
            while prefix < maxPrefix,
                  o.character(at: prefix) == n.character(at: prefix) {
                prefix += 1
            }
            var suffix = 0
            while suffix < (maxPrefix - prefix),
                  o.character(at: o.length - 1 - suffix) == n.character(at: n.length - 1 - suffix) {
                suffix += 1
            }
            return max(prefix, n.length - suffix)
        }
    }
}
