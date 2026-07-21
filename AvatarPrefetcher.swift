import Foundation
import UIKit

/// Aggressively pulls avatar images into `ImageCache` in the background so that
/// `CachedAvatarView` can render synchronously from cache. Hooked from:
///   • `ProfileRepository.updateFromEvent` — every time a kind-0 lands.
///   • `wispApp.init` — sweep all profiles already persisted in UserDefaults.
///   • `FeedViewModel` / `MessagesViewModel` / `NotificationsViewModel` — bulk
///     enqueue when batches of profiles arrive.
///
/// Design notes:
///   • Bounded concurrency (default 8) so we don't blow up the relay/CDN-side
///     connection budget when 1000+ profiles arrive at once.
///   • Two-tier queue: feed-driven enqueues (profiles arriving for what the
///     user is looking at) drain BEFORE the launch sweep's backlog of every
///     persisted profile — previously one FIFO let hundreds of stale sweep
///     avatars queue ahead of the viewport's, so rows showed placeholders
///     while the prefetcher churned through profiles nobody was viewing.
///   • Priority-tier fetches also pre-decode the feed-size `#avatar120`
///     bucket so `CachedAvatarView`'s synchronous cache read renders with no
///     placeholder flash (sweep-tier skips this — decoding hundreds of
///     avatars nobody may view would just churn `DecodedImageCache`).
///   • Dedupes via in-memory sets (`inflight` for active fetches, `failed` for
///     URLs that 4xx'd so we don't retry forever).
///   • Skips work entirely when the user has disabled `autoLoadMedia`.
actor AvatarPrefetcher {
    static let shared = AvatarPrefetcher()

    private var inflight: Set<String> = []
    private var failed: Set<String> = []
    private var priorityQueue: [String] = []
    private var bulkQueue: [String] = []
    private var enqueued: Set<String> = []
    private let maxConcurrent = 8
    private var activeCount = 0

    private init() {}

    /// Enqueue a single avatar URL. No-op if the URL is empty, already cached on
    /// disk, currently in flight, or known-failed.
    func enqueue(_ urlString: String?) {
        enqueue(urlString, bulk: false)
    }

    private func enqueue(_ urlString: String?, bulk: Bool) {
        guard let urlString, !urlString.isEmpty else { return }
        if enqueued.contains(urlString) { return }
        if failed.contains(urlString) { return }
        if ImageCache.shared.has(urlString) { return }
        enqueued.insert(urlString)
        if bulk {
            bulkQueue.append(urlString)
        } else {
            priorityQueue.append(urlString)
        }
        Task { await self.pump() }
    }

    /// Bulk enqueue. Use when a batch of profiles arrives (feed prefetch, contact
    /// list, search results).
    func enqueue(urls: [String?]) {
        for u in urls { enqueue(u, bulk: false) }
    }

    /// Sweep every persisted profile in UserDefaults and enqueue its avatar.
    /// Called once on app launch; bounded by `maxConcurrent` so it doesn't fan
    /// out into hundreds of simultaneous requests, and queued at bulk tier so
    /// it can't starve avatars the user is about to see.
    func sweepPersistedProfiles() {
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix("profile_") && !key.hasPrefix("profile_ts_") {
            if let dict = defaults.dictionary(forKey: key),
               let pic = dict["picture"] as? String, !pic.isEmpty {
                enqueue(pic, bulk: true)
            }
        }
    }

    private func pump() async {
        while activeCount < maxConcurrent, !(priorityQueue.isEmpty && bulkQueue.isEmpty) {
            let priority = !priorityQueue.isEmpty
            let url = priority ? priorityQueue.removeFirst() : bulkQueue.removeFirst()
            inflight.insert(url)
            activeCount += 1
            Task { await self.fetch(url, preDecode: priority) }
        }
    }

    private func fetch(_ urlString: String, preDecode: Bool) async {
        defer {
            Task { await self.markFinished(urlString) }
        }
        // Auto-load gate: bypass when the user disabled it. We still keep the
        // URL out of `enqueued` so the next time they re-enable the setting,
        // CachedAvatarView's own load path picks it up.
        guard await MainActor.run(body: { AppSettings.shared.autoLoadMedia }) else {
            return
        }
        guard let url = URL(string: urlString) else {
            await markFailed(urlString)
            return
        }
        if ImageCache.shared.has(urlString) { return }
        do {
            // Dedicated background pool (see `HttpClientFactory.prefetchClient`)
            // so prefetch can't starve foreground image loads on URLSession.shared.
            let (data, response) = try await HttpClientFactory.prefetchClient.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                await markFailed(urlString)
                return
            }
            ImageCache.shared.store(data, for: urlString)
            // Priority-tier only: pre-decode the feed-size bucket so the row's
            // synchronous DecodedImageCache read renders flash-free. Never for
            // likely-animated sources — a pre-stored static frame would
            // satisfy CachedAvatarView's `cachedStatic` branch before its
            // animated load path ever runs, freezing avatars that should
            // animate. (Decode runs here on the actor executor — off-main,
            // and serial enough to self-limit CPU.)
            if preDecode, !AnimatedImageHint.isLikelyAnimated(url: urlString, mime: nil) {
                let cap = MediaLookaheadPrefetcher.feedAvatarPixelCap
                if let img = AnimatedImageDecoder.decodeStatic(data: data, maxPixelSize: cap) {
                    let key = "\(urlString)#avatar\(Int(cap))"
                    await MainActor.run { DecodedImageCache.storeStatic(img, for: key) }
                }
            }
        } catch {
            await markFailed(urlString)
        }
    }

    private func markFinished(_ url: String) {
        inflight.remove(url)
        activeCount = max(0, activeCount - 1)
        Task { await self.pump() }
    }

    private func markFailed(_ url: String) {
        failed.insert(url)
    }
}
