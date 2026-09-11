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

    init(session: AppSession, conversation: ConversationManifest) {
        self.session = session
        self.conversation = conversation
        super.init(title: "子代理与记忆")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = session.observe { [weak self] in self?.render() }
        render()
    }

    isolated deinit {
        if let observer { session.removeObserver(observer) }
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
                    ? "这里只显示 Agent 已提供的记忆内容，配置开关不代表支持读取内容。" : nil,
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
