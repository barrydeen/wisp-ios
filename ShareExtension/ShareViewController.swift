import UIKit
import UniformTypeIdentifiers

/// Share Extension entry point. Stages every shared image/video into the
/// App Group container via `PendingShareStore`, then hands off to the main
/// app with `wisp://share` — no compose UI lives here; the main app opens
/// straight into `ComposeView` with the media already attached (see
/// `wispApp.onOpenURL`, `MainView.pendingShare`).
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setUpUI()
        Task { await handleShare() }
    }

    private func setUpUI() {
        statusLabel.text = "Sharing to Wisp…"
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .label
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32)
        ])
    }

    private func handleShare() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .compactMap { $0.attachments }
            .flatMap { $0 } ?? []

        var stagedAny = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                if await stage(provider, typeIdentifier: UTType.movie.identifier, preferredExtension: "mov") {
                    stagedAny = true
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if await stage(provider, typeIdentifier: UTType.image.identifier, preferredExtension: "jpg") {
                    stagedAny = true
                }
            }
        }

        guard stagedAny else {
            statusLabel.text = "Wisp doesn't support this content."
            spinner.stopAnimating()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        guard let url = URL(string: "wisp://share") else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        extensionContext?.open(url) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func stage(_ provider: NSItemProvider, typeIdentifier: String, preferredExtension: String) async -> Bool {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: PendingShareStore.stage(fileAt: url, preferredExtension: preferredExtension))
            }
        }
    }
}
