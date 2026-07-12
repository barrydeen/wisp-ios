import SwiftUI

/// Modal sheet for switching between signed-in accounts, reordering them, or
/// adding a new one. Replaces the old inline expand/collapse panel in
/// `SidebarDrawerView` — a sheet is easier to reach, easier to dismiss, and
/// gives "Sign in with another account" a full-width, unambiguous row instead
/// of competing with a cramped drawer header.
struct AccountSwitcherSheet: View {
    let initialAccounts: [String]
    let activePubkey: String
    let activeProfile: ProfileData?
    let onSwitchAccount: (Keypair) -> Void
    let onAddAccount: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [String] = []
    /// Local mirror of `ProfileRepository`'s cache for the listed accounts.
    /// `ProfileRepository` isn't observable, so a row for an account whose
    /// kind-0 hasn't been fetched yet (e.g. a freshly imported key that has
    /// never appeared as an author/mention in this session's feed) would
    /// otherwise show its npub fallback forever — nothing would ever tell
    /// SwiftUI to re-render once the profile arrived. Seeding this from the
    /// cache in `onAppear` and then refreshing it from `.task`'s `ensure(_:)`
    /// call closes that gap.
    @State private var profiles: [String: ProfileData] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accounts")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            // The sheet itself is capped at .medium (~half the screen), so the
            // list just needs to fill whatever space is left after the title,
            // divider, and "Sign in with another account" row — it scrolls
            // within that instead of growing the sheet taller.
            ScrollView {
                // Reordering swaps two entries in `accounts`, which SwiftUI's
                // ForEach diffing reads as "this identified row moved from
                // position A to B" and animates the whole row sliding between
                // slots — including the up/down buttons, making them appear
                // to float from one row to the other. Reordering should just
                // recolor each row's arrows for its new position, not
                // animate a slide, so animation is disabled for this state.
                VStack(spacing: 0) {
                    ForEach(Array(accounts.enumerated()), id: \.element) { index, acctPubkey in
                        accountRow(acctPubkey, index: index)
                    }
                }
                .animation(nil, value: accounts)
            }
            .frame(maxHeight: .infinity)

            Divider()
                .padding(.horizontal, 16)

            addAccountRow
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear {
            accounts = initialAccounts
            profiles = ProfileRepository.shared.getAll(initialAccounts)
        }
        .task {
            let fetched = await ProfileRepository.shared.ensure(initialAccounts)
            profiles.merge(fetched) { _, new in new }
        }
    }

    private func accountRow(_ acctPubkey: String, index: Int) -> some View {
        let isActive = acctPubkey == activePubkey
        let acctProfile = isActive ? activeProfile : profiles[acctPubkey]

        return Button {
            // `switchAccount` (not `loadAccount`) so the keychain's `active`
            // slot and `cachedActive` are updated before the loading splash
            // reads `NostrKey.load()` to pick the avatar — otherwise the
            // splash renders the previous account's avatar through the
            // entire transition.
            if !isActive, let kp = NostrKey.switchAccount(pubkey: acctPubkey) {
                onSwitchAccount(kp)
            }
            dismiss()
        } label: {
            HStack(spacing: 12) {
                CachedAvatarView(url: acctProfile?.picture, size: 40)
                Text(acctProfile?.displayString ?? Nip19.shortNpub(hex: acctPubkey))
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if NostrKey.isWatchOnly(pubkey: acctPubkey) {
                    Image(systemName: "eye")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.wispPrimary)
                }
                if accounts.count > 1 {
                    Button {
                        move(acctPubkey, offset: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(index > 0 ? Color.secondary : Color.secondary.opacity(0.3))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0)

                    Button {
                        move(acctPubkey, offset: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(index < accounts.count - 1 ? Color.secondary : Color.secondary.opacity(0.3))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .disabled(index == accounts.count - 1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Persists the reorder via `NostrKey` and mirrors it into local state so
    /// the sheet reflects the new order immediately without needing to be
    /// reopened (`NostrKey.accounts()` reads back from UserDefaults, which
    /// SwiftUI has no observation into).
    private func move(_ pubkey: String, offset: Int) {
        NostrKey.moveAccount(pubkey: pubkey, offset: offset)
        guard let index = accounts.firstIndex(of: pubkey) else { return }
        let target = index + offset
        guard target >= 0, target < accounts.count else { return }
        accounts.swapAt(index, target)
    }

    private var addAccountRow: some View {
        Button {
            onAddAccount()
            dismiss()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.wispSurfaceVariant)
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 40, height: 40)
                Text("Sign in with another account")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
