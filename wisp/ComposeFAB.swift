import SwiftUI

/// Floating compose button. Designed to overlay the home tab content, sitting just
/// above the bottom tab bar.
struct ComposeFAB: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "pencil")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.wispPrimary, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
        }
        .accessibilityLabel("New post")
    }
}
