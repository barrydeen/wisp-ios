import SwiftUI

/// Sheet shown from a profile screen's "Add to list" toolbar button. Lets the
/// user check-toggle the target pubkey across their existing people lists and
/// quick-create a new list with the target as its first member.
struct AddProfileToListSheet: View {
    let keypair: Keypair
    let targetPubkey: String

    @Environment(\.dismiss) private var dismiss
    @State private var repo = PeopleListRepository.shared
    @State private var profileRepo = ProfileRepository.shared
    @State private var showCreate = false
    @State private var newListName = ""
    @State private var isPrivate = false

    private var normalized: String { targetPubkey.lowercased() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                targetCard
                privacyToggle

                if repo.lists.isEmpty {
                    emptyState
                } else {
                    Text("Your lists")
                        .font(.subheadline.weight(.semibold))
                    listsSection
                }

                createButton
                Spacer(minLength: 24)
            }
            .padding(20)
        }
        .background(Color.wispBackground.ignoresSafeArea())
        .navigationTitle("Add to list")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .alert("New people list", isPresented: $showCreate) {
            TextField("List name", text: $newListName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let trimmed = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                if let created = repo.createList(name: trimmed, keypair: keypair) {
                    repo.addMember(normalized, to: created.dTag, isPrivate: isPrivate, keypair: keypair)
                }
            }
        } message: {
            Text("Give your new list a name. The current profile will be added automatically.")
        }
    }

    private var targetCard: some View {
        let profile = profileRepo.get(normalized)
        return HStack(spacing: 12) {
            CachedAvatarView(url: profile?.picture, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.displayString ?? shortKey(normalized))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let nip = profile?.nip05, !nip.isEmpty {
                    Text(nip).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
    }

    private var privacyToggle: some View {
        HStack(spacing: 8) {
            Image(systemName: isPrivate ? "lock.fill" : "lock.open")
                .foregroundStyle(isPrivate ? Color.wispPrimary : .secondary)
            Text(isPrivate ? "Private (encrypted)" : "Public")
                .font(.subheadline)
                .foregroundStyle(isPrivate ? .primary : .secondary)
            Spacer()
            Toggle("", isOn: $isPrivate)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.wispSurfaceVariant.opacity(0.25),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You don't have any people lists yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Create one to add this profile.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.wispSurfaceVariant.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private var listsSection: some View {
        VStack(spacing: 0) {
            ForEach(repo.lists) { list in
                listRow(list)
                if list.id != repo.lists.last?.id {
                    Divider().overlay(Color.wispSurfaceVariant.opacity(0.4))
                }
            }
        }
        .background(Color.wispSurfaceVariant.opacity(0.25),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private func listRow(_ list: PeopleList) -> some View {
        let alreadyIn = list.publicMembers.contains(normalized) || list.privateMembers.contains(normalized)
        return Button {
            if alreadyIn {
                repo.removeMember(normalized, from: list.dTag, keypair: keypair)
            } else {
                repo.addMember(normalized, to: list.dTag, isPrivate: isPrivate, keypair: keypair)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: alreadyIn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
                    .foregroundStyle(alreadyIn ? Color.wispPrimary : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(list.name)
                            .font(.subheadline.weight(.medium))
                        if !list.privateMembers.isEmpty {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("\(list.allMembers.count) member\(list.allMembers.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var createButton: some View {
        Button {
            newListName = ""
            showCreate = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.wispPrimary)
                Text("Create new list with this profile")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(12)
            .background(Color.wispSurfaceVariant.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func shortKey(_ s: String) -> String {
        Nip19.shortNpub(hex: s)
    }
}
