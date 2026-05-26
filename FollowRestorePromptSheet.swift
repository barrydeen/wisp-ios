import SwiftUI

/// Modal sheet surfaced when `FollowHistoryGuard` detects that the active
/// account's follow list looks clobbered (substantially smaller than a
/// recoverable version from relay history). The user can either restore the
/// larger list — republishing it as a fresh kind-3 — or keep what they
/// arrived with, in which case the smaller list becomes the new baseline.
///
/// Used by `MainView` for the cross-session / cross-client clobber case;
/// `OnboardingView` has its own inline UI for the first-launch case.
struct FollowRestorePromptSheet: View {
    let candidate: FollowRestoreCandidate
    let currentCount: Int
    var onRestore: () -> Void
    var onKeep: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isRestoring = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.wispPrimary)
                .padding(.top, 32)

            VStack(spacing: 10) {
                Text("Your follow list looks shorter than usual")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(bodyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)

            VStack(spacing: 10) {
                Button {
                    isRestoring = true
                    onRestore()
                } label: {
                    HStack(spacing: 8) {
                        if isRestoring { ProgressView().controlSize(.small).tint(.white) }
                        Text(isRestoring ? "Restoring…" : "Restore \(candidate.count) \(Self.followsWord(candidate.count))")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .background(Color.wispPrimary, in: Capsule())
                .foregroundStyle(.white)
                .disabled(isRestoring)

                Button {
                    onKeep()
                    dismiss()
                } label: {
                    Text(currentCount == 0 ? "Start fresh" : "Keep \(currentCount) \(Self.followsWord(currentCount))")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .background(Color.wispSurfaceVariant, in: Capsule())
                .foregroundStyle(.primary)
                .disabled(isRestoring)
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 32)
        .background(Color.wispBackground.ignoresSafeArea())
        .interactiveDismissDisabled(isRestoring)
    }

    private var bodyText: String {
        let when = Self.relativeDate(from: candidate.createdAt)
        let backup = "\(candidate.count) \(Self.followsWord(candidate.count))"
        if currentCount == 0 {
            return "Wisp found a backup with \(backup) from \(when). Another app may have cleared your contact list while you were away. Would you like to restore it?"
        }
        let loaded = currentCount == 1 ? "only 1 is loaded right now" : "only \(currentCount) are loaded right now"
        return "Wisp found a backup with \(backup) from \(when), but \(loaded). Another app may have shortened your contact list. Restore the larger version?"
    }

    private static func relativeDate(from createdAt: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(createdAt))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private static func followsWord(_ n: Int) -> String {
        n == 1 ? "follow" : "follows"
    }
}
