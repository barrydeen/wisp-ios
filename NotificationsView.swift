import SwiftUI

struct NotificationsView: View {
    @Bindable var viewModel: NotificationsViewModel
    let onPeerTap: (String) -> Void
    let onDmTap: (String) -> Void
    var onNoteTap: ((String) -> Void)? = nil

    var body: some View {
        list
            .background(Color.wispBackground)
            // Frosted unified top header — same `.bar` material as the home feed
            // and ProfileView. Title + summary pills + filter chips share one
            // backdrop, content scrolls under them.
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    header
                    filterChipBar
                }
                .background(
                    LinearGradient(
                        colors: [
                            Color.wispBackground.opacity(0.92),
                            Color.wispBackground.opacity(0.65)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .onAppear {
                // Debounced mark-as-read so a quick tab swipe doesn't immediately clear the dot.
                Task {
                    try? await Task.sleep(for: .milliseconds(1500))
                    viewModel.markAllRead()
                }
            }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Notifications")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    AppSettings.shared.notificationSoundsEnabled.toggle()
                } label: {
                    Image(systemName: AppSettings.shared.notificationSoundsEnabled
                          ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppSettings.shared.notificationSoundsEnabled
                                    ? "Mute notification sounds" : "Enable notification sounds")
                if viewModel.isLoading {
                    ProgressView().scaleEffect(0.7)
                }
            }
            summaryRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var summaryRow: some View {
        let s = viewModel.summary
        let pills: [(String, String, Color)] = [
            ("bubble.right.fill", "\(s.replyCount)", .wispPrimary),
            ("heart.fill", "\(s.reactionCount)", .pink),
            ("bolt.fill", s.zapSats > 0 ? "\(NotificationStyle.formatSats(s.zapSats)) sats" : "0", .wispZapColor),
            ("arrow.2.squarepath", "\(s.repostCount)", .wispRepostColor),
            ("at.circle.fill", "\(s.mentionCount)", .wispPrimary),
            ("envelope.fill", "\(s.dmCount)", .wispPrimary),
            ("checkmark.circle.fill", "\(s.pollVoteCount)", .wispPrimary)
        ]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(pills.enumerated()), id: \.offset) { _, p in
                    HStack(spacing: 4) {
                        Image(systemName: p.0)
                            .font(.system(size: 10, weight: .semibold))
                        Text(p.1).font(.caption)
                    }
                    .foregroundStyle(p.2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(p.2.opacity(0.12))
                    .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Filter chip bar

    private var filterChipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(NotificationFilterChip.allCases, id: \.self) { chip in
                    Button { viewModel.setFilter(chip) } label: {
                        Text(chip.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(viewModel.filter == chip ? .white : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                viewModel.filter == chip
                                    ? Color.wispPrimary
                                    : Color.wispSurfaceVariant.opacity(0.5)
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            if viewModel.groups.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.groups, id: \.id) { group in
                        NotificationRowView(
                            group: group,
                            viewModel: viewModel,
                            onPeerTap: onPeerTap,
                            onDmTap: onDmTap,
                            onNoteTap: onNoteTap
                        )
                        Divider().overlay(Color.wispSurfaceVariant.opacity(0.4))
                    }
                }
            }
        }
        .refreshable { await viewModel.refresh() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No notifications yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Replies, mentions, zaps, reactions, reposts, and DMs will appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
    }
}
