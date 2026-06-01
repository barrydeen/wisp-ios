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
            LiveNowRow(streams: liveStreams, profiles: profiles, onSelect: onSelect)
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
        }
    }
}

/// Horizontal pill row shown at the top of the home feed listing live NIP-53 streams
/// the user follows. Sorted by chatter count descending.
struct LiveNowRow: View {
    let streams: [LiveStream]
    let profiles: [String: ProfileData]
    let onSelect: (LiveStream) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                liveBadge
                ForEach(streams) { stream in
                    LiveNowPill(stream: stream, profile: profiles[stream.activity.streamerPubkey ?? stream.activity.hostPubkey])
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
