import SwiftUI

struct NotificationsView: View {
    @Bindable var viewModel: NotificationsViewModel
    let onPeerTap: (String) -> Void
    let onDmTap: (String) -> Void
    var onNoteTap: ((String) -> Void)? = nil

    @State private var showFilterSheet = false

    var body: some View {
        list
            .background(Color.wispBackground)
            .safeAreaInset(edge: .top, spacing: 0) {
                topBar
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
            .sheet(isPresented: $showFilterSheet) {
                NotificationFilterSheet(viewModel: viewModel)
                    .presentationDetents([.medium, .large])
            }
            .onAppear {
                Task {
                    try? await Task.sleep(for: .milliseconds(1500))
                    viewModel.markAllRead()
                }
            }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Notifications")
                    .font(.title3.weight(.semibold))
                Text("|  24h")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showFilterSheet = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(filterButtonTint)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Filter notifications")

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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Tint the filter button when not all types are enabled — matches Android.
    private var filterButtonTint: Color {
        viewModel.enabledTypes.count == NotificationFilter.allCases.count
            ? .secondary
            : .wispPrimary
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                DailySummaryBar(viewModel: viewModel)

                if viewModel.filteredItems.isEmpty {
                    emptyState
                } else {
                    ForEach(viewModel.filteredItems, id: \.id) { item in
                        NotificationRowView(
                            item: item,
                            viewModel: viewModel,
                            onPeerTap: onPeerTap,
                            onDmTap: onDmTap,
                            onNoteTap: onNoteTap
                        )
                        Divider().overlay(Color.wispSurfaceVariant.opacity(0.4))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.15), value: viewModel.enabledTypes)
        }
        .refreshable { await viewModel.refresh() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No notifications")
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

// MARK: - Daily summary bar

/// Last-24h counts per type. Tapping a stat isolates its filter; tapping again
/// (when already isolated) restores the full set. Mirrors Android's
/// `DailySummaryBar`.
private struct DailySummaryBar: View {
    @Bindable var viewModel: NotificationsViewModel

    var body: some View {
        let s = viewModel.summary
        HStack(spacing: 0) {
            stat(filter: .replies, label: "\(s.replyCount)") {
                Image(systemName: "bubble.right").font(.system(size: 14))
            }
            stat(filter: .reactions, label: "\(s.reactionCount)") {
                Image(systemName: "heart").font(.system(size: 14))
            }
            stat(filter: .zaps, label: s.zapSats > 0 ? "\(NotificationStyle.formatSats(s.zapSats))" : "0") {
                BoltIcon(tint: tint(for: .zaps))
                    .frame(width: 12, height: 14)
            }
            stat(filter: .reposts, label: "\(s.repostCount)") {
                Image(systemName: "arrow.2.squarepath").font(.system(size: 14))
            }
            stat(filter: .mentions, label: "\(s.mentionCount + s.quoteCount)") {
                Image(systemName: "at").font(.system(size: 14))
            }
            stat(filter: .dms, label: "\(s.dmCount)") {
                Image(systemName: "envelope").font(.system(size: 14))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.wispSurfaceVariant.opacity(0.35))
    }

    @ViewBuilder
    private func stat<Icon: View>(
        filter: NotificationFilter,
        label: String,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        let active = viewModel.enabledTypes == [filter]
        Button {
            if active {
                viewModel.enableAll()
            } else {
                viewModel.isolateType(filter)
            }
        } label: {
            HStack(spacing: 4) {
                icon().foregroundStyle(tint(for: filter))
                Text(label)
                    .font(.caption)
                    .foregroundStyle(active ? Color.wispPrimary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                active
                    ? Color.wispPrimary.opacity(0.12)
                    : Color.clear
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func tint(for filter: NotificationFilter) -> Color {
        switch filter {
        case .reactions: .pink
        case .zaps:      .wispZapColor
        case .reposts:   .wispRepostColor
        default:         .wispPrimary
        }
    }
}

// MARK: - Filter sheet

/// Bottom sheet of per-type toggles + Enable/Disable All. Mirrors Android's
/// `NotificationFilterSheet`.
private struct NotificationFilterSheet: View {
    @Bindable var viewModel: NotificationsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(NotificationFilter.allCases, id: \.self) { filter in
                        FilterRow(
                            filter: filter,
                            isOn: Binding(
                                get: { viewModel.enabledTypes.contains(filter) },
                                set: { _ in viewModel.toggleType(filter) }
                            )
                        )
                    }
                }
                Section {
                    HStack(spacing: 0) {
                        Button("Enable All") { viewModel.enableAll() }
                            .frame(maxWidth: .infinity)
                        Divider()
                        Button("Disable All") { viewModel.disableAll() }
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Filter notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct FilterRow: View {
    let filter: NotificationFilter
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            iconView
                .frame(width: 24, height: 24)
            Text(filter.label)
                .foregroundStyle(isOn ? .primary : .secondary)
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden()
        }
    }

    @ViewBuilder
    private var iconView: some View {
        let tint: Color = isOn ? activeTint : .secondary
        switch filter {
        case .zaps:
            BoltIcon(tint: tint).frame(width: 14, height: 18)
        case .replies:
            Image(systemName: "bubble.right").foregroundStyle(tint)
        case .reactions:
            Image(systemName: "heart").foregroundStyle(tint)
        case .reposts:
            Image(systemName: "arrow.2.squarepath").foregroundStyle(tint)
        case .mentions:
            Image(systemName: "at").foregroundStyle(tint)
        case .votes:
            Image(systemName: "chart.bar").foregroundStyle(tint)
        case .dms:
            Image(systemName: "envelope").foregroundStyle(tint)
        }
    }

    private var activeTint: Color {
        switch filter {
        case .reactions: .pink
        case .zaps:      .wispZapColor
        case .reposts:   .wispRepostColor
        default:         .wispPrimary
        }
    }
}
