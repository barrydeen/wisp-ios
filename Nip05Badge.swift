import SwiftUI

struct Nip05Badge: View {
    let nip05: String
    let pubkey: String
    var showHandle: Bool = true
    @ObservedObject private var verifier = Nip05Verifier.shared

    var body: some View {
        let _ = verifier.version  // observe
        let status = verifier.status(for: pubkey)
        HStack(spacing: 4) {
            if showHandle {
                Text(displayString)
                    .font(.caption)
                    .foregroundStyle(textColor(for: status))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            switch status {
            case .verified:
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.wispPrimary)
            case .mismatch:
                Image(systemName: "xmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            case .error:
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            case .checking:
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 10, height: 10)
            case .unknown:
                EmptyView()
            }
        }
        .onAppear {
            verifier.checkOrFetch(pubkey: pubkey, nip05: nip05)
        }
    }

    private var displayString: String {
        // Strip leading "_@" — common convention where the local part is "_"
        if nip05.hasPrefix("_@") { return String(nip05.dropFirst(2)) }
        return nip05
    }

    private func textColor(for status: Nip05Status) -> Color {
        switch status {
        case .verified: return Color.wispPrimary
        case .mismatch: return .secondary
        case .error: return .secondary
        default: return .secondary
        }
    }
}

struct PowBadge: View {
    let bits: Int

    var body: some View {
        Text("PoW \(bits)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.wispPrimary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.wispPrimary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }
}
