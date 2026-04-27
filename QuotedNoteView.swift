import SwiftUI

@MainActor
final class QuotedNoteCache {
    static let shared = QuotedNoteCache()
    private var cache: [String: NostrEvent] = [:]
    private var inflight: [String: Task<NostrEvent?, Never>] = [:]

    private static let defaultRelays = [
        "wss://relay.damus.io",
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://relay.nostr.band"
    ]

    func cached(eventId: String) -> NostrEvent? { cache[eventId] }

    func cache(_ event: NostrEvent) {
        cache[event.id] = event
    }

    func fetch(eventId: String, relayHints: [String]) async -> NostrEvent? {
        if let cached = cache[eventId] { return cached }
        if let existing = inflight[eventId] { return await existing.value }

        let task = Task<NostrEvent?, Never> { [weak self] in
            guard let self else { return nil }
            let relays = self.relayList(hints: relayHints)
            let filter = NostrFilter(kinds: nil, authors: nil, limit: 1)
            // Pass id-filter via raw json — NostrFilter doesn't expose ids; query and filter client-side
            let events = await RelayPool.query(
                relays: relays,
                filter: filterByIds(eventId: eventId),
                timeout: 6
            )
            return events.first(where: { $0.id == eventId })
        }
        inflight[eventId] = task
        let result = await task.value
        inflight[eventId] = nil
        if let result {
            cache[eventId] = result
        }
        return result
    }

    private func relayList(hints: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for r in hints + Self.defaultRelays {
            if seen.insert(r).inserted { out.append(r) }
        }
        return Array(out.prefix(6))
    }

    private func filterByIds(eventId: String) -> NostrFilter {
        var f = NostrFilter()
        f.ids = [eventId]
        f.limit = 1
        return f
    }
}

struct QuotedNoteView: View {
    let eventId: String
    let relayHints: [String]
    let profiles: [String: ProfileData]
    var onProfileTap: ((String) -> Void)? = nil
    var onNoteTap: ((String) -> Void)? = nil
    var onHashtagTap: ((String) -> Void)? = nil

    @State private var event: NostrEvent?
    @State private var loaded = false
    @State private var profile: ProfileData?

    var body: some View {
        Group {
            if let event {
                noteCard(event)
            } else if loaded {
                missingCard
            } else {
                loadingCard
            }
        }
        .task(id: eventId) { await load() }
    }

    private var loadingCard: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Loading quoted note…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispSurfaceVariant.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.wispSurfaceVariant, lineWidth: 1)
        )
    }

    private var missingCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.bubble")
                .foregroundStyle(.secondary)
            Text("Quoted note not found")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispSurfaceVariant.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.wispSurfaceVariant, lineWidth: 1)
        )
    }

    private func noteCard(_ event: NostrEvent) -> some View {
        Button {
            onNoteTap?(event.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    CachedAvatarView(url: profile?.picture, size: 24)
                    EmojiText(
                        profile?.displayString ?? String(event.pubkey.prefix(8)) + "…",
                        emojiMap: profile?.emojiMap ?? [:],
                        textStyle: .caption1,
                        weight: .semibold
                    )
                    Spacer()
                    Text(relativeTime(from: event.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if event.kind == 9735 {
                    zapReceiptBody(event)
                } else {
                    RichContentView(
                        content: event.content,
                        tags: event.tags,
                        profiles: profiles,
                        onProfileTap: onProfileTap,
                        onNoteTap: onNoteTap,
                        onHashtagTap: onHashtagTap,
                        showLinkPreviews: false
                    )
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.wispSurfaceVariant.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.wispSurfaceVariant, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func zapReceiptBody(_ event: NostrEvent) -> some View {
        let sats = Nip57.zapAmountSats(receipt: event)
        let message = Nip57.zapMessage(receipt: event)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13))
                Text(sats > 0 ? "\(CurrencyFormatter.short(sats: sats)) sats" : "Zap")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Color.wispZapColor)

            if let message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func load() async {
        if let cached = QuotedNoteCache.shared.cached(eventId: eventId) {
            self.event = cached
            self.profile = profiles[cached.pubkey] ?? ProfileRepository.shared.get(cached.pubkey)
            loaded = true
            return
        }
        let result = await QuotedNoteCache.shared.fetch(eventId: eventId, relayHints: relayHints)
        if let result {
            self.event = result
            self.profile = profiles[result.pubkey] ?? ProfileRepository.shared.get(result.pubkey)
        }
        loaded = true
    }
}
