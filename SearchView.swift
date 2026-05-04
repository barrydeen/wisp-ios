import SwiftUI

struct SearchView: View {
    let keypair: Keypair
    @Bindable var viewModel: SearchViewModel
    @Binding var path: NavigationPath

    @FocusState private var queryFocused: Bool
    @State private var showAddRelaySheet = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))

            if viewModel.showAdvanced {
                advancedPanel
                Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
            }

            results
        }
        .background(Color.wispBackground)
        .onAppear { viewModel.start() }
        .sheet(isPresented: $showAddRelaySheet) {
            AddRelaySheet { url in
                viewModel.addCustomRelay(url)
            }
            .presentationDetents([.height(220)])
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            if !queryFocused {
                modePill
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)

                TextField("Search", text: Binding(
                    get: { viewModel.query },
                    set: { viewModel.updateQuery($0) }
                ))
                .focused($queryFocused)
                .submitLabel(.search)
                .onSubmit { viewModel.runSearch() }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)

                if !viewModel.query.isEmpty {
                    Button {
                        viewModel.updateQuery("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 20))

            if queryFocused {
                // Standard iOS search-cancel affordance: appears only when
                // the field is focused, dismisses the keyboard, and (if the
                // query is empty) collapses any focus-only state.
                Button("Cancel") {
                    queryFocused = false
                }
                .font(.subheadline)
                .foregroundStyle(Color.wispPrimary)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                Button {
                    viewModel.showAdvanced.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18))
                        .foregroundStyle(viewModel.showAdvanced ? Color.wispPrimary : .secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.2), value: queryFocused)
    }

    private var modePill: some View {
        Menu {
            Button {
                viewModel.setMode(.notes)
            } label: {
                Label("Notes", systemImage: "text.bubble")
            }
            Button {
                viewModel.setMode(.people)
            } label: {
                Label("People", systemImage: "person.crop.circle")
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.mode == .notes ? "Notes" : "People")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(Color.wispOnSurface)
        }
    }

    // MARK: - Advanced panel

    private var advancedPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            relaySelector

            if viewModel.mode == .notes {
                authorFilterSection
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.wispSurfaceVariant.opacity(0.3))
    }

    private var relaySelector: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Menu {
                Button {
                    viewModel.setRelayOption(.default)
                } label: {
                    if viewModel.relayOption == .default {
                        Label("Default (search.nostrarchives.com)", systemImage: "checkmark")
                    } else {
                        Text("Default (search.nostrarchives.com)")
                    }
                }

                if !viewModel.savedSearchRelays.isEmpty {
                    Button {
                        viewModel.setRelayOption(.all)
                    } label: {
                        if viewModel.relayOption == .all {
                            Label("All saved relays", systemImage: "checkmark")
                        } else {
                            Text("All saved relays")
                        }
                    }

                    Divider()

                    ForEach(viewModel.savedSearchRelays, id: \.self) { url in
                        Button {
                            viewModel.setRelayOption(.individual, url: url)
                        } label: {
                            if viewModel.relayOption == .individual && viewModel.selectedRelayUrl == url {
                                Label(displayHost(url), systemImage: "checkmark")
                            } else {
                                Text(displayHost(url))
                            }
                        }
                    }

                    Divider()

                    ForEach(viewModel.savedSearchRelays, id: \.self) { url in
                        Button(role: .destructive) {
                            viewModel.removeCustomRelay(url)
                        } label: {
                            Label("Remove \(displayHost(url))", systemImage: "trash")
                        }
                    }
                }

                Divider()

                Button {
                    showAddRelaySheet = true
                } label: {
                    Label("Add custom relay\u{2026}", systemImage: "plus")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentRelayLabel)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(Color.wispOnSurface)
            }

            Spacer()
        }
    }

    private var currentRelayLabel: String {
        switch viewModel.relayOption {
        case .default: return "Default"
        case .all: return "All saved"
        case .individual:
            if let url = viewModel.selectedRelayUrl { return displayHost(url) }
            return "Default"
        }
    }

    private var authorFilterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                if let author = viewModel.authorFilter {
                    HStack(spacing: 6) {
                        CachedAvatarView(url: author.picture, size: 20)
                            .clipShape(Circle())
                        EmojiText(
                            author.displayString,
                            emojiMap: author.emojiMap,
                            textStyle: .caption1,
                            weight: .medium
                        )
                        Button {
                            viewModel.setAuthorFilter(nil)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 14))
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        TextField("Filter by author", text: Binding(
                            get: { viewModel.authorQuery },
                            set: { viewModel.updateAuthorQuery($0) }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 14))
                }

                Spacer()
            }

            if viewModel.authorFilter == nil, !viewModel.authorResults.isEmpty {
                VStack(spacing: 0) {
                    ForEach(viewModel.authorResults, id: \.pubkey) { profile in
                        Button {
                            viewModel.setAuthorFilter(profile)
                        } label: {
                            HStack(spacing: 8) {
                                CachedAvatarView(url: profile.picture, size: 28)
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 1) {
                                    EmojiText(
                                        profile.displayString,
                                        emojiMap: profile.emojiMap,
                                        textStyle: .caption1,
                                        weight: .semibold
                                    )
                                    if let nip05 = profile.nip05, !nip05.isEmpty {
                                        Text(nip05)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                    }
                }
                .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            } else if viewModel.isAuthorSearching {
                HStack {
                    ProgressView().scaleEffect(0.7)
                    Text("Searching authors\u{2026}")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if viewModel.isSearching && currentResultsEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Searching\u{2026}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !viewModel.hasSearched && currentResultsEmpty {
            emptyHint(icon: "magnifyingglass", text: "Start typing to search")
        } else if viewModel.hasSearched && currentResultsEmpty && !viewModel.isSearching {
            emptyHint(icon: "tray", text: "No results found")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if viewModel.mode == .notes {
                        notesList
                    } else {
                        peopleList
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var notesList: some View {
        ForEach(viewModel.notes, id: \.id) { event in
            NavigationLink(value: ThreadRoute(eventId: event.id, authorPubkey: event.pubkey)) {
                PostCardView(
                    event: event,
                    profile: viewModel.noteProfiles[event.pubkey] ?? ProfileRepository.shared.get(event.pubkey),
                    profiles: viewModel.noteProfiles,
                    engagement: viewModel.engagement[event.id],
                    onProfileTap: { _ in },
                    onNoteTap: { eventId in
                        path.append(ThreadRoute(eventId: eventId, authorPubkey: event.pubkey))
                    },
                    onHashtagTap: { _ in }
                )
            }
            .buttonStyle(.plain)
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
        }
    }

    private var peopleList: some View {
        ForEach(viewModel.people, id: \.pubkey) { profile in
            NavigationLink(value: ProfileRoute(pubkey: profile.pubkey)) {
                HStack(alignment: .top, spacing: 12) {
                    CachedAvatarView(url: profile.picture, size: 44)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            EmojiText(
                                profile.displayString,
                                emojiMap: profile.emojiMap,
                                textStyle: .subheadline,
                                weight: .semibold
                            )
                            if let nip05 = profile.nip05, !nip05.isEmpty {
                                Nip05Badge(nip05: nip05, pubkey: profile.pubkey)
                            }
                            Spacer(minLength: 0)
                        }
                        if let about = profile.about, !about.isEmpty {
                            Text(about)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
        }
    }

    // MARK: - Helpers

    private var currentResultsEmpty: Bool {
        viewModel.mode == .notes ? viewModel.notes.isEmpty : viewModel.people.isEmpty
    }

    private func emptyHint(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func displayHost(_ url: String) -> String {
        var s = url
        if s.hasPrefix("wss://") { s = String(s.dropFirst("wss://".count)) }
        else if s.hasPrefix("ws://") { s = String(s.dropFirst("ws://".count)) }
        return s
    }
}

// MARK: - Add relay sheet

private struct AddRelaySheet: View {
    let onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add search relay")
                .font(.headline)

            TextField("wss://relay.example.com", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(12)
                .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Add") {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onAdd(trimmed)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .background(Color.wispBackground)
    }
}
