import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ComposeView: View {
    @State var viewModel: ComposeViewModel
    @Environment(\.dismiss) private var dismiss

    @FocusState private var contentFocused: Bool
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showScheduleSheet = false
    @State private var showCancelConfirm = false
    @State private var showGifPicker = false

    /// Draft to load on first appear. Nil for `.new` and `.reply`/`.quote` composers.
    /// Loaded from `.task` rather than `init` to defeat SwiftUI's State preservation
    /// (which ignores `State(initialValue:)` when state already exists for this view identity).
    private let initialDraft: Nip37.Draft?

    init(keypair: Keypair, mode: ComposeMode = .new) {
        self.initialDraft = nil
        _viewModel = State(initialValue: ComposeViewModel(keypair: keypair, mode: mode))
    }

    init(keypair: Keypair, draft: Nip37.Draft) {
        self.initialDraft = draft
        _viewModel = State(initialValue: ComposeViewModel(keypair: keypair, mode: .new))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.wispBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    contextHeader

                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if viewModel.galleryMode {
                                galleryArea
                            }

                            textEditor

                            actionsRow

                            if viewModel.pollEnabled {
                                PollOptionsEditor(viewModel: viewModel)
                                    .padding(.horizontal, 12)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            if !viewModel.attachments.isEmpty, !viewModel.galleryMode {
                                attachmentsRow
                            }

                            if !viewModel.hashtags.isEmpty {
                                HashtagChipsView(hashtags: viewModel.hashtags)
                            }

                            if viewModel.explicit {
                                nsfwBanner
                            }

                            if !viewModel.mentionCandidates.isEmpty {
                                mentionPopup
                            }

                            if !viewModel.emojiCandidates.isEmpty {
                                emojiPopup
                            }

                            if shouldShowPreview {
                                ComposerPreviewCard(
                                    content: viewModel.previewContent,
                                    tags: previewTags,
                                    userProfile: ProfileRepository.shared.get(viewModel.keypair.pubkey)
                                )
                            }

                            if let error = viewModel.lastError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 12)
                            }

                            Color.clear.frame(height: 80)
                        }
                        .padding(.top, 12)
                    }

                    if viewModel.scheduleEnabled {
                        scheduleBanner
                    }

                    Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))

                    bottomBar
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        if viewModel.hasUnsavedContent {
                            showCancelConfirm = true
                        } else {
                            viewModel.cancelPublish()
                            viewModel.explicitlyDiscarded = true
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.mode.allowsGalleryToggle {
                        Button {
                            viewModel.toggleGallery()
                        } label: {
                            Label(viewModel.galleryMode ? "Text" : "Gallery",
                                  systemImage: viewModel.galleryMode ? "doc.plaintext" : "photo.on.rectangle")
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(navTitle).font(.headline)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            if let draft = initialDraft, viewModel.currentDraftId != draft.dTag {
                viewModel.loadDraft(draft)
            }
            await viewModel.start()
            contentFocused = true
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            let captured = items
            pickerItems = []
            Task { await viewModel.addMedia(items: captured) }
        }
        .interactiveDismissDisabled(viewModel.isPublishing || viewModel.countdownSeconds != nil)
        .sheet(isPresented: $showScheduleSheet) {
            ScheduleSheet(
                initialDate: viewModel.scheduleAt,
                onConfirm: { date in viewModel.setSchedule(date) },
                onCancel: { /* keep existing schedule */ }
            )
        }
        .sheet(isPresented: $showGifPicker) {
            GifPickerView { gifUrl in
                appendGifUrl(gifUrl)
            }
        }
        .confirmationDialog(
            "Discard this post?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Save Draft") {
                Task {
                    await viewModel.saveDraft()
                    viewModel.cancelPublish()
                    dismiss()
                }
            }
            Button("Discard", role: .destructive) {
                viewModel.cancelPublish()
                viewModel.explicitlyDiscarded = true
                viewModel.clearLocalAutosave()
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("You have unsaved content.")
        }
        .onChange(of: viewModel.draftSaved) { _, saved in
            if saved { dismiss() }
        }
        .onChange(of: viewModel.content) { _, _ in
            viewModel.writeLocalAutosave()
        }
        .onChange(of: viewModel.explicit) { _, _ in
            viewModel.writeLocalAutosave()
        }
        .onChange(of: viewModel.powEnabled) { _, _ in
            viewModel.writeLocalAutosave()
        }
        .onChange(of: viewModel.scheduleAt) { _, _ in
            viewModel.writeLocalAutosave()
        }
        .onDisappear {
            // Auto-save on dismiss when the user navigated away without publishing
            // or explicitly discarding (e.g. swipe-to-dismiss the sheet).
            guard viewModel.hasUnsavedContent,
                  viewModel.publishedEventId == nil,
                  !viewModel.explicitlyDiscarded,
                  !viewModel.draftSaved else { return }
            let vm = viewModel
            Task { await vm.saveDraft() }
        }
    }

    // MARK: - Sub-areas

    @ViewBuilder
    private var contextHeader: some View {
        switch viewModel.mode {
        case .reply(let parent, _):
            replyContextRow(parent: parent)
                .padding(.horizontal, 12)
                .padding(.top, 8)
        case .quote(let q):
            quoteContextRow(quoted: q)
                .padding(.horizontal, 12)
                .padding(.top, 8)
        case .new:
            EmptyView()
        }
    }

    private func replyContextRow(parent: NostrEvent) -> some View {
        let profile = ProfileRepository.shared.get(parent.pubkey)
        return HStack(alignment: .top, spacing: 8) {
            CachedAvatarView(url: profile?.picture, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Replying to \(profile?.displayString ?? String(parent.pubkey.prefix(8)) + "\u{2026}")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(resolveNostrMentions(String(parent.content.prefix(140))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispSurfaceVariant.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private func quoteContextRow(quoted: NostrEvent) -> some View {
        let profile = ProfileRepository.shared.get(quoted.pubkey)
        return HStack(alignment: .top, spacing: 8) {
            CachedAvatarView(url: profile?.picture, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Quoting \(profile?.displayString ?? String(quoted.pubkey.prefix(8)) + "\u{2026}")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(resolveNostrMentions(String(quoted.content.prefix(200))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispSurfaceVariant.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private func resolveNostrMentions(_ content: String) -> String {
        let pattern = #"nostr:(?:npub1|nprofile1)[a-z0-9]+|(?<!\w)(?:npub1|nprofile1)[a-z0-9]{50,}(?!\w)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return content }
        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return content }
        var out = ""
        var lastEnd = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let token = ns.substring(with: match.range)
            let uri = token.lowercased().hasPrefix("nostr:") ? token : "nostr:\(token)"
            if case .profileRef(let pk, _)? = Nip19.decodeNostrUri(uri) {
                let name = ProfileRepository.shared.get(pk)?.displayString ?? String(pk.prefix(8)) + "\u{2026}"
                out += "@\(name)"
            } else {
                out += token
            }
            lastEnd = match.range.upperBound
        }
        out += ns.substring(from: lastEnd)
        return out
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                if viewModel.content.isEmpty {
                    Text(placeholderText)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
                TextEditor(text: Binding(
                    get: { viewModel.content },
                    set: { newVal in
                        viewModel.updateContent(newVal)
                        recomputeTriggers(for: newVal)
                    }
                ))
                .focused($contentFocused)
                .scrollContentBackground(.hidden)
                .frame(minHeight: viewModel.galleryMode ? 80 : 160)
                .padding(.horizontal, 12)
            }
            if let progress = viewModel.uploadProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var galleryArea: some View {
        VStack(spacing: 8) {
            if viewModel.attachments.isEmpty {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 8, matching: .any(of: [.images, .videos])) {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("Add photos or video")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .background(Color.wispSurfaceVariant.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.attachments) { attachment in
                            attachmentThumb(attachment, size: 140)
                        }
                        PhotosPicker(selection: $pickerItems, maxSelectionCount: 8, matching: .any(of: [.images, .videos])) {
                            VStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .font(.system(size: 22, weight: .semibold))
                                Text("Add").font(.caption2)
                            }
                            .frame(width: 140, height: 140)
                            .background(Color.wispSurfaceVariant.opacity(0.4),
                                        in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
    }

    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.attachments) { attachment in
                    attachmentThumb(attachment, size: 80)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func attachmentThumb(_ attachment: ComposeAttachment, size: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                if let bytes = attachment.localBytes, let img = UIImage(data: bytes) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else if let url = attachment.url {
                    AsyncImage(url: URL(string: url)) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: Color.wispSurfaceVariant
                        }
                    }
                } else {
                    Color.wispSurfaceVariant
                }

                if attachment.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
                }

                if attachment.url == nil {
                    Color.black.opacity(0.4)
                    ProgressView().tint(.white)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button {
                viewModel.removeMedia(id: attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .background(Circle().fill(.black.opacity(0.5)))
            }
            .padding(4)
        }
    }

    private var scheduleBanner: some View {
        let date = viewModel.scheduleAt ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        let formatted = formatter.string(from: date)
        return HStack(spacing: 8) {
            Image(systemName: "clock.fill")
                .foregroundStyle(Color.wispPrimary)
            Text("Scheduled for \(formatted)")
                .font(.caption.weight(.medium))
            Spacer()
            Button {
                viewModel.setSchedule(nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispPrimary.opacity(0.1))
    }

    private var nsfwBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Content marked as NSFW")
                .font(.caption.weight(.medium))
            Spacer()
        }
        .foregroundStyle(.orange)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
    }

    private var mentionPopup: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(viewModel.mentionCandidates) { candidate in
                Button {
                    viewModel.selectMention(candidate)
                } label: {
                    MentionCandidateRow(candidate: candidate)
                }
                .buttonStyle(.plain)
                Divider().overlay(Color.wispSurfaceVariant.opacity(0.4))
            }
        }
        .background(Color.wispSurfaceVariant.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
    }

    private var emojiPopup: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.emojiCandidates) { emoji in
                    Button {
                        viewModel.selectEmoji(emoji)
                    } label: {
                        HStack(spacing: 4) {
                            AsyncImage(url: URL(string: emoji.url)) { phase in
                                switch phase {
                                case .success(let img): img.resizable()
                                default: Color.clear
                                }
                            }
                            .frame(width: 18, height: 18)
                            Text(":\(emoji.shortcode):")
                                .font(.caption2.weight(.medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.wispSurfaceVariant.opacity(0.6),
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: - Actions row (under text editor)

    private var actionsRow: some View {
        HStack(spacing: 22) {
            if !viewModel.galleryMode, !viewModel.pollEnabled {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 4, matching: .any(of: [.images, .videos])) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
            }

            if !viewModel.pollEnabled {
                Button {
                    pasteImageFromClipboard()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 22))
                        .foregroundStyle(UIPasteboard.general.hasImages ? Color.wispPrimary : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Paste image from clipboard")
                .disabled(!UIPasteboard.general.hasImages)
            }

            if !viewModel.pollEnabled {
                Button {
                    showGifPicker = true
                } label: {
                    Text("GIF")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add GIF")
            }

            Button {
                viewModel.toggleNsfw()
            } label: {
                Image(systemName: "exclamationmark.triangle\(viewModel.explicit ? ".fill" : "")")
                    .font(.system(size: 22))
                    .foregroundStyle(viewModel.explicit ? Color.orange : .secondary)
            }

            Button {
                viewModel.togglePow()
            } label: {
                Image(systemName: "shield\(viewModel.powEnabled ? ".fill" : "")")
                    .font(.system(size: 22))
                    .foregroundStyle(viewModel.powEnabled ? Color.wispPrimary : .secondary)
            }

            if viewModel.mode.allowsPollToggle {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.togglePoll()
                    }
                } label: {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 22))
                        .foregroundStyle(viewModel.pollEnabled ? Color.wispPrimary : .secondary)
                }
                .accessibilityLabel(viewModel.pollEnabled ? "Disable poll" : "Create poll")
            }

            Button {
                showScheduleSheet = true
            } label: {
                Image(systemName: "clock\(viewModel.scheduleEnabled ? ".fill" : "")")
                    .font(.system(size: 22))
                    .foregroundStyle(viewModel.scheduleEnabled ? Color.wispPrimary : .secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: - Bottom publish bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if viewModel.countdownSeconds != nil {
                Button(role: .destructive) {
                    viewModel.cancelPublish()
                } label: {
                    Text("Undo")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .background(Color.wispSurfaceVariant, in: Capsule())

                Button {
                    viewModel.publishNow()
                } label: {
                    Text("Post Now (\(viewModel.countdownSeconds ?? 0)s)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .background(Color.wispPrimary, in: Capsule())
                .foregroundStyle(.white)
            } else {
                Button {
                    viewModel.publish()
                } label: {
                    Group {
                        // Only flag mining once the miner has reported real
                        // attempts. Low-difficulty PoW returns nearly
                        // instantly, leaving `miningAttempts` at 0 — the
                        // label would otherwise flash "Mining 0" before
                        // settling on "Publishing", which reads as a stray
                        // countdown number.
                        if viewModel.isMining && viewModel.miningAttempts > 0 {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small).tint(.white)
                                Text("Mining \(viewModel.miningAttempts)")
                                    .font(.subheadline.weight(.semibold))
                            }
                        } else if viewModel.isPublishing || viewModel.isMining {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small).tint(.white)
                                Text(viewModel.scheduleEnabled ? "Scheduling" : "Publishing")
                                    .font(.subheadline.weight(.semibold))
                            }
                        } else {
                            Text(viewModel.scheduleEnabled ? "Schedule Post" : "Publish")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .background(Color.wispPrimary, in: Capsule())
                .foregroundStyle(.white)
                .disabled(viewModel.isPublishing || viewModel.isMining)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onChange(of: viewModel.publishedEventId) { _, newId in
            if newId != nil { dismiss() }
        }
    }

    // MARK: - Helpers

    private var navTitle: String {
        switch viewModel.mode {
        case .new:
            if viewModel.pollEnabled { return "New Poll" }
            return viewModel.galleryMode ? "Gallery" : "New Post"
        case .reply: return "Reply"
        case .quote: return "Quote"
        }
    }

    private var placeholderText: String {
        if viewModel.pollEnabled { return "Ask a question…" }
        switch viewModel.mode {
        case .new: return viewModel.galleryMode ? "Add a caption…" : "What's on your mind?"
        case .reply: return "Write your reply…"
        case .quote: return "Add a comment…"
        }
    }

    private var shouldShowPreview: Bool {
        if viewModel.galleryMode { return false }
        let hasText = !viewModel.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !viewModel.attachments.isEmpty
        return hasText || hasAttachments
    }

    /// Hand off a Giphy CDN URL to the view model, which re-hosts the bytes on
    /// the user's Blossom servers (so the published note doesn't depend on
    /// Giphy's rate-limited anonymous CDN) and appends the resulting URL to
    /// the post body.
    private func appendGifUrl(_ url: String) {
        Task { await viewModel.attachGifFromGiphy(url) }
    }

    /// Hand the system pasteboard's image item providers to the view model,
    /// which uploads each one to Blossom and appends as an attachment.
    /// `.onPasteCommand` is unavailable on iOS, so this routes through a
    /// visible button that reads `UIPasteboard.general` on tap.
    private func pasteImageFromClipboard() {
        let providers = UIPasteboard.general.itemProviders.filter { $0.canLoadObject(ofClass: UIImage.self) }
        guard !providers.isEmpty else { return }
        Task { await viewModel.addPastedImages(providers) }
    }

    private var previewTags: [[String]] {
        // Best-effort tag preview: real tags are built at publish time.
        var tags: [[String]] = []
        for tag in viewModel.hashtags { tags.append(["t", tag]) }
        return tags
    }

    /// Re-derive `@mention` and `:emoji:` triggers from the current content. We pick the
    /// last whitespace-delimited token at the end of the buffer as a heuristic for the
    /// caret position — works for the typical "type at end" flow that the SwiftUI
    /// `TextEditor` defaults to.
    private func recomputeTriggers(for text: String) {
        // Find the start of the last token. NBSPs inside a sanitised display
        // name are not token breaks (`isMentionTokenBreak`), so a multi-word
        // mention stays a single `@displayName` trigger token.
        var idx = text.endIndex
        while idx > text.startIndex {
            let prev = text.index(before: idx)
            if text[prev].isMentionTokenBreak { break }
            idx = prev
        }
        let token = String(text[idx..<text.endIndex])
        let utf16Offset = text.utf16.distance(from: text.utf16.startIndex,
                                              to: idx.samePosition(in: text.utf16) ?? text.utf16.startIndex)

        if token.hasPrefix("@"), token.count >= 1 {
            let query = String(token.dropFirst())
            // Only show popup once they typed at least 1 char OR have an active candidate set.
            if query.isEmpty {
                viewModel.updateMentionTrigger(query: nil, atOffsetUtf16: nil)
            } else {
                viewModel.updateMentionTrigger(query: query, atOffsetUtf16: utf16Offset)
            }
        } else {
            viewModel.updateMentionTrigger(query: nil, atOffsetUtf16: nil)
        }

        if token.hasPrefix(":"), token.count >= 2, !token.dropFirst().contains(":") {
            let query = String(token.dropFirst())
            viewModel.updateEmojiTrigger(query: query, atOffsetUtf16: utf16Offset)
        } else {
            viewModel.updateEmojiTrigger(query: nil, atOffsetUtf16: nil)
        }
    }
}
