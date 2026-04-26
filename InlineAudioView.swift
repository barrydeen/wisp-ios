import SwiftUI
import AVFoundation

struct InlineAudioView: View {
    let meta: MediaMeta
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var duration: Double = 0
    @State private var timeObserver: Any?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.wispPrimary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                ProgressView(value: progress, total: max(duration, 0.001))
                    .tint(Color.wispPrimary)

                HStack {
                    Text(formatTime(progress))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatTime(duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.wispSurfaceVariant.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .onDisappear {
            player?.pause()
            if let obs = timeObserver, let p = player {
                p.removeTimeObserver(obs)
            }
        }
    }

    private var displayName: String {
        URL(string: meta.url)?.lastPathComponent ?? "Audio"
    }

    private func togglePlayback() {
        if player == nil { initPlayer() }
        guard let p = player else { return }
        if isPlaying {
            p.pause()
        } else {
            MediaAudioSession.activatePlayback()
            p.play()
        }
        isPlaying.toggle()
    }

    private func initPlayer() {
        guard let url = URL(string: meta.url) else { return }
        let p = AVPlayer(url: url)
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            progress = time.seconds.isFinite ? time.seconds : 0
            if let item = p.currentItem {
                let d = item.duration.seconds
                duration = d.isFinite ? d : 0
            }
        }
        player = p
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
