import SwiftUI

/// Detail/editor for a single people list. Members shown with avatar + name,
/// each with a public/private toggle and a remove button. "Add member" opens
/// `AddToPeopleListPickerSheet` to pick from follows or paste a key.
struct PeopleListEditorView: View {
    let keypair: Keypair
    let dTag: String
    var onViewFeed: ((PeopleList) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var repo = PeopleListRepository.shared
    @State private var profileRepo = ProfileRepository.shared
    @State private var showAddMember = false

    private var list: PeopleList? { repo.list(dTag: dTag) }

    var body: some View {
        ScrollView {
            if let list {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard(list)
                    membersSection(list)
                    Spacer(minLength: 24)
                }
                .padding(20)
            } else {
                missingState
                    .padding(40)
            }
        }
        .background(Color.wispBackground.ignoresSafeArea())
        .navigationTitle(list?.name ?? "List")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddMember) {
            NavigationStack {
                AddToPeopleListPickerSheet(keypair: keypair, dTag: dTag)
            }
        }
        .task {
            await fetchMissingProfiles()
        }
    }

    private var missingState: some View {
        VStack(spacing: 8) {
            Text("List not found")
                .font(.headline)
                .foregroundStyle(.secondary)
            Button("Go back") { dismiss() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func headerCard(_ list: PeopleList) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(list.name)
                    .font(.title3.weight(.bold))
                Text("\(list.allMembers.count) member\(list.allMembers.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let onViewFeed {
                Button {
                    onViewFeed(list)
                } label: {
                    Label("Feed", systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.wispPrimary, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func membersSection(_ list: PeopleList) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Members")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    showAddMember = true
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.wispPrimary)
                }
                .buttonStyle(.plain)
            }

            if list.allMembers.isEmpty {
                Text("No members yet. Tap Add to include people.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(list.allMembers, id: \.self) { pubkey in
                        memberRow(pubkey: pubkey, isPrivate: list.isPrivate(pubkey))
                        if pubkey != list.allMembers.last {
                            Divider().overlay(Color.wispSurfaceVariant.opacity(0.4))
                        }
                    }
                }
                .background(Color.wispSurfaceVariant.opacity(0.25),
                            in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private func memberRow(pubkey: String, isPrivate: Bool) -> some View {
        let profile = profileRepo.get(pubkey)
        HStack(spacing: 12) {
            CachedAvatarView(url: profile?.picture, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.displayString ?? shortKey(pubkey))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let nip = profile?.nip05, !nip.isEmpty {
                    Text(nip)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()

            Button {
                repo.setMemberPrivacy(pubkey, in: dTag, isPrivate: !isPrivate, keypair: keypair)
            } label: {
                Image(systemName: isPrivate ? "lock.fill" : "lock.open")
                    .font(.system(size: 13))
                    .foregroundStyle(isPrivate ? Color.wispPrimary : .secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                repo.removeMember(pubkey, from: dTag, keypair: keypair)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.red.opacity(0.7))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
    }

    private func shortKey(_ s: String) -> String {
        Nip19.shortNpub(hex: s)
    }

    private func fetchMissingProfiles() async {
        guard let list else { return }
        let missing = list.allMembers.filter { profileRepo.get($0) == nil }
        guard !missing.isEmpty else { return }
        for batch in missing.chunked(into: 150) {
            let results = await RelayPool.query(
                relays: RelayDefaults.indexers,
                filter: NostrFilter(kinds: [0], authors: batch),
                timeout: 8
            )
            var bestByAuthor: [String: NostrEvent] = [:]
            for event in results where event.kind == 0 {
                if let existing = bestByAuthor[event.pubkey],
                   event.createdAt <= existing.createdAt { continue }
                bestByAuthor[event.pubkey] = event
            }
            for (_, event) in bestByAuthor {
                _ = profileRepo.updateFromEvent(event)
            }
        }
    }
}
