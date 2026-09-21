import SwiftUI

// MARK: - Render side (ALT badge + Description dialog)

/// The small dark "ALT" chip shown on images that carry an accessibility
/// description. Sighted users can inspect the text too — the badge is a
/// sibling tap target next to the image, never a nested control, so VoiceOver
/// gets two clean focus stops ("the description, image" / "View image
/// description").
struct AltBadge: View {
    var body: some View {
        Text("ALT")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.65), in: Capsule())
    }
}

/// The "Description" bottom sheet behind every ALT badge — a sheet, not an
/// alert, so long descriptions are fully readable (scrollable, expandable to
/// full height) instead of bouncing off the alert's size limit.
struct MediaAltDescriptionSheet: ViewModifier {
    let alt: String?
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            AltDescriptionSheet(text: alt ?? "")
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// Sheet body: the full accessibility description, scrollable.
struct AltDescriptionSheet: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Description")
                    .font(.headline)
                Spacer()
                AltBadge()
            }
            ScrollView {
                Text(text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 16)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

extension View {
    func mediaAltDescriptionSheet(alt: String?, isPresented: Binding<Bool>) -> some View {
        modifier(MediaAltDescriptionSheet(alt: alt, isPresented: isPresented))
    }
}

/// Applies an accessibility label only when one exists — applying an empty
/// label would collapse the element to nothing for VoiceOver, so undescribed
/// media must keep its default behavior.
struct AltAccessibilityLabel: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label, !label.isEmpty {
            content.accessibilityLabel(label)
        } else {
            content
        }
    }
}

// MARK: - Compose side (alt-text editor)

/// Identifiable sheet payload: which attachment is being described, what to
/// preview, and the text to start from.
struct AltTextEditorTarget: Identifiable {
    let attachmentID: UUID
    /// Uploaded URL for the preview when local bytes are gone.
    var previewURL: String?
    /// Pre-upload bytes for the preview.
    var localBytes: Data?
    var initialText: String?

    var id: UUID { attachmentID }
}

/// The alt-text editor behind the composer's "+ ALT / ✓ ALT" chip: image
/// preview, one-line explainer, a capped multiline field, Save/Clear. Saving
/// never blocks publishing — alt text is optional metadata, and clearing the
/// field removes the imeta `alt` slot at publish time.
struct AltTextEditorView: View {
    let target: AltTextEditorTarget
    /// Called with the trimmed description, or nil when cleared.
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    /// Hard cap matching the web composer — alt text is a description, not an
    /// essay; every client truncating at their own limit would be worse.
    static let maxCharacters = 2000

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                previewImage
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Text("A short description makes your photo accessible to screen reader users — and gives everyone context if the image doesn't load.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $text)
                    .frame(minHeight: 96)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .bottomTrailing) {
                        Text("\(remaining) remaining")
                            .font(.caption2)
                            .foregroundStyle(remaining < 100 ? .orange : .secondary)
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                    .onChange(of: text) { _, newValue in
                        if newValue.count > Self.maxCharacters {
                            text = String(newValue.prefix(Self.maxCharacters))
                        }
                    }

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("Description")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(text)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { if text.isEmpty { text = target.initialText ?? "" } }
    }

    private var remaining: Int {
        max(0, Self.maxCharacters - text.count)
    }

    @ViewBuilder
    private var previewImage: some View {
        if let bytes = target.localBytes, let img = UIImage(data: bytes) {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
        } else if let url = target.previewURL {
            AsyncImage(url: URL(string: url)) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                default: Color.wispSurfaceVariant
                }
            }
        } else {
            Color.wispSurfaceVariant
                .overlay {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
        }
    }
}
