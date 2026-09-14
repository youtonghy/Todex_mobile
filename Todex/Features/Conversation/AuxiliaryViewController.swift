import TodexCore
import UIKit

/// Structured view of subagent runs and memory entries projected by the
/// conversation runtime. Data arrives through the shared event stream; the list
/// refreshes live while this page is open.
@MainActor
final class AuxiliaryViewController: SettingsListController {
    private let session: AppSession
    private let conversation: ConversationManifest
    private var observer: UUID?
    private var syncing = false
    private var syncError: String?

    init(session: AppSession, conversation: ConversationManifest) {
        self.session = session
        self.conversation = conversation
        super.init(title: "子代理与记忆")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = session.observe { [weak self] in self?.render() }
        let refresh = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            primaryAction: UIAction { [weak self] _ in self?.sync() })
        refresh.accessibilityIdentifier = "aux.refresh"
        refresh.accessibilityLabel = "同步记录"
        navigationItem.rightBarButtonItem = refresh
        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in self?.sync() }, for: .valueChanged)
        render()
        if session.runtimes[conversation.id]?.readyForActions != true { sync() }
    }

    isolated deinit {
        if let observer { session.removeObserver(observer) }
    }

    /// Re-reads the conversation journal so subagent runs and memory entries
    /// reflect the authoritative backend record, not just events seen live.
    private func sync() {
        guard !syncing else { return }
        guard session.isConnected else {
            refreshControl?.endRefreshing()
            syncError = session.lastError ?? "尚未连接后端"
            render()
            return
        }
        syncing = true
        syncError = nil
        render()
        let id = conversation.id
        Task { [weak self] in
            guard let self else { return }
            defer {
                syncing = false
                refreshControl?.endRefreshing()
                render()
            }
            do { try await session.recover(id) } catch { syncError = error.localizedDescription }
        }
    }

    private static let subagentStatus: [String: String] = [
        "queued": "等待执行", "running": "执行中", "completed": "已完成",
        "failed": "失败", "cancelled": "已取消",
    ]
    private static let memoryScope: [String: String] = [
        "user": "用户记忆", "workspace": "工作区记忆", "conversation": "对话记忆",
    ]

    private func render() {
        let runtime = session.runtimes[conversation.id]
        var sections: [SettingsSection] = []
        var syncRows: [SettingsRow] = []
        if syncing {
            syncRows.append(
                SettingsRow(
                    title: "正在同步对话记录…", symbol: "arrow.triangle.2.circlepath",
                    id: "aux.syncing", enabled: false, activity: true))
        } else if runtime?.readyForActions != true {
            syncRows.append(
                SettingsRow(
                    title: "同步对话记录",
                    detail: session.isConnected ? "重新读取后端记录" : "尚未连接后端",
                    symbol: "arrow.triangle.2.circlepath", id: "aux.sync",
                    enabled: session.isConnected
                ) { [weak self] in self?.sync() })
        }
        if let syncError {
            syncRows.append(
                SettingsRow(
                    title: syncError, detail: "点按重试", symbol: "exclamationmark.triangle",
                    id: "aux.sync.error", color: .systemRed
                ) { [weak self] in self?.sync() })
        }
        if !syncRows.isEmpty {
            sections.append(SettingsSection(title: "同步", rows: syncRows))
        }
        let agents = runtime?.subagents ?? []
        sections.append(
            SettingsSection(
                title: "子代理（\(agents.count)）",
                rows:
                    agents.isEmpty
                    ? [SettingsRow(title: "当前对话尚未收到子代理运行记录", id: "aux.agents.empty", enabled: false)]
                    : agents.enumerated().map { index, run in
                        var detail = Self.subagentStatus[run["status"].stringValue] ?? run["status"].stringValue
                        let task = run["task"].stringValue
                        if !task.isEmpty { detail += "\n\(task)" }
                        let result = run["result"].stringValue
                        if !result.isEmpty { detail += "\n\n\(result)" }
                        let error = run["error"].stringValue
                        if !error.isEmpty { detail += "\n\n错误：\(error)" }
                        return SettingsRow(
                            title: run["title"].optionalString ?? "Subagent",
                            detail: detail, symbol: "person.crop.rectangle.stack",
                            id: "aux.agent.\(index)", enabled: false)
                    }))
        let memories = runtime?.memoryEntries ?? []
        sections.append(
            SettingsSection(
                title: "记忆（\(memories.count)）",
                footer: memories.isEmpty
                    ? "这里显示 Agent 写入的记忆内容（memory 事件）。当前没有 Agent 提供过记忆记录；Codex /memories 等记忆配置需经独立的 codex.local 适配器，统一对话尚不支持。"
                    : nil,
                rows:
                    memories.isEmpty
                    ? [SettingsRow(title: "当前 Agent 尚未提供可读取的记忆记录", id: "aux.memory.empty", enabled: false)]
                    : memories.enumerated().map { index, entry in
                        let content = entry["content"].stringValue
                        let firstLine = content.components(separatedBy: .newlines).first ?? content
                        var detail = Self.memoryScope[entry["scope"].stringValue] ?? "对话记忆"
                        if let updated = entry["updatedAt"].optionalString, !updated.isEmpty {
                            detail += " · \(updated)"
                        }
                        if content != firstLine { detail += "\n\(content.dropFirst(firstLine.count).trimmingCharacters(in: .newlines))" }
                        return SettingsRow(
                            title: String(firstLine.prefix(80)),
                            detail: detail, symbol: "brain",
                            id: "aux.memory.\(index)", enabled: false)
                    }))
        self.sections = sections
        redraw()
    }
}
