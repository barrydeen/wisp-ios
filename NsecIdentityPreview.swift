import SwiftUI

/// Live "this is the account you're about to log in as" card. Renders the
/// avatar, display name, and NIP-05 for the pubkey derived from whatever the
/// user has typed into the nsec / hex field, so they can sanity-check the
/// key before tapping Log In. Used by both the splash sheet (first-time
/// login) and the Add Account sheet — same component so both surfaces stay
/// in sync.
///
/// Lookup chain: parse the input → fall back to the local
/// `ProfileRepository` cache → debounced relay query for kind-0 if still
/// unresolved. Generation-tracking keeps a stale debounced result from
/// overwriting newer state if the user edits the field again.
struct NsecIdentityPreview: View {
    let nsecInput: String

    @State private var previewPubkey: String?
    @State private var previewProfile: ProfileData?
    @State private var isLookingUpProfile = false
    @State private var lookupGeneration: Int = 0

    var body: some View {
        Group {
            if let pubkey = previewPubkey {
                HStack(spacing: 12) {
                    CachedAvatarView(url: previewProfile?.picture, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(previewProfile?.displayString ?? shortNpub(hex: pubkey))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let nip05 = previewProfile?.nip05, !nip05.isEmpty {
                            Text(nip05)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if isLookingUpProfile {
                            Text("Looking up profile…")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } else if previewProfile == nil {
                            Text("No profile published")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Color.wispSurfaceVariant.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 12))
                .transition(.opacity)
            } else {
                // Reserve the slot so the layout doesn't shift when the
                // preview pops in. Same height as the populated card above.
                Color.clear.frame(height: 64)
            }
        }
        .onChange(of: nsecInput) { _, newValue in
            handleInputChange(newValue)
        }
    }

    private func handleInputChange(_ newValue: String) {
        let parsed = NostrKey.parseNsec(newValue)
        if let kp = parsed {
            if previewPubkey != kp.pubkey {
                previewPubkey = kp.pubkey
                previewProfile = ProfileRepository.shared.get(kp.pubkey)
                isLookingUpProfile = previewProfile == nil
                lookupGeneration += 1
                debouncedProfileLookup(pubkey: kp.pubkey, generation: lookupGeneration)
            }
        } else {
            previewPubkey = nil
            previewProfile = nil
            isLookingUpProfile = false
        }
    }

    private func debouncedProfileLookup(pubkey: String, generation: Int) {
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard generation == lookupGeneration, previewPubkey == pubkey else { return }
            if let cached = ProfileRepository.shared.get(pubkey) {
                previewProfile = cached
                isLookingUpProfile = false
                return
            }
            isLookingUpProfile = true
            let results = await RelayPool.query(
                relays: RelayDefaults.indexers,
                filter: NostrFilter(kinds: [0], authors: [pubkey], limit: 5),
                timeout: 6
            )
            guard generation == lookupGeneration, previewPubkey == pubkey else { return }
            isLookingUpProfile = false
            if let best = results.filter({ $0.kind == 0 }).max(by: { $0.createdAt < $1.createdAt }),
               let updated = ProfileRepository.shared.updateFromEvent(best) {
                previewProfile = updated
            }
        }
    }

    /// Local npub-short fallback (`npub1abcd…wxyz`) so the preview never
    /// surfaces a raw hex pubkey while the profile is still loading.
    private func shortNpub(hex: String) -> String {
        guard let data = Hex.decode(hex), data.count == 32,
              let full = Nip19.npubEncode(pubkey: Array(data)) else {
            return String(hex.prefix(8)) + "\u{2026}"
        }
        return "\(full.prefix(9))\u{2026}\(full.suffix(4))"
    }
}
