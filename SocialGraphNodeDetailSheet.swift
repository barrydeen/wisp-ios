import SwiftUI

/// Bottom sheet shown when the user taps a node on the social graph canvas (or a row in
/// the ranked list). Displays the profile, the within-network follower count, and an
/// avatar strip of the first-degree followers (loaded on demand from the SQLite store).
struct SocialGraphNodeDetailSheet: View {
    let node: GraphNode
    let activeUserPubkey: String
    let profile: ProfileData?
    let profiles: [String: ProfileData]
    let followers: [String]                    // first-degree pubkeys who follow this node
    let onProfileTap: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            CachedAvatarView(url: profile?.picture, size: 72)
                .quickFollowOnLongPress(pubkey: node.pubkey)
                .padding(.top, 8)

            VStack(spacing: 4) {
                Text(profile?.displayString ?? truncated(node.pubkey))
                    .font(.headline)
                if let nip05 = profile?.nip05, !nip05.isEmpty {
                    Text(nip05)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Followed by \(node.followerCount) of your follows")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !followers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: -8) {
                        ForEach(followers.prefix(30), id: \.self) { pk in
                            Button {
                                onProfileTap(pk)
                            } label: {
                                CachedAvatarView(url: profiles[pk]?.picture, size: 36)
                                    .overlay(Circle().stroke(Color.wispBackground, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .quickFollowOnLongPress(pubkey: pk)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            Button {
                onProfileTap(node.pubkey)
                onDismiss()
            } label: {
                Text("View Profile")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.wispPrimary, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func truncated(_ pk: String) -> String {
        Nip19.shortNpub(hex: pk)
    }
}
