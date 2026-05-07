import SwiftUI

// MARK: - Follow toggle

/// Pill-shaped Follow / Following toggle used across the suggestions step.
/// Matches Android's FollowToggleButton: 32pt height, capsule shape, primary
/// fill when not yet selected and tonal-neutral when already followed.
struct FollowToggleButton: View {
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(selected ? "Following" : "Follow")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Color.wispOnSurface : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(
                    Capsule().fill(selected ? Color.wispSurfaceVariant : Color.wispPrimary)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Filter chip

/// Capsule-shaped chip with an optional leading checkmark. Used for both
/// "Your topics" and "Popular topics" sections on the topic-picker step.
struct OnboardingFilterChip: View {
    let label: String
    let selected: Bool
    var leadingCheck: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if leadingCheck {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                }
                Text(label)
                    .font(.subheadline)
            }
            .foregroundStyle(selected ? Color.white : Color.wispOnSurface)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(selected ? Color.wispPrimary : Color.wispSurface)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Creator card

/// Square-ish card used for the two hardcoded creator suggestions. Contains
/// a centered avatar, name, role description, and a Follow toggle.
struct CreatorCard: View {
    let profile: ProfileData
    let role: String
    let selected: Bool
    var onToggle: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            CachedAvatarView(url: profile.picture, size: 56)
                .frame(width: 56, height: 56)
                .clipShape(Circle())

            Text(profile.displayString)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.wispOnSurface)
                .lineLimit(1)

            Text(role)
                .font(.caption)
                .foregroundStyle(Color.wispOnSurfaceVariant)
                .lineLimit(1)

            FollowToggleButton(selected: selected, action: onToggle)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.wispSurfaceVariant.opacity(0.5))
        )
    }
}

// MARK: - News card

/// Fixed-width 120pt card used in the horizontal "News sources" carousel.
struct NewsCard: View {
    let profile: ProfileData
    let selected: Bool
    var onToggle: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            CachedAvatarView(url: profile.picture, size: 56)
                .frame(width: 56, height: 56)
                .clipShape(Circle())

            Text(profile.displayString)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.wispOnSurface)
                .lineLimit(1)

            FollowToggleButton(selected: selected, action: onToggle)
        }
        .padding(12)
        .frame(width: 120)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.wispSurfaceVariant.opacity(0.5))
        )
    }
}

// MARK: - Stacked avatars

/// Overlapping avatar row that expands into a vertical follow list. Mirrors
/// Android's StackedAvatars: up to 8 visible, "+N" badge for overflow,
/// chevron toggles the expanded list.
struct StackedAvatars: View {
    let profiles: [ProfileData]
    let selected: Set<String>
    var onToggle: (String) -> Void

    @State private var expanded = false

    private let avatarSize: CGFloat = 44
    private let overlap: CGFloat = 0.65
    private let visibleCount: Int = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                stackRow
                Spacer()
                if !profiles.isEmpty {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            expanded.toggle()
                        }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.title3)
                            .foregroundStyle(Color.wispOnSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                }
            }

            if expanded {
                VStack(spacing: 4) {
                    ForEach(profiles, id: \.pubkey) { profile in
                        expandedRow(profile)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var stackRow: some View {
        let visible = Array(profiles.prefix(visibleCount))
        let overflow = max(0, profiles.count - visibleCount)
        let step = avatarSize * overlap
        let totalWidth = visible.isEmpty
            ? 0
            : (CGFloat(visible.count - 1) * step) + avatarSize + (overflow > 0 ? step : 0)

        return ZStack(alignment: .leading) {
            ForEach(Array(visible.enumerated()), id: \.element.pubkey) { idx, profile in
                CachedAvatarView(url: profile.picture, size: avatarSize)
                    .frame(width: avatarSize, height: avatarSize)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.wispBackground, lineWidth: 2))
                    .offset(x: CGFloat(idx) * step)
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.wispOnSurface)
                    .frame(width: avatarSize, height: avatarSize)
                    .background(Circle().fill(Color.wispSurfaceVariant))
                    .overlay(Circle().stroke(Color.wispBackground, lineWidth: 2))
                    .offset(x: CGFloat(visible.count) * step)
            }
        }
        .frame(width: totalWidth, height: avatarSize, alignment: .leading)
    }

    @ViewBuilder
    private func expandedRow(_ profile: ProfileData) -> some View {
        HStack(spacing: 12) {
            CachedAvatarView(url: profile.picture, size: 40)
                .frame(width: 40, height: 40)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayString)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.wispOnSurface)
                    .lineLimit(1)
                if let about = profile.about, !about.isEmpty {
                    Text(about)
                        .font(.caption)
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            FollowToggleButton(selected: selected.contains(profile.pubkey)) {
                onToggle(profile.pubkey)
            }
            .frame(width: 110)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Intro post countdown bar

/// Bottom bar shown while the intro post is in its "post-now" countdown
/// window. Side-by-side Undo + "Post now (Ns)" buttons.
struct IntroPostCountdownBar: View {
    let countdown: Int
    var onUndo: () -> Void
    var onPostNow: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(role: .destructive, action: onUndo) {
                Text("Undo").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button(action: onPostNow) {
                Text("Post now (\(countdown)s)").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.wispPrimary)
            .controlSize(.large)
        }
    }
}

