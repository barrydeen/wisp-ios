import SwiftUI

/// Rich, playable preview card for a music-track event (kind 36787) referenced
/// inside note content via `nostr:naddr1…`. Compact horizontal layout: square
/// artwork, "MUSIC" badge + title, artist, optional author footer, and a
/// play/pause control wired into the global `AudioPlayerStore` (so playback
/// survives row recycling and drives the floating mini-player + lock-screen
/// chrome, exactly like `InlineAudioView`).
///
/// State machine mirrors `ArticleCardView`: loading → loaded / missing
/// (tap-to-retry with one silent auto-retry) plus blocked / safety-hidden stubs
/// so filtered authors never render or play.
struct MusicTrackCardView: View {
    let dTag: String
    let author: String
    let relayHints: [String]
    let profiles: [String: ProfileData]
    var onProfileTap: ((String) -> Void)? = nil

    @Environment(AudioPlayerStore.self) private var store

    @State private var event: NostrEvent?
    @State private var loaded = false
    @State private var blocked = false
    @State private var safetyHidden = false
    @State private var profile: ProfileData?
    @State private var attempt: Int = 0

    /// One silent redundancy retry on initial miss — broadens the relay set
    /// without making the user tap. Matches `ArticleCardView`.
    private static let autoRetryAttempts = 1

    var body: some View {
        Group {
            if blocked {
                stubCard(icon: "nosign", text: "Track from a blocked user")
            } else if safetyHidden {
                stubCard(icon: "eye.slash", text: "Track hidden by your safety filters")
            } else if let event {
                musicTrackCard(event)
            } else if loaded {
                missingCard
            } else {
                loadingCard
            }
        }
        .task(id: TaskKey(dTag: dTag, author: author, attempt: attempt)) { await load() }
        // Re-gate in place on safety-filter snapshot installs — same rationale
        // as ArticleCardView: a resolved track keeps rendering after the filter
        // tightens (and a hidden one stays hidden after it relaxes) unless we
        // re-evaluate here.
        .onReceive(NotificationCenter.default.publisher(for: .safetyFilterChanged)) { _ in
            if let event,
               SafetyFilter.shared.shouldDrop(event: event, context: .feed) {
                self.event = nil
                safetyHidden = true
                loaded = true
            } else if safetyHidden {
                safetyHidden = false
                loaded = false
                attempt += 1
            }
        }
    }

    /// Composite key so a retry (attempt bump) re-runs `.task` the same way a
    /// coordinate change does.
    private struct TaskKey: Hashable {
        let dTag: String
        let author: String
        let attempt: Int
    }

    // MARK: - States

    private var loadingCard: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.wispOnSurfaceVariant)
            Text("Loading track…")
                .font(AppFont.bodyMedium)
                .foregroundStyle(Color.wispOnSurfaceVariant)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.wispOutline, lineWidth: 1)
        )
        .padding(.vertical, 6)
    }

    private func stubCard(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispSurfaceVariant.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.wispSurfaceVariant, lineWidth: 1)
        )
        .padding(.vertical, 6)
        .accessibilityLabel(text)
    }

    private var missingCard: some View {
        Button {
            attempt += 1
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                Text("Music track not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.wispPrimary)
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
        .buttonStyle(.plain)
        .padding(.vertical, 6)
        .accessibilityLabel("Music track not found. Tap to retry.")
    }

    // MARK: - Loaded card

    private func musicTrackCard(_ event: NostrEvent) -> some View {
        let title = firstTag(event, "title")
        let artist = firstTag(event, "artist")
        let audioUrl = firstTag(event, "url")
        let image = firstTag(event, "image")
        let durationSecs = firstTag(event, "duration").flatMap { Int($0) }

        let isCurrent = audioUrl.map { store.isCurrent(url: $0) } ?? false
        let playing = isCurrent && store.isPlaying

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                artwork(image: image)

                VStack(alignment: .leading, spacing: 3) {
                    Text("MUSIC")
                        .font(AppFont.labelSmall)
                        .foregroundStyle(Color.wispPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.wispPrimary.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))

                    Text(title ?? "Untitled Track")
                        .font(AppFont.scaled(14, weight: .semibold))
                        .foregroundStyle(Color.wispOnSurface)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let artist, !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(artist)
                            .font(AppFont.bodySmall)
                            .foregroundStyle(Color.wispOnSurfaceVariant)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    authorFooter
                }

                Spacer(minLength: 0)

                playButton(audioUrl: audioUrl, title: title, artist: artist, image: image, playing: playing)
            }

            // Active scrubber when this track owns the global player; otherwise
            // the static duration on the right of the play button suffices.
            if isCurrent {
                progressStrip
            } else if let durationSecs {
                HStack {
                    Spacer()
                    Text(formatTime(Double(durationSecs)))
                        .font(.caption2)
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                }
                .padding(.top, 8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.wispOutline, lineWidth: 1)
        )
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func artwork(image: String?) -> some View {
        let side: CGFloat = 64
        Group {
            if let image, let url = URL(string: image) {
                RetryingAsyncImage(
                    url: url,
                    content: { img in
                        img.resizable().scaledToFill()
                    },
                    loading: {
                        Rectangle().fill(Color.wispSurfaceVariant.opacity(0.4))
                            .overlay(ProgressView().controlSize(.small))
                    },
                    failure: { artworkPlaceholder }
                )
            } else {
                artworkPlaceholder
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private var artworkPlaceholder: some View {
        Rectangle()
            .fill(Color.wispSurfaceVariant.opacity(0.4))
            .overlay(
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
            )
    }

    @ViewBuilder
    private var authorFooter: some View {
        Button {
            onProfileTap?(author)
        } label: {
            HStack(spacing: 6) {
                CachedAvatarView(url: profile?.picture, size: 18)
                EmojiText(
                    profile?.displayString ?? Nip19.shortNpub(hex: author),
                    emojiMap: profile?.emojiMap ?? [:],
                    textStyle: .caption2,
                    weight: .medium,
                    color: UIColor(Color.wispOnSurfaceVariant)
                )
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func playButton(audioUrl: String?, title: String?, artist: String?, image: String?, playing: Bool) -> some View {
        Button {
            guard let audioUrl else { return }
            if store.isCurrent(url: audioUrl) {
                store.togglePlayPause()
            } else {
                store.play(AudioTrack(
                    url: audioUrl,
                    title: title,
                    artist: artist,
                    artworkUrl: image,
                    authorPubkey: author
                ))
            }
        } label: {
            Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.wispPrimary)
        }
        .buttonStyle(.plain)
        .disabled(audioUrl == nil)
        .opacity(audioUrl == nil ? 0.4 : 1)
        .accessibilityLabel(playing ? "Pause" : "Play")
    }

    private var progressStrip: some View {
        let position = Double(store.positionMs) / 1000
        let duration = max(0.001, Double(store.durationMs) / 1000)
        return VStack(spacing: 4) {
            ProgressView(value: min(position, duration), total: duration)
                .tint(Color.wispPrimary)
            HStack {
                Text(formatTime(position))
                    .font(.caption2)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                Spacer()
                Text(formatTime(duration))
                    .font(.caption2)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
            }
        }
        .padding(.top, 8)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Loading

    private func firstTag(_ event: NostrEvent, _ name: String) -> String? {
        event.tags.first(where: { $0.count >= 2 && $0[0] == name })?[1]
    }

    private func load() async {
        if SafetyFilter.shared.snapshot.blockedPubkeys.contains(author) {
            blocked = true
            loaded = true
            return
        }
        if let cached = MusicTrackCache.shared.cached(author: author, dTag: dTag) {
            if SafetyFilter.shared.shouldDrop(event: cached, context: .feed) {
                self.safetyHidden = true
                loaded = true
                return
            }
            self.event = cached
            self.profile = profiles[author] ?? ProfileRepository.shared.get(author)
            loaded = true
            return
        }
        // Re-enter the loading state so a tap-to-retry hides the missing card
        // while the next attempt is in flight.
        loaded = false
        event = nil

        let result: NostrEvent?
        if attempt == 0 {
            result = await MusicTrackCache.shared.fetch(author: author, dTag: dTag, relayHints: relayHints)
        } else {
            // Brief backoff before broader retries — same curve as ArticleCardView.
            let delay = min(3.0, 0.75 * Double(attempt))
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            result = await MusicTrackCache.shared.refetch(
                author: author,
                dTag: dTag,
                relayHints: relayHints,
                attempt: attempt
            )
        }
        if Task.isCancelled { return }

        if let result {
            if SafetyFilter.shared.shouldDrop(event: result, context: .feed) {
                self.safetyHidden = true
                loaded = true
                return
            }
            self.event = result
            self.profile = profiles[author] ?? ProfileRepository.shared.get(author)
            loaded = true
            // The card may render before the author's profile has resolved —
            // hydrate it in the background so the footer fills in.
            if self.profile == nil {
                Task {
                    let got = await ProfileRepository.shared.ensure([author])
                    if let p = got[author] { self.profile = p }
                }
            }
            return
        }
        if attempt < Self.autoRetryAttempts {
            attempt += 1
        } else {
            loaded = true
        }
    }
}
