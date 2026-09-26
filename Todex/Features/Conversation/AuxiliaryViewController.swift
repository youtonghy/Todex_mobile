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
        super.init(title: String(localized: "子代理与记忆"))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = session.observe { [weak self] in self?.render() }
        let refresh = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            primaryAction: UIAction { [weak self] _ in self?.sync() })
        refresh.accessibilityIdentifier = "aux.refresh"
        refresh.accessibilityLabel = String(localized: "同步记录")
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
            syncError = session.lastError ?? String(localized: "尚未连接后端")
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

    static let subagentStatus: [String: String] = [
        "queued": String(localized: "等待执行"), "running": String(localized: "执行中"), "completed": String(localized: "已完成"),
        "failed": String(localized: "失败"), "cancelled": String(localized: "已取消"),
    ]
    private static let memoryScope: [String: String] = [
        "user": String(localized: "用户记忆"), "workspace": String(localized: "工作区记忆"), "conversation": String(localized: "对话记忆"),
    ]

    private func render() {
        let runtime = session.runtimes[conversation.id]
        var sections: [SettingsSection] = []
        var syncRows: [SettingsRow] = []
        if syncing {
            syncRows.append(
                SettingsRow(
                    title: String(localized: "正在同步对话记录…"), symbol: "arrow.triangle.2.circlepath",
                    id: "aux.syncing", enabled: false, activity: true))
        } else if runtime?.readyForActions != true {
            syncRows.append(
                SettingsRow(
                    title: String(localized: "同步对话记录"),
                    detail: session.isConnected ? String(localized: "重新读取后端记录") : String(localized: "尚未连接后端"),
                    symbol: "arrow.triangle.2.circlepath", id: "aux.sync",
                    enabled: session.isConnected
                ) { [weak self] in self?.sync() })
        }
        if let syncError {
            syncRows.append(
                SettingsRow(
                    title: syncError, detail: String(localized: "点按重试"), symbol: "exclamationmark.triangle",
                    id: "aux.sync.error", color: .systemRed
                ) { [weak self] in self?.sync() })
        }
        if !syncRows.isEmpty {
            sections.append(SettingsSection(title: String(localized: "同步"), rows: syncRows))
        }
        let agents = runtime?.subagents ?? []
        sections.append(
            SettingsSection(
                title: String(localized: "子代理（\(agents.count)）"),
                rows:
                    agents.isEmpty
                    ? [SettingsRow(title: String(localized: "当前对话尚未收到子代理运行记录"), id: "aux.agents.empty", enabled: false)]
                    : agents.enumerated().map { index, run in
                        // Summary here; the full run (details, usage, metadata) is one tap away.
                        var detail = Self.subagentStatus[run["status"].stringValue] ?? run["status"].stringValue
                        if let duration = SubagentDetailViewController.duration(run) { detail += " · \(duration)" }
                        let task = run["task"].stringValue
                        if !task.isEmpty { detail += "\n\(Self.excerpt(task))" }
                        let error = run["error"].stringValue
                        if !error.isEmpty { detail += String(localized: "\n错误：\(Self.excerpt(error))") }
                        let id = run["id"].stringValue
                        return SettingsRow(
                            title: run["title"].optionalString ?? "Subagent",
                            detail: detail, symbol: "person.crop.rectangle.stack",
                            id: "aux.agent.\(index)"
                        ) { [weak self] in
                            guard let self else { return }
                            navigationController?.pushViewController(
                                SubagentDetailViewController(
                                    session: session, conversationId: conversation.id, runId: id),
                                animated: true)
                        }
                    }))
        let memories = runtime?.memoryEntries ?? []
        sections.append(
            SettingsSection(
                title: String(localized: "记忆（\(memories.count)）"),
                footer: memories.isEmpty
                    ? String(localized: "这里显示 Agent 写入的记忆内容（memory 事件）。当前没有 Agent 提供过记忆记录；Codex /memories 等记忆配置需经独立的 codex.local 适配器，统一对话尚不支持。")
                    : nil,
                rows:
                    memories.isEmpty
                    ? [SettingsRow(title: String(localized: "当前 Agent 尚未提供可读取的记忆记录"), id: "aux.memory.empty", enabled: false)]
                    : memories.enumerated().map { index, entry in
                        let content = entry["content"].stringValue
                        let firstLine = content.components(separatedBy: .newlines).first ?? content
                        var detail = Self.memoryScope[entry["scope"].stringValue] ?? String(localized: "对话记忆")
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
    private static func excerpt(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).prefix(3).joined(separator: "\n")
        return lines.count > 240 ? String(lines.prefix(240)) + "…" : lines
    }
}

/// One subagent run in full, desktop SubagentsPanel parity: status, duration,
/// task, result or error, the detail fields and raw metadata. It follows the
/// runtime live, so a running run updates in place.
@MainActor
final class SubagentDetailViewController: SettingsListController {
    private let session: AppSession
    private let conversationId: String
    private let runId: String
    private var observer: UUID?

    init(session: AppSession, conversationId: String, runId: String) {
        self.session = session
        self.conversationId = conversationId
        self.runId = runId
        super.init(title: String(localized: "子代理"))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = session.observe { [weak self] in self?.render() }
        render()
    }

    isolated deinit {
        if let observer { session.removeObserver(observer) }
    }

    private func render() {
        guard let run = session.runtimes[conversationId]?.subagents.first(where: { $0["id"].stringValue == runId })
        else {
            sections = [
                SettingsSection(
                    title: String(localized: "子代理"),
                    rows: [
                        SettingsRow(title: String(localized: "运行记录已不可用，请返回后重新同步"), id: "subagent.missing", enabled: false)
                    ])
            ]
            redraw()
            return
        }
        title = run["title"].optionalString ?? "Subagent"
        let status = run["status"].stringValue
        var overview = [
            SettingsRow(
                title: AuxiliaryViewController.subagentStatus[status] ?? status, detail: String(localized: "状态"),
                symbol: Self.statusSymbol(status), id: "subagent.status", color: Self.statusColor(status))
        ]
        if let duration = Self.duration(run) {
            overview.append(SettingsRow(title: duration, detail: String(localized: "用时"), symbol: "timer", id: "subagent.duration"))
        }
        var sections = [SettingsSection(title: String(localized: "概览"), rows: overview)]
        // A failed run's result is its error text, as on desktop.
        let failed = status == "failed"
        let error = run["error"].stringValue.isEmpty && failed ? run["result"].stringValue : run["error"].stringValue
        let result = failed ? "" : run["result"].stringValue
        let texts = [(String(localized: "任务"), run["task"].stringValue, "task"), (String(localized: "结果"), result, "result"), (String(localized: "错误"), error, "error")]
        for (heading, text, id) in texts where !text.isEmpty {
            sections.append(
                SettingsSection(
                    title: heading,
                    rows: [
                        SettingsRow(
                            title: text, id: "subagent.\(id)", color: id == "error" ? .systemRed : .label)
                    ]))
        }
        let usage = run["usage"].objectValue.sorted { $0.key < $1.key }
            .compactMap { key, value in value.doubleValue.map { "\(key) \(Self.number($0))" } }
            .joined(separator: " · ")
        let details: [(String, String)] = [
            (String(localized: "类型"), run["agentKind"].stringValue), ("Agent", run["agentId"].stringValue),
            ("Parent", run["parentId"].stringValue), (String(localized: "开始"), Self.time(run["startedAt"].stringValue)),
            (String(localized: "结束"), Self.time(run["finishedAt"].stringValue)), (String(localized: "输出文件"), run["outputFile"].stringValue),
            (String(localized: "用量"), usage), (String(localized: "条目"), run["providerItemId"].stringValue),
        ].filter { !$0.1.isEmpty }
        if !details.isEmpty {
            sections.append(
                SettingsSection(
                    title: String(localized: "详情"),
                    rows: details.enumerated().map { index, item in
                        SettingsRow(title: item.1, detail: item.0, id: "subagent.detail.\(index)")
                    }))
        }
        if !run["metadata"].isNull, let metadata = Self.pretty(run["metadata"]) {
            sections.append(
                SettingsSection(
                    title: String(localized: "元数据"),
                    rows: [SettingsRow(title: metadata, id: "subagent.metadata")]))
        }
        self.sections = sections
        redraw()
    }

    /// Desktop `durationLabel`: only once both ends are known.
    static func duration(_ run: JSONValue) -> String? {
        guard let start = date(run["startedAt"].stringValue), let end = date(run["finishedAt"].stringValue) else {
            return nil
        }
        let ms = end.timeIntervalSince(start) * 1000
        guard ms.isFinite, ms >= 0 else { return nil }
        if ms < 1000 { return "<1s" }
        let seconds = Int((ms / 1000).rounded())
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
    private static func date(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        return (try? Date(value, strategy: .iso8601))
            ?? (try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
    private static func time(_ value: String) -> String {
        guard let date = date(value) else { return value }
        return date.formatted(date: .abbreviated, time: .standard)
    }
    private static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
    private static func pretty(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }
    private static func statusSymbol(_ status: String) -> String {
        switch status {
        case "running": "circle.dotted.circle"
        case "completed": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "cancelled": "stop.circle"
        default: "clock"
        }
    }
    private static func statusColor(_ status: String) -> UIColor {
        switch status {
        case "running": Theme.accent
        case "completed": .systemGreen
        case "failed": .systemRed
        case "cancelled": .systemOrange
        default: .secondaryLabel
        }
    }
}
