import SwiftUI

/// Wraps `LiveNowRow` so the home feed's `LazyVStack` body never reads
/// `LiveStreamRepository.streams` directly. Discovery rewrites `streams` on
/// every live chat message; keeping that read inside this subview scopes the
/// `@Observable` invalidation here instead of re-evaluating the whole feed
/// body (and its `ForEach` of `PostCardView`s) on every chat event.
struct FeedLiveNowSection: View {
    let profiles: [String: ProfileData]
    let onSelect: (LiveStream) -> Void
    @State private var repo = LiveStreamRepository.shared

    var body: some View {
        let liveStreams = repo.liveNowSorted
        if !liveStreams.isEmpty {
            // The feed's `profiles` dict only covers feed-row authors — a live
            // host is usually not in it. Pills look up `repo.hostProfiles`
            // (the dedicated observable store for pill avatars) first and fall
            // back to the feed dict. Per-pill lookups, NOT a dict merge: this
            // body re-evaluates on every discovery chat message, and merging
            // the whole feed-profiles dict each time is real main-thread work
            // during the startup chat backfill.
            let hostProfiles = repo.hostProfiles
            LiveNowRow(streams: liveStreams, profiles: profiles, hostProfiles: hostProfiles, onSelect: onSelect)
                .task(id: missingHostPubkeys(streams: liveStreams, hostProfiles: hostProfiles)) {
                    // Self-heal pills whose host kind-0 never resolved (e.g. the
                    // coordinator's startup query timed out). Routed through the
                    // coordinator's debounced batch — NOT a direct
                    // `ProfileRepository.ensure` — so streams trickling in during
                    // startup collapse into one light indexer query instead of
                    // overlapping `waitForAllRelays` fetches competing with the
                    // initial feed load. The coordinator caps retries per pubkey.
                    for pk in missingHostPubkeys(streams: liveStreams, hostProfiles: hostProfiles) {
                        LiveStreamCoordinator.shared.requestHostProfile(pk)
                    }
                }
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
        }
    }

    /// Pubkeys of visible pills that have no profile from any source yet.
    private func missingHostPubkeys(streams: [LiveStream], hostProfiles: [String: ProfileData]) -> Set<String> {
        Set(streams.map { $0.activity.streamerPubkey ?? $0.activity.hostPubkey }
            .filter { hostProfiles[$0] == nil && profiles[$0] == nil })
    }
}

/// Horizontal pill row shown at the top of the home feed listing live NIP-53 streams
/// the user follows. Sorted by chatter count descending.
struct LiveNowRow: View {
    let streams: [LiveStream]
    let profiles: [String: ProfileData]
    let hostProfiles: [String: ProfileData]
    let onSelect: (LiveStream) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                liveBadge
                ForEach(streams) { stream in
                    let key = stream.activity.streamerPubkey ?? stream.activity.hostPubkey
                    LiveNowPill(stream: stream, profile: hostProfiles[key] ?? profiles[key])
                        .onTapGesture { onSelect(stream) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
    }

    private var liveBadge: some View {
        Text("LIVE")
            .font(.caption2.weight(.heavy))
            .tracking(0.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(red: 0.898, green: 0.224, blue: 0.208), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct LiveNowPill: View {
    let stream: LiveStream
    let profile: ProfileData?

    var body: some View {
        HStack(spacing: 8) {
            CachedAvatarView(url: profile?.picture, size: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text(stream.activity.title ?? profile?.displayName ?? "Live Stream")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.wispOnSurface)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 160, alignment: .leading)
                Text("\(stream.chatters.count) chatting")
                    .font(.caption2)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 14)
        .padding(.vertical, 4)
        .frame(height: 48)
        .background(Color.wispPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 28))
    }
}

/// Navigation route for opening a `LiveStreamView` from the pill row.
struct LiveStreamRoute: Hashable {
    let aTagValue: String
    let hostPubkey: String
    let dTag: String
    let relayHints: [String]
}
