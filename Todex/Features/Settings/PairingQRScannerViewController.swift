import AVFoundation
import TodexCore
import UIKit

@MainActor
final class PairingQRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let onScan: @MainActor (String) throws -> (message: String, complete: Bool, received: Int, total: Int)
    private let onReset: @MainActor () -> Void
    private let message = UILabel()
    private let progressLabel = UILabel()
    private let progressBar = UIProgressView(progressViewStyle: .bar)
    private let highlight = CAShapeLayer()
    private let checkmark = UIImageView(
        image: UIImage(systemName: "checkmark.circle.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 72, weight: .regular)))
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
        onScan: @escaping @MainActor (String) throws -> (message: String, complete: Bool, received: Int, total: Int),
        onReset: @escaping @MainActor () -> Void
    ) {
        self.onScan = onScan
        self.onReset = onReset
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "扫描配对二维码")
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
        addViewfinder()
        // Highlight the most recently recognized code position.
        highlight.fillColor = UIColor.systemGreen.withAlphaComponent(0.18).cgColor
        highlight.strokeColor = UIColor.systemGreen.cgColor
        highlight.lineWidth = 3
        highlight.lineJoin = .round
        highlight.isHidden = true
        view.layer.addSublayer(highlight)
        checkmark.tintColor = .systemGreen
        checkmark.isHidden = true
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(checkmark)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "pairing.scanner.close"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "重置分片"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                seen.removeAll()
                onReset()
                showProgress(received: 0, total: 0)
                message.text = String(localized: "已清空分片，请扫描同一批次二维码。")
            })
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "pairing.scanner.reset"
        message.text = String(localized: "正在准备相机…")
        message.numberOfLines = 0
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = .white
        message.textAlignment = .center
        message.accessibilityIdentifier = "pairing.scanner.status"
        let retry = Theme.button(String(localized: "重试相机"), icon: "arrow.clockwise") { [weak self] in self?.startCamera() }
        retry.accessibilityIdentifier = "pairing.scanner.retry"
        let settings = Theme.button(String(localized: "相机权限设置"), icon: "gear") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
        settings.accessibilityIdentifier = "pairing.scanner.permissions"
        progressLabel.font = .preferredFont(forTextStyle: .subheadline)
        progressLabel.textColor = .white
        progressLabel.textAlignment = .center
        progressLabel.accessibilityIdentifier = "pairing.scanner.progress"
        progressBar.isHidden = true
        progressLabel.isHidden = true
        progressBar.accessibilityIdentifier = "pairing.scanner.progressBar"
        let progressRow = UIStackView(arrangedSubviews: [progressBar, progressLabel])
        progressRow.axis = .vertical
        progressRow.spacing = 6
        let controls = UIStackView(arrangedSubviews: [message, progressRow, retry, settings])
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
            checkmark.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            checkmark.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            checkmark.widthAnchor.constraint(equalToConstant: 72),
            checkmark.heightAnchor.constraint(equalToConstant: 72),
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
        drawViewfinder()
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
        message.text = String(localized: "正在准备相机…")
        cameraTask = Task { [weak self] in
            do {
                guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String != nil else {
                    throw TodexError.invalid(String(localized: "应用尚未配置相机权限说明，请使用二维码图片导入"))
                }
                let allowed: Bool
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized: allowed = true
                case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
                default: allowed = false
                }
                try Task.checkCancellation()
                guard allowed else { throw TodexError.invalid(String(localized: "未获得相机权限。可前往系统设置允许访问，或返回使用照片导入。")) }
                guard let self, visible, cameraGeneration == current else { return }
                try await capture.start(delegate: self)
                guard !Task.isCancelled, visible, cameraGeneration == current else { return }
                message.text = String(localized: "将二维码放在画面中；分片二维码可连续扫描。")
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

    // Metadata objects are immutable snapshots; the box just tells the
    // compiler they may cross to the main actor for preview-layer conversion.
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let box = ScannerCodeBox(codes: metadataObjects.compactMap {
            guard let code = $0 as? AVMetadataMachineReadableCodeObject, !code.corners.isEmpty else { return nil }
            return code
        })
        Task { @MainActor [weak self] in self?.receive(box) }
    }

    private func receive(_ box: ScannerCodeBox) {
        guard visible, !finished else { return }
        // Highlight the first recognizable code's position on the preview.
        var values: [String] = []
        var shown = false
        for code in box.codes {
            guard let preview,
                let transformed = preview.transformedMetadataObject(for: code) as? AVMetadataMachineReadableCodeObject,
                !transformed.corners.isEmpty
            else { continue }
            if !shown {
                let path = UIBezierPath()
                path.move(to: transformed.corners[0])
                for corner in transformed.corners.dropFirst() { path.addLine(to: corner) }
                path.close()
                highlight.path = path.cgPath
                highlight.isHidden = false
                shown = true
            }
            if let value = code.stringValue { values.append(value) }
        }
        if !shown { highlight.isHidden = true }
        for raw in values {
            // Bound storage and reject oversized camera payloads before retaining them.
            guard raw.utf8.count <= 65_536, !seen.contains(raw) else { continue }
            if seen.count >= 256 { seen.removeAll() }
            seen.insert(raw)
            do {
                let feedback = try onScan(raw)
                message.text = feedback.message
                message.textColor = .white
                showProgress(received: feedback.received, total: feedback.total)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                UIAccessibility.post(notification: .announcement, argument: feedback.message)
                if feedback.complete {
                    finished = true
                    capture.stop()
                    checkmark.isHidden = false
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    UIAccessibility.post(notification: .announcement, argument: String(localized: "扫描完成"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                        self?.dismiss(animated: true)
                    }
                    return
                }
            } catch {
                message.text = error.localizedDescription
                UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
            }
        }
    }

    private func showProgress(received: Int, total: Int) {
        let visible = total > 1
        progressBar.isHidden = !visible
        progressLabel.isHidden = !visible
        guard visible else { return }
        progressBar.progress = Float(received) / Float(total)
        progressLabel.text = String(localized: "已收到 \(received)/\(total) 分片")
    }

    /// Dimmed overlay with a transparent center square and corner brackets,
    /// framing the scan area without blocking the preview.
    private func addViewfinder() {
        let overlay = UIView()
        overlay.isUserInteractionEnabled = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        overlay.layoutIfNeeded()
        let layer = CAShapeLayer()
        overlay.layer.addSublayer(layer)
        // Drawn lazily in layout so it tracks rotation.
        viewfinderLayer = layer
    }
    private var viewfinderLayer: CAShapeLayer?

    private func drawViewfinder() {
        guard let layer = viewfinderLayer else { return }
        let side = min(view.bounds.width, view.bounds.height) * 0.62
        let frame = CGRect(
            x: view.bounds.midX - side / 2,
            y: view.bounds.midY - side / 2 - 20,
            width: side, height: side)
        // Even-odd dimmed mask with a clear window.
        let dim = UIBezierPath(rect: view.bounds)
        dim.append(UIBezierPath(roundedRect: frame, cornerRadius: 18))
        dim.usesEvenOddFillRule = true
        layer.path = dim.cgPath
        layer.fillRule = .evenOdd
        layer.fillColor = UIColor.black.withAlphaComponent(0.45).cgColor
        // Four corner brackets.
        let bracket = CAShapeLayer()
        let arm: CGFloat = 26
        var corners = UIBezierPath()
        for (origin, direction) in [
            (frame.origin, CGPoint(x: 1, y: 1)),
            (CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: -1, y: 1)),
            (CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: -1, y: -1)),
            (CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: 1, y: -1)),
        ] as [(CGPoint, CGPoint)] {
            corners.move(to: CGPoint(x: origin.x + direction.x * arm, y: origin.y))
            corners.addLine(to: origin)
            corners.addLine(to: CGPoint(x: origin.x, y: origin.y + direction.y * arm))
        }
        bracket.path = corners.cgPath
        bracket.strokeColor = UIColor.white.cgColor
        bracket.lineWidth = 4
        bracket.lineCap = .round
        bracket.fillColor = nil
        if let old = layer.sublayers?.first { old.removeFromSuperlayer() }
        layer.addSublayer(bracket)
    }
}

/// AVMetadataMachineReadableCodeObject snapshots are immutable after delivery;
/// the box marks them sendable for the capture-queue -> main-actor hop.
private nonisolated struct ScannerCodeBox: @unchecked Sendable {
    let codes: [AVMetadataMachineReadableCodeObject]
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
                onIssue(error?.localizedDescription ?? String(localized: "相机发生错误，请重试或使用照片导入。"))
            },
            NotificationCenter.default.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
            ) { _ in
                onIssue(String(localized: "相机已中断。请返回前台后重试，或使用照片导入。"))
            },
            NotificationCenter.default.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
            ) { _ in
                onIssue(String(localized: "相机中断已结束，请继续扫码；若画面未恢复，可点按重试相机。"))
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
                    guard session.isRunning else { throw TodexError.invalid(String(localized: "相机无法启动，请重试或使用照片导入")) }
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
            throw TodexError.invalid(String(localized: "此设备没有可用相机，请使用二维码图片导入"))
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureMetadataOutput()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // A failed configuration is retryable without accumulating duplicate inputs.
        for old in session.inputs { session.removeInput(old) }
        for old in session.outputs { session.removeOutput(old) }
        guard session.canAddInput(input) else { throw TodexError.invalid(String(localized: "相机输入不可用")) }
        session.addInput(input)
        guard session.canAddOutput(output) else { throw TodexError.invalid(String(localized: "此相机不支持二维码识别")) }
        session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else { throw TodexError.invalid(String(localized: "此相机不支持二维码识别")) }
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        output.metadataObjectTypes = [.qr]
    }

    func stop() { queue.async { [self] in if session.isRunning { session.stopRunning() } } }
}
