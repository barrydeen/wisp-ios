import SwiftUI

enum MessagesTab: String, CaseIterable, Identifiable {
    case dms
    case rooms
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dms: "Direct Messages"
        case .rooms: "Chat Rooms"
        }
    }
}

struct MessagesView: View {
    @Bindable var viewModel: MessagesViewModel
    @Bindable var groupListVM: GroupListViewModel
    @State private var tab: MessagesTab = .dms
    @State private var navPath = NavigationPath()
    @State private var showingNewDm = false

    var body: some View {
        NavigationStack(path: $navPath) {
            VStack(spacing: 0) {
                tabBar

                Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))

                ZStack {
                    switch tab {
                    case .dms:
                        DmListView(
                            viewModel: viewModel,
                            onTap: { conv in navPath.append(conv) },
                            onCompose: { showingNewDm = true }
                        )
                    case .rooms:
                        GroupListView(viewModel: groupListVM,
                                      onTap: { room in navPath.append(room) })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.wispBackground)
            .navigationDestination(for: DmConversation.self) { conv in
                DmConversationView(keypair: viewModel.keypair, participants: conv.participants)
            }
            .navigationDestination(for: GroupRoom.self) { room in
                GroupRoomView(viewModel: GroupRoomViewModel(
                    keypair: viewModel.keypair, relayUrl: room.relayUrl,
                    groupId: room.groupId, repository: groupListVM.repository))
            }
        }
        .sheet(isPresented: $showingNewDm) {
            NewDmSheet(keypair: viewModel.keypair) { recipientHex in
                showingNewDm = false
                let conv = DmConversation(
                    conversationKey: DmRepository.conversationKey(participants: [recipientHex, viewModel.keypair.pubkey]),
                    participants: [recipientHex],
                    messages: [],
                    lastMessageAt: 0
                )
                navPath.append(conv)
            }
        }
        .onAppear {
            viewModel.refreshSnapshot()
            viewModel.markAllRead()
            // Idempotent — start() guards on `subscription == nil`, so this only does work
            // after MainView.onDisappear has torn the subscription down.
            Task { await viewModel.start() }
            // A deep link tap that flipped the tab to messages while this view
            // wasn't mounted lands here on first appear — `.onChange` won't
            // fire for state set before the observer existed.
            handlePendingDeepLink()
        }
        .onChange(of: groupListVM.pendingChatDeepLink) { _, _ in
            handlePendingDeepLink()
        }
    }

    /// Consume `groupListVM.pendingChatDeepLink`: switch to the rooms sub-tab,
    /// send a (idempotent) join request if not already a member, and push the
    /// `GroupRoom` onto this tab's NavigationPath.
    private func handlePendingDeepLink() {
        guard let dl = groupListVM.pendingChatDeepLink else { return }
        tab = .rooms
        Task { @MainActor in
            // joinGroup is idempotent when the room is already populated;
            // for fresh joins it sends kind-9021 and adds the optimistic
            // room to the repository.
            _ = await groupListVM.joinGroup(
                relayUrl: dl.relayUrl, groupId: dl.groupId, code: dl.code
            )
            // The relay-side normalization in joinGroup lowercases + strips
            // trailing slashes, so look up the room by the same key shape.
            let normalized = normalizeRelay(dl.relayUrl)
            if let room = groupListVM.repository.getRoom(
                relayUrl: normalized, groupId: dl.groupId
            ) {
                navPath.append(room)
            }
            groupListVM.pendingChatDeepLink = nil
        }
    }

    private func normalizeRelay(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        if !s.hasPrefix("wss://") && !s.hasPrefix("ws://") { s = "wss://" + s }
        return s
    }

    @ViewBuilder
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(MessagesTab.allCases) { t in
                Button {
                    tab = t
                } label: {
                    VStack(spacing: 4) {
                        Text(t.title)
                            .font(.subheadline.weight(t == tab ? .semibold : .regular))
                            .foregroundStyle(t == tab ? Color.wispPrimary : .secondary)
                        Rectangle()
                            .fill(t == tab ? Color.wispPrimary : Color.clear)
                            .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }
}

struct ChatRoomsPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.3.sequence")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Chat rooms coming soon")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("NIP-29 group chats will land in a future update.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension DmConversation: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(conversationKey)
    }
}
