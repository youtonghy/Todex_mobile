import TodexCore
import UIKit

/// Result page for one `codex.local.request`: loads once, renders the JSON
/// response as grouped rows, and offers the raw payload as selectable text.
/// Used by the adapter slash commands that have no dedicated editor
/// (`/hooks`, `/plugins`, `/apps`, `/mcp`, `/ps`, `/status` subcommands,
/// `/skills`, `/memories` config, `thread/*` readers).
@MainActor
final class CodexLocalResultController: SettingsListController {
    private let session: AppSession
    private let conversation: ConversationManifest
    private let load: @MainActor () async throws -> JSONValue
    private var result: JSONValue?
    private var loadError: String?
    private var loading = false

    init(
        session: AppSession, conversation: ConversationManifest, title: String,
        load: @escaping @MainActor () async throws -> JSONValue
    ) {
        self.session = session
        self.conversation = conversation
        self.load = load
        super.init(title: title)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            primaryAction: UIAction { [weak self] _ in self?.fetch() })
        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in self?.fetch() }, for: .valueChanged)
        fetch()
    }

    private func fetch() {
        guard !loading else { return }
        loading = true
        loadError = nil
        render()
        Task { [weak self] in
            guard let self else { return }
            defer {
                loading = false
                refreshControl?.endRefreshing()
                render()
            }
            do { result = try await load() } catch {
                loadError = CodexLocal.describeError(error.localizedDescription)
            }
        }
    }

    private func render() {
        var sections: [SettingsSection] = []
        if loading {
            sections.append(
                SettingsSection(
                    title: title ?? "",
                    rows: [
                        SettingsRow(
                            title: String(localized: "正在请求…"), symbol: "arrow.triangle.2.circlepath",
                            id: "local.loading", enabled: false, activity: true)
                    ]))
        }
        if let loadError {
            sections.append(
                SettingsSection(
                    title: String(localized: "错误"),
                    rows: [
                        SettingsRow(
                            title: loadError, detail: String(localized: "点按重试"), symbol: "exclamationmark.triangle",
                            id: "local.error", color: .systemRed
                        ) { [weak self] in self?.fetch() }
                    ]))
        }
        if let result {
            sections.append(contentsOf: Self.sections(for: result))
            if let raw = Self.pretty(result) {
                sections.append(
                    SettingsSection(
                        title: String(localized: "原始数据"),
                        rows: [
                            SettingsRow(
                                title: String(localized: "查看原始响应"), symbol: "doc.plaintext", id: "local.raw"
                            ) { [weak self] in
                                self?.navigationController?.pushViewController(
                                    SettingsTextController(title: self?.title ?? "", text: raw), animated: true)
                            }
                        ]))
            }
        }
        self.sections = sections
        redraw()
    }

    /// Human-friendly projection of an adapter response: scalars become
    /// overview rows, arrays of objects become per-item rows, everything else
    /// stays reachable through the raw view.
    static func sections(for result: JSONValue) -> [SettingsSection] {
        var sections: [SettingsSection] = []
        // The list payload may live one level down (result/data/payload).
        let root: JSONValue = {
            for key in ["result", "data", "payload"] {
                if case .object = result[key], !result[key].objectValue.isEmpty {
                    return result[key]
                }
            }
            return result
        }()
        var scalars: [(String, String)] = []
        var arraySections: [SettingsSection] = []
        var objectBlobs: [(String, String)] = []
        for (key, value) in root.objectValue.sorted(by: { $0.key < $1.key }) {
            switch value {
            case .array(let items):
                arraySections.append(
                    SettingsSection(title: key, rows: items.enumerated().map { row(for: $1, index: $0) }))
            case .object:
                if let text = pretty(value) { objectBlobs.append((key, text)) }
            case .string(let text):
                if !text.isEmpty { scalars.append((key, text)) }
            case .number(let number):
                scalars.append((key, Self.number(number)))
            case .bool(let flag):
                scalars.append((key, flag ? "true" : "false"))
            case .null:
                break
            }
        }
        if case .array(let items) = root {
            arraySections.append(
                SettingsSection(title: String(localized: "条目"), rows: items.enumerated().map { row(for: $1, index: $0) }))
        }
        if !scalars.isEmpty {
            sections.append(
                SettingsSection(
                    title: String(localized: "概览"),
                    rows: scalars.enumerated().map { index, item in
                        SettingsRow(title: item.1, detail: item.0, id: "local.scalar.\(index)", enabled: false)
                    }))
        }
        sections.append(contentsOf: arraySections)
        for (key, text) in objectBlobs {
            sections.append(
                SettingsSection(title: key, rows: [SettingsRow(title: text, id: "local.obj.\(key)", enabled: false)]))
        }
        if sections.isEmpty {
            sections.append(
                SettingsSection(
                    title: "",
                    rows: [SettingsRow(title: String(localized: "响应为空"), id: "local.empty", enabled: false)]))
        }
        return sections
    }

    /// Title field preference for one list entry; remaining scalars compress
    /// into the subtitle.
    private static let titleKeys = ["name", "title", "displayName", "id", "command", "path", "model", "server", "cwd", "kind"]
    private static func row(for item: JSONValue, index: Int) -> SettingsRow {
        guard case .object = item else {
            return SettingsRow(title: item.optionalString ?? Self.pretty(item) ?? "", id: "local.item.\(index)", enabled: false)
        }
        let title = titleKeys.lazy.compactMap { item[$0].optionalString }.first
            ?? item.objectValue.keys.sorted().first ?? "#\(index + 1)"
        let detail = item.objectValue.sorted { $0.key < $1.key }
            .filter { $0.key != titleKeys.first(where: { item[$0].optionalString == title }) }
            .compactMap { key, value -> String? in
                switch value {
                case .string(let text): return text.isEmpty ? nil : "\(key): \(text)"
                case .number(let number): return "\(key): \(Self.number(number))"
                case .bool(let flag): return "\(key): \(flag)"
                case .null: return nil
                case .array(let list) where list.count <= 6 && list.allSatisfy({ $0.optionalString != nil }):
                    return "\(key): \(list.compactMap(\.optionalString).joined(separator: ", "))"
                default: return nil
                }
            }
            .prefix(8)
            .joined(separator: "\n")
        return SettingsRow(title: title, detail: detail, id: "local.item.\(index)", enabled: false)
    }

    static func pretty(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }
    private static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}

/// `/personality`: writes the style onto the workspace record (desktop stores
/// it the same passthrough way) and mirrors it to the live adapter thread
/// through `thread/settings/update` when a thread exists.
@MainActor
final class CodexPersonalityController: SettingsListController {
    private static let options: [(id: String, title: String, detail: String)] = [
        ("friendly", String(localized: "友好"), String(localized: "更温和、更健谈的沟通风格。")),
        ("pragmatic", String(localized: "务实"), String(localized: "直接、简洁、以行动为导向的沟通风格。")),
        ("none", String(localized: "默认"), String(localized: "使用模型的默认沟通风格。")),
    ]
    private let session: AppSession
    private let conversation: ConversationManifest
    private let workspace: WorkspaceRecord
    private var applying = false
    private var lastError: String?

    init(session: AppSession, conversation: ConversationManifest, workspace: WorkspaceRecord) {
        self.session = session
        self.conversation = conversation
        self.workspace = workspace
        super.init(title: String(localized: "性格"))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    private func render() {
        let current = workspace.personality ?? "none"
        var rows = Self.options.map { option in
            SettingsRow(
                title: option.title, detail: option.detail, symbol: "person.crop.circle",
                id: "personality.\(option.id)", enabled: !applying, checked: option.id == current
            ) { [weak self] in self?.apply(option.id) }
        }
        if applying {
            rows.append(SettingsRow(title: String(localized: "正在应用…"), id: "personality.busy", enabled: false, activity: true))
        }
        if let lastError {
            rows.append(
                SettingsRow(title: lastError, symbol: "exclamationmark.triangle", id: "personality.error", color: .systemRed))
        }
        sections = [
            SettingsSection(
                title: String(localized: "沟通风格"),
                footer: String(localized: "应用到当前工作区；存在本地线程时同步到 Codex 会话。"),
                rows: rows)
        ]
        redraw()
    }

    private func apply(_ personality: String) {
        guard !applying else { return }
        applying = true
        lastError = nil
        render()
        Task { [weak self] in
            guard let self else { return }
            defer { applying = false; render() }
            do {
                guard let api = session.api else { throw TodexError.disconnected }
                var updated = workspace
                updated.personality = personality
                updated.updatedAt = Int(Date().timeIntervalSince1970 * 1_000)
                _ = try await api.replaceWorkspaces([updated])
                if !session.sidecar(for: conversation.id).threadId.isEmpty {
                    _ = try await session.localThreadRequest(
                        "thread/settings/update", params: ["personality": .string(personality)],
                        in: conversation, requireExisting: true)
                }
                try await session.refresh()
            } catch { lastError = CodexLocal.describeError(error.localizedDescription) }
        }
    }
}

/// `/goal`: shows the adapter thread's goal and offers set/pause/resume/clear
/// (desktop `thread/goal/*` actions).
@MainActor
final class CodexGoalController: SettingsListController {
    private let session: AppSession
    private let conversation: ConversationManifest
    private var goal: JSONValue?
    private var loadError: String?
    private var busy = false

    init(session: AppSession, conversation: ConversationManifest) {
        self.session = session
        self.conversation = conversation
        super.init(title: String(localized: "目标"))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        fetch()
    }

    private func call(_ method: String, params: JSONValue? = nil, title _: String = "") async throws {
        let result = try await session.localThreadRequest(
            method, params: params, in: conversation, timeout: 30)
        if method == "thread/goal/get" { goal = result["result"].isNull ? result : result["result"] }
    }

    private func fetch() {
        run { try await self.call("thread/goal/get") }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        loadError = nil
        render()
        Task { [weak self] in
            guard let self else { return }
            defer { busy = false; render() }
            do { try await work() } catch { loadError = CodexLocal.describeError(error.localizedDescription) }
        }
    }

    private func render() {
        var sections: [SettingsSection] = []
        var rows: [SettingsRow] = []
        if busy {
            rows.append(SettingsRow(title: String(localized: "正在处理…"), id: "goal.busy", enabled: false, activity: true))
        }
        if let loadError {
            rows.append(
                SettingsRow(
                    title: loadError, detail: String(localized: "点按重试"), symbol: "exclamationmark.triangle",
                    id: "goal.error", color: .systemRed
                ) { [weak self] in self?.fetch() })
        }
        let data = goal.map { CodexLocal.data(of: ["payload": $0]) } ?? .null
        let objective = data["objective"].optionalString ?? data["goal"].optionalString ?? data["text"].optionalString ?? ""
        let status = data["status"].optionalString ?? ""
        if !objective.isEmpty || !status.isEmpty {
            rows.append(
                SettingsRow(
                    title: objective.isEmpty ? String(localized: "（无目标文本）") : objective,
                    detail: status, symbol: "target", id: "goal.current", enabled: false))
        } else if goal != nil {
            rows.append(SettingsRow(title: String(localized: "当前线程没有目标"), id: "goal.none", enabled: false))
        }
        sections.append(SettingsSection(title: String(localized: "当前目标"), rows: rows))
        sections.append(
            SettingsSection(
                title: String(localized: "操作"),
                rows: [
                    SettingsRow(
                        title: String(localized: "编辑目标"), detail: objective, symbol: "pencil", id: "goal.edit",
                        enabled: !busy
                    ) { [weak self] in
                        guard let self else { return }
                        editField(title: String(localized: "目标"), value: objective, id: "goal.field") { [weak self] text in
                            self?.run { try await self?.call("thread/goal/set", params: ["objective": .string(text)]) }
                        }
                    },
                    SettingsRow(title: String(localized: "暂停目标"), symbol: "pause", id: "goal.pause", enabled: !busy) {
                        [weak self] in
                        self?.run { try await self?.call("thread/goal/set", params: ["status": "paused"]) }
                    },
                    SettingsRow(title: String(localized: "恢复目标"), symbol: "play", id: "goal.resume", enabled: !busy) {
                        [weak self] in
                        self?.run { try await self?.call("thread/goal/set", params: ["status": "active"]) }
                    },
                    SettingsRow(title: String(localized: "清除目标"), symbol: "trash", id: "goal.clear", color: .systemRed, enabled: !busy) {
                        [weak self] in
                        self?.run {
                            try await self?.call("thread/goal/clear")
                            self?.goal = .null
                        }
                    },
                    SettingsRow(title: String(localized: "刷新"), symbol: "arrow.clockwise", id: "goal.refresh", enabled: !busy) {
                        [weak self] in self?.fetch()
                    },
                ]))
        self.sections = sections
        redraw()
    }
}

/// `/memories`: adapter memory settings — `config/read` shows the codex
/// config, toggles write back through `config/batchWrite` (+`thread/memoryMode/set`
/// for generate-memories), and `memory/reset` clears stored memories.
@MainActor
final class CodexMemoriesController: SettingsListController {
    private let session: AppSession
    private let conversation: ConversationManifest
    private let workspace: WorkspaceRecord
    private var config: JSONValue?
    private var loadError: String?
    private var busy = false

    init(session: AppSession, conversation: ConversationManifest, workspace: WorkspaceRecord) {
        self.session = session
        self.conversation = conversation
        self.workspace = workspace
        super.init(title: String(localized: "记忆"))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        fetch()
    }

    private var useMemories: Bool {
        let memories = config?["config"]["memories"] ?? config?["memories"] ?? .null
        return memories["useMemories"].boolValue || memories["use_memories"].boolValue
    }
    private var generateMemories: Bool {
        let memories = config?["config"]["memories"] ?? config?["memories"] ?? .null
        return memories["generateMemories"].boolValue || memories["generate_memories"].boolValue
    }

    private func fetch() {
        run { [weak self] in
            guard let self else { return }
            config = try await session.localRequest(
                "config/read", params: ["cwd": .string(workspace.path)], in: conversation)
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        loadError = nil
        render()
        Task { [weak self] in
            guard let self else { return }
            defer { busy = false; render() }
            do { try await work() } catch { loadError = CodexLocal.describeError(error.localizedDescription) }
        }
    }

    private func write(_ keyPath: String, value: Bool) {
        run { [weak self] in
            guard let self else { return }
            _ = try await session.localRequest(
                "config/batchWrite",
                params: [
                    "edits": [["keyPath": .string(keyPath), "value": .bool(value), "mergeStrategy": "replace"]],
                    "reloadUserConfig": .bool(true),
                ], in: conversation)
            if keyPath == "memories.generate_memories", !session.sidecar(for: conversation.id).threadId.isEmpty {
                _ = try await session.localThreadRequest(
                    "thread/memoryMode/set", params: ["mode": .string(value ? "enabled" : "disabled")],
                    in: conversation, requireExisting: true)
            }
            fetch()
        }
    }

    private func reset() {
        let alert = UIAlertController(
            title: String(localized: "重置记忆"), message: String(localized: "清除此 Agent 保存的全部记忆？此操作不可撤销。"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "重置"), style: .destructive) { [weak self] _ in
                self?.run { [weak self] in
                    guard let self else { return }
                    _ = try await session.localRequest("memory/reset", params: nil, in: conversation)
                }
            })
        present(alert, animated: true)
    }

    private func render() {
        var sections: [SettingsSection] = []
        var rows: [SettingsRow] = []
        if busy {
            rows.append(SettingsRow(title: String(localized: "正在处理…"), id: "memory.busy", enabled: false, activity: true))
        }
        if let loadError {
            rows.append(
                SettingsRow(
                    title: loadError, detail: String(localized: "点按重试"), symbol: "exclamationmark.triangle",
                    id: "memory.error", color: .systemRed
                ) { [weak self] in self?.fetch() })
        }
        if config != nil {
            rows.append(
                SettingsRow(
                    title: String(localized: "使用记忆"), detail: String(localized: "读取并引用已保存的记忆"),
                    symbol: "brain", id: "memory.use", enabled: !busy, checked: useMemories
                ) { [weak self] in self?.write("memories.use_memories", value: !(self?.useMemories ?? false)) })
            rows.append(
                SettingsRow(
                    title: String(localized: "生成记忆"), detail: String(localized: "对话中自动记录可复用的信息"),
                    symbol: "brain.head.profile", id: "memory.generate", enabled: !busy, checked: generateMemories
                ) { [weak self] in self?.write("memories.generate_memories", value: !(self?.generateMemories ?? false)) })
        } else if !busy {
            rows.append(
                SettingsRow(
                    title: String(localized: "读取记忆配置"), symbol: "arrow.triangle.2.circlepath", id: "memory.load"
                ) { [weak self] in self?.fetch() })
        }
        sections.append(SettingsSection(title: String(localized: "记忆设置"), rows: rows))
        sections.append(
            SettingsSection(
                title: String(localized: "操作"),
                rows: [
                    SettingsRow(
                        title: String(localized: "重置记忆"), symbol: "trash", id: "memory.reset", color: .systemRed,
                        enabled: !busy
                    ) { [weak self] in self?.reset() },
                    SettingsRow(title: String(localized: "查看配置"), symbol: "doc.plaintext", id: "memory.config", enabled: config != nil) {
                        [weak self] in
                        guard let self, let text = self.config.flatMap(CodexLocalResultController.pretty) else { return }
                        navigationController?.pushViewController(
                            SettingsTextController(title: String(localized: "配置"), text: text), animated: true)
                    },
                ]))
        self.sections = sections
        redraw()
    }
}

/// `/feedback`: adapter `feedback/upload` — classification, reason and
/// include-logs choice, matching desktop's categories exactly.
@MainActor
final class CodexFeedbackController: SettingsListController {
    private static let categories: [(id: String, title: String, detail: String)] = [
        ("bad_result", String(localized: "结果不佳"), String(localized: "Codex 产出了不正确或无帮助的结果。")),
        ("good_result", String(localized: "结果优秀"), String(localized: "Codex 做得很好，分享正面反馈。")),
        ("bug", String(localized: "缺陷"), String(localized: "应用或 Codex 本身出现问题。")),
        ("safety_check", String(localized: "安全问题"), String(localized: "上报安全/审批相关的顾虑。")),
        ("other", String(localized: "其他"), String(localized: "其他想告诉维护者的内容。")),
    ]
    private let session: AppSession
    private let conversation: ConversationManifest
    private var classification = "other"
    private var reason = ""
    private var includeLogs = false
    private var sending = false
    private var notice: String?

    init(session: AppSession, conversation: ConversationManifest) {
        self.session = session
        self.conversation = conversation
        super.init(title: String(localized: "反馈"))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    private func render() {
        var sections = [
            SettingsSection(
                title: String(localized: "分类"),
                rows: Self.categories.map { category in
                    SettingsRow(
                        title: category.title, detail: category.detail, id: "feedback.\(category.id)",
                        enabled: !sending, checked: classification == category.id
                    ) { [weak self] in
                        self?.classification = category.id
                        self?.render()
                    }
                }),
            SettingsSection(
                title: String(localized: "详情"),
                rows: [
                    SettingsRow(
                        title: reason.isEmpty ? String(localized: "补充说明（可选）") : reason,
                        symbol: "text.quote", id: "feedback.reason", enabled: !sending
                    ) { [weak self] in
                        self?.editField(title: String(localized: "补充说明"), value: self?.reason ?? "", id: "feedback.reason.field") {
                            self?.reason = $0
                            self?.render()
                        }
                    },
                    SettingsRow(
                        title: String(localized: "附带日志"), detail: String(localized: "上传会话日志以辅助诊断"),
                        symbol: "doc.zipper", id: "feedback.logs", enabled: !sending, checked: includeLogs
                    ) { [weak self] in
                        self?.includeLogs.toggle()
                        self?.render()
                    },
                ]),
        ]
        var actionRows = [
            SettingsRow(
                title: String(localized: "提交反馈"), symbol: "paperplane", id: "feedback.submit", enabled: !sending
            ) { [weak self] in self?.submit() }
        ]
        if sending {
            actionRows.append(SettingsRow(title: String(localized: "正在提交…"), id: "feedback.busy", enabled: false, activity: true))
        }
        if let notice {
            actionRows.append(SettingsRow(title: notice, id: "feedback.notice", color: .secondaryLabel, enabled: false))
        }
        sections.append(SettingsSection(title: String(localized: "提交"), rows: actionRows))
        self.sections = sections
        redraw()
    }

    private func submit() {
        guard !sending else { return }
        sending = true
        notice = nil
        render()
        Task { [weak self] in
            guard let self else { return }
            defer { sending = false; render() }
            do {
                var params: JSONValue = ["classification": .string(classification), "includeLogs": .bool(includeLogs)]
                let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { params["reason"] = .string(trimmed) }
                let threadId = session.sidecar(for: conversation.id).threadId
                if !threadId.isEmpty { params["threadId"] = .string(threadId) }
                _ = try await session.localRequest("feedback/upload", params: params, in: conversation)
                notice = String(localized: "已提交，感谢反馈")
            } catch { notice = CodexLocal.describeError(error.localizedDescription) }
        }
    }
}
