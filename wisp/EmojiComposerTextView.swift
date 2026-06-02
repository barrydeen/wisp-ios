import SwiftUI
import UIKit

/// Emoji-only editable text field for chat surfaces (DM / NIP-29 group / live
/// chat). A stripped-down sibling of `MentionComposerTextView`: it reuses the
/// self-sizing `ComposerSizingTextView` plus the proven caret-restore diff and
/// the shared `EmojiShortcode` `:`-trigger logic, but has none of the
/// mention-pill / atomic-edit machinery. The bound view-model owns the draft
/// text and the emoji candidate list.
struct EmojiComposerTextView: UIViewRepresentable {
    let viewModel: any EmojiComposing
    var placeholder: String = ""
    var maxLines: Int = 5
    /// When set, the Return key calls this instead of inserting a newline
    /// (live chat sends on Return).
    var onSubmit: (() -> Void)?

    private let inset = UIEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
    var font: UIFont { UIFont.preferredFont(forTextStyle: .body) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerSizingTextView {
        let tv = ComposerSizingTextView()
        tv.delegate = context.coordinator
        tv.font = font
        tv.text = viewModel.draft
        tv.textContainerInset = inset
        tv.typingAttributes = [.font: font, .foregroundColor: UIColor.label]

        let ph = UILabel()
        ph.text = placeholder
        ph.font = font
        ph.textColor = .placeholderText
        ph.translatesAutoresizingMaskIntoConstraints = false
        tv.addSubview(ph)
        NSLayoutConstraint.activate([
            ph.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: inset.left),
            ph.topAnchor.constraint(equalTo: tv.topAnchor, constant: inset.top)
        ])
        ph.isHidden = !viewModel.draft.isEmpty
        context.coordinator.placeholder = ph
        context.coordinator.lastSynced = viewModel.draft
        return tv
    }

    func updateUIView(_ uiView: ComposerSizingTextView, context: Context) {
        context.coordinator.parent = self
        let target = viewModel.draft
        context.coordinator.placeholder?.isHidden = !target.isEmpty
        guard target != context.coordinator.lastSynced else { return }

        let old = context.coordinator.lastSynced
        context.coordinator.isProgrammatic = true
        uiView.text = target
        let caret = MentionComposerTextView.Coordinator.caretAfterDiff(old: old, new: target)
        uiView.selectedRange = NSRange(location: caret, length: 0)
        context.coordinator.lastSynced = target
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
        uiView.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = uiView.font?.lineHeight ?? font.lineHeight
        let maxHeight = ceil(lineHeight * CGFloat(maxLines)) + inset.top + inset.bottom
        uiView.isScrollEnabled = ceil(fit.height) > maxHeight
        return CGSize(width: width, height: min(ceil(fit.height), maxHeight))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: EmojiComposerTextView
        weak var placeholder: UILabel?
        var lastSynced = ""
        var isProgrammatic = false

        init(_ parent: EmojiComposerTextView) { self.parent = parent }

        private var viewModel: any EmojiComposing { parent.viewModel }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n", let onSubmit = parent.onSubmit {
                onSubmit()
                return false
            }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isProgrammatic else { return }
            let plain = textView.text ?? ""
            lastSynced = plain
            placeholder?.isHidden = !plain.isEmpty
            viewModel.draft = plain
            recomputeTrigger(textView)
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isProgrammatic else { return }
            recomputeTrigger(textView)
        }

        private func recomputeTrigger(_ textView: UITextView) {
            let ns = (textView.text ?? "") as NSString
            let caret = max(0, min(textView.selectedRange.location, ns.length))
            if let (query, offset) = EmojiShortcode.detectTrigger(in: ns as String, caretUtf16: caret) {
                viewModel.updateEmojiTrigger(query: query, atOffsetUtf16: offset)
            } else {
                viewModel.updateEmojiTrigger(query: nil, atOffsetUtf16: nil)
            }
        }
    }
}
