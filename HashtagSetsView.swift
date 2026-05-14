import SwiftUI

/// CRUD screen for the user's hashtag sets (NIP-51 kind 30015).
/// Reachable from the sidebar drawer "Lists" row and from the feed-picker
/// "Manage sets…" entry.
struct HashtagSetsView: View {
    let keypair: Keypair
    var onViewFeed: ((HashtagSet) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var repo = HashtagSetRepository.shared

    @State private var expanded: Set<String> = []
    @State private var newTagInputs: [String: String] = [:]

    @State private var showCreate = false
    @State private var newSetName = ""

    @State private var renameTarget: HashtagSet?
    @State private var renameInput = ""

    @State private var deleteTarget: HashtagSet?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if keypair.isWatchOnly {
                    watchOnlyBanner
                }
                Group {
                    if repo.hashtagSets.isEmpty {
                        emptyState
                    } else {
                        ForEach(repo.hashtagSets) { set in
                            setCard(set)
                        }
                    }

                    if !keypair.isWatchOnly {
                        createButton
                    }
                }
                .disabled(keypair.isWatchOnly)
                .opacity(keypair.isWatchOnly ? 0.4 : 1)
                Spacer(minLength: 24)
            }
            .padding(20)
        }
        .background(Color.wispBackground.ignoresSafeArea())
        .navigationTitle("Hashtag Sets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .alert("New hashtag set", isPresented: $showCreate) {
            TextField("Set name", text: $newSetName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let trimmed = newSetName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                _ = repo.createHashtagSet(name: trimmed, keypair: keypair)
            }
        } message: {
            Text("Give your new set a name. You can add hashtags after creating it.")
        }
        .alert(
            "Rename set",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Set name", text: $renameInput)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let set = renameTarget {
                    let trimmed = renameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        repo.renameHashtagSet(dTag: set.dTag, newName: trimmed, keypair: keypair)
                    }
                }
                renameTarget = nil
            }
        }
        .alert(
            "Delete set?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                if let set = deleteTarget {
                    repo.deleteHashtagSet(dTag: set.dTag, keypair: keypair)
                }
                deleteTarget = nil
            }
        } message: {
            Text(deleteTarget.map { "\u{201C}\($0.name)\u{201D} will be removed from all your devices." } ?? "")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No hashtag sets yet")
                .font(.subheadline.weight(.semibold))
            Text("Group hashtags into sets so you can browse them as a single feed. Tap any hashtag in a post to add it to a set.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.wispSurfaceVariant.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Set card

    @ViewBuilder
    private func setCard(_ set: HashtagSet) -> some View {
        let isExpanded = expanded.contains(set.dTag)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    onViewFeed?(set)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "number")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.wispPrimary)
                            .frame(width: 32, height: 32)
                            .background(Color.wispSurfaceVariant.opacity(0.5),
                                        in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(set.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("\(set.hashtags.count) hashtag\(set.hashtags.count == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onViewFeed == nil)

                Button {
                    toggleExpanded(set.dTag)
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.wispSurfaceVariant.opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            if isExpanded {
                Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))
                expandedBody(set)
            }
        }
        .background(Color.wispSurfaceVariant.opacity(0.25),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func expandedBody(_ set: HashtagSet) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if set.hashtags.isEmpty {
                Text("No hashtags yet. Add some below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(set.hashtags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text("#\(tag)")
                                .font(.caption.weight(.medium))
                            Button {
                                repo.removeHashtag(tag, fromSet: set.dTag, keypair: keypair)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.wispSurfaceVariant.opacity(0.7),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(Color.wispPrimary)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField(
                    "Add hashtag",
                    text: Binding(
                        get: { newTagInputs[set.dTag] ?? "" },
                        set: { newTagInputs[set.dTag] = $0 }
                    )
                )
                .textFieldStyle(.plain)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.wispBackground, in: RoundedRectangle(cornerRadius: 8))
                .onSubmit { commitNewTag(for: set) }

                Button {
                    commitNewTag(for: set)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Color.wispPrimary, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled((newTagInputs[set.dTag] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 8) {
                Button {
                    renameInput = set.name
                    renameTarget = set
                } label: {
                    Label("Rename", systemImage: "pencil")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.wispSurfaceVariant.opacity(0.6), in: Capsule())
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(role: .destructive) {
                    deleteTarget = set
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.15), in: Capsule())
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }

    // MARK: - Create button

    private var createButton: some View {
        Button {
            newSetName = ""
            showCreate = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                Text("New hashtag set")
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

    // MARK: - Actions

    private func toggleExpanded(_ dTag: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if expanded.contains(dTag) {
                expanded.remove(dTag)
            } else {
                expanded.insert(dTag)
            }
        }
    }

    private func commitNewTag(for set: HashtagSet) {
        let raw = (newTagInputs[set.dTag] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        // Allow comma- or whitespace-separated batch entry.
        let pieces = raw.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        for piece in pieces {
            repo.addHashtag(piece, toSet: set.dTag, keypair: keypair)
        }
        newTagInputs[set.dTag] = ""
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

/// Minimal flow-layout for chip wrapping. SwiftUI doesn't ship one until iOS 17's
/// `Layout` API; we use that here since the project deployment target is iOS 26.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
