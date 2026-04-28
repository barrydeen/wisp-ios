import Foundation
import Observation
import CoreGraphics
import SwiftUI
import PhotosUI

@Observable
@MainActor
final class ComposeViewModel {
    let keypair: Keypair
    /// Mode is mutable because loading a draft can switch a `.new` composer into
    /// a `.reply` based on the draft's reconstructed `e`/`p` tags.
    var mode: ComposeMode

    // MARK: - Editable state

    var content: String = ""
    var galleryMode: Bool = false
    var explicit: Bool = false
    var powEnabled: Bool = PowPreferences.snapshot().noteEnabled

    var attachments: [ComposeAttachment] = []
    var mentions: [InsertedMention] = []
    var hashtags: [String] = []

    // MARK: - Poll state (NIP-88 / NIP-69)

    var pollEnabled: Bool = false
    var pollOptions: [String] = ["", ""]
    var pollType: Nip88.PollType = .singlechoice
    var isZapPoll: Bool = false
    var zapPollMinSats: Int? = nil
    var zapPollMaxSats: Int? = nil
    var pollEndsAt: Int? = nil

    // MARK: - Autocomplete state

    var mentionQuery: String?
    var mentionCandidates: [MentionCandidate] = []
    var emojiQuery: String?
    var emojiCandidates: [CustomEmoji] = []

    // MARK: - Publish lifecycle

    var isPublishing: Bool = false
    var isMining: Bool = false
    var miningAttempts: Int = 0
    var uploadProgress: String?
    var countdownSeconds: Int?
    var lastError: String?
    var publishedEventId: String?

    // MARK: - Drafts & scheduling

    /// Set when the composer is opened from an existing draft. Reused on
    /// subsequent saves so the same `d` tag updates the same draft.
    var currentDraftId: String?
    /// When non-nil, publish goes to the scheduler relay with this `created_at`.
    var scheduleAt: Date?
    /// Set after a successful `saveDraft()` — UI uses this to dismiss.
    var draftSaved: Bool = false
    /// True once the user has explicitly chosen to discard via the Cancel dialog.
    /// Suppresses the auto-save-on-disappear path.
    var explicitlyDiscarded: Bool = false

    var scheduleEnabled: Bool { scheduleAt != nil }
    /// True when there is text/content the user might lose if the sheet is dismissed.
    var hasUnsavedContent: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Private

    @ObservationIgnored private var blossomServers: [String] = [BlossomServerList.defaultServer]
    @ObservationIgnored private var blossomLoaded = false
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var publishContinuation: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var mineTask: Task<Void, Never>?
    private var powDifficulty: Int { PowPreferences.shared.noteDifficulty }

    /// Track mention triggers via a sentinel index into the content string. When the
    /// `@` signal is active this is the UTF-16 offset of the `@` character.
    @ObservationIgnored private var mentionStartUtf16: Int?
    @ObservationIgnored private var emojiStartUtf16: Int?

    // MARK: - Init

    init(keypair: Keypair, mode: ComposeMode = .new) {
        self.keypair = keypair
        self.mode = mode
        switch mode {
        case .quote(let event):
            // Auto-append the quote URI on open.
            content = Nip18.appendNoteUri(content: "", eventIdHex: event.id, relayHints: [], authorHex: event.pubkey)
        case .new:
            loadLocalAutosave()
        default:
            break
        }
    }

    // MARK: - Local autosave (instant restore on reopen)

    /// Per-pubkey, per-mode UserDefaults bucket. Only `.new` composers autosave —
    /// reply/quote contexts depend on parent events that aren't trivially restored.
    private var autosaveKey: String { "compose_autosave_new_\(keypair.pubkey)" }

    func writeLocalAutosave() {
        guard case .new = mode else { return }
        // Don't autosave when editing a saved draft — the draft is the source of truth
        // and writes go through `saveDraft()`. Otherwise opening a draft would clobber
        // the .new composer's autosave with the draft's content.
        guard currentDraftId == nil else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            UserDefaults.standard.removeObject(forKey: autosaveKey)
            return
        }
        var payload: [String: Any] = [
            "content": content,
            "explicit": explicit,
            "powEnabled": powEnabled
        ]
        if let ts = scheduleAt?.timeIntervalSince1970 {
            payload["scheduleAt"] = ts
        }
        UserDefaults.standard.set(payload, forKey: autosaveKey)
    }

    func clearLocalAutosave() {
        UserDefaults.standard.removeObject(forKey: autosaveKey)
    }

    private func loadLocalAutosave() {
        guard let payload = UserDefaults.standard.dictionary(forKey: autosaveKey),
              let saved = payload["content"] as? String,
              !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        content = saved
        explicit = payload["explicit"] as? Bool ?? false
        powEnabled = payload["powEnabled"] as? Bool ?? powEnabled
        if let ts = payload["scheduleAt"] as? TimeInterval {
            scheduleAt = Date(timeIntervalSince1970: ts)
        }
    }

    // MARK: - Lifecycle

    func start() async {
        if !blossomLoaded {
            blossomServers = BlossomServerList.cached(for: keypair.pubkey)
            blossomLoaded = true
            // Refresh in the background; first composer open after install hits the network.
            Task { [pubkey = keypair.pubkey] in
                let fresh = await BlossomServerList.refresh(for: pubkey)
                await MainActor.run { self.blossomServers = fresh }
            }
        }
        Task { await EmojiRepository.shared.refresh(for: keypair.pubkey) }
        // Default mention popup state: empty until the user types `@`.
    }

    // MARK: - Toggles

    func toggleGallery() {
        guard mode.allowsGalleryToggle else { return }
        galleryMode.toggle()
        if galleryMode { pollEnabled = false }
    }

    func toggleNsfw() { explicit.toggle() }
    func togglePow() { powEnabled.toggle() }

    // MARK: - Poll mutation

    func togglePoll() {
        guard mode.allowsPollToggle else { return }
        pollEnabled.toggle()
        if pollEnabled { galleryMode = false }
    }

    func updatePollOption(at index: Int, _ text: String) {
        guard pollOptions.indices.contains(index) else { return }
        pollOptions[index] = text
    }

    func addPollOption() {
        guard pollOptions.count < 10 else { return }
        pollOptions.append("")
    }

    func removePollOption(at index: Int) {
        guard pollOptions.count > 2, pollOptions.indices.contains(index) else { return }
        pollOptions.remove(at: index)
    }

    func togglePollType() {
        pollType = (pollType == .singlechoice) ? .multiplechoice : .singlechoice
    }

    func toggleZapPoll() {
        isZapPoll.toggle()
        // Zap polls are always single-choice (Android forces this).
        if isZapPoll { pollType = .singlechoice }
    }

    func setPollEndsAt(_ ts: Int?) {
        pollEndsAt = ts
    }

    // MARK: - Content mutation

    /// Called from the SwiftUI text-field binding. Re-derives mention/emoji/hashtag state.
    func updateContent(_ new: String) {
        // Auto-prefix bare bech32 (`nevent1...`, `note1...`, `nprofile1...`, `npub1...`) with `nostr:`.
        let prefixed = autoPrefixBareBech32(new)
        if prefixed != content {
            content = prefixed
        } else {
            content = new
        }
        recomputeHashtags()
    }

    /// Insert text at the cursor (delegated by the view via a coordinator that knows the
    /// caret). For simplicity v1 appends at end if cursor unknown.
    func append(_ text: String) {
        content += text
        recomputeHashtags()
    }

    // MARK: - Mentions

    /// Caller (the view) reports the substring after `@` and the offset of the `@` itself.
    /// Pass `nil` to dismiss the popup.
    func updateMentionTrigger(query: String?, atOffsetUtf16: Int?) {
        mentionStartUtf16 = atOffsetUtf16
        mentionQuery = query
        if let query {
            mentionCandidates = MentionSearch.search(query: query, currentUserPubkey: keypair.pubkey)
        } else {
            mentionCandidates = []
        }
    }

    func selectMention(_ candidate: MentionCandidate) {
        guard let startOffset = mentionStartUtf16 else { return }
        let displayName = sanitizeDisplayName(candidate.name)
        let view = content.utf16
        guard startOffset >= 0, startOffset <= view.count else { return }
        let startIdx = view.index(view.startIndex, offsetBy: startOffset)
        // Replace from `@` to end of current word (we use end-of-string as the cursor proxy
        // when the view doesn't tell us otherwise — close enough for v1).
        let replacement = "@\(displayName) "
        let prefix = String(view[..<startIdx])!
        let _ = replacement
        let _ = prefix
        // Actual replacement: replace from `startIdx` to end of the buffer back to where
        // the user's cursor is. We approximate by replacing up to the next whitespace
        // or end of string.
        let s = content
        guard let stringStart = s.utf16.index(s.utf16.startIndex, offsetBy: startOffset, limitedBy: s.utf16.endIndex),
              let stringStartIdx = String.Index(stringStart, within: s) else { return }
        // Find end of current token (whitespace or end of string). NBSPs inside
        // a sanitised display name are not token breaks.
        var end = stringStartIdx
        while end < s.endIndex, !s[end].isMentionTokenBreak { end = s.index(after: end) }
        var newContent = s
        newContent.replaceSubrange(stringStartIdx..<end, with: "@\(displayName) ")
        content = newContent
        mentions.append(InsertedMention(displayName: displayName, pubkey: candidate.pubkey))
        mentionQuery = nil
        mentionCandidates = []
        mentionStartUtf16 = nil
        recomputeHashtags()
    }

    // MARK: - Emoji

    func updateEmojiTrigger(query: String?, atOffsetUtf16: Int?) {
        emojiStartUtf16 = atOffsetUtf16
        emojiQuery = query
        if let query {
            emojiCandidates = EmojiRepository.shared.search(query: query)
        } else {
            emojiCandidates = []
        }
    }

    func selectEmoji(_ emoji: CustomEmoji) {
        guard let startOffset = emojiStartUtf16 else { return }
        let s = content
        guard let stringStart = s.utf16.index(s.utf16.startIndex, offsetBy: startOffset, limitedBy: s.utf16.endIndex),
              let stringStartIdx = String.Index(stringStart, within: s) else { return }
        var end = stringStartIdx
        while end < s.endIndex, !s[end].isMentionTokenBreak { end = s.index(after: end) }
        var newContent = s
        newContent.replaceSubrange(stringStartIdx..<end, with: ":\(emoji.shortcode): ")
        content = newContent
        emojiQuery = nil
        emojiCandidates = []
        emojiStartUtf16 = nil
        recomputeHashtags()
    }

    // MARK: - Media

    /// Pick from `PhotosPickerItem` inputs, decode, compress, and upload to Blossom.
    /// Updates `attachments` and `uploadProgress` as work proceeds.
    func addMedia(items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        // Set progress immediately — the picker bridge can take a few seconds for large
        // videos and the user shouldn't be looking at a frozen UI.
        uploadProgress = items.count > 1 ? "Loading \(items.count) items…" : "Loading…"
        defer { if uploadProgress != nil { uploadProgress = nil } }

        let pickResults = await MediaPicker.loadAll(items)
        guard !pickResults.isEmpty else { return }

        let total = pickResults.count
        var uploaded = 0
        for picked in pickResults {
            let pendingId = UUID()
            let pendingMime = picked.mime
            let pendingDim = picked.dim
            var pendingDuration = picked.durationSec
            // For videos `picked.data` is a poster JPEG, not the full clip — perfect for
            // a thumbnail in the composer without holding the whole video in memory.
            let thumbBytes: Data? = picked.isVideo ? (picked.data.isEmpty ? nil : picked.data) : picked.data

            let pending = ComposeAttachment(
                id: pendingId,
                url: nil,
                mime: pendingMime,
                dim: pendingDim,
                durationSec: pendingDuration,
                sha256Hex: nil,
                localBytes: thumbBytes
            )
            attachments.append(pending)

            do {
                let prepared: (Data, String, CGSize)
                if picked.isVideo {
                    guard let sourceURL = picked.sourceURL else {
                        attachments.removeAll { $0.id == pendingId }
                        lastError = "Couldn't read picked video."
                        continue
                    }
                    uploadProgress = total > 1
                        ? "Compressing video \(uploaded + 1)/\(total)…"
                        : "Compressing video…"
                    do {
                        let r = try await MediaCompressor.compressVideo(sourceURL: sourceURL)
                        prepared = (r.data, r.mime, r.dim != .zero ? r.dim : pendingDim)
                        if let d = r.durationSec { pendingDuration = d }
                    } catch {
                        attachments.removeAll { $0.id == pendingId }
                        lastError = "Video compression failed: \(error)"
                        continue
                    }
                    uploadProgress = total > 1 ? "Uploading \(uploaded + 1)/\(total)…" : "Uploading…"
                } else {
                    uploadProgress = total > 1 ? "Uploading \(uploaded + 1)/\(total)…" : "Uploading…"
                    let r = MediaCompressor.compressImage(data: picked.data, mime: pendingMime)
                    prepared = (r.data, r.mime, r.dim)
                }
                guard let privkeyBytes = Hex.decode(keypair.privkey) else {
                    throw BlossomError.authFailed
                }
                let result = try await BlossomClient.upload(
                    bytes: prepared.0,
                    mime: prepared.1,
                    servers: blossomServers,
                    privkey32: privkeyBytes,
                    pubkey: keypair.pubkey
                )
                if let idx = attachments.firstIndex(where: { $0.id == pendingId }) {
                    attachments[idx] = ComposeAttachment(
                        id: pendingId,
                        url: result.url,
                        mime: prepared.1,
                        dim: prepared.2,
                        durationSec: pendingDuration,
                        sha256Hex: result.sha256Hex,
                        localBytes: nil
                    )
                }
                uploaded += 1
            } catch {
                attachments.removeAll { $0.id == pendingId }
                lastError = "Upload failed: \(error)"
            }
        }
        uploadProgress = nil
    }

    func removeMedia(at offsets: IndexSet) {
        attachments.remove(atOffsets: offsets)
    }

    func removeMedia(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    /// Handle images from a SwiftUI `.onPasteCommand([UTType.image])` callback.
    /// Each provider is loaded to bytes, compressed, and uploaded to Blossom — same
    /// pipeline as the photo picker. In non-gallery mode the resulting URL is also
    /// appended to the post body so it shows up in the live preview alongside the
    /// attachment thumbnail.
    func addPastedImages(_ providers: [NSItemProvider]) async {
        guard !providers.isEmpty else { return }
        uploadProgress = providers.count > 1 ? "Loading \(providers.count) images…" : "Loading…"
        defer { if uploadProgress != nil { uploadProgress = nil } }

        var loaded: [(data: Data, mime: String)] = []
        for provider in providers {
            if let result = await loadPastedImageData(from: provider) {
                loaded.append(result)
            }
        }
        guard !loaded.isEmpty else { return }

        let total = loaded.count
        for (i, item) in loaded.enumerated() {
            await uploadImageBytes(data: item.data, mime: item.mime, progressIndex: i, total: total)
        }
        uploadProgress = nil
    }

    private static let pasteImageTypes: [(typeId: String, mime: String)] = [
        ("public.png", "image/png"),
        ("public.jpeg", "image/jpeg"),
        ("public.heic", "image/heic"),
        ("com.compuserve.gif", "image/gif"),
        ("org.webmproject.webp", "image/webp")
    ]

    private func loadPastedImageData(from provider: NSItemProvider) async -> (data: Data, mime: String)? {
        for entry in Self.pasteImageTypes where provider.hasItemConformingToTypeIdentifier(entry.typeId) {
            if let data = await loadDataRepresentation(from: provider, typeIdentifier: entry.typeId) {
                return (data, entry.mime)
            }
        }
        // Fallback for type-id-less providers (rare): re-encode anything decodable as JPEG.
        if let data = await loadDataRepresentation(from: provider, typeIdentifier: "public.image"),
           let img = UIImage(data: data),
           let jpeg = img.jpegData(compressionQuality: 0.92) {
            return (jpeg, "image/jpeg")
        }
        return nil
    }

    private func loadDataRepresentation(from provider: NSItemProvider, typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { cont in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                cont.resume(returning: data)
            }
        }
    }

    private func uploadImageBytes(data: Data, mime: String, progressIndex: Int, total: Int) async {
        let pendingId = UUID()
        let compressed = MediaCompressor.compressImage(data: data, mime: mime)
        let pending = ComposeAttachment(
            id: pendingId,
            url: nil,
            mime: compressed.mime,
            dim: compressed.dim,
            durationSec: nil,
            sha256Hex: nil,
            localBytes: data
        )
        attachments.append(pending)
        uploadProgress = total > 1 ? "Uploading \(progressIndex + 1)/\(total)…" : "Uploading…"
        do {
            guard let privkeyBytes = Hex.decode(keypair.privkey) else {
                throw BlossomError.authFailed
            }
            let result = try await BlossomClient.upload(
                bytes: compressed.data,
                mime: compressed.mime,
                servers: blossomServers,
                privkey32: privkeyBytes,
                pubkey: keypair.pubkey
            )
            if let idx = attachments.firstIndex(where: { $0.id == pendingId }) {
                attachments[idx] = ComposeAttachment(
                    id: pendingId,
                    url: result.url,
                    mime: compressed.mime,
                    dim: compressed.dim,
                    durationSec: nil,
                    sha256Hex: result.sha256Hex,
                    localBytes: nil
                )
            }
        } catch {
            attachments.removeAll { $0.id == pendingId }
            lastError = "Upload failed: \(error)"
        }
    }

    /// Re-host a GIF picked from Giphy on the user's Blossom servers, then
    /// append the resulting URL to the post body. Falls back to the original
    /// Giphy URL if the rehost fails so the user always gets a working link.
    func attachGifFromGiphy(_ giphyURL: String) async {
        uploadProgress = "Uploading GIF…"
        defer { uploadProgress = nil }
        let outcome = await GifBlossomUploader.rehost(
            giphyURL: giphyURL,
            keypair: keypair,
            servers: blossomServers
        )
        if !content.isEmpty, !content.hasSuffix("\n") { content += "\n" }
        content += outcome.url
        content += "\n"
        if !outcome.didRehost {
            lastError = "Couldn't re-host GIF on your Blossom server — using the Giphy link instead."
        }
    }

    // MARK: - Publish

    /// Begin the 10-second undo countdown. Caller must keep the view alive — the
    /// publish fires after the timer elapses unless `cancelPublish()` is called.
    /// When `scheduleAt` is set, the countdown is skipped (no rush — the
    /// scheduler relay holds the post until the chosen time).
    func publish() {
        guard countdownSeconds == nil, !isPublishing else { return }
        if let validation = validate() {
            lastError = validation
            return
        }
        lastError = nil
        if scheduleEnabled {
            Task { await runPublishPipeline() }
            return
        }
        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for n in stride(from: 10, through: 1, by: -1) {
                self.countdownSeconds = n
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
            self.countdownSeconds = nil
            await self.runPublishPipeline()
        }
    }

    func publishNow() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownSeconds = nil
        Task { await runPublishPipeline() }
    }

    func cancelPublish() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownSeconds = nil
        mineTask?.cancel()
        mineTask = nil
        isPublishing = false
        isMining = false
        miningAttempts = 0
    }

    // MARK: - Drafts

    /// Hydrate the composer from a previously saved draft. Reply context is
    /// reconstructed from the draft's `e` and `p` tags — when the parent event
    /// isn't in cache we synthesize a stub `NostrEvent` with id+pubkey only,
    /// matching the Android client's behavior.
    func loadDraft(_ draft: Nip37.Draft) {
        currentDraftId = draft.dTag
        content = draft.content
        recomputeHashtags()

        // Mentions in the text are already materialized as `nostr:nprofile1...`
        // URIs, so we don't need to repopulate the `mentions` array — the rich
        // renderer handles them, and re-publishing won't mangle them because
        // `materializeMentions` is a no-op for tokens it doesn't recognize.

        // Reconstruct reply context from draft tags (Android: Navigation.kt:989).
        let replyTag = draft.tags.first(where: {
            $0.count >= 4 && $0[0] == "e" && $0[3] == "reply"
        })
        let rootTag = draft.tags.first(where: {
            $0.count >= 4 && $0[0] == "e" && $0[3] == "root"
        })
        let parentTag = replyTag ?? rootTag ?? draft.tags.first(where: {
            $0.count >= 2 && $0[0] == "e"
        })
        if let parentTag, parentTag.count >= 2 {
            let parentId = parentTag[1]
            let parentAuthor = draft.tags.first(where: { $0.count >= 2 && $0[0] == "p" })?[1] ?? ""
            let parentStub = NostrEvent(
                id: parentId, pubkey: parentAuthor, kind: 1,
                createdAt: 0, tags: [], content: "", sig: ""
            )
            let rootStub: NostrEvent? = {
                guard let rootTag, rootTag.count >= 2, rootTag[1] != parentId else { return nil }
                return NostrEvent(
                    id: rootTag[1], pubkey: parentAuthor, kind: 1,
                    createdAt: 0, tags: [], content: "", sig: ""
                )
            }()
            mode = .reply(parent: parentStub, root: rootStub)
        }
    }

    /// Save the current buffer as a NIP-37 draft. Idempotent for a given
    /// `currentDraftId` — calling repeatedly updates the same `d` tag.
    /// Sets `draftSaved = true` on success so the view can dismiss.
    func saveDraft() async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let privkey = Hex.decode(keypair.privkey),
              let pub = Hex.decode(keypair.pubkey),
              let convKey = try? Nip44.getConversationKey(privkey32: privkey, peerXonlyPubkey32: pub) else {
            lastError = "Couldn't derive draft encryption key."
            return
        }

        let dTag = currentDraftId ?? Nip37.newDraftId()
        currentDraftId = dTag

        let materialized = materializeMentions(content)
        // Inner kind is always 1 for now (kind-1 notes only — gallery drafts not supported,
        // matches Android).
        let innerKind = 1
        var innerTags: [[String]] = buildBaseTags(kind: innerKind, materializedContent: materialized)
        // Drop client/imeta we don't want in drafts.
        innerTags = innerTags.filter { tag in
            guard let key = tag.first else { return false }
            return key != "client" && key != "imeta"
        }

        let now = Int(Date().timeIntervalSince1970)
        let innerJSON = Nip37.serializeInner(
            pubkeyHex: keypair.pubkey, innerKind: innerKind,
            content: materialized, tags: innerTags, createdAt: now
        )
        guard let cipher = try? Nip44.encrypt(plaintext: innerJSON, conversationKey: convKey) else {
            lastError = "Failed to encrypt draft."
            return
        }
        let wrapperTags = Nip37.wrapperTags(dTag: dTag, innerKind: innerKind)
        guard let wrapper = try? NostrEvent.sign(
            privkey32: privkey, pubkey: keypair.pubkey,
            kind: Nip37.kindDraft, createdAt: now, tags: wrapperTags, content: cipher
        ) else {
            lastError = "Failed to sign draft."
            return
        }

        let relays = topWriteRelays()
        let succeeded = await RelayPool.publish(event: wrapper, to: relays, timeout: 8)
        if !succeeded.isEmpty {
            draftSaved = true
        } else {
            lastError = "Couldn't reach a relay to save the draft."
        }
    }

    /// Mark the active draft as deleted by publishing an empty-content NIP-37
    /// replacement under the same `d` tag. Called after a successful publish
    /// of the underlying note so the draft doesn't linger.
    private func clearDraftOnPublish() async {
        guard let dTag = currentDraftId else { return }
        currentDraftId = nil
        guard let privkey = Hex.decode(keypair.privkey),
              let pub = Hex.decode(keypair.pubkey),
              let convKey = try? Nip44.getConversationKey(privkey32: privkey, peerXonlyPubkey32: pub) else { return }
        let now = Int(Date().timeIntervalSince1970)
        let innerJSON = Nip37.serializeInner(
            pubkeyHex: keypair.pubkey, innerKind: 1, content: "", tags: [], createdAt: now
        )
        guard let cipher = try? Nip44.encrypt(plaintext: innerJSON, conversationKey: convKey),
              let wrapper = try? NostrEvent.sign(
                  privkey32: privkey, pubkey: keypair.pubkey,
                  kind: Nip37.kindDraft, createdAt: now,
                  tags: Nip37.wrapperTags(dTag: dTag, innerKind: 1), content: cipher
              ) else { return }
        _ = await RelayPool.publish(event: wrapper, to: topWriteRelays(), timeout: 6)
    }

    // MARK: - Scheduling

    func setSchedule(_ date: Date?) {
        scheduleAt = date
    }

    // MARK: - Internals

    private func validate() -> String? {
        if pollEnabled {
            let nonBlank = pollOptions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if nonBlank.count < 2 { return "Add at least 2 poll options." }
            if nonBlank.count > 10 { return "Maximum 10 poll options." }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "Add a poll question." }
            return nil
        }
        if galleryMode {
            if attachments.isEmpty || attachments.contains(where: { $0.url == nil }) {
                return "Add at least one image or video."
            }
        } else {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "Type something first." }
            if attachments.contains(where: { $0.url == nil }) { return "Wait for uploads to finish." }
        }
        return nil
    }

    private func runPublishPipeline() async {
        isPublishing = true
        defer { isPublishing = false }

        let kind = determineKind()
        let materialized = materializeMentions(content)
        var tags = buildBaseTags(kind: kind, materializedContent: materialized)
        let postContent = bodyForPublish(kind: kind, materialized: materialized)

        let scheduleTimestamp: Int? = scheduleAt.map { Int($0.timeIntervalSince1970) }
        var createdAt = scheduleTimestamp ?? Int(Date().timeIntervalSince1970)
        // PoW + scheduling don't mix: mining picks `created_at` to satisfy the difficulty
        // target, which would clobber the future timestamp the scheduler relay needs.
        if powEnabled, scheduleTimestamp == nil {
            isMining = true
            miningAttempts = 0
            let pubkey = keypair.pubkey
            let captured = (kind, createdAt, tags, postContent, powDifficulty)
            let mined: Nip13.MineResult? = await withCheckedContinuation { cont in
                let task = Task.detached(priority: .userInitiated) { [weak self] in
                    let result = Nip13.mine(
                        pubkey: pubkey,
                        kind: captured.0,
                        createdAt: captured.1,
                        tags: captured.2,
                        content: captured.3,
                        targetBits: captured.4,
                        onProgress: { attempts in
                            Task { @MainActor [weak self] in self?.miningAttempts = attempts }
                        }
                    )
                    cont.resume(returning: result)
                    _ = self
                }
                self.mineTask = task
            }
            isMining = false
            mineTask = nil
            guard let mined else {
                lastError = "Proof-of-work cancelled."
                return
            }
            tags = mined.tags
            createdAt = mined.createdAt
        }

        guard let privkeyBytes = Hex.decode(keypair.privkey) else {
            lastError = "Invalid signing key."
            return
        }

        let event: NostrEvent
        do {
            event = try NostrEvent.sign(
                privkey32: privkeyBytes,
                pubkey: keypair.pubkey,
                kind: kind,
                createdAt: createdAt,
                tags: tags,
                content: postContent
            )
        } catch {
            lastError = "Signing failed: \(error)"
            return
        }

        if scheduleTimestamp != nil {
            let relay = DraftsViewModel.schedulerRelay
            await GroupRelayPool.shared.ensureRelay(relay, keypair: keypair)
            let result = await GroupRelayPool.shared.publishWithAuthRetry(event, to: relay)
            switch result {
            case .ok, .duplicate:
                publishedEventId = event.id
                clearLocalAutosave()
                await clearDraftOnPublish()
                Haptics.shared.pulse()
            default:
                lastError = "Scheduler relay rejected the post."
            }
            return
        }

        let relays = topWriteRelays()
        let succeeded = await RelayPool.publish(event: event, to: relays, timeout: 8)
        if succeeded.isEmpty {
            lastError = "No relays accepted the post."
        } else {
            publishedEventId = event.id
            clearLocalAutosave()
            await EventStore.shared.persist([event])
            await clearDraftOnPublish()
            Haptics.shared.pulse()
        }
    }

    private func determineKind() -> Int {
        if pollEnabled {
            return isZapPoll ? Nip69.kindZapPoll : Nip88.kindPoll
        }
        guard galleryMode else { return 1 }
        if attachments.contains(where: { $0.isVideo }) {
            // Pick orientation from the first video.
            if let video = attachments.first(where: { $0.isVideo }) {
                return Nip71.kindFor(width: Int(video.dim.width), height: Int(video.dim.height))
            }
            return Nip71.kindVideoVertical
        }
        return Nip68.kindPicture
    }

    /// For regular notes the body is the materialized content with attachment URLs
    /// spliced onto the end (in `attachments` order). For gallery events the body
    /// is just the caption — upload URLs ride in `imeta` tags instead.
    private func bodyForPublish(kind: Int, materialized: String) -> String {
        switch kind {
        case Nip68.kindPicture, Nip71.kindVideoHorizontal, Nip71.kindVideoVertical:
            return materialized
        default:
            return appendAttachmentUrls(to: materialized)
        }
    }

    private func appendAttachmentUrls(to body: String) -> String {
        let urls = attachments.compactMap { $0.url }
        guard !urls.isEmpty else { return body }
        var out = body
        for url in urls {
            if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
            out += url
        }
        return out
    }

    /// Content as it would appear in the published note, including any spliced
    /// attachment URLs. Used by the live preview card so pasted/uploaded images
    /// render inline even though the URLs no longer live in `content`.
    var previewContent: String {
        bodyForPublish(kind: determineKind(), materialized: content)
    }

    /// Replace each `@displayName` token with `nostr:nprofile1...` (per stored mentions).
    private func materializeMentions(_ source: String) -> String {
        var out = source
        for mention in mentions {
            guard let bytes = Hex.decode(mention.pubkey) else { continue }
            guard let nprofile = Nip19.nprofileEncode(pubkey32: Array(bytes)) else { continue }
            let needle = "@\(mention.displayName)"
            if let range = out.range(of: needle) {
                out.replaceSubrange(range, with: "nostr:\(nprofile)")
            }
        }
        return out
    }

    private func buildBaseTags(kind: Int, materializedContent: String) -> [[String]] {
        var tags: [[String]] = []

        // Reply / quote contextual tags.
        switch mode {
        case .new:
            break
        case .reply(let parent, let root):
            if let root {
                tags.append(["e", root.id, "", "root"])
                if root.id != parent.id {
                    tags.append(["e", parent.id, "", "reply"])
                }
            } else {
                tags.append(["e", parent.id, "", "reply"])
            }
            tags.append(["p", parent.pubkey])
        case .quote(let q):
            tags.append(contentsOf: Nip18.buildQuoteTags(event: q))
        }

        // Mentioned `p` tags from inline mentions, not already present.
        var existingP = Set(tags.compactMap { $0.count >= 2 && $0[0] == "p" ? $0[1] : nil })
        for mention in mentions where !existingP.contains(mention.pubkey) {
            tags.append(["p", mention.pubkey])
            existingP.insert(mention.pubkey)
        }

        // Pre-existing nostr URIs in content -> p tags for profile refs.
        for pubkey in extractProfilePubkeys(materializedContent) where !existingP.contains(pubkey) {
            tags.append(["p", pubkey])
            existingP.insert(pubkey)
        }

        // Hashtags.
        for tag in hashtags {
            tags.append(["t", tag])
        }

        // Poll tags: NIP-88 (kind 1068) or NIP-69 zap poll (kind 6969).
        if pollEnabled {
            let nonBlank = pollOptions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let pollRelays = topWriteRelays()
            if isZapPoll {
                let opts = nonBlank.enumerated().map { Nip69.ZapPollOption(index: $0.offset, label: $0.element) }
                tags.append(contentsOf: Nip69.buildZapPollTags(
                    options: opts,
                    valueMinimum: zapPollMinSats,
                    valueMaximum: zapPollMaxSats,
                    consensusThreshold: nil,
                    closedAt: pollEndsAt,
                    relayUrls: pollRelays
                ))
            } else {
                let opts = nonBlank.map { Nip88.PollOption(id: Nip88.generateOptionId(), label: $0) }
                tags.append(contentsOf: Nip88.buildPollTags(
                    options: opts,
                    pollType: pollType,
                    endsAt: pollEndsAt,
                    relayUrls: pollRelays
                ))
            }
            if explicit { tags.append(["content-warning", ""]) }
            if let clientTag = NostrEvent.clientTagIfEnabled() { tags.append(clientTag) }
            return tags
        }

        // Kind-specific: imeta for gallery, content-warning for NSFW.
        if galleryMode {
            switch kind {
            case Nip68.kindPicture:
                let imeta: [Nip68.ImetaEntry] = attachments.compactMap { a in
                    guard let url = a.url else { return nil }
                    let dim = a.dim != .zero ? "\(Int(a.dim.width))x\(Int(a.dim.height))" : nil
                    return Nip68.ImetaEntry(url: url, mimeType: a.mime, dim: dim, hash: a.sha256Hex)
                }
                let extra = Nip68.buildPictureTags(
                    title: nil,
                    media: imeta,
                    hashtags: [],
                    contentWarning: explicit ? "" : nil
                )
                tags.append(contentsOf: extra)
            case Nip71.kindVideoHorizontal, Nip71.kindVideoVertical:
                let videos: [Nip71.VideoMeta] = attachments.compactMap { a in
                    guard let url = a.url else { return nil }
                    let dim = a.dim != .zero ? "\(Int(a.dim.width))x\(Int(a.dim.height))" : nil
                    return Nip71.VideoMeta(url: url, mimeType: a.mime, dim: dim, duration: a.durationSec, hash: a.sha256Hex)
                }
                let extra = Nip71.buildVideoTags(
                    title: nil,
                    media: videos,
                    hashtags: [],
                    contentWarning: explicit ? "" : nil
                )
                tags.append(contentsOf: extra)
            default:
                break
            }
        } else if explicit {
            tags.append(["content-warning", ""])
        }

        if let clientTag = NostrEvent.clientTagIfEnabled() { tags.append(clientTag) }

        return tags
    }

    private func recomputeHashtags() {
        let regex = try? NSRegularExpression(pattern: "(?<![\\w])#([\\p{L}\\p{N}_]{1,64})", options: [])
        guard let regex else { hashtags = []; return }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        var seen = Set<String>()
        var out: [String] = []
        regex.enumerateMatches(in: content, range: range) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 2,
                  let r = Range(m.range(at: 1), in: content) else { return }
            let tag = String(content[r]).lowercased()
            if seen.insert(tag).inserted { out.append(tag) }
        }
        hashtags = out
    }

    private func autoPrefixBareBech32(_ s: String) -> String {
        let pattern = "(?<![a-z0-9:./])(?<!nostr:)(nevent1|note1|nprofile1|naddr1|npub1)([a-z0-9]{20,})"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        let matches = regex.matches(in: s, range: range)
        if matches.isEmpty { return s }
        var out = s
        for m in matches.reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            let token = String(out[r])
            if Nip19.decodeNostrUri(token) != nil {
                out.replaceSubrange(r, with: "nostr:\(token)")
            }
        }
        return out
    }

    private func extractProfilePubkeys(_ s: String) -> [String] {
        let pattern = "nostr:(npub1[a-z0-9]+|nprofile1[a-z0-9]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        var out: [String] = []
        regex.enumerateMatches(in: s, range: range) { match, _, _ in
            guard let m = match, let r = Range(m.range, in: s) else { return }
            let token = String(s[r])
            if case .profileRef(let pk, _)? = Nip19.decodeNostrUri(token) {
                out.append(pk)
            }
        }
        return out
    }

    private func sanitizeDisplayName(_ name: String) -> String {
        // Replace plain spaces with non-breaking spaces so a multi-word display
        // name reads visually as a space in the editor while staying a single
        // contiguous token for the @-trigger parser. Mention-aware whitespace
        // checks (`isMentionTokenBreak`) ignore U+00A0.
        let cleaned = name.replacingOccurrences(of: " ", with: "\u{00A0}")
            .replacingOccurrences(of: "@", with: "")
        return cleaned.isEmpty ? "user" : cleaned
    }

    private func topWriteRelays() -> [String] {
        RelayRouting.topWriteRelays(for: keypair.pubkey)
    }
}

extension Character {
    /// Whitespace check used by the mention / emoji trigger parser. Identical to
    /// `isWhitespace` except non-breaking space (U+00A0) is treated as part of
    /// the token, so multi-word display names that `sanitizeDisplayName` joined
    /// with NBSP stay a single `@displayName` token.
    var isMentionTokenBreak: Bool {
        if self == "\u{00A0}" { return false }
        return isWhitespace
    }
}
