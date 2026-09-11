import AVFoundation
import TodexCore
import UIKit

@MainActor
final class PairingQRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let onScan: @MainActor (String) throws -> (message: String, complete: Bool)
    private let onReset: @MainActor () -> Void
    private let message = UILabel()
    private var preview: AVCaptureVideoPreviewLayer?
    private var cameraTask: Task<Void, Never>?
    private var seen: Set<String> = []
    private var visible = false
    private var finished = false
    private var cameraGeneration = 0
    private lazy var capture = PairingCameraCapture { [weak self] text in
        Task { @MainActor [weak self] in
            guard let self, visible else { return }
            message.text = text
            message.textColor = .white
        }
    }

    init(
        onScan: @escaping @MainActor (String) throws -> (message: String, complete: Bool),
        onReset: @escaping @MainActor () -> Void
    ) {
        self.onScan = onScan
        self.onReset = onReset
        super.init(nibName: nil, bundle: nil)
        title = "扫描配对二维码"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(onScan:onReset:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let preview = capture.makePreviewLayer()
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.preview = preview
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "pairing.scanner.close"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "重置分片",
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                seen.removeAll()
                onReset()
                message.text = "已清空分片，请扫描同一批次二维码。"
            })
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "pairing.scanner.reset"
        message.text = "正在准备相机…"
        message.numberOfLines = 0
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = .white
        message.textAlignment = .center
        message.accessibilityIdentifier = "pairing.scanner.status"
        let retry = Theme.button("重试相机", icon: "arrow.clockwise") { [weak self] in self?.startCamera() }
        retry.accessibilityIdentifier = "pairing.scanner.retry"
        let settings = Theme.button("相机权限设置", icon: "gear") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
        settings.accessibilityIdentifier = "pairing.scanner.permissions"
        let controls = UIStackView(arrangedSubviews: [message, retry, settings])
        controls.axis = .vertical
        controls.spacing = 12
        controls.isLayoutMarginsRelativeArrangement = true
        controls.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        controls.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        controls.layer.cornerRadius = 20
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            settings.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        startCamera()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        cameraGeneration += 1
        cameraTask?.cancel()
        cameraTask = nil
        capture.stop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        let angle: CGFloat
        switch view.window?.windowScene?.effectiveGeometry.interfaceOrientation {
        case .landscapeLeft: angle = 0
        case .landscapeRight: angle = 180
        case .portraitUpsideDown: angle = 270
        default: angle = 90
        }
        if let connection = preview?.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    @objc private func background() {
        cameraGeneration += 1
        cameraTask?.cancel()
        cameraTask = nil
        capture.stop()
    }
    @objc private func foreground() { if visible { startCamera() } }

    private func startCamera() {
        guard visible, !finished, cameraTask == nil else { return }
        cameraGeneration += 1
        let current = cameraGeneration
        message.text = "正在准备相机…"
        cameraTask = Task { [weak self] in
            do {
                guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String != nil else {
                    throw TodexError.invalid("应用尚未配置相机权限说明，请使用二维码图片导入")
                }
                let allowed: Bool
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized: allowed = true
                case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
                default: allowed = false
                }
                try Task.checkCancellation()
                guard allowed else { throw TodexError.invalid("未获得相机权限。可前往系统设置允许访问，或返回使用照片导入。") }
                guard let self, visible, cameraGeneration == current else { return }
                try await capture.start(delegate: self)
                guard !Task.isCancelled, visible, cameraGeneration == current else { return }
                message.text = "将二维码放在画面中；分片二维码可连续扫描。"
                message.textColor = .white
                view.setNeedsLayout()
            } catch {
                if !Task.isCancelled, self?.cameraGeneration == current {
                    self?.message.text = error.localizedDescription
                    self?.message.textColor = .white
                }
            }
            if self?.cameraGeneration == current { self?.cameraTask = nil }
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let values = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        Task { @MainActor [weak self] in self?.receive(values) }
    }

    private func receive(_ values: [String]) {
        guard visible, !finished else { return }
        for raw in values {
            // Bound storage and reject oversized camera payloads before retaining them.
            guard raw.utf8.count <= 65_536, !seen.contains(raw) else { continue }
            if seen.count >= 256 { seen.removeAll() }
            seen.insert(raw)
            do {
                let feedback = try onScan(raw)
                message.text = feedback.message
                message.textColor = .white
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                UIAccessibility.post(notification: .announcement, argument: feedback.message)
                if feedback.complete {
                    finished = true
                    capture.stop()
                    dismiss(animated: true)
                    return
                }
            } catch {
                message.text = error.localizedDescription
                UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
            }
        }
    }
}

/// AVFoundation requires blocking start/stop calls off the main thread. All mutable session
/// state is confined to this serial queue; the only main-thread access creates the preview
/// layer before capture starts. The layer then observes the session through AVFoundation.
private nonisolated final class PairingCameraCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.todex.pairing.camera")
    private let session = AVCaptureSession()
    private var configured = false  // Access only on queue.
    private var observers: [NSObjectProtocol] = []  // Initialized once; removed at deinit.

    init(onIssue: @escaping @Sendable (String) -> Void) {
        observers = [
            NotificationCenter.default.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
            ) { notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                onIssue(error?.localizedDescription ?? "相机发生错误，请重试或使用照片导入。")
            },
            NotificationCenter.default.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
            ) { _ in
                onIssue("相机已中断。请返回前台后重试，或使用照片导入。")
            },
            NotificationCenter.default.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
            ) { _ in
                onIssue("相机中断已结束，请继续扫码；若画面未恢复，可点按重试相机。")
            },
        ]
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    @MainActor func makePreviewLayer() -> AVCaptureVideoPreviewLayer { AVCaptureVideoPreviewLayer(session: session) }

    func start(delegate: PairingQRScannerViewController) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    if !configured {
                        try configure(delegate: delegate)
                        configured = true
                    }
                    if !session.isRunning { session.startRunning() }
                    guard session.isRunning else { throw TodexError.invalid("相机无法启动，请重试或使用照片导入") }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func configure(delegate: PairingQRScannerViewController) throws {
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video)
        else {
            throw TodexError.invalid("此设备没有可用相机，请使用二维码图片导入")
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureMetadataOutput()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // A failed configuration is retryable without accumulating duplicate inputs.
        for old in session.inputs { session.removeInput(old) }
        for old in session.outputs { session.removeOutput(old) }
        guard session.canAddInput(input) else { throw TodexError.invalid("相机输入不可用") }
        session.addInput(input)
        guard session.canAddOutput(output) else { throw TodexError.invalid("此相机不支持二维码识别") }
        session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else { throw TodexError.invalid("此相机不支持二维码识别") }
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        output.metadataObjectTypes = [.qr]
    }

    func stop() { queue.async { [self] in if session.isRunning { session.stopRunning() } } }
}
