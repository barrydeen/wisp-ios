import SwiftUI

struct ComposerPreviewCard: View {
    let content: String
    let tags: [[String]]
    var pollOptions: [String]? = nil
    let userProfile: ProfileData?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CachedAvatarView(url: userProfile?.picture, size: 32)
                Text(userProfile?.displayString ?? "you")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Preview")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.wispSurfaceVariant.opacity(0.7), in: Capsule())
                    .foregroundStyle(.secondary)
            }

            RichContentView(
                content: content,
                tags: tags,
                profiles: [:],
                // Render link preview cards inline the same way the
                // published note will. The composer's prefetch warms
                // `LinkPreviewService`'s cache for these URLs so the
                // card paints from cache instead of flashing a spinner
                // — the user gets to see what their post will look like
                // before they hit Publish.
                showLinkPreviews: true,
                // Preview is read-only — mentions render as colored text
                // (`wispPrimary`) without the editor's capsule background,
                // so the user isn't tricked into thinking they can edit
                // the pill from here. The composer's editable surface
                // still gets the capsule via its own `.wispMentionPill`
                // attribute pass.
                mentionPillStyle: false,
                // The card has its own horizontal padding, so the gallery
                // must size against the card's available width instead of
                // the feed's edge-bleed math — without this, a 2+ image
                // post paints past the card's right edge.
                nested: true,
                isPreview: true
            )

            if let options = pollOptions, !options.isEmpty {
                pollPreview(options: options)
            }
        }
        .padding(12)
        .background(Color.wispSurfaceVariant.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.wispSurfaceVariant, lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func pollPreview(options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options.indices, id: \.self) { idx in
                HStack(spacing: 8) {
                    Circle()
                        .strokeBorder(Color.wispPrimary, lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                    Text(options[idx])
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
    }
}
