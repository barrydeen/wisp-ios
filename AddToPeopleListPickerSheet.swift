import SwiftUI

/// Picker shown from the people-list editor's "Add member" button. Lets the user
/// pick from their follows (with profile data) or paste an npub / hex pubkey.
/// A privacy toggle controls whether the new entry is added publicly or as an
/// encrypted private member.
struct AddToPeopleListPickerSheet: View {
    let keypair: Keypair
    let dTag: String
    /// Optional pre-targeted pubkey (when invoked from a profile screen, this
    /// is the profile being added). When set, the picker shows a single
    /// confirmation row instead of the follows list.
    var presetPubkey: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var peopleRepo = PeopleListRepository.shared
    @State private var profileRepo = ProfileRepository.shared
    @State private var query: String = ""
    @State private var isPrivate: Bool = false

    private var list: PeopleList? { peopleRepo.list(dTag: dTag) }

    private var follows: [String] {
        FollowsCache.shared.follows(for: keypair.pubkey)
    }

    private var filteredFollows: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return follows }
        return follows.filter { pk in
            if pk.contains(trimmed) { return true }
            let profile = profileRepo.get(pk)
            if let name = profile?.displayString.lowercased(), name.contains(trimmed) { return true }
            if let nip = profile?.nip05?.lowercased(), nip.contains(trimmed) { return true }
            return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let preset = presetPubkey {
                    presetRow(preset)
                } else {
                    queryAndPaste
                    privacyToggle
                    followsList
                }
                Spacer(minLength: 24)
            }
            .padding(20)
        }
        .background(Color.wispBackground.ignoresSafeArea())
        .navigationTitle("Add member")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func presetRow(_ pubkey: String) -> some View {
        let normalized = pubkey.lowercased()
        let profile = profileRepo.get(normalized)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CachedAvatarView(url: profile?.picture, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile?.displayString ?? shortKey(normalized))
                        .font(.subheadline.weight(.semibold))
                    if let nip = profile?.nip05, !nip.isEmpty {
                        Text(nip).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            privacyToggle

            Button {
                peopleRepo.addMember(normalized, to: dTag, isPrivate: isPrivate, keypair: keypair)
                dismiss()
            } label: {
                Text("Add to \u{201C}\(list?.name ?? "list")\u{201D}")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.wispPrimary, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(!Nip51UserLists.isHexPubkey(normalized))
        }
    }

    private var queryAndPaste: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search follows or paste npub", text: $query)
                    .textFieldStyle(.plain)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onSubmit { tryAddFromQuery() }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.wispSurfaceVariant.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: 10))

            if let parsed = parsedPubkey(query) {
                Button {
                    peopleRepo.addMember(parsed, to: dTag, isPrivate: isPrivate, keypair: keypair)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color.wispPrimary)
                        Text("Add \(shortKey(parsed))")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.wispSurfaceVariant.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
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

    @ViewBuilder
    private var followsList: some View {
        if filteredFollows.isEmpty {
            Text("No matching follows")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        } else {
            VStack(spacing: 0) {
                ForEach(filteredFollows, id: \.self) { pubkey in
                    followRow(pubkey)
                    if pubkey != filteredFollows.last {
                        Divider().overlay(Color.wispSurfaceVariant.opacity(0.4))
                    }
                }
            }
            .background(Color.wispSurfaceVariant.opacity(0.25),
                        in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func followRow(_ pubkey: String) -> some View {
        let profile = profileRepo.get(pubkey)
        let alreadyIn = (list?.publicMembers.contains(pubkey) ?? false) ||
                       (list?.privateMembers.contains(pubkey) ?? false)
        Button {
            guard !alreadyIn else { return }
            peopleRepo.addMember(pubkey, to: dTag, isPrivate: isPrivate, keypair: keypair)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                CachedAvatarView(url: profile?.picture, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile?.displayString ?? shortKey(pubkey))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let nip = profile?.nip05, !nip.isEmpty {
                        Text(nip).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if alreadyIn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(alreadyIn)
    }

    private func tryAddFromQuery() {
        guard let parsed = parsedPubkey(query) else { return }
        peopleRepo.addMember(parsed, to: dTag, isPrivate: isPrivate, keypair: keypair)
        dismiss()
    }

    private func parsedPubkey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if Nip51UserLists.isHexPubkey(trimmed) { return trimmed }
        if trimmed.hasPrefix("npub1") || trimmed.hasPrefix("nostr:npub1") {
            let stripped = trimmed.hasPrefix("nostr:") ? String(trimmed.dropFirst(6)) : trimmed
            if let bytes = try? Nip19.npubDecode(stripped) {
                let hex = Hex.encode(Data(bytes)).lowercased()
                if Nip51UserLists.isHexPubkey(hex) { return hex }
            }
        }
        return nil
    }

    private func shortKey(_ s: String) -> String {
        String(s.prefix(8)) + "\u{2026}"
    }
}
