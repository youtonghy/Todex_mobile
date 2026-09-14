import TodexCore
import UIKit

@MainActor
final class SettingsViewController: SettingsListController {
    private var connections: [BackendConnection]
    private var selectedID: String?
    private let session: AppSession?
    private let onSave: @MainActor ([BackendConnection], String?) -> Void
    private let onConnect: @MainActor (BackendConnection) -> Void
    private var connectionNotice = ""

    init(
        connections: [BackendConnection], selectedID: String?, session: AppSession? = nil,
        onSave: @escaping @MainActor ([BackendConnection], String?) -> Void,
        onConnect: @escaping @MainActor (BackendConnection) -> Void
    ) {
        self.session = session
        self.connections = connections
        self.selectedID = connections.contains(where: { $0.id == selectedID }) ? selectedID : connections.first?.id
        self.onSave = onSave
        self.onConnect = onConnect
        super.init(title: "设置")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                persist()
                if presentingViewController != nil || navigationController?.presentingViewController != nil {
                    dismiss(animated: true)
                } else {
                    navigationController?.popViewController(animated: true)
                }
            })
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "settings.done"
        render()
    }

    private var selected: BackendConnection? { connections.first { $0.id == selectedID } }
    private func persist() { onSave(connections, selectedID) }

    private func update(_ id: String, change: (inout BackendConnection) -> Void) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        change(&connections[index])
        connectionNotice = ""
        persist()
        render()
    }

    private func render() {
        var backends = connections.map { connection in
            SettingsRow(
                title: connection.name.isEmpty ? "未命名后端" : connection.name,
                detail: connection.serverURL.isEmpty
                    ? "请填写后端地址"
                    : connection.tenantId.isEmpty
                        ? connection.serverURL : "\(connection.serverURL) · \(connection.tenantId)",
                symbol: "circle.fill", id: "settings.backend.\(connection.id)",
                color: Self.labelColor(connection.color), checked: connection.id == selectedID
            ) { [weak self] in
                self?.selectedID = connection.id
                self?.connectionNotice = ""
                self?.persist()
                self?.render()
            }
        }
        backends.append(
            SettingsRow(title: "添加后端", symbol: "plus", id: "settings.backend.add", color: Theme.accent) { [weak self] in
                guard let self else { return }
                let connection = BackendConnection(name: "新后端", serverURL: "")
                connections.append(connection)
                selectedID = connection.id
                persist()
                render()
                edit(connection, field: "serverURL")
            })
        sections = [SettingsSection(title: "后端连接", footer: "选择后端后可编辑配置；更改自动保存。", rows: backends)]
        if let connection = selected {
            var rows: [SettingsRow] = [
                field("名称", value: connection.name, key: "name", connection: connection),
                SettingsRow(
                    title: "标签颜色", detail: Self.colors.first { $0.0 == connection.color }?.1 ?? connection.color,
                    symbol: "circle.fill", id: "settings.backend.color", color: Self.labelColor(connection.color)
                ) { [weak self] in
                    self?.choose(title: "标签颜色", choices: Self.colors, selected: connection.color) { [weak self] color in
                        self?.update(connection.id) { $0.color = color }
                    }
                },
                field("后端地址", value: connection.serverURL, key: "serverURL", connection: connection),
                SettingsRow(
                    title: "本机设备",
                    detail: DeviceIdentity(secretKeyBase64URL: connection.deviceSecret)?.deviceID ?? "未验证",
                    symbol: "iphone.gen3", id: "settings.backend.device"),
                field("Tenant", value: connection.tenantId, key: "tenantId", connection: connection),
                SettingsRow(title: "传输加密", detail: connection.encryption.rawValue, id: "settings.backend.encryption") {
                    [weak self] in
                    self?.choose(
                        title: "传输加密", choices: EncryptionProtocol.allCases.map { ($0.rawValue, $0.rawValue) },
                        selected: connection.encryption.rawValue
                    ) { [weak self] value in
                        guard let encryption = EncryptionProtocol(rawValue: value) else { return }
                        self?.update(connection.id) { $0.encryption = encryption }
                    }
                },
            ]
            if connection.encryption != .none {
                rows.append(
                    field(
                        "加密公钥", value: connection.publicKey.isEmpty ? "未设置" : "已设置 · 点按编辑", key: "publicKey",
                        connection: connection))
            }
            rows.append(
                SettingsRow(title: "配对与设备验证", detail: "JSON、二维码图片、相机扫码与分片二维码", symbol: "qrcode", id: "settings.pairing")
                { [weak self] in
                    self?.openPairing(connection)
                })
            rows.append(
                SettingsRow(
                    title: "保存并连接", detail: connectionNotice, symbol: "network", id: "settings.backend.connect",
                    color: Theme.accent
                ) { [weak self] in self?.connect(connection.id) })
            rows.append(
                SettingsRow(title: "CLI 管理", detail: "读取此后端的 CLI 版本与升级进度", symbol: "terminal", id: "settings.cli") {
                    [weak self] in
                    self?.navigationController?.pushViewController(
                        CLIViewController(connection: connection), animated: true)
                })
            rows.append(
                SettingsRow(
                    title: "使用统计", detail: "所有已同步对话的 token 用量汇总", symbol: "chart.bar",
                    id: "settings.usage"
                ) { [weak self] in
                    guard let self, let session = self.session else { return }
                    let records = session.runtimes.values.flatMap(\.usageRecords)
                    self.navigationController?.pushViewController(
                        UsageViewController(records: records), animated: true)
                })
            rows.append(
                SettingsRow(title: "关于", detail: "应用与后端版本", symbol: "info.circle", id: "settings.about") {
                    [weak self] in
                    guard let self else { return }
                    self.navigationController?.pushViewController(
                        AboutViewController(session: self.session, connection: connection), animated: true)
                })
            rows.append(
                SettingsRow(title: "删除此后端", symbol: "trash", id: "settings.backend.delete", color: .systemRed) {
                    [weak self] in
                    self?.confirm(title: "删除后端？", message: "移除本机保存的“\(connection.name)”连接配置。", destructive: true) {
                        [weak self] in
                        guard let self else { return }
                        connections.removeAll { $0.id == connection.id }
                        if selectedID == connection.id { selectedID = connections.first?.id }
                        persist()
                        render()
                    }
                })
            sections.append(
                SettingsSection(title: "当前后端", footer: "Token 由主程序通过 Keychain 保存。传输加密启用时，连接还需要对应的公钥。", rows: rows))
        }
        let appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system"
        let sharing = UserDefaults.standard.string(forKey: "workbenchSharing") ?? "conversation"
        sections.append(
            SettingsSection(
                title: "显示与工作台",
                rows: [
                    SettingsRow(
                        title: "外观", detail: ["system": "跟随系统", "light": "浅色", "dark": "深色"][appearance] ?? "跟随系统",
                        symbol: "circle.lefthalf.filled", id: "settings.appearance"
                    ) { [weak self] in
                        self?.choose(
                            title: "外观", choices: [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")],
                            selected: appearance
                        ) { [weak self] value in
                            UserDefaults.standard.set(value, forKey: "appearance")
                            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                                for window in scene.windows { Theme.applyAppearance(to: window) }
                            }
                            self?.render()
                        }
                    },
                    SettingsRow(
                        title: "工作台共享方式", detail: sharing == "workspace" ? "同一工作区共享终端、浏览器和文件标签" : "每个对话独立保存工作台",
                        symbol: "rectangle.3.group", id: "settings.workbenchSharing"
                    ) { [weak self] in
                        self?.choose(
                            title: "工作台共享方式", choices: [("conversation", "每个对话独立"), ("workspace", "同一工作区共享")],
                            selected: sharing
                        ) { [weak self] value in
                            UserDefaults.standard.set(value, forKey: "workbenchSharing")
                            NotificationCenter.default.post(
                                name: Notification.Name("Todex.workbenchSharingChanged"), object: nil)
                            self?.render()
                        }
                    },
                ]))
        let notificationsEnabled = CompletionNotifications.isEnabled()
        sections.append(
            SettingsSection(
                title: "通知",
                footer: "任务正常完成并收到回复时发送系统通知；应用在前台时不提醒。",
                rows: [
                    SettingsRow(
                        title: "任务完成提醒", detail: notificationsEnabled ? "已开启" : "已关闭",
                        symbol: "bell.badge", id: "settings.completionNotifications",
                        checked: notificationsEnabled
                    ) { [weak self] in
                        self?.setCompletionNotifications(!notificationsEnabled)
                    },
                ]))
        redraw()
    }

    private func setCompletionNotifications(_ enabled: Bool) {
        if !enabled {
            UserDefaults.standard.set(false, forKey: CompletionNotifications.defaultsKey)
            render()
            return
        }
        Task { [weak self] in
            let granted = await CompletionNotifications.requestAuthorization()
            guard let self else { return }
            UserDefaults.standard.set(granted, forKey: CompletionNotifications.defaultsKey)
            self.render()
            if !granted { self.promptNotificationSettings() }
        }
    }

    private func promptNotificationSettings() {
        let alert = UIAlertController(
            title: "通知权限未开启",
            message: "系统拒绝了 TodeX 的通知权限。请在系统设置中允许通知后再开启。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "打开系统设置", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        present(alert, animated: true)
    }

    private func field(_ title: String, value: String, key: String, connection: BackendConnection) -> SettingsRow {
        SettingsRow(title: title, detail: value.isEmpty ? "未填写" : value, id: "settings.backend.\(key)") { [weak self] in
            self?.edit(connection, field: key)
        }
    }

    private func edit(_ connection: BackendConnection, field: String) {
        if field == "publicKey" {
            let editor = SettingsTextController(
                title: "加密公钥", text: connection.publicKey, editable: true, actionTitle: "保存"
            ) { [weak self] text in
                self?.update(connection.id) { $0.publicKey = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                self?.navigationController?.popViewController(animated: true)
            }
            navigationController?.pushViewController(editor, animated: true)
            return
        }
        let value =
            switch field {
            case "name": connection.name
            case "tenantId": connection.tenantId
            default: connection.serverURL
            }
        let title =
            switch field {
            case "name": "名称"
            case "tenantId": "Tenant"
            default: "后端地址"
            }
        editField(
            title: title, value: value, id: "settings.backend.\(field).input", secure: false,
            keyboard: field == "serverURL" ? .URL : .default
        ) { [weak self] text in
            self?.update(connection.id) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                switch field {
                case "name": $0.name = trimmed
                case "tenantId": $0.tenantId = trimmed.isEmpty ? "local" : trimmed
                default:
                    $0.serverURL = trimmed
                    if (try? BackendConnection.normalize(trimmed)) != (try? BackendConnection.normalize(connection.serverURL)) {
                        $0.deviceSecret = ""
                    }
                }
            }
        }
    }

    private func connect(_ id: String) {
        guard var connection = connections.first(where: { $0.id == id }) else { return }
        do {
            connection.serverURL = try connection.normalizedURL().absoluteString
            if connection.encryption != .none
                && connection.publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                throw TodexError.invalid("请填写加密公钥，或导入后端配对信息")
            }
            update(id) { $0 = connection }
            connectionNotice = "已提交连接请求；连接状态将在工作区显示。"
            render()
            onConnect(connection)
        } catch { showError(error) }
    }

    private func openPairing(_ connection: BackendConnection) {
        var expectedURL = connection.serverURL
        let pairing = PairingViewController(connection: connection) { [weak self] updated in
            guard let self, selectedID == connection.id,
                let current = connections.first(where: { $0.id == connection.id }),
                current.serverURL == expectedURL
            else { throw TodexError.invalid("后端配置已改变，请重新打开配对页面") }
            update(connection.id) { $0 = updated }
            expectedURL = updated.serverURL
        } onApproved: { [weak self] in
            self?.connect(connection.id)
        }
        navigationController?.pushViewController(pairing, animated: true)
    }

    private static let colors = [
        ("#3b82f6", "蓝色"), ("#8b5cf6", "紫色"), ("#ec4899", "粉色"), ("#ef4444", "红色"), ("#f97316", "橙色"),
        ("#eab308", "黄色"), ("#22c55e", "绿色"), ("#06b6d4", "青色"), ("teal", "青绿"),
    ]

    private static func labelColor(_ color: String) -> UIColor {
        guard color.hasPrefix("#"), color.count == 7, let hex = UInt32(color.dropFirst(), radix: 16) else {
            return Theme.accent
        }
        return UIColor(
            red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
