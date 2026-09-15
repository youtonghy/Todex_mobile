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
        super.init(title: "关于")
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
        var rows: [SettingsRow] = [
            info("应用版本", appVersion.isEmpty ? "未知" : appVersion),
            info("后端", backendName.isEmpty ? "未加载" : backendName),
            info("后端地址", connection?.serverURL ?? "未配置"),
        ]
        if let backendVersion = backendInfo?["version"].optionalString {
            let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            rows.append(
                info(
                    "版本检查",
                    VersionCheck.mismatch(app: app, backend: backendVersion)
                        ? "应用 \(app ?? "未知") 与后端 \(backendVersion) 不一致，请升级" : "一致"))
        }
        if let tenant = connection?.tenantId, !tenant.isEmpty {
            rows.append(info("Tenant", tenant))
        }
        if let backend = backendInfo {
            rows.append(info("数据目录", backend["data_dir"].optionalString ?? "未知"))
            let workspaceRoots = backend["workspace_roots"].arrayValue
                .map(\.stringValue).filter { !$0.isEmpty }
            rows.append(info(
                "工作区根目录",
                workspaceRoots.isEmpty
                    ? (backend["workspace_root"].optionalString ?? "未知")
                    : workspaceRoots.joined(separator: "\n")))
        }
        sections = [
            SettingsSection(title: "TodeX", footer: "iPhone 与 iPad 原生客户端。", rows: rows),
            SettingsSection(
                title: "项目",
                rows: [
                    SettingsRow(title: "项目地址", detail: Self.projectURL, symbol: "link", id: "about.project") {
                        UIPasteboard.general.string = Self.projectURL
                        UIAccessibility.post(notification: .announcement, argument: "已复制")
                    }
                ]),
        ]
        redraw()
    }

    private func info(_ label: String, _ value: String) -> SettingsRow {
        SettingsRow(title: label, detail: value, id: "about.\(label)", enabled: !value.isEmpty) {
            UIPasteboard.general.string = value
            UIAccessibility.post(notification: .announcement, argument: "已复制")
        }
    }
}
