import ImageIO
import PhotosUI
import TodexCore
import UIKit
import UniformTypeIdentifiers
import Vision

@MainActor
final class PairingViewController: SettingsListController, PHPickerViewControllerDelegate {
    private var connection: BackendConnection
    private let onApply: @MainActor (BackendConnection) throws -> Void
    private let onApproved: @MainActor () -> Void
    private var session: DevicePairingSession?
    private var deviceTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var photoTask: Task<Void, Never>?
    private var generation = 0
    private var waiting = false
    private var readingPhotos = false
    private var verificationCode: String?
    private var fingerprint: String?
    private var remainingSeconds = 0
    private var status = String(localized: "扫描后端的配对二维码，或直接开始设备验证。")
    private var failure: String?

    init(
        connection: BackendConnection,
        onApply: @escaping @MainActor (BackendConnection) throws -> Void,
        onApproved: @escaping @MainActor () -> Void = {}
    ) {
        self.connection = connection
        self.onApply = onApply
        self.onApproved = onApproved
        super.init(title: String(localized: "配对与设备验证"))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            cancelDevice(silent: true)
            photoTask?.cancel()
            photoTask = nil
        }
    }

    private func render() {
        sections = [
            SettingsSection(
                title: connection.name,
                rows: [
                    SettingsRow(
                        title: connection.serverURL.isEmpty ? String(localized: "尚未设置地址") : connection.serverURL, detail: status,
                        id: "pairing.status")
                ])
        ]
        if let failure {
            sections.append(
                SettingsSection(
                    title: String(localized: "操作失败"), rows: [SettingsRow(title: failure, id: "pairing.error", color: .systemRed)]))
        }
        let importRows: [SettingsRow] = [
            SettingsRow(
                title: readingPhotos ? String(localized: "正在识别二维码图片…") : String(localized: "从照片选择二维码"),
                detail: String(localized: "只读取后端地址"), symbol: "photo",
                id: "pairing.photos", enabled: !waiting && !readingPhotos, activity: readingPhotos
            ) { [weak self] in self?.choosePhotos() },
            SettingsRow(
                title: String(localized: "相机扫码"), detail: String(localized: "只读取后端地址"), symbol: "qrcode.viewfinder",
                id: "pairing.camera", enabled: !waiting && !readingPhotos
            ) { [weak self] in self?.scan() },
        ]
        sections.append(
            SettingsSection(
                title: String(localized: "扫描配对二维码"),
                footer: String(localized: "二维码只填写后端地址，随后自动开始设备验证；加密公钥只由设备验证确认。"), rows: importRows))
        var deviceRows: [SettingsRow] = []
        if let verificationCode {
            deviceRows.append(
                SettingsRow(
                    title: verificationCode, detail: String(localized: "在后端核对同一个随机码后批准此设备。剩余 \(remainingSeconds) 秒。"),
                    symbol: "checkmark.shield", id: "pairing.verificationCode"))
        }
        if let fingerprint {
            deviceRows.append(
                SettingsRow(
                    title: fingerprint, detail: String(localized: "后端公钥指纹，应与后端设备面板显示的一致。"), symbol: "key",
                    id: "pairing.fingerprint"))
        }
        let pinned = connection.hasPinnedTransport
        deviceRows.append(
            SettingsRow(
                title: waiting
                    ? String(localized: "等待后端批准…") : pinned ? String(localized: "重新配对") : String(localized: "申请设备验证"),
                symbol: "iphone.gen3", id: "pairing.device.begin",
                enabled: !waiting && !readingPhotos, activity: waiting
            ) { [weak self] in self?.beginDevice() })
        if waiting {
            deviceRows.append(
                SettingsRow(title: String(localized: "取消验证"), id: "pairing.device.cancel", color: .systemRed) { [weak self] in
                    self?.cancelDevice(silent: false)
                })
        }
        sections.append(
            SettingsSection(
                title: String(localized: "设备验证"),
                footer: String(localized: "批准后此后端信任本机设备密钥，本机同时保存经验证的传输加密公钥。同一后端重新配对会沿用本机设备密钥。"),
                rows: deviceRows))
        redraw()
    }

    /// Imports a pairing link: fills the address only, then verifies the
    /// device, which is what pins the transport key.
    private func ingest(_ raw: String) throws {
        guard !waiting else { throw TodexError.invalid(String(localized: "请先取消正在进行的设备验证")) }
        let updated = try PairingImporter.ingest(raw.trimmingCharacters(in: .whitespacesAndNewlines), current: connection)
        if updated != connection {
            try onApply(updated)
            connection = updated
        }
        status = String(localized: "已读取后端地址，正在开始设备验证。")
        failure = nil
        render()
        beginDevice()
    }

    private func choosePhotos() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 16
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        readingPhotos = true
        failure = nil
        render()
        photoTask?.cancel()
        photoTask = Task { [weak self] in
            do {
                let reader = PairingImageReader()
                // One selection imports one pairing: the first pairing QR
                // wins; other codes are skipped, reported only if none fits.
                var skipped: (any Error)?
                for result in results {
                    try Task.checkCancellation()
                    let data = try await Self.imageData(result.itemProvider)
                    let frames = try await reader.frames(data)
                    try Task.checkCancellation()
                    guard let self else { return }
                    for frame in frames {
                        do { _ = try PairingImporter.ingest(frame, current: connection) } catch {
                            skipped = error
                            continue
                        }
                        readingPhotos = false
                        photoTask = nil
                        try ingest(frame)
                        return
                    }
                }
                if let skipped { throw skipped }
            } catch {
                if !Task.isCancelled { self?.failure = error.localizedDescription }
            }
            guard !Task.isCancelled else { return }
            self?.readingPhotos = false
            self?.photoTask = nil
            self?.render()
        }
    }

    private static func imageData(_ provider: NSItemProvider) async throws -> Data {
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true })
        else { throw TodexError.invalid(String(localized: "所选项目不是图片")) }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: TodexError.invalid(String(localized: "无法读取图片")))
                }
            }
        }
    }

    private func scan() {
        let scanner = PairingQRScannerViewController { [weak self] raw in
            guard let self else { throw CancellationError() }
            try ingest(raw)
            return status
        }
        present(UINavigationController(rootViewController: scanner), animated: true)
    }

    private func beginDevice() {
        guard !waiting else { return }
        do { _ = try connection.normalizedURL() } catch {
            failure = error.localizedDescription
            render()
            return
        }
        let source = connection
        // Re-pairing the same backend keeps the device key, so its device ID
        // and history-key recipient stay the same; the address change that
        // makes it another backend has already cleared it. The key is saved
        // only with the approval, together with the transport it pins.
        let device = DeviceIdentity(secretKeyBase64URL: source.deviceSecret) ?? DeviceIdentity()
        generation += 1
        let current = generation
        waiting = true
        failure = nil
        verificationCode = nil
        fingerprint = nil
        status = String(localized: "正在向后端申请设备验证…")
        render()
        deviceTask = Task { [weak self] in
            do {
                let session = try await DevicePairingSession.begin(
                    connection: source, deviceName: "TodeX iOS", device: device)
                guard let self, !Task.isCancelled, generation == current, connection == source else {
                    try? await session.cancel()
                    return
                }
                self.session = session
                verificationCode = session.verificationCode
                fingerprint =
                    session.transport.encryption == .none
                    ? String(localized: "无（本机明文）") : session.transport.fingerprint
                let waitingStatus = String(localized: "等待后端批准，请核对随机码。")
                status = waitingStatus
                let expiry = session.expiresAt
                startExpiryClock(expiresAt: expiry, generation: current)
                render()
                let pollInterval = Duration.milliseconds(session.pollIntervalMilliseconds)
                var pollDelay = pollInterval
                while !Task.isCancelled {
                    try await Task.sleep(for: pollDelay)
                    let result: DevicePairingStatus
                    do {
                        result = try await session.poll()
                    } catch let error as DevicePairingRetryableError
                        where Date().timeIntervalSince1970 * 1_000 < expiry
                    {
                        // 429, 5xx, network or timeout: back off and keep
                        // polling until the request expires.
                        try Task.checkCancellation()
                        guard generation == current, connection == source else {
                            try? await session.cancel()
                            return
                        }
                        pollDelay = DevicePairingSession.nextPollDelay(after: pollDelay, error: error)
                        status = String(localized: "\(error.localizedDescription)，正在重试…")
                        render()
                        continue
                    }
                    try Task.checkCancellation()
                    guard generation == current, connection == source else {
                        try? await session.cancel()
                        return
                    }
                    guard Date().timeIntervalSince1970 * 1_000 < expiry else {
                        finishDevice(String(localized: "申请已过期，请重新申请。"), cancel: true)
                        return
                    }
                    pollDelay = pollInterval
                    switch result {
                    case .pending:
                        if status != waitingStatus {
                            status = waitingStatus
                            render()
                        }
                        continue
                    case .approved(let transport):
                        // One write pins the device key and the verified
                        // transport; only then connect.
                        var approved = source
                        approved.pin(transport, deviceSecret: device.secretKeyBase64URL)
                        do {
                            try onApply(approved)
                        } catch {
                            failure = error.localizedDescription
                            finishDevice(String(localized: "设备已批准，但无法保存配对结果，请重新配对。"), cancel: false)
                            return
                        }
                        connection = approved
                        finishDevice(String(localized: "设备已批准，正在连接…"), cancel: false)
                        onApproved()
                        return
                    case .rejected:
                        finishDevice(String(localized: "后端已拒绝申请，请核对后重新申请。"), cancel: false)
                        return
                    case .expired:
                        finishDevice(String(localized: "申请已过期，请重新申请。"), cancel: false)
                        return
                    }
                }
            } catch {
                guard let self, !Task.isCancelled, generation == current else { return }
                failure = error.localizedDescription
                finishDevice(String(localized: "设备验证失败，请重新申请。"), cancel: true)
            }
        }
    }

    private func startExpiryClock(expiresAt: Double, generation current: Int) {
        expiryTask?.cancel()
        remainingSeconds = max(0, Int(ceil((expiresAt - Date().timeIntervalSince1970 * 1_000) / 1_000)))
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, generation == current else { return }
                remainingSeconds = max(0, Int(ceil((expiresAt - Date().timeIntervalSince1970 * 1_000) / 1_000)))
                if remainingSeconds == 0 {
                    finishDevice(String(localized: "申请已过期，请重新申请。"), cancel: true)
                    return
                }
                render()
            }
        }
    }

    private func finishDevice(_ message: String, cancel: Bool) {
        let previous = session
        session = nil
        waiting = false
        verificationCode = nil
        fingerprint = nil
        generation += 1
        deviceTask?.cancel()
        deviceTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        status = message
        render()
        if cancel, let previous { Task { try? await previous.cancel() } }
    }

    private func cancelDevice(silent: Bool) {
        guard waiting || session != nil else { return }
        finishDevice(silent ? String(localized: "验证已停止。") : String(localized: "已取消本次设备验证。"), cancel: true)
    }
}

/// Vision runs outside the main actor; only decoded strings cross back to UIKit.
private actor PairingImageReader {
    func frames(_ data: Data) throws -> [String] {
        try Task.checkCancellation()
        guard data.count <= 25 * 1_024 * 1_024,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096,
                ] as CFDictionary)
        else { throw TodexError.invalid(String(localized: "无法读取图片，或图片超过 25 MiB")) }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        let values = request.results?.compactMap(\.payloadStringValue) ?? []
        guard !values.isEmpty else { throw TodexError.invalid(String(localized: "图片中未识别到二维码，请选择更清晰的原图")) }
        return values
    }
}
