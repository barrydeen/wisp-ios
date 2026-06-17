import UIKit

/// Viewport lookahead: when a feed row appears, warm the media for the next
/// ~10 rows (and a couple behind) so images are already decoded in
/// `DecodedImageCache` — at the exact keys the views read synchronously —
/// by the time the user scrolls to them. This is what removes the
/// constant loading spinners: previously every inline image started its
/// network fetch at row mount, exactly while the user was staring at the
/// blurhash placeholder.
///
/// Feed surfaces call `noteAppeared` as a one-liner next to their existing
/// `engagementRepo.markVisible(event:)` hook.
///
/// Design notes:
///   • O(1) per appear: the id→index map is rebuilt only when the array's
///     cheap identity key (count|firstId|lastId) changes — never a
///     `firstIndex` scan per row (that exact pattern caused the documented
///     O(n²) deep-scroll regression in MainView).
///   • Per-event media extraction (`ContentParser.parse`) is memoized by
///     event id, so each event is parsed once ever — typically *before* its
///     row mounts, off the render critical path.
///   • All fetches run on `HttpClientFactory.mediaPrefetchClient`: a separate
///     connection pool from the foreground `imageClient` (so lookahead bursts
///     can't starve on-screen loads — documented regression) sharing the same
///     `URLCache`. Bounded pump (4 concurrent) is the backpressure.
///   • Static images + video posters are DECODED ahead (`#px1024`).
///     Animated media is byte-warmed only — decoded frame arrays are too
///     memory-heavy to build speculatively.
///   • Upcoming authors' avatars are byte-warmed into `ImageCache` and
///     pre-decoded into the feed-size `#avatar120` bucket, except
///     likely-animated avatars: pre-storing a static frame for those would
///     satisfy `CachedAvatarView.cachedStatic` before its animated branch
///     ever loads, silently freezing avatars that should animate.
///   • Gated on `autoLoadMedia` (both at enqueue and again before each
///     network op, mirroring AvatarPrefetcher). Low Data Mode is honored at
///     the session level (`allowsConstrainedNetworkAccess = false`).
@MainActor
final class MediaLookaheadPrefetcher {
    static let shared = MediaLookaheadPrefetcher()

    /// Rows warmed ahead of / behind the appearing row. Ahead is the scroll
    /// direction that matters; behind is a small cushion for reversals
    /// (scrolled-past rows usually still sit in DecodedImageCache anyway).
    private let lookahead = 10
    private let lookbehind = 2
    private let maxConcurrent = 4
    /// Queued items farther than this from the latest appeared row are
    /// dropped — the user has scrolled away faster than the pump drained.
    private var staleDistance: Int { 2 * lookahead }
    /// Feed avatars render at 40 pt → CachedAvatarView's framePixelCap is
    /// max(40*3, 96) = 120. MUST track that formula or pre-decodes miss.
    /// Shared with AvatarPrefetcher's post-fetch pre-decode (nonisolated:
    /// that's an actor, not MainActor).
    nonisolated static let feedAvatarPixelCap: CGFloat = 120

    private init() {}

    // MARK: - O(1) appear bookkeeping

    private var indexMap: [String: Int] = [:]
    private var arrayIdentity = ""
    private var latestAppearedIndex = 0

    // MARK: - Memoized per-event media plans

    private struct PlanItem {
        enum Kind {
            case staticImage   // decode-ahead at #px1024
            case animatedBytes // URLCache byte-warm only
            case avatar        // bytes → ImageCache (+ static pre-decode)
        }
        let url: URL
        let kind: Kind
        /// Dedup key — equals the decoded-cache key the foreground view reads.
        let key: String
    }

    private final class PlanBox {
        let items: [PlanItem]
        init(_ items: [PlanItem]) { self.items = items }
    }

    /// Event id → media plan. Parse once per event, ever.
    private let planCache: NSCache<NSString, PlanBox> = {
        let c = NSCache<NSString, PlanBox>()
        c.countLimit = 2048
        return c
    }()

    // MARK: - Bounded pump

    private struct QueueEntry {
        let item: PlanItem
        let originIndex: Int
    }

    private var queue: [QueueEntry] = []
    private var enqueuedKeys: Set<String> = []
    private var inflight = 0

    // MARK: - Public hook

    /// Call from a feed row's `.onAppear`, passing the surface's full ordered
    /// array (the same one driving its ForEach) and its profiles dict.
    /// O(1) amortized — the only O(n) pass is the index-map rebuild when the
    /// array actually changed.
    func noteAppeared(eventId: String, in events: [NostrEvent], profiles: [String: ProfileData]) {
        guard AppSettings.shared.autoLoadMedia else { return }
        guard !events.isEmpty else { return }
        rebuildIndexIfNeeded(events)
        guard let i = indexMap[eventId] else { return }
        latestAppearedIndex = i

        let hi = min(events.count - 1, i + lookahead)
        let lo = max(0, i - lookbehind)
        // Nearest-first ahead, then the small behind cushion.
        if i + 1 <= hi {
            for j in (i + 1)...hi { enqueue(event: events[j], at: j, profiles: profiles) }
        }
        if lo <= i - 1 {
            for j in stride(from: i - 1, through: lo, by: -1) {
                enqueue(event: events[j], at: j, profiles: profiles)
            }
        }
        dropStale()
        pump()
    }

    // MARK: - Internals

    private func rebuildIndexIfNeeded(_ events: [NostrEvent]) {
        // Cheap identity: count + boundary ids. Catches prepends, appends,
        // filter swaps, and surface switches without hashing the whole array.
        let identity = "\(events.count)|\(events.first?.id ?? "")|\(events.last?.id ?? "")"
        guard identity != arrayIdentity else { return }
        arrayIdentity = identity
        var map: [String: Int] = [:]
        map.reserveCapacity(events.count)
        for (i, e) in events.enumerated() { map[e.id] = i }
        indexMap = map
    }

    private func enqueue(event: NostrEvent, at index: Int, profiles: [String: ProfileData]) {
        for item in plan(for: event) {
            enqueueItem(item, at: index)
        }
        // Avatar isn't part of the memoized plan: the profile (and its
        // picture URL) often lands after the event does, so resolve it fresh
        // from the dict each pass — a single O(1) lookup.
        if let pic = profiles[event.pubkey]?.picture, !pic.isEmpty, let url = URL(string: pic) {
            enqueueItem(
                PlanItem(url: url, kind: .avatar, key: "\(pic)#avatar\(Int(Self.feedAvatarPixelCap))"),
                at: index
            )
        }
    }

    private func enqueueItem(_ item: PlanItem, at index: Int) {
        if enqueuedKeys.contains(item.key) { return }
        // Skip anything already decoded — no queue slot wasted. (The loader
        // re-checks anyway; this is just an early out.)
        switch item.kind {
        case .staticImage, .avatar:
            if DecodedImageCache.staticImage(for: item.key) != nil { return }
        case .animatedBytes:
            if DecodedImageCache.animatedPayload(for: item.key) != nil { return }
        }
        // Bound the dedup set for marathon sessions; the decoded-cache and
        // in-flight checks still prevent real duplicate work after a reset.
        if enqueuedKeys.count > 4096 { enqueuedKeys.removeAll(keepingCapacity: true) }
        enqueuedKeys.insert(item.key)
        queue.append(QueueEntry(item: item, originIndex: index))
    }

    /// Extract this event's media plan, memoized by event id. ContentParser
    /// runs on the main actor (it's cheap relative to network I/O and this
    /// fires once per event, usually before the row mounts).
    private func plan(for event: NostrEvent) -> [PlanItem] {
        if let box = planCache.object(forKey: event.id as NSString) { return box.items }
        var items: [PlanItem] = []
        for segment in ContentParser.parse(content: event.content, tags: event.tags, authorPubkey: event.pubkey) {
            switch segment {
            case .image(let meta), .unknownMedia(let meta):
                guard let url = URL(string: meta.url) else { continue }
                if AnimatedImageHint.isLikelyAnimated(url: meta.url, mime: meta.mime) {
                    // Key matches AnimatedImageView's bare-URL decoded key.
                    items.append(PlanItem(url: url, kind: .animatedBytes, key: meta.url))
                } else {
                    items.append(PlanItem(
                        url: url,
                        kind: .staticImage,
                        key: InlineMediaLoader.staticKey(url: url, maxPixelSize: 1024)
                    ))
                }
            case .video(let meta):
                // Warm the imeta poster (a plain image) — never the video
                // bytes themselves; AVPlayer owns its own buffering.
                if let poster = meta.posterUrl, let url = URL(string: poster) {
                    items.append(PlanItem(
                        url: url,
                        kind: .staticImage,
                        key: InlineMediaLoader.staticKey(url: url, maxPixelSize: 1024)
                    ))
                }
            default:
                break
            }
        }
        planCache.setObject(PlanBox(items), forKey: event.id as NSString)
        return items
    }

    private func dropStale() {
        guard !queue.isEmpty else { return }
        // O(queue) over a window-bounded queue, not over the events array.
        let latest = latestAppearedIndex
        let limit = staleDistance
        queue.removeAll { abs($0.originIndex - latest) > limit }
    }

    private func pump() {
        while inflight < maxConcurrent, !queue.isEmpty {
            let entry = queue.removeFirst()
            inflight += 1
            Task {
                await run(entry.item)
                inflight -= 1
                pump()
            }
        }
    }

    private func run(_ item: PlanItem) async {
        // Re-check: the user may have toggled auto-load off mid-queue.
        guard AppSettings.shared.autoLoadMedia else { return }
        switch item.kind {
        case .staticImage:
            _ = await InlineMediaLoader.staticImage(url: item.url, maxPixelSize: 1024, source: .prefetch)
        case .animatedBytes:
            await InlineMediaLoader.warmBytes(url: item.url)
        case .avatar:
            await prefetchAvatar(item.url)
        }
    }

    /// Bytes into `ImageCache` (what CachedAvatarView reads first), then —
    /// for non-animated sources only — pre-decode the feed-size bucket so the
    /// row's synchronous `cachedStatic` read hits with zero placeholder
    /// flash. Animated avatars get bytes only: a pre-stored static frame
    /// would shadow CachedAvatarView's animated load path entirely.
    private func prefetchAvatar(_ url: URL) async {
        let urlString = url.absoluteString
        let likelyAnimated = AnimatedImageHint.isLikelyAnimated(url: urlString, mime: nil)
        let cap = Self.feedAvatarPixelCap
        let staticKey = "\(urlString)#avatar\(Int(cap))"
        if !likelyAnimated, DecodedImageCache.staticImage(for: staticKey) != nil { return }
        if likelyAnimated, ImageCache.shared.has(urlString) { return }

        let decoded: UIImage? = await Task.detached(priority: .utility) {
            // ImageCache is nonisolated; its disk read belongs off-main.
            var data = ImageCache.shared.get(urlString)
            if data == nil {
                guard let (fetched, response) = try? await HttpClientFactory.mediaPrefetchClient.data(from: url) else {
                    return nil
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return nil
                }
                ImageCache.shared.store(fetched, for: urlString)
                data = fetched
            }
            guard !likelyAnimated, let data else { return nil }
            return AnimatedImageDecoder.decodeStatic(data: data, maxPixelSize: cap)
        }.value

        if let decoded {
            DecodedImageCache.storeStatic(decoded, for: staticKey)
        }
    }
}
