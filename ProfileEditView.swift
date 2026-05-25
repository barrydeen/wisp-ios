import SwiftUI
import PhotosUI

/// Edit-profile sheet pushed from the active user's own profile. Form fields
/// mirror the kind-0 metadata schema (display_name, name, about, picture,
/// banner, nip05, lud16). Photo pickers upload through the existing Blossom
/// pipeline and write the returned CDN URL into the corresponding text field.
struct ProfileEditView: View {
    let keypair: Keypair
    /// Called with the freshly published `ProfileData` so the parent profile
    /// header can update its binding without a network round-trip.
    var onSaved: (ProfileData) -> Void = { _ in }

    @State private var viewModel: ProfileEditViewModel
    @State private var advancedExpanded = false
    @Environment(\.dismiss) private var dismiss
    @Environment(WalletStore.self) private var walletStore: WalletStore?

    init(keypair: Keypair, onSaved: @escaping (ProfileData) -> Void = { _ in }) {
        self.keypair = keypair
        self.onSaved = onSaved
        _viewModel = State(initialValue: ProfileEditViewModel(keypair: keypair))
    }

    var body: some View {
        // GeometryReader pins the ScrollView's content to the viewport
        // width. Without an explicit upper bound, a long unbroken string
        // in a TextField (e.g. a 70-char nostr.build URL pasted into
        // Picture / Banner URL) reports an intrinsic content width
        // larger than the screen, which ScrollView happily honors —
        // pulling the entire VStack wider than the viewport and
        // shifting every label / field leftward off-screen.
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    bannerWithAvatar
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity)

                    if let status = viewModel.uploadStatus {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let error = viewModel.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    fields
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
                .frame(width: proxy.size.width, alignment: .leading)
            }
        }
        .background(Color.wispBackground.ignoresSafeArea())
        .navigationTitle("Edit Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        if let updated = await viewModel.save() {
                            onSaved(updated)
                            dismiss()
                        }
                    }
                } label: {
                    if viewModel.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save").font(.subheadline.weight(.semibold))
                    }
                }
                .disabled(viewModel.isSaving)
            }
        }
        .task { await viewModel.start() }
    }

    // MARK: - Banner + avatar

    private var bannerWithAvatar: some View {
        ZStack(alignment: .bottomLeading) {
            bannerView
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .clipped()

            avatarView
                .offset(x: 16, y: 42)
        }
    }

    private var bannerView: some View {
        PhotosPicker(
            selection: $viewModel.bannerItem,
            matching: .images,
            photoLibrary: .shared()
        ) {
            ZStack {
                if let preview = viewModel.bannerPreview, let img = UIImage(data: preview) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else if let banner = viewModel.banner.nonEmpty,
                          let url = URL(string: banner) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: Color.wispSurfaceVariant
                        }
                    }
                } else {
                    Color.wispSurfaceVariant
                }
                Color.black.opacity(0.25)
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .onChange(of: viewModel.bannerItem) { _, item in
            Task { await viewModel.handleBannerPick(item) }
        }
    }

    private var avatarView: some View {
        PhotosPicker(
            selection: $viewModel.pictureItem,
            matching: .images,
            photoLibrary: .shared()
        ) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let preview = viewModel.picturePreview, let img = UIImage(data: preview) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        CachedAvatarView(url: viewModel.picture.nonEmpty, size: 84, alwaysLoad: true)
                    }
                }
                .frame(width: 84, height: 84)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.wispBackground, lineWidth: 4))

                Image(systemName: "camera.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(Color.wispPrimary, in: Circle())
                    .overlay(Circle().stroke(Color.wispBackground, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
        }
        .onChange(of: viewModel.pictureItem) { _, item in
            Task { await viewModel.handlePicturePick(item) }
        }
    }

    // MARK: - Fields

    @ViewBuilder
    private var fields: some View {
        field(label: "Display name", text: $viewModel.displayName, placeholder: "Satoshi")
        field(label: "Username", text: $viewModel.name, placeholder: "satoshi", autocaps: false)

        VStack(alignment: .leading, spacing: 6) {
            Text("About")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $viewModel.about)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, minHeight: 90)
                .padding(10)
                .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        field(label: "NIP-05", text: $viewModel.nip05, placeholder: "you@example.com", keyboard: .emailAddress, autocaps: false)
        VStack(alignment: .leading, spacing: 6) {
            field(label: "Lightning Address", text: $viewModel.lud16, placeholder: "you@walletofsatoshi.com", keyboard: .emailAddress, autocaps: false)
            if let walletAddr = walletStore?.lightningAddress,
               !walletAddr.isEmpty,
               walletAddr.lowercased() != viewModel.lud16.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.wispZapColor)
                    Text("Wallet: \(walletAddr)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        viewModel.lud16 = walletAddr
                    } label: {
                        Text("Use")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.wispPrimary.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.wispPrimary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
            }
        }

        advancedSection
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { advancedExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Advanced")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: advancedExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if advancedExpanded {
                field(label: "Picture URL", text: $viewModel.picture, placeholder: "https://…", keyboard: .URL, autocaps: false)
                field(label: "Banner URL", text: $viewModel.banner, placeholder: "https://…", keyboard: .URL, autocaps: false)
            }
        }
        .padding(.top, 8)
    }

    private func field(
        label: String,
        text: Binding<String>,
        placeholder: String,
        keyboard: UIKeyboardType = .default,
        autocaps: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocaps ? .sentences : .never)
                .autocorrectionDisabled(!autocaps)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
