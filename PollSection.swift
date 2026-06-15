import SwiftUI

/// Renders a NIP-88 poll (kind 1068) or NIP-69 zap poll (kind 6969) inside a feed card.
/// Reads tally state from `PollTallyRepository`. Voting mode is shown when the active user
/// hasn't voted and the poll hasn't ended; otherwise a results view with animated bars.
struct PollSection: View {
    let pollEvent: NostrEvent
    var onCastVote: ([String]) -> Void
    var onZapVote: (Int) -> Void

    @State private var tallyRepo = PollTallyRepository.shared
    @State private var pendingMultiSelections: Set<String> = []

    private var isZapPoll: Bool { pollEvent.kind == Nip69.kindZapPoll }

    private func timeLabel(ended: Bool, endsAt: Int?) -> String? {
        guard let endsAt else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(endsAt))
        if ended { return nil }
        let diff = date.timeIntervalSinceNow
        if diff <= 0 { return nil }
        let days = Int(diff / 86400)
        let hours = Int(diff / 3600) % 24
        let minutes = Int(diff / 60) % 60
        if days > 0 { return "\(days) \(days == 1 ? "day" : "days") left" }
        if hours > 0 { return "\(hours) \(hours == 1 ? "hour" : "hours") left" }
        let m = max(1, minutes)
        return "\(m) \(m == 1 ? "minute" : "minutes") left"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isZapPoll {
                zapPollBody
            } else {
                normalPollBody
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Normal poll (kind 1068)

    private var tally: PollTally {
        // Reading `tallies[id]` makes the view dependent on `version` via observation.
        _ = tallyRepo.version
        return tallyRepo.tally(for: pollEvent.id)
    }

    private var normalPollBody: some View {
        let options = Nip88.parsePollOptions(pollEvent)
        let pollType = Nip88.parsePollType(pollEvent)
        let ended = Nip88.isPollEnded(pollEvent)
        let hasVoted = !tally.userVotes.isEmpty
        let isAuthor = pollEvent.pubkey == NostrKey.load()?.pubkey
        let showResults = hasVoted || ended || isAuthor

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(options, id: \.id) { option in
                if showResults {
                    PollResultRow(
                        label: option.label,
                        count: tally.voteCounts[option.id] ?? 0,
                        total: tally.totalVotes,
                        chosen: tally.userVotes.contains(option.id),
                        tint: Color.wispPrimary
                    )
                } else {
                    PollOptionRow(
                        label: option.label,
                        selected: pollType == .multiplechoice
                            ? pendingMultiSelections.contains(option.id)
                            : false,
                        isMulti: pollType == .multiplechoice
                    ) {
                        if pollType == .multiplechoice {
                            if pendingMultiSelections.contains(option.id) {
                                pendingMultiSelections.remove(option.id)
                            } else {
                                pendingMultiSelections.insert(option.id)
                            }
                        } else {
                            onCastVote([option.id])
                        }
                    }
                }
            }

            if !showResults, pollType == .multiplechoice {
                Button {
                    let ordered = options.map(\.id).filter { pendingMultiSelections.contains($0) }
                    if !ordered.isEmpty { onCastVote(ordered) }
                } label: {
                    Text("Vote")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(pendingMultiSelections.isEmpty
                                    ? Color.wispSurfaceVariant
                                    : Color.wispPrimary,
                                    in: Capsule())
                        .foregroundStyle(pendingMultiSelections.isEmpty ? Color.secondary : Color.white)
                }
                .buttonStyle(.plain)
                .disabled(pendingMultiSelections.isEmpty)
            }

            HStack(spacing: 6) {
                Text("\(tally.totalVotes) \(tally.totalVotes == 1 ? "vote" : "votes")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if ended {
                    Text("· Poll ended")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let t = timeLabel(ended: ended, endsAt: Nip88.parseEndsAt(pollEvent)) {
                    Text("· \(t)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("· ∞ left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Zap poll (kind 6969)

    private var zapPollBody: some View {
        let options = Nip69.parseZapPollOptions(pollEvent)
        let closed = Nip69.isZapPollClosed(pollEvent)
        let hasVoted = tally.userOptionIndex != nil
        let isAuthor = pollEvent.pubkey == NostrKey.load()?.pubkey
        let showResults = hasVoted || closed || isAuthor
        let minSats = Nip69.parseValueMinimum(pollEvent)
        let maxSats = Nip69.parseValueMaximum(pollEvent)

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(options, id: \.index) { option in
                if showResults {
                    ZapPollResultRow(
                        label: option.label,
                        sats: tally.satsCounts[option.index] ?? 0,
                        total: tally.totalSats,
                        chosen: tally.userOptionIndex == option.index
                    )
                } else {
                    PollOptionRow(
                        label: option.label,
                        selected: false,
                        isMulti: false,
                        iconOverride: "bolt.fill",
                        tint: Color.wispZapColor
                    ) {
                        onZapVote(option.index)
                    }
                }
            }

            if minSats != nil || maxSats != nil {
                HStack(spacing: 6) {
                    if let minSats {
                        Text("Min: \(minSats) sats").font(.caption).foregroundStyle(.secondary)
                    }
                    if minSats != nil, maxSats != nil {
                        Text("·").font(.caption).foregroundStyle(.secondary)
                    }
                    if let maxSats {
                        Text("Max: \(maxSats) sats").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 6) {
                Text("\(tally.totalSats) sats total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if closed {
                    Text("· Poll ended")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let t = timeLabel(ended: closed, endsAt: Nip69.parseClosedAt(pollEvent)) {
                    Text("· \(t)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("· ∞ left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Rows

private struct PollOptionRow: View {
    let label: String
    let selected: Bool
    let isMulti: Bool
    var iconOverride: String? = nil
    var tint: Color = Color.wispPrimary
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                let icon: String = iconOverride ?? (isMulti
                    ? (selected ? "checkmark.square.fill" : "square")
                    : (selected ? "circle.inset.filled" : "circle"))
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(selected || iconOverride != nil ? tint : .secondary)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.wispSurfaceVariant.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

private struct PollResultRow: View {
    let label: String
    let count: Int
    let total: Int
    let chosen: Bool
    let tint: Color

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(count) / Double(total))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.wispSurfaceVariant.opacity(0.4))
                    RoundedRectangle(cornerRadius: 10)
                        .fill(tint.opacity(chosen ? 0.32 : 0.18))
                        .frame(width: geo.size.width * fraction)
                        .animation(.easeOut(duration: 0.4), value: fraction)
                }
            }
            HStack(spacing: 8) {
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tint)
                }
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text("\(count) (\(Int((fraction * 100).rounded()))%)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 38)
    }
}

private struct ZapPollResultRow: View {
    let label: String
    let sats: Int64
    let total: Int64
    let chosen: Bool

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(sats) / Double(total))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.wispSurfaceVariant.opacity(0.4))
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.wispZapColor.opacity(chosen ? 0.32 : 0.18))
                        .frame(width: geo.size.width * fraction)
                        .animation(.easeOut(duration: 0.4), value: fraction)
                }
            }
            HStack(spacing: 8) {
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.wispZapColor)
                }
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text("\(sats) sats (\(Int((fraction * 100).rounded()))%)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 38)
    }
}
