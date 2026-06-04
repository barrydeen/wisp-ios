import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class MediaServersViewModel {
    enum PublishState: Equatable {
        case idle
        case publishing
        case sent
        case failed(String)
    }

    let pubkey: String
    private(set) var servers: [String]
    var newServerInput: String = ""
    private(set) var errorMessage: String?
    private(set) var publishState: PublishState = .idle

    init(pubkey: String) {
        self.pubkey = pubkey
        self.servers = BlossomServerList.cached(for: pubkey)
        BlossomServerList.editorOpen = true
    }

    deinit {
        BlossomServerList.editorOpen = false
    }

    func addServer() {
        let raw = newServerInput.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingTrailingSlashes()
        guard !raw.isEmpty else { return }
        if raw.lowercased().hasPrefix("http://") {
            errorMessage = "Only HTTPS servers are supported"
            return
        }
        let url = raw.lowercased().hasPrefix("https://") ? raw : "https://\(raw)"
        if servers.contains(url) {
            errorMessage = "Server already added"
            return
        }
        servers.append(url)
        persist()
        newServerInput = ""
        errorMessage = nil
        publishState = .idle
    }

    func removeServer(at offsets: IndexSet) {
        servers.remove(atOffsets: offsets)
        persist()
        publishState = .idle
    }

    func moveServer(from source: Int, to destination: Int) {
        guard servers.indices.contains(source), servers.indices.contains(destination), source != destination else { return }
        let item = servers.remove(at: source)
        servers.insert(item, at: destination)
        persist()
        publishState = .idle
    }

    func publish(keypair: Keypair) async {
        guard let privkeyBytes = Hex.decode(keypair.privkey) else {
            publishState = .failed("Invalid signing key")
            return
        }
        publishState = .publishing
        let tags = servers.map { ["server", $0] }
        let createdAt = NostrClock.now()
        let pubkeyHex = keypair.pubkey
        let relays = topWriteRelays(pubkey: pubkeyHex)

        let signed: NostrEvent
        do {
            signed = try NostrEvent.sign(
                privkey32: Data(privkeyBytes),
                pubkey: pubkeyHex,
                kind: BlossomServerList.kindServerList,
                createdAt: createdAt,
                tags: tags,
                content: ""
            )
        } catch {
            publishState = .failed("Signing failed: \(error.localizedDescription)")
            return
        }

        let acked = await RelayPool.publish(event: signed, to: relays, timeout: 6)
        await EventStore.shared.persist([signed])

        if acked.isEmpty {
            publishState = .failed("No relays accepted the event")
        } else {
            publishState = .sent
        }
    }

    private func persist() {
        BlossomServerList.save(servers: servers, for: pubkey)
    }

    private func topWriteRelays(pubkey: String) -> [String] {
        if let board = RelayScoreBoard.load(pubkey: pubkey) {
            let top = board.scoredRelays.prefix(5).map(\.url)
            if !top.isEmpty { return top }
        }
        return ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
    }
}

private extension String {
    func trimmingTrailingSlashes() -> String {
        var result = self
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
