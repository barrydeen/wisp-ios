import SwiftUI
import AVKit
import AVFoundation

/// Full-screen NIP-53 live stream view: 16:9 player + info bar + chat list + reply quote + input.
struct LiveStreamView: View {
    let route: LiveStreamRoute
    let keypair: Keypair
    @Environment(WalletStore.self) private var wallet
    @State private var vm: LiveStreamViewModel
    @State private var streamRepo = LiveStreamRepository.shared
    @State private var profileRepo = ProfileRepository.shared
    @State private var showStreamZapSheet = false
    @State private var chatZapTarget: LiveChatMessage?

    init(route: LiveStreamRoute, keypair: Keypair) {
        self.route = route
        self.keypair = keypair
        _vm = State(initialValue: LiveStreamViewModel(
            aTagValue: route.aTagValue,
            hostPubkey: route.hostPubkey,
            dTag: route.dTag,
            naddrRelayHints: route.relayHints,
            keypair: keypair
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                StreamPlayer(url: vm.activity?.streamingUrl)
                StreamInfoBar(
                    hostPubkey: vm.hostPubkey,
                    profile: profileRepo.get(vm.activity?.streamerPubkey ?? vm.hostPubkey),
                    status: vm.activity?.status,
                    zapTotalSats: vm.streamZapTotalSats,
                    onZap: { showStreamZapSheet = true }
                )
                Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                LiveChatList(
                    messages: vm.messages,
                    profileRepo: profileRepo,
                    onReply: { vm.setReplyTarget($0) },
                    onReact: { msg, emoji in
                        Task { await vm.sendReaction(messageId: msg.id, targetPubkey: msg.senderPubkey, emoji: emoji) }
                    },
                    onZap: { msg in chatZapTarget = msg }
                )
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { hideKeyboard() })
            if let reply = vm.replyTarget {
                ReplyQuoteBar(message: reply, profile: profileRepo.get(reply.senderPubkey)) {
                    withAnimation { vm.setReplyTarget(nil) }
                }
            }
            LiveChatInputBar(vm: vm)
        }
        .navigationTitle(vm.activity?.title ?? "Live Stream")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.start() }
        .onDisappear {
            vm.cleanup()
            LivePlayerStore.shared.releaseIfNotPiP()
        }
        .sheet(isPresented: $showStreamZapSheet) {
            ZapSheet(
                store: wallet,
                recipientPubkey: vm.hostPubkey,
                recipientLud16: profileRepo.get(vm.hostPubkey)?.lud16,
                recipientName: profileRepo.get(vm.hostPubkey)?.displayName,
                eventId: nil,
                relayHints: vm.chatRelays,
                extraTags: [["a", vm.aTagValue]],
                dismiss: { showStreamZapSheet = false }
            )
        }
        .sheet(item: $chatZapTarget) { msg in
            ZapSheet(
                store: wallet,
                recipientPubkey: msg.senderPubkey,
                recipientLud16: profileRepo.get(msg.senderPubkey)?.lud16,
                recipientName: profileRepo.get(msg.senderPubkey)?.displayName,
                eventId: msg.id,
                relayHints: vm.chatRelays,
                extraTags: [],
                dismiss: { chatZapTarget = nil }
            )
        }
    }
}

// MARK: - Player

/// Singleton that owns the AVPlayer for the currently-watched live stream.
/// Survives `LiveStreamView` dismissal so Picture-in-Picture can keep playing
/// while the user navigates the rest of the app.
@MainActor
final class LivePlayerStore {
    static let shared = LivePlayerStore()

    private(set) var player: AVPlayer?
    private(set) var currentURL: String?
    /// Set true via `AVPlayerViewControllerDelegate` while PiP is active. When false,
    /// view dismissal releases the player; when true, the player stays alive.
    var pipActive: Bool = false

    func ensurePlayer(for urlString: String) -> AVPlayer? {
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        if currentURL == urlString, let existing = player { return existing }
        // Switching streams: tear the previous one down.
        player?.pause()
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        p.allowsExternalPlayback = true
        player = p
        currentURL = urlString
        return p
    }

    /// Called from `LiveStreamView.onDisappear`. Keeps the player alive when PiP is active.
    func releaseIfNotPiP() {
        if pipActive { return }
        player?.pause()
        player = nil
        currentURL = nil
    }

    func releaseAll() {
        player?.pause()
        player = nil
        currentURL = nil
        pipActive = false
    }
}

private struct StreamPlayer: View {
    let url: String?
    @State private var failureMessage: String?

    var body: some View {
        ZStack {
            Color.black
            if let urlString = url, !urlString.isEmpty {
                AVPlayerControllerRepresentable(
                    urlString: urlString,
                    onFailure: { failureMessage = $0 }
                )
                .id(urlString)
                if let failureMessage {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.85))
                        Text("Cannot play stream")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(failureMessage)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                    .padding(12)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Stream offline")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .onAppear { configureAudioSession() }
        .onChange(of: url) { _, _ in failureMessage = nil }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true, options: [])
    }
}

/// Wraps `AVPlayerViewController` for SwiftUI. Gives free play/pause, AirPlay, scrubbing,
/// volume + mute, and Picture-in-Picture via the system controls. The underlying `AVPlayer`
/// lives in `LivePlayerStore.shared` so PiP survives navigation back.
private struct AVPlayerControllerRepresentable: UIViewControllerRepresentable {
    let urlString: String
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFailure: onFailure)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.videoGravity = .resizeAspect
        vc.showsPlaybackControls = true
        vc.delegate = context.coordinator
        attach(player: LivePlayerStore.shared.ensurePlayer(for: urlString), to: vc, context: context)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        let player = LivePlayerStore.shared.ensurePlayer(for: urlString)
        if vc.player !== player {
            attach(player: player, to: vc, context: context)
        }
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.detach()
        // Note: do NOT clear vc.player here — PiP continues against the original player.
    }

    private func attach(player: AVPlayer?, to vc: AVPlayerViewController, context: Context) {
        vc.player = player
        context.coordinator.attach(player: player)
        player?.play()
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        private let onFailure: (String) -> Void
        private var player: AVPlayer?
        private var statusObservation: NSKeyValueObservation?
        private var failedObserver: NSObjectProtocol?

        init(onFailure: @escaping (String) -> Void) {
            self.onFailure = onFailure
        }

        func attach(player: AVPlayer?) {
            detach()
            self.player = player
            guard let item = player?.currentItem else { return }
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard let self else { return }
                if item.status == .failed {
                    let message = item.error?.localizedDescription ?? "Playback failed"
                    Task { @MainActor in self.onFailure(message) }
                }
            }
            failedObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item, queue: .main
            ) { [weak self] note in
                let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                let message = err?.localizedDescription ?? "Stream ended unexpectedly"
                Task { @MainActor in self?.onFailure(message) }
            }
        }

        func detach() {
            statusObservation?.invalidate()
            statusObservation = nil
            if let failedObserver {
                NotificationCenter.default.removeObserver(failedObserver)
            }
            failedObserver = nil
            player = nil
        }

        nonisolated func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            Task { @MainActor in LivePlayerStore.shared.pipActive = true }
        }

        nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            Task { @MainActor in LivePlayerStore.shared.pipActive = false }
        }
    }
}

// MARK: - Info bar

private struct StreamInfoBar: View {
    let hostPubkey: String
    let profile: ProfileData?
    let status: String?
    let zapTotalSats: Int64
    let onZap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            CachedAvatarView(url: profile?.picture, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile?.displayName ?? Nip19.shortNpub(hex: hostPubkey))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let status, status.lowercased() == "live" {
                    Text("LIVE")
                        .font(.caption2.weight(.heavy))
                        .tracking(0.5)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(red: 0.898, green: 0.224, blue: 0.208), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            Spacer()
            Button(action: onZap) {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(Color.wispZapColor)
                    if zapTotalSats > 0 {
                        Text(formatSats(zapTotalSats))
                            .font(.caption.weight(.medium))
                    } else {
                        Text("Zap")
                            .font(.caption.weight(.medium))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.wispSurfaceVariant.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func formatSats(_ sats: Int64) -> String {
        if sats >= 1_000_000 { return String(format: "%.1fM", Double(sats) / 1_000_000) }
        if sats >= 1_000 { return String(format: "%.1fk", Double(sats) / 1_000) }
        return "\(sats)"
    }
}

// MARK: - Chat list

private struct LiveChatList: View {
    let messages: [LiveChatMessage]
    let profileRepo: ProfileRepository
    let onReply: (LiveChatMessage) -> Void
    let onReact: (LiveChatMessage, String) -> Void
    let onZap: (LiveChatMessage) -> Void

    private static let memberPalette: [Color] = [
        Color(red: 0.898, green: 0.451, blue: 0.451),  // E57373 red
        Color(red: 0.506, green: 0.780, blue: 0.518),  // 81C784 green
        Color(red: 0.392, green: 0.710, blue: 0.965),  // 64B5F6 blue
        Color(red: 1.0, green: 0.718, blue: 0.302),    // FFB74D orange
        Color(red: 0.729, green: 0.408, blue: 0.784),  // BA68C8 purple
        Color(red: 0.302, green: 0.816, blue: 0.882),  // 4DD0E1 cyan
        Color(red: 0.941, green: 0.384, blue: 0.573),  // F06292 pink
        Color(red: 0.682, green: 0.835, blue: 0.506),  // AED581 lime
        Color(red: 1.0, green: 0.835, blue: 0.310),    // FFD54F amber
        Color(red: 0.302, green: 0.714, blue: 0.675),  // 4DB6AC teal
        Color(red: 0.475, green: 0.525, blue: 0.796),  // 7986CB indigo
        Color(red: 1.0, green: 0.541, blue: 0.396)     // FF8A65 deep orange
    ]

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(messages) { msg in
                        LiveChatBubble(
                            message: msg,
                            profile: profileRepo.get(msg.senderPubkey),
                            nameColor: Self.color(for: msg.senderPubkey),
                            onReply: { onReply(msg) },
                            onReact: { emoji in onReact(msg, emoji) },
                            onZap: { onZap(msg) }
                        )
                        .id(msg.id)
                    }
                    Color.clear.frame(height: 4).id("__bottom__")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        reader.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private static func color(for pubkey: String) -> Color {
        var hash = 5381
        for byte in pubkey.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
        let idx = abs(hash) % memberPalette.count
        return memberPalette[idx]
    }
}

private struct LiveChatBubble: View {
    let message: LiveChatMessage
    let profile: ProfileData?
    let nameColor: Color
    let onReply: () -> Void
    let onReact: (String) -> Void
    let onZap: () -> Void

    private static let quickReactions = ["+", "🔥", "❤️", "😂", "🤔", "💯"]

    var body: some View {
        if message.isZapAnnouncement {
            zapAnnouncement
        } else {
            standardBubble
        }
    }

    private var standardBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            CachedAvatarView(url: profile?.picture, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile?.displayName ?? Nip19.shortNpub(hex: message.senderPubkey))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(nameColor)
                    Text(timeText)
                        .font(.caption2)
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                }
                Text(message.content)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.reactions.isEmpty {
                    reactionStrip
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                onReply()
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            Menu {
                ForEach(Self.quickReactions, id: \.self) { emoji in
                    Button(emoji) { onReact(emoji) }
                }
            } label: {
                Label("React", systemImage: "face.smiling")
            }
            Button {
                onZap()
            } label: {
                Label("Zap", systemImage: "bolt.fill")
            }
        }
    }

    private var reactionStrip: some View {
        HStack(spacing: 4) {
            ForEach(Array(message.reactions.keys).sorted(), id: \.self) { emoji in
                let count = message.reactions[emoji]?.count ?? 0
                HStack(spacing: 3) {
                    Text(emoji.isEmpty ? "+" : emoji).font(.caption)
                    Text("\(count)").font(.caption2).foregroundStyle(Color.wispOnSurfaceVariant)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.wispSurfaceVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var zapAnnouncement: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(Color.wispZapColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(message.zapAmountSats) sats from \(profile?.displayName ?? Nip19.shortNpub(hex: message.senderPubkey))")
                    .font(.caption.weight(.semibold))
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.caption)
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.wispZapColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.wispZapColor.opacity(0.5), lineWidth: 1)
        )
    }

    private var timeText: String {
        let date = Date(timeIntervalSince1970: TimeInterval(message.createdAt))
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Reply quote bar

private struct ReplyQuoteBar: View {
    let message: LiveChatMessage
    let profile: ProfileData?
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.wispPrimary)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(profile?.displayName ?? Nip19.shortNpub(hex: message.senderPubkey))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.wispPrimary)
                Text(message.content)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.wispSurfaceVariant.opacity(0.4))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Input bar

private struct LiveChatInputBar: View {
    @Bindable var vm: LiveStreamViewModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $vm.messageText, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { send() }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.wispSurfaceVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Color.wispPrimary, in: Circle())
            }
            .disabled(vm.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.wispBackground)
    }

    private func send() {
        focused = false
        hideKeyboard()
        vm.sendMessage()
    }
}

private func hideKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil, from: nil, for: nil
    )
}
