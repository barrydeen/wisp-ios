import SwiftUI

/// Detail/editor for a single note (bookmark) list. Renders each bookmarked
/// event as a `PostCardView`, fetched on demand if not already cached.
struct NoteListEditorView: View {
    let keypair: Keypair
    let dTag: String
    var onViewFeed: ((NoteList) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var repo = NoteListRepository.shared
    @State private var profileRepo = ProfileRepository.shared
    @State private var engagementRepo = EngagementRepository.shared
    @State private var events: [String: NostrEvent] = [:]
    @State private var profiles: [String: ProfileData] = [:]
    @State private var isLoading = false

    private var list: NoteList? { repo.list(dTag: dTag) }

    var body: some View {
        ScrollView {
            if let list {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard(list)
                    notesSection(list)
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            } else {
                missingState.padding(40)
            }
        }
        .background(Color.wispBackground.ignoresSafeArea())
        .navigationTitle(list?.name ?? "List")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadEvents()
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
    private func headerCard(_ list: NoteList) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(list.name)
                    .font(.title3.weight(.bold))
                Text("\(list.allNotes.count) note\(list.allNotes.count == 1 ? "" : "s")")
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
    private func notesSection(_ list: NoteList) -> some View {
        if list.allNotes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No bookmarked notes yet")
                    .font(.subheadline.weight(.semibold))
                Text("Use the bookmark icon on any post to save it to this list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.wispSurfaceVariant.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: 12))
        } else {
            VStack(spacing: 12) {
                ForEach(list.allNotes, id: \.self) { id in
                    noteCard(id: id, isPrivate: list.isPrivate(id))
                }
            }
        }
    }

    @ViewBuilder
    private func noteCard(id: String, isPrivate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let event = events[id] {
                PostCardView(
                    event: event,
                    profile: profiles[event.pubkey],
                    profiles: profiles,
                    engagement: nil
                )
            } else {
                HStack {
                    ProgressView()
                    Text("Loading note\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
            }

            HStack(spacing: 8) {
                Button {
                    repo.setNotePrivacy(id, in: dTag, isPrivate: !isPrivate, keypair: keypair)
                } label: {
                    Label(isPrivate ? "Private" : "Public",
                          systemImage: isPrivate ? "lock.fill" : "lock.open")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.wispSurfaceVariant.opacity(0.6), in: Capsule())
                        .foregroundStyle(isPrivate ? Color.wispPrimary : .secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(role: .destructive) {
                    repo.removeNote(id, from: dTag, keypair: keypair)
                } label: {
                    Label("Remove", systemImage: "trash")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.15), in: Capsule())
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(Color.wispSurfaceVariant.opacity(0.25),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private func loadEvents() async {
        guard let list else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let ids = list.allNotes
        guard !ids.isEmpty else { return }

        let cached = await EventStore.shared.eventsByIds(ids)
        var byId: [String: NostrEvent] = [:]
        for event in cached { byId[event.id] = event }

        let missing = ids.filter { byId[$0] == nil }
        if !missing.isEmpty {
            for batch in missing.chunked(into: 200) {
                let relays = RelayDefaults.indexers + ["wss://nos.lol"]
                let results = await RelayPool.query(
                    relays: relays,
                    filter: NostrFilter(ids: batch, limit: batch.count),
                    timeout: 10
                )
                for event in results { byId[event.id] = event }
                Task { await EventPersistQueue.shared.enqueue(results) }
            }
        }
        events = byId

        var byAuthor: [String: ProfileData] = [:]
        let authors = Array(Set(byId.values.map(\.pubkey)))
        var stillMissing: [String] = []
        for pk in authors {
            if let profile = profileRepo.get(pk) {
                byAuthor[pk] = profile
            } else {
                stillMissing.append(pk)
            }
        }
        if !stillMissing.isEmpty {
            for batch in stillMissing.chunked(into: 150) {
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
                    if let profile = profileRepo.updateFromEvent(event) {
                        byAuthor[event.pubkey] = profile
                    }
                }
            }
        }
        profiles = byAuthor
    }
}
