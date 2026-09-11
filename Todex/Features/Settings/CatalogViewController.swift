import TodexCore
import UIKit

/// The owner binds command to the current conversation and inserts conversationId into payloads.
typealias SettingsCommand = @MainActor (String, JSONValue, TimeInterval) async throws -> JSONValue

@MainActor
final class CatalogViewController: SettingsListController {
    private enum Kind: Int, CaseIterable { case skills, mcp, commands }
    private let connection: BackendConnection
    private let workspace: String
    private let provider: String
    private let client: HTTPClient
    private let command: SettingsCommand
    /// Arguments are resourceId and display name, respectively.
    private let insertSkill: @MainActor (String, String) -> Void
    private let insertText: @MainActor (String) -> Void
    private var kind = Kind.skills
    private var items: [JSONValue] = []
    private var loading = false
    private var errorMessage: String?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var attachedSkills: Set<String> = []
    private let picker = UISegmentedControl(items: ["Skills", "MCP", "命令"])

    init(
        connection: BackendConnection, workspace: String, provider: String,
        command: @escaping @MainActor (String, JSONValue, TimeInterval) async throws -> JSONValue,
        insertSkill: @escaping @MainActor (String, String) -> Void, insertText: @escaping @MainActor (String) -> Void
    ) {
        self.connection = connection
        self.workspace = workspace
        self.provider = provider
        self.command = command
        self.insertSkill = insertSkill
        self.insertText = insertText
        client = HTTPClient(connection: connection)
        super.init(title: "能力目录")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        picker.selectedSegmentIndex = 0
        picker.accessibilityIdentifier = "catalog.category"
        picker.accessibilityLabel = "能力分类"
        picker.addAction(
            UIAction { [weak self] _ in
                guard let self, let kind = Kind(rawValue: picker.selectedSegmentIndex) else { return }
                self.kind = kind
                refresh()
            }, for: .valueChanged)
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 64))
        picker.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
            picker.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            picker.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            picker.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            picker.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -8),
        ])
        tableView.tableHeaderView = header
        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .refresh, primaryAction: UIAction { [weak self] _ in self?.refresh() })
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "catalog.refresh"
        refresh()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            generation += 1
            task?.cancel()
            task = nil
        }
    }

    private func refresh() {
        generation += 1
        let current = generation
        let requestedKind = kind
        task?.cancel()
        loading = true
        errorMessage = nil
        items = []
        render()
        let query = ["provider": provider, "workspace": workspace]
        task = Task { [weak self, client, command] in
            do {
                guard !query["workspace", default: ""].isEmpty else { throw TodexError.invalid("请先选择工作区") }
                let value: JSONValue
                let key: String
                switch requestedKind {
                case .skills:
                    value = try await client.request(path: "/v2/catalog/skills", query: query)
                    key = "skills"
                case .mcp:
                    value = try await command("mcp.list", [:], 45)
                    key = "servers"
                case .commands:
                    value = try await client.request(path: "/v2/providers/commands", query: query)
                    key = "commands"
                }
                let loaded = try SettingsResponse.array(value, key: key)
                try Task.checkCancellation()
                guard let self, generation == current else { return }
                items = loaded
                loading = false
                task = nil
                refreshControl?.endRefreshing()
                render()
            } catch {
                guard let self, !Task.isCancelled, generation == current else { return }
                errorMessage = SettingsResponse.errorMessage(error, feature: "所选目录")
                loading = false
                task = nil
                refreshControl?.endRefreshing()
                render()
            }
        }
    }

    private func render() {
        navigationItem.rightBarButtonItem?.isEnabled = !loading
        sections = [SettingsSection(title: "\(provider) · \(connection.name)", footer: workspace, rows: [])]
        if loading {
            sections.append(
                SettingsSection(
                    title: "状态",
                    rows: [
                        SettingsRow(
                            title: "正在读取…", symbol: "arrow.triangle.2.circlepath", id: "catalog.loading", activity: true
                        )
                    ]))
        }
        if let errorMessage {
            sections.append(
                SettingsSection(
                    title: "读取失败",
                    rows: [
                        SettingsRow(
                            title: errorMessage, detail: "点按重试", symbol: "exclamationmark.triangle",
                            id: "catalog.error", color: .systemRed
                        ) { [weak self] in self?.refresh() }
                    ]))
        }
        let rows = items.enumerated().map { index, item in
            let id = item["resourceId"].optionalString ?? String(index)
            var detail = item["description"].stringValue
            switch kind {
            case .skills:
                let state =
                    !item["valid"].boolValue
                    ? "无效" : item["active"].boolValue ? "当前启用" : !item["shadowedBy"].isNull ? "被覆盖" : "未启用"
                detail += "\n\(state) · \(item["scope"].stringValue) · \(item["source"].stringValue)"
                if let error = item["error"].optionalString { detail += "\n\(error)" }
            case .mcp:
                detail +=
                    "\n\(item["transport"].stringValue) · \(item["scope"].stringValue) · \(item["source"].stringValue)"
                if let error = item["error"].optionalString { detail += "\n\(error)" }
            case .commands:
                detail += "\n\(item["invocation"].stringValue)"
                if let hint = item["argumentHint"].optionalString { detail += " \(hint)" }
            }
            return SettingsRow(
                title: item["name"].optionalString ?? "未命名",
                detail: detail.trimmingCharacters(in: .whitespacesAndNewlines), id: "catalog.item.\(id)",
                enabled: !loading
            ) { [weak self] in
                guard let self else { return }
                switch kind {
                case .skills: openSkill(item)
                case .mcp:
                    navigationController?.pushViewController(
                        MCPServerViewController(server: item, command: command), animated: true)
                case .commands: openCommand(item)
                }
            }
        }
        if !rows.isEmpty {
            sections.append(SettingsSection(title: "目录", rows: rows))
        } else if !loading && errorMessage == nil {
            sections.append(SettingsSection(title: "目录", rows: [SettingsRow(title: "没有找到可用项目", id: "catalog.empty")]))
        }
        redraw()
    }

    private func openSkill(_ item: JSONValue) {
        guard item["valid"].boolValue, let id = item["resourceId"].optionalString, !id.isEmpty else {
            showError(TodexError.invalid(item["error"].optionalString ?? "此 Skill 无效或缺少资源标识"))
            return
        }
        generation += 1
        let current = generation
        task?.cancel()
        loading = true
        errorMessage = nil
        render()
        let query = ["provider": provider, "workspace": workspace]
        task = Task { [weak self, client] in
            do {
                let value = try await client.request(path: "/v2/catalog/skills/\(HTTPClient.segment(id))", query: query)
                try Task.checkCancellation()
                guard let content = value["content"].optionalString else { throw TodexError.invalid("后端未返回 Skill 正文") }
                guard let self, generation == current else { return }
                loading = false
                task = nil
                render()
                let name = item["name"].stringValue
                let detail = SettingsTextController(
                    title: name, text: content,
                    detail: "\(item["source"].stringValue) · 附加后，Backend 在下一条消息读取并注入此 Skill。", actionTitle: "附加"
                ) { [weak self] _ in
                    guard let self else { throw CancellationError() }
                    guard !attachedSkills.contains(id) else { throw TodexError.invalid("此 Skill 已附加到待发送消息") }
                    insertSkill(id, name)
                    attachedSkills.insert(id)
                }
                navigationController?.pushViewController(detail, animated: true)
            } catch {
                guard let self, !Task.isCancelled, generation == current else { return }
                loading = false
                task = nil
                render()
                showError(error)
            }
        }
    }

    private func openCommand(_ item: JSONValue) {
        guard let invocation = item["invocation"].optionalString, !invocation.isEmpty else {
            showError(TodexError.invalid("命令缺少后端提供的 invocation，无法插入"))
            return
        }
        let detail = SettingsTextController(
            title: item["name"].stringValue, text: item.prettyPrinted, detail: "将原样插入 \(invocation)。可在消息输入框补充参数。",
            actionTitle: "插入"
        ) { [insertText] _ in
            insertText(invocation)
        }
        navigationController?.pushViewController(detail, animated: true)
    }
}

@MainActor
private final class MCPServerViewController: SettingsListController {
    private var server: JSONValue
    private let command: SettingsCommand
    private var task: Task<Void, Never>?
    private var loading = false
    private var failure: String?

    init(server: JSONValue, command: @escaping SettingsCommand) {
        self.server = server
        self.command = command
        super.init(title: server["name"].optionalString ?? "MCP")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    private func refreshTools() {
        guard !loading, let id = server["resourceId"].optionalString, !id.isEmpty else { return }
        loading = true
        failure = nil
        render()
        task = Task { [weak self, command] in
            do {
                let value = try await command("mcp.refresh", ["resourceId": .string(id)], 60)
                try Task.checkCancellation()
                guard value["resourceId"].stringValue == id else { throw TodexError.invalid("MCP 刷新响应的资源标识不匹配") }
                self?.server = value
            } catch {
                if !Task.isCancelled { self?.failure = error.localizedDescription }
            }
            guard !Task.isCancelled else { return }
            self?.loading = false
            self?.task = nil
            self?.render()
        }
    }

    private func render() {
        let enabled = server["enabled"].boolValue
        let id = server["resourceId"].stringValue
        sections = [
            SettingsSection(
                title: "服务", footer: "刷新工具会由 Backend 连接此 MCP；调用结果在详情页显示。",
                rows: [
                    SettingsRow(
                        title: enabled ? "可用" : "已禁用",
                        detail: "\(server["transport"].stringValue) · \(server["source"].stringValue)",
                        id: "mcp.server.status"),
                    SettingsRow(
                        title: loading ? "正在发现工具…" : "刷新工具", symbol: "arrow.clockwise", id: "mcp.tools.refresh",
                        enabled: enabled && !loading && !id.isEmpty
                    ) { [weak self] in self?.refreshTools() },
                ])
        ]
        if let error = failure ?? server["error"].optionalString {
            sections.append(
                SettingsSection(
                    title: "服务错误", rows: [SettingsRow(title: error, id: "mcp.server.error", color: .systemRed)]))
        }
        let tools = server["tools"].arrayValue
        let rows = tools.enumerated().map { index, tool in
            SettingsRow(
                title: tool["name"].stringValue, detail: tool["description"].stringValue, id: "mcp.tool.\(index)",
                enabled: enabled && !loading && !tool["name"].stringValue.isEmpty
            ) { [weak self] in
                guard let self else { return }
                navigationController?.pushViewController(
                    MCPToolViewController(resourceID: id, tool: tool, command: command), animated: true)
            }
        }
        sections.append(
            SettingsSection(
                title: "工具",
                rows: rows.isEmpty
                    ? [SettingsRow(title: loading ? "正在读取…" : "尚未列出工具，请先刷新", id: "mcp.tools.empty")] : rows))
        redraw()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            task?.cancel()
            task = nil
        }
    }
}

@MainActor
private final class MCPToolViewController: SettingsListController {
    private let resourceID: String
    private let tool: JSONValue
    private let command: SettingsCommand
    private var arguments: JSONValue = [:]
    private var result: JSONValue?
    private var failure: String?
    private var loading = false
    private var task: Task<Void, Never>?

    init(resourceID: String, tool: JSONValue, command: @escaping SettingsCommand) {
        self.resourceID = resourceID
        self.tool = tool
        self.command = command
        super.init(title: tool["name"].stringValue)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    private func render() {
        sections = [
            SettingsSection(
                title: "工具", footer: tool["description"].optionalString,
                rows: [
                    SettingsRow(
                        title: "参数说明",
                        detail: tool["inputSchema"].isNull
                            ? "此后端未提供参数 Schema，请按工具说明填写 JSON 对象。" : "查看后端提供的 JSON Schema", id: "mcp.tool.schema",
                        enabled: !tool["inputSchema"].isNull
                    ) { [weak self] in
                        guard let self else { return }
                        navigationController?.pushViewController(
                            SettingsTextController(title: "参数 Schema", text: tool["inputSchema"].prettyPrinted),
                            animated: true)
                    },
                    SettingsRow(
                        title: "编辑参数 JSON", detail: String(arguments.prettyPrinted.prefix(400)),
                        id: "mcp.tool.arguments", enabled: !loading
                    ) { [weak self] in self?.editArguments() },
                    SettingsRow(
                        title: loading ? "正在调用…" : "调用工具", symbol: "play", id: "mcp.tool.call", color: Theme.accent,
                        enabled: !loading
                    ) { [weak self] in self?.callTool() },
                ])
        ]
        if let failure {
            sections.append(
                SettingsSection(
                    title: "调用失败", rows: [SettingsRow(title: failure, id: "mcp.tool.error", color: .systemRed)]))
        }
        if let result {
            let isError = result["result"]["isError"].boolValue || result["isError"].boolValue
            sections.append(
                SettingsSection(
                    title: "结果",
                    rows: [
                        SettingsRow(
                            title: isError ? "工具报告错误 · 查看结果" : "查看完整调用结果",
                            detail: String(result.prettyPrinted.prefix(600)), id: "mcp.tool.result",
                            color: isError ? .systemRed : .label
                        ) { [weak self] in
                            self?.navigationController?.pushViewController(
                                SettingsTextController(title: "MCP 结果", text: result.prettyPrinted), animated: true)
                        }
                    ]))
        }
        redraw()
    }

    private func editArguments() {
        let editor = SettingsTextController(
            title: "参数 JSON", text: arguments.prettyPrinted, detail: "请输入 JSON 对象；参数不会自动填入或猜测。", editable: true,
            actionTitle: "保存"
        ) { [weak self] text in
            guard text.utf8.count <= 1_048_576 else { throw TodexError.invalid("参数 JSON 不能超过 1 MiB") }
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            guard case .object = value else { throw TodexError.invalid("工具参数必须是 JSON 对象，例如 {}") }
            self?.arguments = value
            self?.render()
            self?.navigationController?.popViewController(animated: true)
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    private func callTool() {
        guard !loading else { return }
        loading = true
        failure = nil
        result = nil
        render()
        let payload: JSONValue = ["resourceId": .string(resourceID), "toolName": tool["name"], "arguments": arguments]
        task = Task { [weak self, command] in
            do {
                let result = try await command("mcp.call", payload, 90)
                try Task.checkCancellation()
                self?.result = result
            } catch {
                if !Task.isCancelled { self?.failure = error.localizedDescription }
            }
            guard !Task.isCancelled else { return }
            self?.loading = false
            self?.task = nil
            self?.render()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            task?.cancel()
            task = nil
        }
    }
}
