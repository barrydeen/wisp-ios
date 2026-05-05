import SwiftUI

struct GroupDetailView: View {
    @Bindable var viewModel: GroupRoomViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showLeaveConfirm = false
    @State private var showDeleteConfirm = false
    @State private var showInviteSheet = false
    @State private var lastInviteLink: String?
    @State private var statusMessage: String?

    private var room: GroupRoom? { viewModel.room }
    private var isAdmin: Bool {
        room?.admins.contains(viewModel.keypair.pubkey) ?? false
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    CachedAvatarView(url: room?.metadata?.picture, size: 60)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(room?.metadata?.name ?? viewModel.groupId)
                            .font(.title3.weight(.semibold))
                        if let about = room?.metadata?.about, !about.isEmpty {
                            Text(about).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text(viewModel.relayUrl)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 6)
            }

            if let m = room?.metadata {
                Section("Privacy") {
                    label("Private", on: m.isPrivate)
                    label("Closed",  on: m.isClosed)
                    label("Restricted", on: m.isRestricted)
                    label("Hidden", on: m.isHidden)
                }
            }

            Section("Members (\(room?.members.count ?? 0))") {
                ForEach(room?.members ?? [], id: \.self) { pubkey in
                    MemberRow(
                        pubkey: pubkey,
                        isAdmin: room?.admins.contains(pubkey) == true,
                        showActions: isAdmin && pubkey != viewModel.keypair.pubkey,
                        onPromote: { Task { await promote(pubkey) } },
                        onRemove: { Task { await remove(pubkey) } }
                    )
                }
            }

            if isAdmin {
                Section("Admin") {
                    Button("Generate invite link") { Task { await createInvite() } }
                    if let link = lastInviteLink {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("New invite:").font(.caption).foregroundStyle(.secondary)
                            Text(link).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    Button("Delete group", role: .destructive) { showDeleteConfirm = true }
                }
            }

            Section {
                Toggle("Notifications",
                       isOn: Binding(
                        get: { viewModel.repository.notifiedGroupKeys.contains("\(viewModel.relayUrl)|\(viewModel.groupId)") },
                        set: { viewModel.repository.setNotified($0, relayUrl: viewModel.relayUrl, groupId: viewModel.groupId) }))
                Button("Leave group", role: .destructive) { showLeaveConfirm = true }
            }

            if let s = statusMessage {
                Section { Text(s).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Room info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: Nip29.buildInviteLink(relayUrl: viewModel.relayUrl, groupId: viewModel.groupId)) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .task(id: room?.members) {
            // Batch-fetch any missing profiles for the member + admin lists.
            guard let listVM = GroupListViewModelRegistry.shared else { return }
            let pubkeys = Set((room?.members ?? []) + (room?.admins ?? []))
            await withTaskGroup(of: Void.self) { group in
                for pk in pubkeys where ProfileRepository.shared.get(pk) == nil {
                    group.addTask { await listVM.requestProfileIfNeeded(pk) }
                }
            }
        }
        .confirmationDialog("Leave \(room?.metadata?.name ?? "this group")?",
                            isPresented: $showLeaveConfirm, titleVisibility: .visible) {
            Button("Leave", role: .destructive) {
                Task {
                    await leaveGroup()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this group?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await deleteGroup()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func label(_ name: String, on: Bool) -> some View {
        HStack {
            Text(name)
            Spacer()
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on ? AnyShapeStyle(Color.wispPrimary) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
        }
    }

    private func short(_ s: String) -> String {
        s.count >= 12 ? Nip19.shortNpub(hex: s) : s
    }

    // MARK: - Actions (delegate to GroupListViewModel via the singleton repo's parent)

    @MainActor
    private func leaveGroup() async {
        // We need the GroupListViewModel; nudge through a notification so the parent screen tears down.
        // Simpler: invoke directly through a lazily-resolved shared list VM.
        await GroupListViewModelRegistry.shared?.leaveGroup(relayUrl: viewModel.relayUrl, groupId: viewModel.groupId)
        dismiss()
    }

    @MainActor
    private func deleteGroup() async {
        guard let listVM = GroupListViewModelRegistry.shared else { return }
        let res = await listVM.deleteGroup(relayUrl: viewModel.relayUrl, groupId: viewModel.groupId)
        switch res {
        case .success: dismiss()
        case .failure(let e): statusMessage = "Delete failed: \(e)"
        }
    }

    @MainActor
    private func createInvite() async {
        guard let listVM = GroupListViewModelRegistry.shared else { return }
        let res = await listVM.createInvite(relayUrl: viewModel.relayUrl, groupId: viewModel.groupId)
        switch res {
        case .success(let code):
            lastInviteLink = Nip29.buildInviteLink(relayUrl: viewModel.relayUrl, groupId: viewModel.groupId, code: code)
        case .failure(let e):
            statusMessage = "Invite failed: \(e)"
        }
    }

    @MainActor
    private func promote(_ pubkey: String) async {
        guard let listVM = GroupListViewModelRegistry.shared else { return }
        _ = await listVM.putUser(relayUrl: viewModel.relayUrl, groupId: viewModel.groupId,
                                 targetPubkey: pubkey, roles: ["admin"])
    }

    @MainActor
    private func remove(_ pubkey: String) async {
        guard let listVM = GroupListViewModelRegistry.shared else { return }
        _ = await listVM.removeUser(relayUrl: viewModel.relayUrl, groupId: viewModel.groupId, targetPubkey: pubkey)
    }
}

/// Tiny weak-singleton so `GroupDetailView` can reach the active `GroupListViewModel`
/// without threading it through every navigation destination.
@MainActor
enum GroupListViewModelRegistry {
    private(set) static weak var shared: GroupListViewModel?
    static func register(_ vm: GroupListViewModel) { shared = vm }
}

private struct MemberRow: View {
    let pubkey: String
    let isAdmin: Bool
    let showActions: Bool
    let onPromote: () -> Void
    let onRemove: () -> Void

    @State private var profile: ProfileData?

    var body: some View {
        HStack(spacing: 10) {
            CachedAvatarView(url: profile?.picture, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.displayString ?? short(pubkey))
                    .font(.subheadline)
                    .lineLimit(1)
                Text(short(pubkey))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if isAdmin {
                Text("admin").font(.caption2)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.wispPrimary.opacity(0.2), in: Capsule())
            }
            Spacer()
            if showActions {
                Menu {
                    Button("Promote to admin", action: onPromote)
                    Button("Remove", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.tertiary)
                }
            }
        }
        .task(id: pubkey) {
            profile = ProfileRepository.shared.get(pubkey)
        }
    }

    private func short(_ s: String) -> String {
        s.count >= 12 ? Nip19.shortNpub(hex: s) : s
    }
}
