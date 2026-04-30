import SwiftUI

/// Standard back-affordance for views that hide the system navigation bar
/// (`ProfileView`, hashtag / list / trending / people / Spark setup) and
/// render their own header. Matches the iOS 26 system back style — a
/// circular translucent pill with a chevron — so a screen with a custom
/// header reads the same as a screen using `.navigationTitle`.
///
/// Without this, each custom header inherits whatever tint its enclosing
/// `Button` is given (often the accent color, which renders the chevron
/// in blue while the Thread screen's system back button stays white).
struct BackChevronButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
                .overlay(
                    Circle().stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
