import CoreImage.CIFilterBuiltins
import TodexCore
import UIKit

/// End-to-end encrypted conversation history of the connected backend
/// (history v3, `TodeX_backend/docs/history-encryption.md`): history is always
/// encrypted, so this manages recipients, old-history grants and the recovery
/// key. Everything acts through the live session; private keys never leave
/// this device.
@MainActor
final class HistoryEncryptionViewController: SettingsListController {
    private let session: AppSession
    private var observer: UUID?
    private var loadError: String?
    private var loading = true
    private var busy = false
    /// Running grant/import progress, shown under its section.
    private var progress: String?
    /// Opened from the home screen's "set up now": start creating the
    /// recovery key once the state is known to lack one.
    private var setUpRecovery: Bool

    init(session: AppSession, setUpRecovery: Bool = false) {
        self.session = session
        self.setUpRecovery = setUpRecovery
        super.init(title: String(localized: "会话历史加密"))
    }

    isolated deinit { if let observer { session.removeObserver(observer) } }

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = session.observe { [weak self] in self?.render() }
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        loading = true
        render()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await session.refreshHistoryEncryption()
                loadError = nil
            } catch {
                loadError = SettingsResponse.errorMessage(error, feature: String(localized: "会话历史加密"))
            }
            loading = false
            render()
            // Only the first load acts on "set up now"; later reloads never
            // reopen the flow.
            if setUpRecovery {
                setUpRecovery = false
                if session.historyRecoveryMissing, presentedViewController == nil { beginReplaceRecovery(hasCurrent: false) }
            }
        }
    }

    /// Runs one change and reports failures; rows are disabled meanwhile.
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        render()
        Task { [weak self] in
            do { try await work() } catch {
                if !(error is CancellationError) { self?.showError(error) }
            }
            self?.busy = false
            self?.progress = nil
            self?.render()
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        guard let state = session.historyEncryption else {
            sections = [
                SettingsSection(
                    title: String(localized: "会话历史加密"),
                    rows: [
                        loading
                            ? SettingsRow(title: String(localized: "正在读取…"), id: "history.loading", activity: true)
                            : SettingsRow(
                                title: String(localized: "读取失败"),
                                detail: loadError ?? String(localized: "请先连接此后端"),
                                symbol: "exclamationmark.triangle", id: "history.error", color: .systemRed),
                        SettingsRow(title: String(localized: "重试"), symbol: "arrow.clockwise", id: "history.retry", color: Theme.accent) {
                            [weak self] in self?.reload()
                        },
                    ])
            ]
            redraw()
            return
        }
        let mine = session.historyDeviceRecipientID
        let revoked = session.historyAccessRevoked
        let registered = mine != nil && state.myRid == mine && !revoked
        sections = revoked ? [revokedNotice()] : []
        sections += [
            SettingsSection(
                title: String(localized: "会话历史加密"),
                footer: String(localized: "会话内容在后端磁盘上始终只以密文保存，只有已授权的设备能解密；后端运行 Agent 时仍能看到明文。旧版未加密的对话保持原样，只能查看、导出、归档或删除。"),
                rows: [
                    SettingsRow(
                        title: String(localized: "端到端加密"),
                        detail: String(localized: "始终开启 · 密钥纪元 \(state.epoch)"),
                        symbol: "lock.shield", id: "history.mode"),
                    SettingsRow(
                        title: String(localized: "本机历史密钥"),
                        detail: revoked
                            ? String(localized: "已吊销")
                            : registered
                                ? String(localized: "已登记 · \(Self.short(mine ?? ""))")
                                : String(localized: "未登记。完成设备配对后会自动登记。"),
                        symbol: "iphone.gen3", id: "history.device",
                        color: revoked ? .systemRed : registered ? .label : .systemOrange),
                    SettingsRow(
                        title: String(localized: "申请读取旧历史"),
                        detail: String(localized: "请已授权的设备批准，本机才能读取登记之前的历史"),
                        symbol: "hand.raised", id: "history.request", color: Theme.accent, enabled: !busy && registered
                    ) { [weak self] in
                        self?.perform {
                            try await self?.session.requestHistoryGrant()
                            self?.showNotice(
                                title: String(localized: "已发送申请"),
                                message: String(localized: "请在一台已授权的设备上打开“会话历史加密”并批准。"))
                        }
                    },
                ]),
            grantSection(state, revoked: revoked),
            recipientSection(state, mine: mine, revoked: revoked),
        ]
        if !state.revokedDevices.isEmpty { sections.append(revokedDeviceSection(state, revoked: revoked)) }
        sections.append(recoverySection(state, revoked: revoked))
        redraw()
    }

    /// Shown while this device is blocked: every history action is disabled
    /// until another authorized device restores it.
    private func revokedNotice() -> SettingsSection {
        SettingsSection(
            title: String(localized: "访问已吊销"),
            footer: String(localized: "在另一台已授权设备的“会话历史加密”中恢复本机后，本机会自动登记新的历史密钥；之后需重新申请读取旧历史。"),
            rows: [
                SettingsRow(
                    title: TodexError.server(code: HistoryEncryption.accessRevoked, message: "").localizedDescription,
                    symbol: "lock.slash", id: "history.revoked", color: .systemRed)
            ])
    }

    private func revokedDeviceSection(_ state: HistoryEncryptionState, revoked: Bool) -> SettingsSection {
        let me = session.historyDeviceID
        let rows = state.revokedDevices.map { device in
            SettingsRow(
                title: device.deviceId + (device.deviceId == me ? String(localized: "（本机）") : ""),
                detail: [
                    device.revokedAt.map { String(localized: "吊销于 \($0)") },
                    device.deviceId == me ? nil : String(localized: "恢复访问"),
                ].compactMap { $0 }.joined(separator: " · "),
                symbol: "lock.slash", id: "history.revokedDevice.\(device.deviceId)",
                color: .secondaryLabel, enabled: !busy && !revoked && device.deviceId != me
            ) { [weak self] in self?.confirmRestore(device) }
        }
        return SettingsSection(
            title: String(localized: "已吊销的设备"),
            footer: String(localized: "被吊销的设备无法再访问加密历史，直到在此恢复访问。恢复后它会登记新的历史密钥，旧历史需重新授权。"),
            rows: rows)
    }

    private func grantSection(_ state: HistoryEncryptionState, revoked: Bool) -> SettingsSection {
        let pending = state.grants.filter(\.isPending)
        var rows = pending.map { grant in
            SettingsRow(
                title: grant.deviceId ?? Self.short(grant.rid),
                detail: String(localized: "申请于 \(grant.requestedAt ?? String(localized: "未知"))"),
                symbol: "person.badge.key", id: "history.grant.\(grant.grantId)", enabled: !busy && !revoked
            ) { [weak self] in self?.chooseGrant(grant) }
        }
        if let progress { rows.append(SettingsRow(title: progress, id: "history.progress", activity: true)) }
        if rows.isEmpty {
            rows = [SettingsRow(title: String(localized: "没有待处理的申请"), id: "history.grants.empty", color: .secondaryLabel)]
        }
        return SettingsSection(
            title: String(localized: "待授权请求"),
            footer: String(localized: "批准后，本机会在本地解开它能读取的历史密钥，再为对方重新加密后上传；后端看不到这些密钥。中断后再次批准会从上次进度继续。"),
            rows: rows)
    }

    private func recipientSection(_ state: HistoryEncryptionState, mine: String?, revoked: Bool) -> SettingsSection {
        let rows = state.recipients.map { recipient in
            let name =
                recipient.isRecovery
                ? String(localized: "恢复密钥")
                : (recipient.deviceId ?? Self.short(recipient.rid)) + (recipient.rid == mine ? String(localized: "（本机）") : "")
            return SettingsRow(
                title: name,
                detail: [
                    Self.short(recipient.rid), recipient.addedAt.map { String(localized: "添加于 \($0)") },
                    recipient.isRevoked ? String(localized: "已吊销") : nil,
                ].compactMap { $0 }.joined(separator: " · "),
                symbol: recipient.isRecovery ? "key" : "desktopcomputer", id: "history.recipient.\(recipient.rid)",
                color: recipient.isRevoked ? .secondaryLabel : .label, enabled: !busy && !revoked && !recipient.isRevoked
            ) { [weak self] in self?.confirmRevoke(recipient, isSelf: recipient.rid == mine) }
        }
        return SettingsSection(
            title: String(localized: "可解密的设备与密钥"),
            footer: String(localized: "吊销后，之后生成的历史密钥不再为它加密，设备会被永久禁止访问加密历史，直到另一台已授权设备恢复它；它已取得的旧密钥无法收回。"),
            rows: rows.isEmpty
                ? [SettingsRow(title: String(localized: "暂无"), id: "history.recipients.empty", color: .secondaryLabel)] : rows)
    }

    private func recoverySection(_ state: HistoryEncryptionState, revoked: Bool) -> SettingsSection {
        var rows: [SettingsRow] = []
        if state.activeRecovery == nil {
            rows.append(
                SettingsRow(
                    title: String(localized: "尚未设置恢复密钥"),
                    detail: String(localized: "所有已授权的设备丢失或重置后，加密历史将永久无法读取"),
                    symbol: "exclamationmark.triangle", id: "history.recovery.missing", color: .systemOrange))
        }
        rows += [
            SettingsRow(
                title: state.activeRecovery == nil ? String(localized: "立即设置恢复密钥") : String(localized: "更换恢复密钥"),
                symbol: state.activeRecovery == nil ? "key" : "arrow.triangle.2.circlepath", id: "history.recovery.replace",
                color: state.activeRecovery == nil ? Theme.accent : .label, enabled: !busy && !revoked
            ) { [weak self] in self?.beginReplaceRecovery(hasCurrent: state.activeRecovery != nil) },
            SettingsRow(
                title: String(localized: "导入恢复密钥"),
                detail: String(localized: "输入 24 个单词或扫描恢复二维码，让本机读取全部历史"),
                symbol: "square.and.arrow.down", id: "history.recovery.import", color: Theme.accent,
                enabled: !busy && !revoked && state.activeRecovery != nil
            ) { [weak self] in self?.chooseImport() },
        ]
        return SettingsSection(
            title: String(localized: "恢复密钥"),
            footer: String(localized: "恢复密钥只在创建时显示一次，后端只保存它的公钥。"),
            rows: rows)
    }

    // MARK: Flows

    /// Creates or replaces the recovery key: it is shown once, and only its
    /// public half is uploaded after the user confirms they saved it.
    private func beginReplaceRecovery(hasCurrent: Bool) {
        let replace: @MainActor () -> Void = { [weak self] in
            self?.showRecoveryKey { seed in
                self?.perform { try await self?.session.setRecoveryKey(seed: seed) }
            }
        }
        guard hasCurrent else {
            replace()
            return
        }
        confirm(
            title: String(localized: "更换恢复密钥？"),
            message: String(localized: "旧恢复密钥从此不再获得新的历史密钥。"), destructive: true, action: replace)
    }

    /// Shows a fresh recovery key; `completion` receives its seed once the
    /// user confirms they saved it. Cancelling uploads nothing.
    private func showRecoveryKey(completion: @escaping @MainActor (Data) -> Void) {
        let seed = HistoryRecoveryKey.generateSeed()
        let controller: RecoveryKeyViewController
        do {
            controller = try RecoveryKeyViewController(seed: seed) { [weak self] in
                self?.dismiss(animated: true) { completion(seed) }
            }
        } catch {
            showError(error)
            return
        }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.isModalInPresentation = true
        present(navigation, animated: true)
    }

    private func confirmRevoke(_ recipient: HistoryRecipient, isSelf: Bool) {
        confirm(
            title: String(localized: "吊销此接收方？"),
            message: recipient.isRecovery
                ? String(localized: "吊销后它无法读取之后的新历史。")
                : isSelf
                    ? String(localized: "这是本机。吊销是永久的：本机将无法读取任何加密历史，也不能重新登记，直到另一台已授权设备恢复它。")
                    : String(localized: "吊销是永久的：该设备将无法读取任何加密历史，也不能重新登记，直到已授权设备在“已吊销的设备”中恢复它。恢复后它需重新申请读取旧历史。"),
            destructive: true
        ) { [weak self] in
            self?.perform { try await self?.session.revokeHistoryRecipient(recipient.rid) }
        }
    }

    private func confirmRestore(_ device: HistoryRevokedDevice) {
        confirm(
            title: String(localized: "恢复此设备的访问？"),
            message: String(localized: "恢复后该设备会登记新的历史密钥，可以读取之后的新历史；旧历史仍需它重新申请并由已授权设备批准。请确认这是你自己的设备。")
        ) { [weak self] in
            self?.perform { try await self?.session.restoreHistoryDevice(device.deviceId) }
        }
    }

    private func chooseGrant(_ grant: HistoryGrantRequest) {
        let sheet = UIAlertController(
            title: grant.deviceId ?? Self.short(grant.rid),
            message: String(localized: "批准后，该设备可以读取本机能读取的全部历史。请确认这是你自己的设备。"),
            preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: String(localized: "批准"), style: .default) { [weak self] _ in self?.authorize(grant) })
        sheet.addAction(
            UIAlertAction(title: String(localized: "忽略申请"), style: .destructive) { [weak self] _ in
                self?.perform { try await self?.session.dismissHistoryGrant(grant.grantId) }
            })
        sheet.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        anchor(sheet)
        present(sheet, animated: true)
    }

    private func authorize(_ grant: HistoryGrantRequest) {
        progress = String(localized: "正在授权…")
        perform { [weak self] in
            guard let self else { return }
            let result = try await session.authorizeHistoryGrant(grant) { [weak self] value in
                self?.progress = String(localized: "已上传 \(value.processed) 个密钥，跳过 \(value.skipped) 个")
                self?.render()
            }
            showNotice(
                title: String(localized: "授权完成"),
                message: String(localized: "已为该设备重新加密 \(result.processed) 个历史密钥；本机无法读取的 \(result.skipped) 个已跳过。"))
        }
    }

    private func chooseImport() {
        let sheet = UIAlertController(title: String(localized: "导入恢复密钥"), message: nil, preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: String(localized: "输入单词或粘贴文本"), style: .default) { [weak self] _ in
                guard let self else { return }
                let editor = SettingsTextController(
                    title: String(localized: "导入恢复密钥"), text: "",
                    detail: String(localized: "输入 24 个单词（以空格分隔），或粘贴恢复二维码中的 todex-recovery: 文本。"),
                    editable: true, actionTitle: String(localized: "导入")
                ) { [weak self] text in
                    guard let self else { return }
                    try await importRecovery(HistoryRecoveryKey.seed(parsing: text))
                }
                navigationController?.pushViewController(editor, animated: true)
            })
        sheet.addAction(
            UIAlertAction(title: String(localized: "扫描二维码"), style: .default) { [weak self] _ in self?.scanRecovery() })
        sheet.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        anchor(sheet)
        present(sheet, animated: true)
    }

    private func scanRecovery() {
        let scanner = PairingQRScannerViewController { [weak self] text in
            let seed = try HistoryRecoveryKey.seed(qrString: text)
            self?.perform { try await self?.importRecovery(seed) }
            return String(localized: "已读取恢复密钥")
        }
        scanner.title = String(localized: "扫描恢复二维码")
        present(UINavigationController(rootViewController: scanner), animated: true)
    }

    private func importRecovery(_ seed: Data) async throws {
        progress = String(localized: "正在导入恢复密钥…")
        render()
        let result = try await session.importRecoveryKey(seed) { [weak self] value in
            self?.progress = String(localized: "已取得 \(value.processed) 个密钥")
            self?.render()
        }
        progress = nil
        render()
        showNotice(
            title: String(localized: "导入完成"),
            message: String(localized: "本机已取得 \(result.processed) 个历史密钥，加密历史会重新载入。"))
    }

    private func anchor(_ sheet: UIAlertController) {
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.safeAreaInsets.top + 22, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
    }

    private static func short(_ rid: String) -> String { rid.count > 10 ? String(rid.prefix(10)) + "…" : rid }
}

/// Shows a recovery key once: 24 numbered words and the QR code. The user
/// confirms they saved it, or cancels.
@MainActor
final class RecoveryKeyViewController: UIViewController {
    private let words: [String]
    private let qrText: String
    private let onSaved: @MainActor () -> Void

    init(seed: Data, onSaved: @escaping @MainActor () -> Void) throws {
        words = try HistoryRecoveryKey.words(seed: seed)
        qrText = try HistoryRecoveryKey.qrString(seed: seed)
        self.onSaved = onSaved
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "恢复密钥")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(seed:onSaved:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        let note = UILabel()
        note.text = String(localized: "请按顺序抄写这 24 个单词，或保存下方二维码，并离线妥善保管。任何拿到它的人都能读取你的全部加密历史；它只显示这一次。")
        note.numberOfLines = 0
        note.font = .preferredFont(forTextStyle: .callout)
        note.adjustsFontForContentSizeCategory = true
        note.textColor = .secondaryLabel

        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 8
        for row in stride(from: 0, to: words.count, by: 3) {
            let line = UIStackView()
            line.axis = .horizontal
            line.distribution = .fillEqually
            line.spacing = 8
            for index in row..<min(row + 3, words.count) {
                let label = UILabel()
                label.text = "\(index + 1). \(words[index])"
                label.font = UIFontMetrics(forTextStyle: .body).scaledFont(
                    for: .monospacedSystemFont(ofSize: 16, weight: .medium))
                label.adjustsFontForContentSizeCategory = true
                label.adjustsFontSizeToFitWidth = true
                label.minimumScaleFactor = 0.6
                line.addArrangedSubview(label)
            }
            grid.addArrangedSubview(line)
        }
        grid.isAccessibilityElement = true
        grid.accessibilityLabel = words.enumerated().map { "\($0.offset + 1) \($0.element)" }.joined(separator: ", ")
        grid.accessibilityIdentifier = "history.recovery.words"

        let qr = UIImageView(image: Self.qrImage(qrText))
        qr.contentMode = .scaleAspectFit
        qr.layer.magnificationFilter = .nearest
        qr.backgroundColor = .white
        qr.isAccessibilityElement = true
        qr.accessibilityLabel = String(localized: "恢复密钥二维码")
        qr.heightAnchor.constraint(equalToConstant: 220).isActive = true

        var saved = UIButton.Configuration.filled()
        saved.title = String(localized: "我已妥善保存")
        saved.baseBackgroundColor = Theme.accent
        let savedButton = UIButton(configuration: saved, primaryAction: UIAction { [weak self] _ in self?.onSaved() })
        savedButton.accessibilityIdentifier = "history.recovery.saved"

        let stack = UIStackView(arrangedSubviews: [note, grid, qr, savedButton])
        stack.axis = .vertical
        stack.spacing = 20
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        let scroll = UIScrollView()
        view.addSubview(scroll)
        scroll.pinEdges(to: view)
        scroll.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
    }

    private static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
            let image = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: image)
    }
}
