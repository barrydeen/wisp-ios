import SwiftUI

/// Inline article preview for a kind-30023 long-form event that arrives in a
/// feed, profile, or thread as a top-level note. Renders the rich card —
/// hero image, "ARTICLE" badge, title, summary — instead of dumping the raw
/// markdown body through `RichContentView`. Tapping pushes an `ArticleRoute`
/// to open the full reader. 1:1 with Android's `FeedArticleItem`
/// (`FeedScreen.kt`), minus the author row + action bar, which `PostCardView`
/// already supplies around it.
///
/// Distinct from `ArticleCardView`, which resolves a `nostr:naddr1…` embed by
/// fetching the article: here the full event is already in hand, so there is
/// no loading / missing / retry state.
struct ArticleFeedPreview: View {
    let event: NostrEvent
    var relayHints: [String] = []

    private func firstTag(_ name: String) -> String? {
        event.tags.first(where: { $0.count >= 2 && $0[0] == name })?[1]
    }

    private var dTag: String { firstTag("d") ?? "" }

    var body: some View {
        let title = firstTag("title")
        let summary = firstTag("summary")
        let image = firstTag("image")

        return NavigationLink(
            value: ArticleRoute(author: event.pubkey, dTag: dTag, relayHints: relayHints)
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if let image, let imageUrl = URL(string: image) {
                    heroImage(imageUrl, urlString: image, title: title)
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
                            .font(AppFont.scaled(15, weight: .semibold))
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
    }

    /// Hero image: aspect ratio from the article's NIP-92 imeta tag when
    /// present, else a 2:1 frame approximating Android's 180dp cap. Matches
    /// `ArticleCardView.heroImage`.
    @ViewBuilder
    private func heroImage(_ url: URL, urlString: String, title: String?) -> some View {
        let meta = ContentParser.parseImetaTags(event.tags)[urlString]
        let ratio = ContentParser.parseAspectRatio(meta?.dimension)
        let safeRatio = (ratio ?? 0) > 0 ? ratio! : 2.0

        Color.clear
            .aspectRatio(safeRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(
                RetryingAsyncImage(
                    url: url,
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
}
