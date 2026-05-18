import SwiftUI

struct MentionCandidateRow: View {
    let candidate: MentionCandidate
    /// Short npub to render beneath the name when multiple candidates
    /// share the same display name. Nil when the name is unique in the
    /// popup. Lets the author tell impersonators / clones apart at a
    /// glance — the underlying pubkeys are different, just the metadata
    /// is identical.
    var disambiguationNpub: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            CachedAvatarView(url: candidate.picture, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let nip = candidate.nip05, !nip.isEmpty {
                    Text(nip)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let npub = disambiguationNpub {
                    Text(npub)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if candidate.isFollowing {
                Text("Following")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.wispSurfaceVariant, in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }
}
