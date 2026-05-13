import SwiftUI
import AVFoundation

/// Live camera QR scanner. Yields the first detected payload via `onScanned` and
/// then stops the session — caller dismisses the sheet.
struct QRCodeScannerView: UIViewControllerRepresentable {
    let onScanned: (String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        let vc = QRCodeScannerViewController()
        vc.onScanned = onScanned
        vc.onCancel = onCancel
        return vc
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {}
}

final class QRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var metadataOutput: AVCaptureMetadataOutput?
    private var hasReported = false
    // Dedicated high-priority queue so metadata callbacks don't contend with the main thread.
    private let captureQueue = DispatchQueue(label: "com.wisp.qrscan", qos: .userInteractive)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            print("[QRScanner] viewDidLoad: camera/input unavailable")
            showCameraUnavailable()
            return
        }
        print("[QRScanner] viewDidLoad: input ready")

        // Prefer the highest quality preset that the device supports — faster
        // decode on the full sensor image vs the default 640×480 preview.
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            print("[QRScanner] viewDidLoad: cannot add output")
            showCameraUnavailable()
            return
        }
        session.addOutput(output)
        // Run delegate on a background queue — not .main — so detection
        // doesn't block the UI during sheet presentation animations.
        output.setMetadataObjectsDelegate(self, queue: captureQueue)
        output.metadataObjectTypes = [.qr]
        metadataOutput = output
        print("[QRScanner] viewDidLoad: setup complete, metadataTypes=\(output.metadataObjectTypes)")

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.layer.bounds
        view.layer.addSublayer(layer)
        preview = layer

        addOverlay()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.layer.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        print("[QRScanner] viewDidAppear")
        // Start on the capture queue (required; startRunning() blocks until ready).
        captureQueue.async { [session] in
            guard !session.isRunning else {
                print("[QRScanner] session already running")
                return
            }
            print("[QRScanner] starting session")
            session.startRunning()
            print("[QRScanner] session isRunning=\(session.isRunning)")
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        print("[QRScanner] metadata callback: \(metadataObjects.count) objects, hasReported=\(hasReported)")
        guard !hasReported,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = obj.stringValue else { return }
        print("[QRScanner] scanned value: \(value)")
        hasReported = true
        captureQueue.async { [session] in session.stopRunning() }
        DispatchQueue.main.async { [weak self] in
            AudioServicesPlaySystemSound(SystemSoundID(1004))
            self?.onScanned?(value)
        }
    }

    // MARK: - Overlay

    private func addOverlay() {
        // Cancel button
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        cancelButton.backgroundColor = UIColor(white: 0, alpha: 0.5)
        cancelButton.layer.cornerRadius = 8
        cancelButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancelButton)

        // Guide frame
        let frameView = UIView()
        frameView.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        frameView.layer.borderWidth = 3
        frameView.layer.cornerRadius = 16
        frameView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(frameView)

        // Dim overlay outside guide box
        let dimView = QRDimView()
        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.isUserInteractionEnabled = false
        view.insertSubview(dimView, belowSubview: frameView)

        NSLayoutConstraint.activate([
            cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),

            frameView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            frameView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            frameView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.7),
            frameView.heightAnchor.constraint(equalTo: frameView.widthAnchor),

            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Update dim cutout after layout
        DispatchQueue.main.async { [weak self, weak dimView, weak frameView] in
            guard let self, let dimView, let frameView else { return }
            dimView.cutout = self.view.convert(frameView.bounds, from: frameView)
            dimView.setNeedsDisplay()
        }
    }

    @objc private func cancelTapped() { onCancel?() }

    private func showCameraUnavailable() {
        let label = UILabel()
        label.text = "Camera unavailable"
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        cancelButton.backgroundColor = UIColor(white: 0, alpha: 0.5)
        cancelButton.layer.cornerRadius = 8
        cancelButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32)
        ])
    }
}

// Semi-transparent overlay that punches a clear hole over the guide box.
private final class QRDimView: UIView {
    var cutout: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fill(rect)
        ctx.setBlendMode(.clear)
        let path = UIBezierPath(roundedRect: cutout.insetBy(dx: -2, dy: -2), cornerRadius: 18)
        ctx.addPath(path.cgPath)
        ctx.fillPath()
    }
}
