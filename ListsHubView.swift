import SwiftUI

/// Two-tab hub for the user's NIP-51 lists: people lists (kind 30000) and
/// note lists / bookmark sets (kind 30003). Each row pushes into the matching
/// editor view; "View feed" jumps to the per-list feed.
struct ListsHubView: View {
    let keypair: Keypair
    var onViewPeopleFeed: ((PeopleList) -> Void)? = nil
    var onViewNoteFeed: ((NoteList) -> Void)? = nil

    enum Tab: Hashable { case people, notes }

    @Environment(\.dismiss) private var dismiss
    @State private var peopleRepo = PeopleListRepository.shared
    @State private var noteRepo = NoteListRepository.shared
    @State private var selectedTab: Tab = .people
    @State private var showCreate = false
    @State private var newListName = ""
    @State private var renameTarget: RenameTarget?
    @State private var renameInput = ""
    @State private var deleteTarget: DeleteTarget?

    private struct RenameTarget: Identifiable {
        let id = UUID()
        let tab: Tab
        let dTag: String
        let currentName: String
    }

    private struct DeleteTarget: Identifiable {
        let id = UUID()
        let tab: Tab
        let dTag: String
        let name: String
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if keypair.isWatchOnly {
                        watchOnlyBanner
                    }
                    switch selectedTab {
                    case .people: peopleSection
                    case .notes: notesSection
                    }
                    if !keypair.isWatchOnly {
                        createButton
                    }
                    Spacer(minLength: 24)
                }
                .padding(20)
            }
        }
        .background(Color.wispBackground.ignoresSafeArea())
        .navigationTitle("Lists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .alert(createAlertTitle, isPresented: $showCreate) {
            TextField("List name", text: $newListName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let trimmed = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                switch selectedTab {
                case .people: _ = peopleRepo.createList(name: trimmed, keypair: keypair)
                case .notes: _ = noteRepo.createList(name: trimmed, keypair: keypair)
                }
            }
        } message: {
            Text("Give your new list a name. You can add \(selectedTab == .people ? "people" : "notes") after creating it.")
        }
        .alert("Rename list", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("List name", text: $renameInput)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let target = renameTarget {
                    let trimmed = renameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        switch target.tab {
                        case .people: peopleRepo.renameList(dTag: target.dTag, newName: trimmed, keypair: keypair)
                        case .notes: noteRepo.renameList(dTag: target.dTag, newName: trimmed, keypair: keypair)
                        }
                    }
                }
                renameTarget = nil
            }
        }
        .alert("Delete list?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    switch target.tab {
                    case .people: peopleRepo.deleteList(dTag: target.dTag, keypair: keypair)
                    case .notes: noteRepo.deleteList(dTag: target.dTag, keypair: keypair)
                    }
                }
                deleteTarget = nil
            }
        } message: {
            Text(deleteTarget.map { "\u{201C}\($0.name)\u{201D} will be removed from all your devices." } ?? "")
        }
    }

    private var createAlertTitle: String {
        selectedTab == .people ? "New people list" : "New note list"
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(.people, label: "People", count: peopleRepo.lists.count)
            tabButton(.notes, label: "Notes", count: noteRepo.lists.count)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private func tabButton(_ tab: Tab, label: String, count: Int) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.wispSurfaceVariant.opacity(0.6), in: Capsule())
                    }
                }
                .foregroundStyle(tab == selectedTab ? Color.wispPrimary : .secondary)
                Rectangle()
                    .fill(tab == selectedTab ? Color.wispPrimary : Color.clear)
                    .frame(height: 2)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sections

    @ViewBuilder
    private var peopleSection: some View {
        if peopleRepo.lists.isEmpty {
            emptyState(
                title: "No people lists yet",
                subtitle: "Group people into curated feeds. Add members from any profile or right here."
            )
        } else {
            ForEach(peopleRepo.lists) { list in
                peopleRow(list)
            }
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        if noteRepo.lists.isEmpty {
            emptyState(
                title: "No note lists yet",
                subtitle: "Bookmark notes into named lists. Tap the bookmark icon on any post to add it here."
            )
        } else {
            ForEach(noteRepo.lists) { list in
                noteRow(list)
            }
        }
    }

    private func emptyState(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.wispSurfaceVariant.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Rows

    private func peopleRow(_ list: PeopleList) -> some View {
        NavigationLink(value: PeopleListEditorRoute(dTag: list.dTag)) {
            rowChrome(
                icon: "person.2",
                title: list.name,
                subtitle: "\(list.allMembers.count) member\(list.allMembers.count == 1 ? "" : "s")",
                hasPrivate: !list.privateMembers.isEmpty,
                onView: onViewPeopleFeed.map { fn in { fn(list) } },
                onRename: {
                    renameInput = list.name
                    renameTarget = RenameTarget(tab: .people, dTag: list.dTag, currentName: list.name)
                },
                onDelete: {
                    deleteTarget = DeleteTarget(tab: .people, dTag: list.dTag, name: list.name)
                }
            )
        }
        .buttonStyle(.plain)
    }

    private func noteRow(_ list: NoteList) -> some View {
        NavigationLink(value: NoteListEditorRoute(dTag: list.dTag)) {
            rowChrome(
                icon: "bookmark",
                title: list.name,
                subtitle: "\(list.allNotes.count) note\(list.allNotes.count == 1 ? "" : "s")",
                hasPrivate: !list.privateNotes.isEmpty,
                onView: onViewNoteFeed.map { fn in { fn(list) } },
                onRename: {
                    renameInput = list.name
                    renameTarget = RenameTarget(tab: .notes, dTag: list.dTag, currentName: list.name)
                },
                onDelete: {
                    deleteTarget = DeleteTarget(tab: .notes, dTag: list.dTag, name: list.name)
                }
            )
        }
        .buttonStyle(.plain)
    }

    private func rowChrome(
        icon: String,
        title: String,
        subtitle: String,
        hasPrivate: Bool,
        onView: (() -> Void)?,
        onRename: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.wispPrimary)
                .frame(width: 32, height: 32)
                .background(Color.wispSurfaceVariant.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if hasPrivate {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)

            if let onView {
                Button {
                    onView()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.wispPrimary)
                        .frame(width: 32, height: 32)
                        .background(Color.wispSurfaceVariant.opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            Menu {
                Button {
                    onRename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color.wispSurfaceVariant.opacity(0.5),
                                in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(Color.wispSurfaceVariant.opacity(0.25),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private var createButton: some View {
        Button {
            newListName = ""
            showCreate = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                Text(selectedTab == .people ? "New people list" : "New note list")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(Color.wispPrimary)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color.wispSurfaceVariant.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var watchOnlyBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "eye")
                .foregroundStyle(Color.wispPrimary)
                .font(.subheadline)
                .padding(.top, 2)
            Text("Watch-only mode")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispSurface, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Editor routes

struct PeopleListEditorRoute: Hashable {
    let dTag: String
}

struct NoteListEditorRoute: Hashable {
    let dTag: String
}
