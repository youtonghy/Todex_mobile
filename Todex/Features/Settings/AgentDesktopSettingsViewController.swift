import TodexCore
import UIKit

/// Agent desktop tools of one backend (web `AgentDesktopSettings`,
/// `AgentBrowserSettings`, `ComputerUseSettings`). The agent browser and
/// Computer Use both run on the backend's computer; this app only watches
/// them, so everything here is backend state, refreshed while shown.
@MainActor
final class AgentDesktopSettingsViewController: SettingsListController {
    private static let refreshInterval: Duration = .seconds(5)

    private enum Load {
        case loading
        case loaded(AgentDesktopSettings)
        /// The backend predates desktop tools (HTTP 404).
        case unsupported
        case failed(String)
    }

    private let connection: BackendConnection
    private let session: AppSession?
    private let api: APIClient
    private var load = Load.loading
    private var profiles = AgentBrowserProfiles(profiles: [], workspaces: [:])
    private var saving = false
    private var refreshTask: Task<Void, Never>?

    init(connection: BackendConnection, session: AppSession?) {
        self.connection = connection
        self.session = session
        api = APIClient(connection: connection)
        super.init(title: String(localized: "Agent 桌面工具"))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: Self.refreshInterval) } catch { return }
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func refresh() async {
        do {
            let settings = try await api.agentDesktop()
            guard !Task.isCancelled else { return }
            load = .loaded(settings)
            if settings.enabled, settings.browser != nil {
                // Older backends have no profiles route; the list stays empty.
                if let next = try? await api.agentBrowserProfiles(), !Task.isCancelled { profiles = next }
            }
        } catch {
            guard !Task.isCancelled else { return }
            if case TodexError.server(let code, _) = error, code == "404" {
                load = .unsupported
            } else if case .loaded = load {
                // Keep the last state through a transient failure; the next tick retries.
            } else {
                load = .failed(error.localizedDescription)
            }
        }
        render()
    }

    /// Runs one change; its result replaces the shown settings.
    private func change(_ work: @escaping @MainActor () async throws -> AgentDesktopSettings) {
        guard !saving else { return }
        saving = true
        render()
        Task { [weak self] in
            do {
                let settings = try await work()
                self?.load = .loaded(settings)
            } catch {
                self?.showNotice(title: String(localized: "无法保存设置"), message: error.localizedDescription)
            }
            self?.saving = false
            self?.render()
        }
    }

    private func changeProfiles(_ work: @escaping @MainActor () async throws -> AgentBrowserProfiles) {
        guard !saving else { return }
        saving = true
        render()
        Task { [weak self] in
            do {
                let next = try await work()
                self?.profiles = next
            } catch {
                self?.showNotice(title: String(localized: "无法保存设置"), message: error.localizedDescription)
            }
            self?.saving = false
            self?.render()
        }
    }

    private func render() {
        switch load {
        case .loading:
            sections = [
                SettingsSection(
                    title: String(localized: "Agent 桌面工具"),
                    rows: [SettingsRow(title: String(localized: "正在读取…"), id: "agentDesktop.loading", activity: true)])
            ]
        case .unsupported:
            sections = [
                SettingsSection(
                    title: String(localized: "Agent 桌面工具"),
                    rows: [
                        SettingsRow(
                            title: String(localized: "此后端暂不支持 Agent 桌面工具，请先更新后端。"), symbol: "exclamationmark.triangle",
                            id: "agentDesktop.unsupported", color: .secondaryLabel)
                    ])
            ]
        case .failed(let message):
            sections = [
                SettingsSection(
                    title: String(localized: "Agent 桌面工具"),
                    rows: [
                        SettingsRow(
                            title: String(localized: "读取失败"), detail: message, symbol: "exclamationmark.triangle",
                            id: "agentDesktop.error", color: .systemRed),
                        SettingsRow(title: String(localized: "重试"), symbol: "arrow.clockwise", id: "agentDesktop.retry", color: Theme.accent) {
                            [weak self] in Task { await self?.refresh() }
                        },
                    ])
            ]
        case .loaded(let settings):
            sections = [
                SettingsSection(
                    title: String(localized: "Agent 桌面工具"),
                    footer: String(localized: "作用于当前后端：两者都在后端所在的电脑上运行，所有客户端都能实时观看。每个会话首次使用前都会先询问。"),
                    rows: [
                        SettingsRow(
                            title: String(localized: "允许 Agent 使用浏览器和 Computer Use"), symbol: "macwindow.on.rectangle",
                            id: "agentDesktop.enabled", enabled: !saving, switchValue: settings.enabled
                        ) { [weak self, api] enabled in self?.change { try await api.setAgentDesktop(enabled: enabled) } }
                    ])
            ]
            if settings.enabled {
                sections += browserSections(settings)
                sections.append(computerSection(settings))
            }
        }
        redraw()
    }

    // MARK: Agent browser

    private func browserSections(_ settings: AgentDesktopSettings) -> [SettingsSection] {
        guard let status = settings.browser else {
            return [
                SettingsSection(
                    title: String(localized: "Agent 浏览器"),
                    rows: [
                        SettingsRow(
                            title: String(localized: "此后端仍在桌面端运行浏览器，请升级后端后再使用 Agent 浏览器。"),
                            id: "agentBrowser.legacy", color: .secondaryLabel)
                    ])
            ]
        }
        let chromium = status.chromium
        let progress = Int(((chromium.progress ?? 0) * 100).rounded())
        var rows = [
            SettingsRow(
                title: chromium.installed
                    ? String(localized: "Chromium \(chromium.version) 已就绪")
                    : chromium.downloading
                        ? String(localized: "正在下载 Chromium… \(progress)%") : String(localized: "尚未安装 Chromium"),
                detail: chromium.error ?? (chromium.installed ? status.reason ?? "" : ""),
                symbol: chromium.installed ? "checkmark.circle" : "arrow.down.circle", id: "agentBrowser.chromium",
                color: chromium.error != nil ? .systemRed : chromium.installed ? .label : .systemOrange,
                activity: chromium.downloading)
        ]
        if !chromium.installed, !chromium.downloading {
            rows.append(
                SettingsRow(
                    title: String(localized: "下载浏览器组件"), symbol: "arrow.down.to.line", id: "agentBrowser.install",
                    color: Theme.accent, enabled: !saving
                ) { [weak self, api] in self?.change { try await api.installAgentBrowser() } })
        }
        return [
            SettingsSection(
                title: String(localized: "Agent 浏览器"),
                footer: String(localized: "在 \(status.host)（后端所在的电脑）上打开 Chromium 窗口，因此 localhost 指那台电脑。每个工作区使用独立的浏览器资料。"),
                rows: rows),
            profileSection(),
        ]
    }

    private var workspaces: [WorkspaceRecord] {
        // Workspaces belong to the connected backend only.
        guard let session, session.connection?.id == connection.id else { return [] }
        return session.workspaces
    }

    private static func key(_ workspace: WorkspaceRecord) -> String { workspace.id.isEmpty ? workspace.path : workspace.id }

    private func profileSection() -> SettingsSection {
        var rows: [SettingsRow] = workspaces.map { workspace in
            let key = Self.key(workspace)
            let current = profiles.workspaces[key].flatMap { id in profiles.profiles.first { $0.id == id } }
            return SettingsRow(
                title: String(localized: "\(workspace.name) 使用的浏览器资料"),
                detail: current?.name ?? String(localized: "首次使用时创建"), symbol: "folder",
                id: "agentBrowser.workspace.\(workspace.id)", enabled: !saving
            ) { [weak self] in self?.chooseProfile(for: workspace) }
        }
        for profile in profiles.profiles {
            let used = usedBy(profile.id)
            rows.append(
                SettingsRow(
                    title: profile.name, detail: used.isEmpty ? String(localized: "未使用") : used.joined(separator: ", "),
                    symbol: "person.crop.square", id: "agentBrowser.profile.\(profile.id)", enabled: !saving
                ) { [weak self] in self?.manage(profile) })
        }
        if profiles.profiles.isEmpty {
            rows.append(
                SettingsRow(
                    title: String(localized: "还没有浏览器资料；每个工作区首次使用时会自动创建。"), id: "agentBrowser.noProfiles",
                    color: .secondaryLabel))
        }
        return SettingsSection(
            title: String(localized: "浏览器资料"),
            footer: String(localized: "切换后，该工作区已打开的 Agent 标签会关闭，并在新资料中重新打开。"), rows: rows)
    }

    private func usedBy(_ profileID: String) -> [String] {
        profiles.workspaces.filter { $0.value == profileID }.keys.sorted().map { key in
            workspaces.first { $0.id == key || $0.path == key }?.name
                ?? key.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? key
        }
    }

    private func chooseProfile(for workspace: WorkspaceRecord) {
        let key = Self.key(workspace)
        let sheet = UIAlertController(
            title: String(localized: "\(workspace.name) 使用的浏览器资料"),
            message: String(localized: "切换后，该工作区已打开的 Agent 标签会关闭，并在新资料中重新打开。"), preferredStyle: .actionSheet)
        for profile in profiles.profiles {
            let selected = profiles.workspaces[key] == profile.id
            sheet.addAction(
                UIAlertAction(title: selected ? "✓ \(profile.name)" : profile.name, style: .default) { [weak self, api] _ in
                    guard !selected else { return }
                    self?.changeProfiles { try await api.assignAgentBrowserProfile(workspace: key, profileId: profile.id) }
                })
        }
        let name = String(localized: "资料 \(profiles.profiles.count + 1)")
        sheet.addAction(
            UIAlertAction(title: String(localized: "新建资料"), style: .default) { [weak self, api] _ in
                self?.changeProfiles {
                    let created = try await api.createAgentBrowserProfile(name: name)
                    return try await api.assignAgentBrowserProfile(workspace: key, profileId: created.id)
                }
            })
        sheet.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        presentSheet(sheet, row: "agentBrowser.workspace.\(workspace.id)")
    }

    private func manage(_ profile: AgentBrowserProfile) {
        let sheet = UIAlertController(title: profile.name, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: String(localized: "重命名资料"), style: .default) { [weak self, api] _ in
                self?.editField(title: String(localized: "重命名资料"), value: profile.name, id: "agentBrowser.profile.name") {
                    [weak self, api] name in
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed != profile.name else { return }
                    self?.changeProfiles { try await api.renameAgentBrowserProfile(id: profile.id, name: trimmed) }
                }
            })
        sheet.addAction(
            UIAlertAction(title: String(localized: "删除资料"), style: .destructive) { [weak self, api] _ in
                self?.confirm(
                    title: String(localized: "删除资料"),
                    message: String(localized: "删除“\(profile.name)”及其 Cookie、存储和缓存？"), destructive: true
                ) { [weak self, api] in
                    self?.changeProfiles { try await api.deleteAgentBrowserProfile(id: profile.id) }
                }
            })
        sheet.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        presentSheet(sheet, row: "agentBrowser.profile.\(profile.id)")
    }

    private func presentSheet(_ sheet: UIAlertController, row id: String) {
        if let popover = sheet.popoverPresentationController {
            let cell = tableView.visibleCells.first { $0.accessibilityIdentifier == id }
            popover.sourceView = cell ?? view
            popover.sourceRect = cell?.bounds ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    // MARK: Computer Use

    private func computerSection(_ settings: AgentDesktopSettings) -> SettingsSection {
        guard let status = settings.computer else {
            return SettingsSection(
                title: "Computer Use",
                rows: [
                    SettingsRow(
                        title: String(localized: "此后端仍在桌面端执行 Computer Use，请升级后端后再使用。"), id: "computerUse.legacy",
                        color: .secondaryLabel)
                ])
        }
        let missing = !status.permissions.screen || !status.permissions.accessibility
        var rows = [
            SettingsRow(
                title: String(localized: "允许 Agent 控制 \(status.host)"),
                detail: String(localized: "即当前后端所在的电脑。每个会话需先由那台电脑前的人确认；每个新应用和每次密码框输入都会再次询问。TodeX、系统设置、凭据存储和密码管理器永远不会被操作。"),
                symbol: "desktopcomputer", id: "computerUse.enabled", enabled: !saving && status.supported,
                switchValue: settings.computerEnabled
            ) { [weak self, api] enabled in self?.change { try await api.setAgentDesktop(computerEnabled: enabled) } }
        ]
        if status.supported {
            rows.append(
                SettingsRow(
                    title: status.permissions.screen ? String(localized: "已授予屏幕录制") : String(localized: "需要屏幕录制权限"),
                    symbol: status.permissions.screen ? "checkmark.circle" : "exclamationmark.triangle",
                    id: "computerUse.screen", color: status.permissions.screen ? .systemGreen : .systemOrange))
            rows.append(
                SettingsRow(
                    title: status.permissions.accessibility ? String(localized: "已授予辅助功能") : String(localized: "需要辅助功能权限"),
                    symbol: status.permissions.accessibility ? "checkmark.circle" : "exclamationmark.triangle",
                    id: "computerUse.accessibility", color: status.permissions.accessibility ? .systemGreen : .systemOrange))
            if missing {
                rows.append(
                    SettingsRow(
                        title: String(localized: "请求授权"), symbol: "lock.open", id: "computerUse.grant", color: Theme.accent,
                        enabled: !saving
                    ) { [weak self, api] in self?.change { try await api.requestComputerPermissions() } })
            }
        }
        let footer =
            missing && status.supported
            ? String(localized: "系统授权提示会出现在 \(status.host) 上，请在那里为 todex-agentd 授权。") : status.reason
        return SettingsSection(title: "Computer Use", footer: footer, rows: rows)
    }
}
