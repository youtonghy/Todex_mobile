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
    private var importer = PairingImporter()
    private var session: DevicePairingSession?
    private var deviceTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var photoTask: Task<Void, Never>?
    private var generation = 0
    private var waiting = false
    private var readingPhotos = false
    private var verificationCode: String?
    private var remainingSeconds = 0
    private var status = String(localized: "导入后端提供的配对信息，或申请设备验证。")
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
        var importRows: [SettingsRow] = [
            SettingsRow(
                title: String(localized: "粘贴配对 JSON"), symbol: "curlybraces", id: "pairing.json", enabled: !waiting && !readingPhotos
            ) { [weak self] in self?.editJSON() },
            SettingsRow(
                title: String(localized: "从剪贴板导入"), symbol: "doc.on.clipboard", id: "pairing.clipboard",
                enabled: !waiting && !readingPhotos
            ) { [weak self] in
                guard let self else { return }
                do {
                    guard let raw = UIPasteboard.general.string,
                        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { throw TodexError.invalid(String(localized: "剪贴板中没有配对文本")) }
                    _ = try ingest(raw)
                } catch {
                    failure = error.localizedDescription
                    render()
                }
            },
            SettingsRow(
                title: readingPhotos ? String(localized: "正在识别二维码图片…") : String(localized: "从照片选择二维码"), detail: String(localized: "支持多张图片及分片二维码"), symbol: "photo",
                id: "pairing.photos", enabled: !waiting && !readingPhotos, activity: readingPhotos
            ) { [weak self] in self?.choosePhotos() },
            SettingsRow(
                title: String(localized: "相机扫码"), detail: String(localized: "连续扫描同一批次的全部分片"), symbol: "qrcode.viewfinder", id: "pairing.camera",
                enabled: !waiting && !readingPhotos
            ) { [weak self] in self?.scan() },
        ]
        if importer.totalCount > 0 {
            importRows.append(
                SettingsRow(
                    title: String(localized: "分片进度 \(importer.receivedCount)/\(importer.totalCount)"), detail: String(localized: "点按清空本批次后重新导入"),
                    id: "pairing.fragments.reset", enabled: !readingPhotos
                ) { [weak self] in
                    self?.resetFragments()
                })
        }
        sections.append(SettingsSection(title: String(localized: "导入配对"), footer: String(localized: "分片可按任意顺序扫描；收齐同一批次后才会保存配对信息。"), rows: importRows))
        var deviceRows: [SettingsRow] = []
        if let verificationCode {
            deviceRows.append(
                SettingsRow(
                    title: verificationCode, detail: String(localized: "在后端核对同一个随机码后批准此设备。剩余 \(remainingSeconds) 秒。"),
                    symbol: "checkmark.shield", id: "pairing.verificationCode"))
        }
        deviceRows.append(
            SettingsRow(
                title: waiting ? String(localized: "等待后端批准…") : String(localized: "申请设备验证"), symbol: "iphone.gen3", id: "pairing.device.begin",
                enabled: !waiting && !readingPhotos, activity: waiting
            ) { [weak self] in self?.beginDevice() })
        if waiting {
            deviceRows.append(
                SettingsRow(title: String(localized: "取消验证"), id: "pairing.device.cancel", color: .systemRed) { [weak self] in
                    self?.cancelDevice(silent: false)
                })
        }
        sections.append(
            SettingsSection(title: String(localized: "设备验证"), footer: String(localized: "批准后此后端即信任本机设备密钥；传输加密公钥仍需从配对信息导入。"), rows: deviceRows))
        redraw()
    }

    @discardableResult
    private func ingest(_ raw: String) throws -> Bool {
        guard !waiting else { throw TodexError.invalid(String(localized: "请先取消正在进行的设备验证")) }
        let updated = try importer.ingest(raw.trimmingCharacters(in: .whitespacesAndNewlines), current: connection)
        if let updated {
            try onApply(updated)
            connection = updated
            status = String(localized: "配对信息已导入并保存。")
        } else {
            status = String(localized: "已收到分片 \(importer.receivedCount)/\(importer.totalCount)，请继续导入本批次剩余分片。")
        }
        failure = nil
        render()
        // A fresh import with no enrolled device flows straight into
        // verification: scan -> verify -> connect needs no extra taps.
        if updated != nil, DeviceIdentity(secretKeyBase64URL: connection.deviceSecret) == nil {
            beginDevice()
        }
        return updated != nil
    }

    private func resetFragments() {
        importer = PairingImporter()
        failure = nil
        status = String(localized: "已清空配对分片。")
        render()
    }

    private func editJSON() {
        let editor = SettingsTextController(
            title: String(localized: "配对 JSON"), text: "", detail: String(localized: "粘贴后端 TUI 提供的完整 JSON，或本批次的一个二维码分片。"), editable: true, actionTitle: String(localized: "导入")
        ) { [weak self] text in
            guard let self else { throw CancellationError() }
            _ = try ingest(text)
            navigationController?.popViewController(animated: true)
        }
        navigationController?.pushViewController(editor, animated: true)
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
                for result in results {
                    try Task.checkCancellation()
                    let data = try await Self.imageData(result.itemProvider)
                    let frames = try await reader.frames(data)
                    try Task.checkCancellation()
                    guard let self else { return }
                    for frame in frames {
                        // One selection imports one pairing. Do not overwrite it with another QR in the image.
                        if try ingest(frame) {
                            readingPhotos = false
                            photoTask = nil
                            render()
                            return
                        }
                    }
                }
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
            let complete = try ingest(raw)
            return (status, complete, importer.receivedCount, importer.totalCount)
        } onReset: { [weak self] in
            self?.resetFragments()
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
        var source = connection
        if DeviceIdentity(secretKeyBase64URL: source.deviceSecret) == nil {
            do {
                source.deviceSecret = DeviceIdentity().secretKeyBase64URL
                try onApply(source)
                connection = source
            } catch {
                failure = error.localizedDescription
                render()
                return
            }
        }
        generation += 1
        let current = generation
        waiting = true
        failure = nil
        verificationCode = nil
        status = String(localized: "正在向后端申请设备验证…")
        render()
        deviceTask = Task { [weak self] in
            do {
                let session = try await DevicePairingSession.begin(
                    connection: source, deviceName: "TodeX iOS", device: DeviceIdentity(secretKeyBase64URL: source.deviceSecret)!)
                guard let self, !Task.isCancelled, generation == current, connection == source else {
                    try? await session.cancel()
                    return
                }
                self.session = session
                verificationCode = session.verificationCode
                status = String(localized: "等待后端批准，请核对随机码。")
                let expiry = session.expiresAt
                startExpiryClock(expiresAt: expiry, generation: current)
                render()
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(session.pollIntervalMilliseconds))
                    let result = try await session.poll()
                    try Task.checkCancellation()
                    guard generation == current, connection == source else {
                        try? await session.cancel()
                        return
                    }
                    guard Date().timeIntervalSince1970 * 1_000 < expiry else {
                        finishDevice(String(localized: "申请已过期，请重新申请。"), cancel: true)
                        return
                    }
                    switch result {
                    case .pending: continue
                    case .approved:
                        // The device key was already persisted before the
                        // request; approval only activates it on the backend.
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
