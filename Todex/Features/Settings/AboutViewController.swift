import TodexCore
import UIKit

/// Read-only app/backend facts with tap-to-copy rows, mirroring the desktop About panel.
@MainActor
final class AboutViewController: SettingsListController {
    private static let projectURL = "https://github.com/youtonghy/Todex_mobile"
    private let session: AppSession?
    private let connection: BackendConnection?
    private var backendInfo: JSONValue?
    private var loadTask: Task<Void, Never>?

    init(session: AppSession?, connection: BackendConnection?) {
        self.session = session
        self.connection = connection
        super.init(title: String(localized: "关于"))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
        loadBackendVersion()
    }

    isolated deinit { loadTask?.cancel() }

    private func loadBackendVersion() {
        guard let api = session?.api, backendInfo == nil, loadTask == nil else { return }
        loadTask = Task { [weak self] in
            defer { self?.loadTask = nil }
            let value = try? await api.version()
            guard let self, !Task.isCancelled else { return }
            backendInfo = value
            render()
        }
    }

    private func render() {
        let appVersion = [
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).map { "(\($0))" },
        ].compactMap { $0 }.joined(separator: " ")
        let backendName = [
            backendInfo?["name"].optionalString, backendInfo?["version"].optionalString,
        ].compactMap { $0 }.joined(separator: " ")
        // Desktop AboutPanel: connection state and the active workspace. The
        // status belongs to the session's backend, which may differ from the
        // one being viewed in Settings.
        let sessionBackend = session?.connection?.id == connection?.id
        let status =
            sessionBackend
            ? (session?.status ?? String(localized: "尚未连接")) : String(localized: "未连接（当前会话使用其他后端）")
        var rows: [SettingsRow] = [
            info(String(localized: "应用版本"), appVersion.isEmpty ? String(localized: "未知") : appVersion),
            info(String(localized: "后端"), backendName.isEmpty ? String(localized: "未加载") : backendName),
            info(String(localized: "后端地址"), connection?.serverURL ?? String(localized: "未配置")),
            info(String(localized: "连接状态"), status),
            info(String(localized: "工作区"), sessionBackend ? (session?.activeConversation?.workspace ?? String(localized: "未选择")) : String(localized: "未选择")),
        ]
        if let backendVersion = backendInfo?["version"].optionalString {
            let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            rows.append(
                info(
                    String(localized: "版本检查"),
                    VersionCheck.mismatch(app: app, backend: backendVersion)
                        ? String(localized: "应用 \(app ?? String(localized: "未知")) 与后端 \(backendVersion) 不一致，请升级") : String(localized: "一致")))
        }
        if let tenant = connection?.tenantId, !tenant.isEmpty {
            rows.append(info("Tenant", tenant))
        }
        if let backend = backendInfo {
            rows.append(info(String(localized: "数据目录"), backend["data_dir"].optionalString ?? String(localized: "未知")))
            let workspaceRoots = backend["workspace_roots"].arrayValue
                .map(\.stringValue).filter { !$0.isEmpty }
            rows.append(info(
                String(localized: "工作区根目录"),
                workspaceRoots.isEmpty
                    ? (backend["workspace_root"].optionalString ?? String(localized: "未知"))
                    : workspaceRoots.joined(separator: "\n")))
        }
        sections = [
            SettingsSection(title: "TodeX", footer: String(localized: "iPhone 与 iPad 原生客户端。"), rows: rows),
            SettingsSection(
                title: String(localized: "项目"),
                rows: [
                    SettingsRow(title: String(localized: "项目地址"), detail: Self.projectURL, symbol: "link", id: "about.project") {
                        UIPasteboard.general.string = Self.projectURL
                        UIAccessibility.post(notification: .announcement, argument: String(localized: "已复制"))
                    }
                ]),
        ]
        #if DEBUG
            sections.append(
                SettingsSection(
                    title: String(localized: "调试"),
                    footer: String(localized: "仅调试构建可用。记录连接生命周期，最多保留最近 \(DebugLog.capacity) 条；令牌与密钥在写入前已脱敏。"),
                    rows: [
                        SettingsRow(
                            title: String(localized: "导出调试日志"), symbol: "square.and.arrow.up", id: "about.debugLog.export",
                            color: Theme.accent
                        ) { [weak self] in self?.exportDebugLog() }
                    ]))
        #endif
        redraw()
    }

    #if DEBUG
        private func exportDebugLog() {
            let log = DebugLog.export()
            guard !log.isEmpty else {
                showNotice(title: String(localized: "暂无调试日志"), message: String(localized: "连接后端后会记录连接生命周期事件。"))
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("todex-ios-debug.log")
            do {
                try Data(log.utf8).write(to: url, options: [.atomic, .completeFileProtection])
            } catch {
                showError(error)
                return
            }
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let popover = share.popoverPresentationController {
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
            present(share, animated: true)
        }
    #endif

    private func info(_ label: String, _ value: String) -> SettingsRow {
        SettingsRow(title: label, detail: value, id: "about.\(label)", enabled: !value.isEmpty) {
            UIPasteboard.general.string = value
            UIAccessibility.post(notification: .announcement, argument: String(localized: "已复制"))
        }
    }
}
