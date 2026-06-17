import SwiftUI

/// Rich preview card for a NIP-23 long-form article (kind 30023) referenced
/// inside note content via `nostr:naddr1…`. 1:1 port of Android's
/// `ArticleCard` (`RichContent.kt`): hero image, "ARTICLE" badge + title,
/// summary, author + published date footer. Tapping the card pushes an
/// `ArticleRoute`; tapping the author name routes to their profile.
///
/// State machine mirrors `QuotedNoteView`: loading → loaded / missing
/// (tap-to-retry with one silent auto-retry) plus blocked / safety-hidden
/// stubs so filtered authors never render.
struct ArticleCardView: View {
    let dTag: String
    let author: String
    let relayHints: [String]
    let profiles: [String: ProfileData]
    var onProfileTap: ((String) -> Void)? = nil

    @State private var event: NostrEvent?
    @State private var loaded = false
    @State private var blocked = false
    @State private var safetyHidden = false
    @State private var profile: ProfileData?
    @State private var attempt: Int = 0

    /// One silent redundancy retry on initial miss — broadens the relay set
    /// without making the user tap. Matches `QuotedNoteView`.
    private static let autoRetryAttempts = 1

    var body: some View {
        Group {
            if blocked {
                stubCard(icon: "nosign", text: "Article from a blocked user")
            } else if safetyHidden {
                stubCard(icon: "eye.slash", text: "Article hidden by your safety filters")
            } else if let event {
                articleCard(event)
            } else if loaded {
                missingCard
            } else {
                loadingCard
            }
        }
        .task(id: TaskKey(dTag: dTag, author: author, attempt: attempt)) { await load() }
        // Re-gate in place on safety-filter snapshot installs — same rationale
        // as QuotedNoteView: a resolved article keeps rendering after the
        // filter tightens (and a hidden one stays hidden after it relaxes)
        // unless we re-evaluate here.
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
            Text("Loading article…")
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
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text("Article not found")
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
        .accessibilityLabel("Article not found. Tap to retry.")
    }

    // MARK: - Loaded card

    private func articleCard(_ event: NostrEvent) -> some View {
        let title = firstTag(event, "title")
        let summary = firstTag(event, "summary")
        let image = firstTag(event, "image")
        let publishedAt = firstTag(event, "published_at").flatMap { Int($0) }

        return NavigationLink(value: ArticleRoute(author: author, dTag: dTag, relayHints: relayHints)) {
            VStack(alignment: .leading, spacing: 0) {
                if let image, let imageUrl = URL(string: image) {
                    heroImage(imageUrl, event: event, urlString: image, title: title)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 8) {
                        Text("ARTICLE")
                            .font(AppFont.labelSmall)
                            .foregroundStyle(Color.wispPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.wispPrimary.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                        Text(title ?? "Untitled Article")
                            .font(AppFont.scaled(14, weight: .semibold))
                            .foregroundStyle(Color.wispOnSurface)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(summary)
                            .font(AppFont.bodySmall)
                            .foregroundStyle(Color.wispOnSurfaceVariant)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                    HStack(spacing: 0) {
                        // Author name + avatar route to the profile; the rest
                        // of the card opens the article via the surrounding
                        // NavigationLink.
                        Button {
                            onProfileTap?(author)
                        } label: {
                            HStack(spacing: 6) {
                                CachedAvatarView(url: profile?.picture, size: 20)
                                EmojiText(
                                    profile?.displayString ?? Nip19.shortNpub(hex: author),
                                    emojiMap: profile?.emojiMap ?? [:],
                                    textStyle: .caption1,
                                    weight: .medium,
                                    color: UIColor(Color.wispOnSurfaceVariant)
                                )
                            }
                        }
                        .buttonStyle(.plain)
                        if let publishedAt {
                            Text(" · \(Self.formatQuotedTimestamp(publishedAt))")
                                .font(AppFont.scaled(12, weight: .medium))
                                .foregroundStyle(Color.wispOnSurfaceVariant.opacity(0.7))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.wispSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.wispOutline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
    }

    /// Hero image: aspect ratio from the article's NIP-92 imeta tag when
    /// present, else capped at 180pt — matches Android's
    /// `aspectRatio(ratio) / heightIn(max = 180.dp)` + Crop scaling.
    @ViewBuilder
    private func heroImage(_ url: URL, event: NostrEvent, urlString: String, title: String?) -> some View {
        let meta = ContentParser.parseImetaTags(event.tags, authorPubkey: event.pubkey)[urlString]
        let ratio = ContentParser.parseAspectRatio(meta?.dimension)
        // A malformed imeta dim ("0x100") parses to ratio 0 — treat any
        // non-positive ratio as missing so the frame never degenerates.
        let safeRatio = (ratio ?? 0) > 0 ? ratio! : heroFallbackRatio

        Color.clear
            .aspectRatio(safeRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(
                RetryingAsyncImage(
                    url: url,
                    authorPubkey: event.pubkey,
                    content: { image in
                        image
                            .resizable()
                            .scaledToFill()
                    },
                    loading: {
                        Rectangle().fill(Color.wispSurfaceVariant.opacity(0.4))
                            .overlay(ProgressView().controlSize(.small))
                    },
                    failure: {
                        Rectangle().fill(Color.wispSurfaceVariant.opacity(0.4))
                    }
                )
            )
            .clipped()
            .accessibilityLabel(title ?? "Article image")
    }

    /// Without imeta dimensions Android caps the hero at 180dp tall; a 2:1
    /// frame approximates that for typical card widths.
    private var heroFallbackRatio: CGFloat { 2.0 }

    /// Port of Android's `formatQuotedTimestamp`: "Ns" / "Nm" / "Nh" /
    /// "yesterday" / "MMM d" — different bucketing from the app-wide
    /// `relativeTime(from:)`, kept for card parity.
    static func formatQuotedTimestamp(_ epoch: Int) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince1970) - epoch)
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24
        if seconds < 60 { return "\(seconds)s" }
        if minutes < 60 { return "\(minutes)m" }
        if hours < 24 { return "\(hours)h" }
        if days == 1 { return "yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
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
        if let cached = ArticleCache.shared.cached(author: author, dTag: dTag) {
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
        // Re-enter the loading state so a tap-to-retry hides the missing
        // card while the next attempt is in flight.
        loaded = false
        event = nil

        let result: NostrEvent?
        if attempt == 0 {
            result = await ArticleCache.shared.fetch(author: author, dTag: dTag, relayHints: relayHints)
        } else {
            // Brief backoff before broader retries — same curve as QuotedNoteView.
            let delay = min(3.0, 0.75 * Double(attempt))
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            result = await ArticleCache.shared.refetch(
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
