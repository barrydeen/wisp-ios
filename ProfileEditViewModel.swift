import Foundation
import Observation
import PhotosUI
import SwiftUI

/// Backs the "Edit Profile" sheet shown from the active user's own profile.
///
/// On `start()` we re-fetch the latest kind-0 from the indexer set + the user's
/// write relays so the merge baseline matches what's on the network — not just
/// what's in our local cache. Save merges the editable fields onto the existing
/// content JSON (preserving any keys this client doesn't model, e.g. `website`),
/// keeps the existing tag list (so NIP-30 `:shortcode:` `emoji` tags carry over),
/// signs a new kind-0, and republishes to the user's write relays plus the top
/// score-board entries.
@Observable
@MainActor
final class ProfileEditViewModel {
    let keypair: Keypair

    // Form fields
    var displayName: String = ""
    var name: String = ""
    var about: String = ""
    var picture: String = ""
    var banner: String = ""
    var nip05: String = ""
    var lud16: String = ""

    // Pending media uploads
    var pictureItem: PhotosPickerItem?
    var bannerItem: PhotosPickerItem?
    /// Local preview bytes shown while the user is choosing/uploading. Cleared
    /// once the upload finishes and the URL field is populated.
    var picturePreview: Data?
    var bannerPreview: Data?

    var isLoading: Bool = false
    var isSaving: Bool = false
    var uploadStatus: String?
    var lastError: String?

    @ObservationIgnored private var existingTags: [[String]] = []
    @ObservationIgnored private var existingJson: [String: Any] = [:]
    @ObservationIgnored private var blossomServers: [String] = [BlossomServerList.defaultServer]

    private static let indexerRelays = RelayDefaults.indexers

    init(keypair: Keypair) {
        self.keypair = keypair
        // Seed the form from the cached profile so the sheet has something to show
        // before the network fetch lands. `start()` overwrites with the network
        // copy if it's newer.
        if let cached = ProfileRepository.shared.get(keypair.pubkey) {
            applyProfile(cached)
        }
    }

    func start() async {
        isLoading = true
        defer { isLoading = false }

        async let kind0: [NostrEvent] = RelayPool.query(
            relays: Self.indexerRelays,
            filter: NostrFilter(kinds: [0], authors: [keypair.pubkey], limit: 5),
            timeout: 8
        )
        async let _ = refreshBlossomServers()

        let results = await kind0
        if let best = results.filter({ $0.kind == 0 }).max(by: { $0.createdAt < $1.createdAt }) {
            existingTags = best.tags
            if let data = best.content.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                existingJson = json
            }
            if let updated = ProfileRepository.shared.updateFromEvent(best) {
                applyProfile(updated)
            }
        }
    }

    private func refreshBlossomServers() async {
        let cached = BlossomServerList.cached(for: keypair.pubkey)
        if !cached.isEmpty { blossomServers = cached }
        let fresh = await BlossomServerList.refresh(for: keypair.pubkey)
        if !fresh.isEmpty { blossomServers = fresh }
    }

    private func applyProfile(_ p: ProfileData) {
        displayName = p.displayName ?? ""
        name = p.name ?? ""
        about = p.about ?? ""
        picture = p.picture ?? ""
        banner = p.banner ?? ""
        nip05 = p.nip05 ?? ""
        lud16 = p.lud16 ?? ""
    }

    // MARK: - Image pickers

    func handlePicturePick(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        await uploadPicked(item, for: .picture)
    }

    func handleBannerPick(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        await uploadPicked(item, for: .banner)
    }

    private enum Slot { case picture, banner }

    private func uploadPicked(_ item: PhotosPickerItem, for slot: Slot) async {
        do {
            let picked = try await MediaPicker.load(item)
            guard !picked.isVideo else {
                lastError = "Pick an image, not a video."
                return
            }
            switch slot {
            case .picture: picturePreview = picked.data
            case .banner: bannerPreview = picked.data
            }
            uploadStatus = slot == .picture ? "Uploading photo…" : "Uploading banner…"
            defer { uploadStatus = nil }

            let compressed = MediaCompressor.compressImage(data: picked.data, mime: picked.mime)
            let result = try await BlossomClient.upload(
                bytes: compressed.data,
                mime: compressed.mime,
                servers: blossomServers,
                keypair: keypair
            )
            switch slot {
            case .picture:
                picture = result.url
                picturePreview = nil
            case .banner:
                banner = result.url
                bannerPreview = nil
            }
        } catch {
            lastError = "Upload failed: \(error.localizedDescription)"
            switch slot {
            case .picture: picturePreview = nil
            case .banner: bannerPreview = nil
            }
        }
    }

    // MARK: - Save

    /// Build, sign, and publish the merged kind-0. Returns the updated
    /// `ProfileData` so the caller can refresh its header binding.
    @discardableResult
    func save() async -> ProfileData? {
        isSaving = true
        defer { isSaving = false }

        var merged = existingJson
        applyField(&merged, key: "display_name", value: displayName)
        applyField(&merged, key: "name", value: name)
        applyField(&merged, key: "about", value: about)
        applyField(&merged, key: "picture", value: picture)
        applyField(&merged, key: "banner", value: banner)
        applyField(&merged, key: "nip05", value: nip05)
        applyField(&merged, key: "lud16", value: lud16)

        guard let contentData = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]),
              let content = String(data: contentData, encoding: .utf8) else {
            lastError = "Failed to encode profile JSON."
            return nil
        }

        // Carry forward tags except the previous client tag — we'll re-append a
        // fresh one if the user has it enabled.
        var tags = existingTags.filter { $0.first != "client" }
        if let clientTag = NostrEvent.clientTagIfEnabled() {
            tags.append(clientTag)
        }

        let event: NostrEvent
        do {
            event = try await Signer.sign(
                keypair: keypair,
                kind: 0,
                tags: tags,
                content: content,
                createdAt: Int(Date().timeIntervalSince1970)
            )
        } catch {
            lastError = "Signing failed: \(error.localizedDescription)"
            return nil
        }

        let relays = await publishRelays()
        guard !relays.isEmpty else {
            lastError = "No relays to publish to."
            return nil
        }

        let succeeded = await RelayPool.publish(event: event, to: relays, timeout: 10)
        guard !succeeded.isEmpty else {
            lastError = "Publish failed — no relay accepted the update."
            return nil
        }

        let updated = ProfileRepository.shared.updateFromEvent(event)
        existingTags = event.tags
        existingJson = merged
        return updated
    }

    private func applyField(_ dict: inout [String: Any], key: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            dict.removeValue(forKey: key)
        } else {
            dict[key] = trimmed
        }
    }

    private func publishRelays() async -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        let writes = await RelayListRepository.shared.getWriteRelays(keypair.pubkey)
        for url in writes where seen.insert(url).inserted {
            ordered.append(url)
        }
        if let board = RelayScoreBoard.load(pubkey: keypair.pubkey) {
            for entry in board.scoredRelays.prefix(5) where seen.insert(entry.url).inserted {
                ordered.append(entry.url)
            }
        }
        for url in Self.indexerRelays where seen.insert(url).inserted {
            ordered.append(url)
        }
        return ordered
    }
}
