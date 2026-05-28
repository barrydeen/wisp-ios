#if DEBUG
import SwiftUI

/// Debug-only developer playground. Wired into `InterfaceSettingsView`
/// under a `#if DEBUG` row so it ships nowhere near a release build.
/// Pin throwaway experiments here — animation styles, prototype layouts,
/// single-shot repros — instead of building a temporary entry in
/// production code.
struct DeveloperToolsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Nothing live right now. Add experimental sections here.")
                    .font(.subheadline)
                    .foregroundStyle(theme.palette.onSurfaceVariant)
            }
            .padding(20)
        }
        .background(theme.palette.background.ignoresSafeArea())
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", action: dismiss.callAsFunction)
            }
        }
    }
}

#Preview {
    NavigationStack { DeveloperToolsView() }
}
#endif
