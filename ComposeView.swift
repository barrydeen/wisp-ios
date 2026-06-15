import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Observation

/// Cross-surface channel for the autosaved draft. `ComposeView` writes the
/// draft here from its autosave-on-dismiss path; `MainView` watches it and
/// raises the shared `SuccessToast` ("Draft saved", tap to reopen). Lives
/// outside the View so reply / quote composers presented from `PostCardView`
/// or `NotificationComposer` light up the same pill without each entry point
/// threading a callback up to the tab root.
@MainActor
@Observable
final class DraftSavedToastStore {
    static let shared = DraftSavedToastStore()
    var pendingDraft: Nip37.Draft? = nil
    private init() {}
}


struct ComposeView: View {
    @State var viewModel: ComposeViewModel
    @Environment(\.dismiss) private var dismiss

    @FocusState private var contentFocused: Bool
    @State private var showScheduleSheet = false
    @State private var showCancelConfirm = false
    @State private var showGifPicker = false
    @State private var showDraftsSheet = false
    @State private var photosPickerMaxCount: Int = 8
    @State private var showAccountPicker = false

    /// Draft to load on first appear. Nil for `.new` and `.reply`/`.quote` composers.
    /// Loaded from `.task` rather than `init` to defeat SwiftUI's State preservation
    /// (which ignores `State(initialValue:)` when state already exists for this view identity).
    private let initialDraft: Nip37.Draft?

    private let previewAnchorID = "composer-preview-card"

    init(keypair: Keypair, mode: ComposeMode = .new) {
        self.initialDraft = nil
        _viewModel = State(initialValue: ComposeViewModel(keypair: keypair, mode: mode))
    }

    init(keypair: Keypair, draft: Nip37.Draft) {
        self.initialDraft = draft
        _viewModel = State(initialValue: ComposeViewModel(keypair: keypair, mode: .new))
    }

    init(keypair: Keypair, initialText: String) {
        self.initialDraft = nil
        _viewModel = State(initialValue: ComposeViewModel(keypair: keypair, initialText: initialText))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.wispBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    contextHeader

                    ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if viewModel.galleryMode {
                                galleryArea
                            }

                            // Avatar + "posting as" label rendered as a slim
                            // header row above the editor so the editor
                            // itself can take the full content width.
                            // Hidden entirely for single-account users —
                            // nothing to switch to, so the row would just
                            // be visual noise. Tapping the row (when
                            // multi-account) opens a sheet picker —
                            // SwiftUI `Menu` items can't render arbitrary
                            // images, so a custom picker is the only way
                            // to show real avatars next to names.
                            if viewModel.availableSigningAccounts.count > 1 {
                                VStack(alignment: .leading, spacing: 2) {
                                    signingAccountHeader
                                        .padding(.horizontal, 12)
                                    textEditor
                                }
                            } else {
                                textEditor
                            }

                            quoteContextHeader

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

                            if !viewModel.mentionCandidates.isEmpty || viewModel.isMentionSearchingRemote {
                                mentionPopup
                            }

                            if !viewModel.emojiCandidates.isEmpty {
                                emojiPopup
                            }

                            if shouldShowPreview {
                                ComposerPreviewCard(
                                    content: viewModel.previewContent,
                                    tags: previewTags,
                                    pollOptions: viewModel.pollEnabled
                                        ? viewModel.pollOptions.filter { !$0.isEmpty }
                                        : nil,
                                    userProfile: ProfileRepository.shared.get(viewModel.signingKeypair.pubkey)
                                )
                                .id(previewAnchorID)
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
                    .onChange(of: viewModel.countdownSeconds) { oldValue, newValue in
                        // When the undo countdown starts, bring the post
                        // preview into view (top-aligned) so the user can
                        // spot-check what's about to publish before the
                        // window closes.
                        guard oldValue == nil, newValue != nil, shouldShowPreview else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(previewAnchorID, anchor: .top)
                        }
                    }
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
                    Button {
                        cancelTapped()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Close")
                    .disabled(isPublishInFlight)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        contentFocused = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            showDraftsSheet = true
                        }
                    } label: {
                        Image(systemName: "tray.full")
                    }
                    .accessibilityLabel("Drafts")
                    .disabled(isPublishInFlight)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.mode.allowsGalleryToggle {
                        // No principal title — the pill itself identifies
                        // the current post type ("Switch to Gallery" means
                        // we're in Text, vice versa), and reply / quote
                        // modes use `contextHeader` to show the parent
                        // event. Dropping the title freed enough trailing
                        // space to fit the full label.
                        Button {
                            viewModel.toggleGallery()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: viewModel.galleryMode ? "doc.plaintext" : "photo.on.rectangle")
                                    .font(.system(size: 13, weight: .semibold))
                                    .symbolEffectsRemoved()
                                    .transaction { $0.animation = nil }
                                Text(viewModel.galleryMode ? "Switch to Text" : "Switch to Gallery")
                                    .font(.subheadline.weight(.semibold))
                                    .transaction { $0.animation = nil }
                            }
                            .foregroundStyle(Color.wispPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .strokeBorder(Color.wispPrimary.opacity(0.5), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isPublishInFlight)
                        .opacity(isPublishInFlight ? 0.4 : 1)
                    }
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
            // Drafts / reply prefills land before the view observes
            // `content`, so warm their links once on open too.
            viewModel.prefetchSocialPreviews()
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
        .sheet(isPresented: $showDraftsSheet) {
            DraftsScheduledView(keypair: viewModel.keypair)
        }
        .sheet(isPresented: $showAccountPicker) {
            accountPickerSheet
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
        // `.alert` rather than `.confirmationDialog` so the cancel-role
        // "Keep Editing" button renders as an explicit choice. iOS 26
        // hides the cancel button on confirmation dialogs presented over
        // sheets, leaving only Save Draft / Discard visible.
        .alert(
            "Discard this post?",
            isPresented: $showCancelConfirm
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
            viewModel.scheduleLocalAutosave()
            viewModel.prefetchSocialPreviews()
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
                    await MainActor.run {
                        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                            DraftSavedToastStore.shared.pendingDraft = draft
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sub-areas

    private var isPublishInFlight: Bool {
        viewModel.isPublishing
            || viewModel.countdownSeconds != nil
            || viewModel.uploadProgress != nil
    }

    /// Discard-confirmation pivot used by both the leading chevron and any
    /// programmatic dismiss. Confirms before dropping unsaved content.
    /// Open the system photo picker via the imperative service rather
    /// than a SwiftUI `.background(PhotosPickerPresenter)` host. The
    /// service walks to the topmost presented VC and presents the
    /// picker directly, bypassing the unreliable representable/host
    /// plumbing that was tearing down the picker after ~1s on
    /// iPhone 13 Pro Max.
    private func presentPhotoPicker(max: Int) {
        contentFocused = false
        PhotoPickerService.present(maxCount: max) { providers in
            // Synchronous progress flip so the dismiss-disabled guard
            // catches before the addMedia task hops onto a runloop.
            viewModel.uploadProgress = providers.count > 1
                ? "Loading \(providers.count) items…"
                : "Loading…"
            Task { await viewModel.addMediaProviders(providers) }
        }
    }

    private func cancelTapped() {
        if viewModel.hasUnsavedContent {
            showCancelConfirm = true
        } else {
            viewModel.cancelPublish()
            viewModel.explicitlyDiscarded = true
            dismiss()
        }
    }

    @ViewBuilder
    private var contextHeader: some View {
        switch viewModel.mode {
        case .reply(let parent, _):
            replyContextRow(parent: parent)
                .padding(.horizontal, 12)
                .padding(.top, 8)
        case .quote, .new:
            EmptyView()
        }
    }

    @ViewBuilder
    private var quoteContextHeader: some View {
        if case .quote(let q) = viewModel.mode {
            quoteContextRow(quoted: q)
                .padding(.horizontal, 12)
        }
    }

    private func replyContextRow(parent: NostrEvent) -> some View {
        let profile = ProfileRepository.shared.get(parent.pubkey)
        let recipientName = profile?.displayString ?? Nip19.shortNpub(hex: parent.pubkey)
        return HStack(alignment: .top, spacing: 8) {
            CachedAvatarView(url: profile?.picture, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if viewModel.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.wispPrimary)
                    }
                    Text(viewModel.isPrivate
                         ? "Replying privately to \(recipientName)"
                         : "Replying to \(recipientName)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
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
        let collapsed = collapseMediaUrls(source)
        let resolved = resolveNostrMentions(collapsed)
        return String(resolved.prefix(max))
    }

    private static let previewImageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "svg"]
    private static let previewVideoExts: Set<String> = ["mp4", "mov", "webm", "m3u8"]

    private func collapseMediaUrls(_ content: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return content }
        let ns = content as NSString
        let matches = detector.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return content }
        var out = ""
        var lastEnd = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let urlStr = ns.substring(with: match.range)
            let ext = (urlStr as NSString).pathExtension.lowercased()
            if Self.previewImageExts.contains(ext) { out += "[image]" }
            else if Self.previewVideoExts.contains(ext) { out += "[video]" }
            else { out += urlStr }
            lastEnd = match.range.upperBound
        }
        out += ns.substring(from: lastEnd)
        return out
    }

    private func resolveNostrMentions(_ content: String) -> String {
        let pattern = #"nostr:(?:npub1|nprofile1)[a-z0-9]+|(?<!\w)(?:npub1|nprofile1)[a-z0-9]{50,}(?!\w)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return content }
        let ns = content as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: content, range: fullRange)
        guard !matches.isEmpty else { return content }
        var urlRanges: [NSRange] = []
        if let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            urlRanges = linkDetector.matches(in: content, range: fullRange).map(\.range)
        }
        var out = ""
        var lastEnd = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let token = ns.substring(with: match.range)
            let insideURL = urlRanges.contains { NSIntersectionRange($0, match.range).length > 0 }
            if insideURL {
                out += token
            } else {
                let uri = token.lowercased().hasPrefix("nostr:") ? token : "nostr:\(token)"
                if case .profileRef(let pk, _)? = Nip19.decodeNostrUri(uri) {
                    let name = ProfileRepository.shared.get(pk)?.displayString ?? Nip19.shortNpub(hex: pk)
                    out += "@\(name)"
                } else {
                    out += token
                }
            }
            lastEnd = match.range.upperBound
        }
        out += ns.substring(from: lastEnd)
        return out
    }

    // MARK: - Signing account header

    /// Slim "posting as" header row rendered above the text editor. The
    /// avatar + display-name combo identifies the active signing
    /// keypair; tapping (when multiple accounts are signable) opens
    /// `accountPickerSheet`. Single-account users see a non-tappable
    /// row, still useful as a visual reinforcement of "this is your
    /// post". The `.id(pubkey)` on the avatar guards against a
    /// SwiftUI quirk where a reused `CachedAvatarView` keeps the
    /// previous account's image when the URL changes — forces a
    /// fresh view instance on switch as a belt-and-braces on top of
    /// the in-view URL-change reset.
    @ViewBuilder
    private var signingAccountHeader: some View {
        let pubkey = viewModel.signingKeypair.pubkey
        let profile = ProfileRepository.shared.get(pubkey)
        let multiAccount = viewModel.availableSigningAccounts.count > 1
        let name = profile?.displayString ?? Nip19.shortNpub(hex: pubkey)

        Button {
            guard multiAccount else { return }
            showAccountPicker = true
        } label: {
            HStack(spacing: 8) {
                CachedAvatarView(url: profile?.picture, size: 28)
                    .id(pubkey)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.wispOnSurface)
                    .lineLimit(1)
                if multiAccount {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!multiAccount)
    }

    /// Bottom-sheet picker for the signing account. Replaces a SwiftUI
    /// `Menu` because Menu items can only show SF Symbols — not real
    /// avatar images — and the picker is significantly more legible
    /// with profile pictures next to names.
    private var accountPickerSheet: some View {
        NavigationStack {
            ZStack {
                Color.wispBackground.ignoresSafeArea()
                List {
                    ForEach(viewModel.availableSigningAccounts, id: \.pubkey) { keypair in
                        let kProfile = ProfileRepository.shared.get(keypair.pubkey)
                        let active = keypair.pubkey == viewModel.signingKeypair.pubkey
                        let kName = kProfile?.displayString ?? Nip19.shortNpub(hex: keypair.pubkey)
                        Button {
                            viewModel.switchSigningAccount(keypair)
                            showAccountPicker = false
                        } label: {
                            HStack(spacing: 12) {
                                CachedAvatarView(url: kProfile?.picture, size: 40)
                                    .id(keypair.pubkey)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.wispOnSurface)
                                        .lineLimit(1)
                                    Text(Nip19.shortNpub(hex: keypair.pubkey))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if active {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Color.wispPrimary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.wispSurfaceVariant.opacity(0.4))
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Post as")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showAccountPicker = false }
                }
            }
        }
        .presentationDetents([.medium])
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
                    presentPhotoPicker(max: 8)
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
                            presentPhotoPicker(max: 8)
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
                if let bytes = attachment.localBytes,
                   AnimatedImageHint.isLikelyAnimated(url: "", mime: attachment.mime),
                   let payload = AnimatedImageDecoder.decode(data: bytes, maxPixelSize: size * UIScreen.main.scale) {
                    // Animated GIF / animated WebP / APNG — render with the
                    // per-frame decoder so the thumbnail plays before publish.
                    // The simple `UIImage(data:)` path freezes on frame 0.
                    AnimatedImageRenderer(payload: payload, contentMode: .scaleAspectFill)
                } else if let bytes = attachment.localBytes, let img = UIImage(data: bytes) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else if let url = attachment.url,
                          AnimatedImageHint.isLikelyAnimated(url: url, mime: attachment.mime) {
                    // Post-upload: bytes have been cleared but the attachment
                    // is animated. Fetch + animate from the Blossom URL.
                    AnimatedImageView(
                        url: URL(string: url),
                        aspect: nil,
                        contentMode: .fill,
                        placeholder: { Color.wispSurfaceVariant },
                        failure: { Color.wispSurfaceVariant }
                    )
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
        // Display-name collision detection. Search relays surface
        // impersonators using the same display name as a real account
        // (different pubkeys, identical bio). We can't safely dedupe
        // by content, so we surface a short npub beneath the colliding
        // names so the user can tell them apart.
        let nameCounts: [String: Int] = viewModel.mentionCandidates.reduce(into: [:]) { acc, c in
            acc[c.name.lowercased(), default: 0] += 1
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(viewModel.mentionCandidates) { candidate in
                Button {
                    viewModel.selectMention(candidate)
                } label: {
                    let isCollision = (nameCounts[candidate.name.lowercased()] ?? 0) > 1
                    MentionCandidateRow(
                        candidate: candidate,
                        disambiguationNpub: isCollision ? Nip19.shortNpub(hex: candidate.pubkey) : nil
                    )
                }
                .buttonStyle(.plain)
                Divider().overlay(Color.wispSurfaceVariant.opacity(0.4))
            }
            if viewModel.isMentionSearchingRemote {
                // Pinned at the bottom so any local matches stay clickable
                // at the top while we wait on the relay. The spinner is the
                // signal that "more results may yet arrive" — without it
                // the popup looks like it's already final.
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Searching…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(Color.wispSurfaceVariant.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
    }

    private var emojiPopup: some View {
        EmojiSuggestionBar(candidates: viewModel.emojiCandidates) { emoji in
            viewModel.selectEmoji(emoji)
        }
    }

    // MARK: - Actions row (under text editor)

    private var actionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
            if !viewModel.galleryMode, !viewModel.pollEnabled {
                Button {
                    presentPhotoPicker(max: 4)
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
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Paste image from clipboard")
            }

            if !viewModel.pollEnabled {
                Button {
                    // Resign the compose text field before presenting so the
                    // keyboard animation finishes ahead of the modal. Without
                    // the hop, the keyboard collapse mid-present can cancel
                    // the in-flight UIKit modal and SwiftUI flips
                    // `showGifPicker` back to false — same shape as the
                    // drafts-sheet keyboard race.
                    contentFocused = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showGifPicker = true
                    }
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

            // Private-reply toggle — only meaningful for `.reply` mode. Locked
            // (no-op) when the parent is itself a private rumor; the icon stays
            // filled to signal the chain stays encrypted.
            if case .reply = viewModel.mode {
                Button {
                    viewModel.togglePrivate()
                } label: {
                    Image(systemName: viewModel.isPrivate ? "lock.fill" : "lock")
                        .font(.system(size: 22))
                        .foregroundStyle(viewModel.isPrivate ? Color.wispPrimary : .secondary)
                }
                .disabled(viewModel.isPrivateLocked)
                .accessibilityLabel(viewModel.isPrivate ? "Disable private reply" : "Send privately")
            }

            Button {
                showScheduleSheet = true
            } label: {
                Image(systemName: "clock\(viewModel.scheduleEnabled ? ".fill" : "")")
                    .font(.system(size: 22))
                    .foregroundStyle(viewModel.scheduleEnabled ? Color.wispPrimary : .secondary)
            }
            .disabled(viewModel.isPrivate)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    // MARK: - Bottom publish bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if viewModel.countdownSeconds != nil {
                Button(role: .destructive) {
                    viewModel.cancelPublish()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.red, in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.publishNow()
                } label: {
                    countdownProgressLabel
                }
                .buttonStyle(.plain)
            } else {
                // Grey the button out when the composer has no content to
                // publish (no text, no attachments). Visual feedback matches
                // the disabled state — tapping while empty errors out with
                // "Type something first.", which a greyed-out button heads
                // off before the user discovers it.
                let inFlight = viewModel.isPublishing || viewModel.isMining
                let isInactive = !viewModel.canPublish
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
                        } else if inFlight {
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
                    .frame(height: 44)
                }
                .background(
                    isInactive ? Color.wispSurfaceVariant : Color.wispPrimary,
                    in: Capsule()
                )
                .foregroundStyle(isInactive ? Color.secondary : Color.white)
                .disabled(inFlight || isInactive)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onChange(of: viewModel.publishedEventId) { _, newId in
            guard let newId else { return }
            // Normal posts hand off to `PostPublisher` which drives a bottom
            // pill ("Mining…" → "Broadcasting n/N" → "Posted to N relays").
            // The pill is the single source of confirmation — suppress the
            // top toast in that case. DMs and scheduled posts still finish
            // in-sheet and surface through the toast as before.
            if newId != "handed-off" {
                SuccessToast.shared.show(publishToastMessage)
            }
            dismiss()
        }
    }

    private var publishToastMessage: String {
        switch viewModel.mode {
        case .reply: return "Reply sent"
        case .quote: return "Quote posted"
        case .new: return viewModel.pollEnabled ? "Poll posted" : "Posted"
        }
    }

    // MARK: - Helpers

    private var navTitle: String {
        switch viewModel.mode {
        case .new:
            if viewModel.pollEnabled { return "New Poll" }
            return viewModel.galleryMode ? "Gallery Post" : "New Post"
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

    private var countdownProgressLabel: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let started = viewModel.countdownStartedAt ?? context.date
            let total = max(Double(viewModel.countdownTotalSeconds), 1)
            let elapsed = context.date.timeIntervalSince(started)
            let progress = max(0, min(1, elapsed / total))
            let remaining = max(0, Int(ceil(total - elapsed)))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.wispPrimary.opacity(0.25)
                    Color.wispPrimary
                        .frame(width: geo.size.width * progress)
                    Text("Post Now (\(remaining)s)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .clipShape(Capsule())
            }
            .frame(height: 44)
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
    ///
    /// Detection has to handle a few quirks:
    /// - `canLoadObject(ofClass: UIImage.self)` misses Photos.app's custom UTI
    ///   pasteboard items. `hasItemConformingToTypeIdentifier("public.image")`
    ///   is the authoritative check — it includes every UTI that conforms to
    ///   `public.image` (PNG, JPEG, GIF, HEIC, WebP, TIFF, RAW, …).
    /// - When the clipboard has zero matching providers but `UIPasteboard`'s
    ///   high-level `image` accessor returns something (some sources only
    ///   write through the legacy API), fall back to that and re-wrap it as
    ///   a provider so the existing upload pipeline runs unchanged.
    /// - On nothing-to-paste, surface a toast so the user knows the tap
    ///   registered. Otherwise a silent button feels broken.
    private func pasteImageFromClipboard() {
        let pasteboard = UIPasteboard.general
        let providers = pasteboard.itemProviders.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        if !providers.isEmpty {
            Task { await viewModel.addPastedImages(providers) }
            return
        }
        if let image = pasteboard.image, let png = image.pngData() {
            let provider = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
            Task { await viewModel.addPastedImages([provider]) }
            return
        }
        QuickFollowToast.shared.show("No image on clipboard")
    }

    private var previewTags: [[String]] {
        // Best-effort tag preview: real tags are built at publish time.
        var tags: [[String]] = []
        for tag in viewModel.hashtags { tags.append(["t", tag]) }
        return tags
    }

}
