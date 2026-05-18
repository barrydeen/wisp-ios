import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Observation

/// Shared one-shot "Draft saved" pill state. `ComposeView` writes to this
/// from its autosave-on-dismiss path; `MainView` renders the pill from it.
/// Lives outside the View so reply / quote composers presented from
/// `PostCardView` or `NotificationComposer` light up the same pill without
/// each entry point needing to thread a callback up to the tab root.
@MainActor
@Observable
final class DraftSavedToastStore {
    static let shared = DraftSavedToastStore()
    var pendingDraft: Nip37.Draft? = nil
    private init() {}
}

/// Shared one-shot "Post published" pill state. `ComposeViewModel` writes to
/// this after an immediate publish succeeds; `MainView` renders a themed
/// pill linking back to the new post — same indirection as the draft toast
/// so reply / quote composers anywhere in the app light up the same indicator.
struct PublishedPostToast: Equatable {
    let id: String
    let pubkey: String
    /// Set when the published event is a reply. Holds the direct parent's event id
    /// so the toast can navigate to the parent's thread (showing the reply below it)
    /// rather than opening the reply itself as the thread focal.
    let parentEventId: String?
    let parentAuthorPubkey: String?
}

@MainActor
@Observable
final class PostPublishedToastStore {
    static let shared = PostPublishedToastStore()
    var published: PublishedPostToast? = nil
    private init() {}
}

struct ComposeView: View {
    @State var viewModel: ComposeViewModel
    @Environment(\.dismiss) private var dismiss

    @FocusState private var contentFocused: Bool
    @State private var showScheduleSheet = false
    @State private var showCancelConfirm = false
    @State private var showImageOnlyConfirm = false
    @State private var showGifPicker = false
    @State private var showPhotosPicker = false
    @State private var photosPickerMaxCount: Int = 8

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
        }
        .interactiveDismissDisabled(
            viewModel.isPublishing
            || viewModel.countdownSeconds != nil
            // Block swipe-dismiss while an upload is in flight so the draft
            // autosave on disappear catches the finished URLs.
            || viewModel.uploadProgress != nil
        )
        .sheet(isPresented: $showScheduleSheet) {
            ScheduleSheet(
                initialDate: viewModel.scheduleAt,
                onConfirm: { date in viewModel.setSchedule(date) },
                onCancel: { /* keep existing schedule */ }
            )
        }
        // GIF picker is presented as a true UIKit modal via a hidden
        // representable rather than a SwiftUI .sheet / .fullScreenCover.
        // Embedding `GiphyViewController` as a child view (which is what
        // SwiftUI's modal hosts do) breaks its internal layout — the
        // bottom search bar collides with the trending-suggestions
        // carousel because Giphy assumes it owns its modal context.
        .background(
            GifPickerPresenter(isPresented: $showGifPicker) { gifUrl in
                appendGifUrl(gifUrl)
            }
        )
        // Photos picker presented as a real UIKit modal via PHPickerViewController.
        // SwiftUI's `.photosPicker(...)` modifier and inline `PhotosPicker` were
        // both observed to dismiss the compose sheet mid-scroll or right after
        // selection on iOS 26 — the UIKit bridge avoids that coordination path.
        .background(
            PhotosPickerPresenter(
                isPresented: $showPhotosPicker,
                maxCount: photosPickerMaxCount
            ) { providers in
                Task { await viewModel.addMediaProviders(providers) }
            }
        )
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
        .confirmationDialog(
            "Post without a caption?",
            isPresented: $showImageOnlyConfirm,
            titleVisibility: .visible
        ) {
            Button("Post") {
                viewModel.publish()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("This post has no text. Send the attachment on its own?")
        }
        .onChange(of: viewModel.draftSaved) { _, saved in
            if saved { dismiss() }
        }
        .onChange(of: viewModel.content) { _, _ in
            viewModel.scheduleLocalAutosave()
        }
        .onChange(of: viewModel.attachments.map { $0.url ?? "" }) { _, _ in
            viewModel.scheduleLocalAutosave()
        }
        .onChange(of: viewModel.explicit) { _, _ in
            viewModel.scheduleLocalAutosave()
        }
        .onChange(of: viewModel.powEnabled) { _, _ in
            viewModel.scheduleLocalAutosave()
        }
        .onChange(of: viewModel.scheduleAt) { _, _ in
            viewModel.scheduleLocalAutosave()
        }
        .onDisappear {
            // The local autosave is debounced off the keystroke, so the last
            // few characters may not be persisted yet. Flush them now — unless
            // an explicit discard / successful publish already cleared the
            // bucket (those paths call `clearLocalAutosave()`), in which case
            // just drop the pending debounce so it can't resurrect the bucket.
            if viewModel.explicitlyDiscarded || viewModel.publishedEventId != nil {
                viewModel.clearLocalAutosave()
            } else {
                viewModel.flushLocalAutosave()
            }
            // Auto-save on dismiss when the user navigated away without publishing
            // or explicitly discarding (e.g. swipe-to-dismiss the sheet). Fires
            // for reply / quote / new alike — `saveDraft` builds the appropriate
            // reply context tags via `buildBaseTags`, so re-opening the draft
            // restores the parent thread.
            guard viewModel.hasUnsavedContent,
                  viewModel.publishedEventId == nil,
                  !viewModel.explicitlyDiscarded,
                  !viewModel.draftSaved else { return }
            let vm = viewModel
            Task {
                if let draft = await vm.saveDraft() {
                    await MainActor.run { DraftSavedToastStore.shared.pendingDraft = draft }
                }
            }
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
                Text("Replying to \(profile?.displayString ?? Nip19.shortNpub(hex: parent.pubkey))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(previewContent(parent.content, max: 140))
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
                Text("Quoting \(profile?.displayString ?? Nip19.shortNpub(hex: quoted.pubkey))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(previewContent(quoted.content, max: 200))
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

    /// Render-friendly preview of an event's `.content`. When the content is
    /// itself a serialized Nostr event (some clients embed events inside the
    /// `content` string of a kind-1), surface the inner `content` field
    /// instead of dumping the raw JSON envelope into the reply / quote
    /// context card. Mentions are resolved before truncation so a long
    /// `nostr:nprofile1…` token that straddles the cutoff still collapses
    /// to its `@displayName` instead of leaking a half bech32 string.
    private func previewContent(_ raw: String, max: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: String
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["id"] is String, obj["pubkey"] is String {
            let inner = (obj["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if inner.isEmpty { return "[shared event]" }
            source = inner
        } else {
            source = raw
        }
        let resolved = resolveNostrMentions(source)
        return String(resolved.prefix(max))
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
                let name = ProfileRepository.shared.get(pk)?.displayString ?? Nip19.shortNpub(hex: pk)
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
                MentionComposerTextView(viewModel: viewModel)
                    .frame(minHeight: viewModel.galleryMode ? 80 : 160, alignment: .topLeading)
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
                Button {
                    photosPickerMaxCount = 8
                    showPhotosPicker = true
                } label: {
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
                .buttonStyle(.plain)
                .tint(Color(.secondaryLabel))
                .padding(.horizontal, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.attachments) { attachment in
                            attachmentThumb(attachment, size: 140)
                        }
                        Button {
                            photosPickerMaxCount = 8
                            showPhotosPicker = true
                        } label: {
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
                        .buttonStyle(.plain)
                        .tint(Color(.secondaryLabel))
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
                Button {
                    photosPickerMaxCount = 4
                    showPhotosPicker = true
                } label: {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .tint(Color(.secondaryLabel))
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
                    if viewModel.isImageOnlyPost {
                        showImageOnlyConfirm = true
                    } else {
                        viewModel.publish()
                    }
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

}
