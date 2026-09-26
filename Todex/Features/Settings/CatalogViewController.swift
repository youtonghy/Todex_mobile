import TodexCore
import UIKit

/// The owner binds command to the current conversation and inserts conversationId into payloads.
typealias SettingsCommand = @MainActor (String, JSONValue, TimeInterval) async throws -> JSONValue

@MainActor
final class CatalogViewController: SettingsListController {
    private enum Kind: Int, CaseIterable { case skills, mcp, commands }
    /// Desktop CapabilitiesPanel: a "通用" view aggregated across providers
    /// alongside the per-provider view.
    private enum Scope: Equatable {
        case common
        case provider(String)
    }
    private struct Item {
        var value: JSONValue
        /// IDs of the providers whose catalog returned this item, conversation provider first.
        var providers: [String] = []
    }
    private let connection: BackendConnection
    private let workspace: String
    private let provider: String
    private let providers: [ProviderDescriptor]
    private let client: HTTPClient
    private let command: SettingsCommand
    /// Arguments are resourceId and display name, respectively. Toggles: an
    /// attached skill is removed again (desktop onToggleSkill).
    private let insertSkill: @MainActor (String, String) -> Void
    /// Resource IDs of the skills currently attached to the conversation draft.
    private let attachedSkills: @MainActor () -> Set<String>
    private let insertText: @MainActor (String) -> Void
    private var kind = Kind.skills
    private var scope: Scope
    private var items: [Item] = []
    private var loading = false
    private var errorMessage: String?
    /// Providers whose catalog failed while others succeeded (common view).
    private var partialErrors: [String] = []
    private var task: Task<Void, Never>?
    private var generation = 0
    private let picker = UISegmentedControl(items: ["Skills", "MCP", String(localized: "命令")])
    private let scopeButton = UIButton(type: .system)

    init(
        connection: BackendConnection, workspace: String, provider: String, providers: [ProviderDescriptor],
        command: @escaping @MainActor (String, JSONValue, TimeInterval) async throws -> JSONValue,
        insertSkill: @escaping @MainActor (String, String) -> Void,
        attachedSkills: @escaping @MainActor () -> Set<String>,
        insertText: @escaping @MainActor (String) -> Void
    ) {
        self.connection = connection
        self.workspace = workspace
        self.provider = provider
        self.providers = providers
        self.command = command
        self.insertSkill = insertSkill
        self.attachedSkills = attachedSkills
        self.insertText = insertText
        scope = .provider(provider)
        client = HTTPClient(connection: connection)
        super.init(title: String(localized: "能力目录"))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        picker.selectedSegmentIndex = 0
        picker.accessibilityIdentifier = "catalog.category"
        picker.accessibilityLabel = String(localized: "能力分类")
        picker.addAction(
            UIAction { [weak self] _ in
                guard let self, let kind = Kind(rawValue: picker.selectedSegmentIndex) else { return }
                self.kind = kind
                refresh()
            }, for: .valueChanged)
        scopeButton.showsMenuAsPrimaryAction = true
        scopeButton.accessibilityIdentifier = "catalog.scope"
        scopeButton.contentHorizontalAlignment = .leading
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 104))
        picker.translatesAutoresizingMaskIntoConstraints = false
        scopeButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(scopeButton)
        header.addSubview(picker)
        NSLayoutConstraint.activate([
            scopeButton.topAnchor.constraint(equalTo: header.topAnchor, constant: 4),
            scopeButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            scopeButton.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -20),
            scopeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            picker.topAnchor.constraint(equalTo: scopeButton.bottomAnchor, constant: 4),
            picker.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            picker.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            picker.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            picker.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -8),
        ])
        tableView.tableHeaderView = header
        renderScope()
        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .refresh, primaryAction: UIAction { [weak self] _ in self?.refresh() })
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "catalog.refresh"
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Attachment state may change in a pushed detail page.
        if isViewLoaded, !loading { render() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            generation += 1
            task?.cancel()
            task = nil
        }
    }

    private func displayName(_ id: String) -> String {
        providers.first { $0.id == id }?.displayName ?? id
    }
    /// Scope menu: 通用 plus each provider with its availability (● / ○).
    private func renderScope() {
        let title: String
        switch scope {
        case .common: title = String(localized: "范围：通用（所有 Agent 共享）")
        case .provider(let id): title = String(localized: "范围：\(displayName(id))\(id == provider ? String(localized: "（当前对话）") : "")")
        }
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = Theme.icon("chevron.up.chevron.down", pointSize: 11)
        config.imagePlacement = .trailing
        config.imagePadding = 4
        config.contentInsets = .zero
        scopeButton.configuration = config
        var elements: [UIMenuElement] = [
            UIAction(title: String(localized: "通用"), subtitle: String(localized: "汇总各 Agent 共享的 Skill 与 MCP"), state: scope == .common ? .on : .off) {
                [weak self] _ in self?.setScope(.common)
            }
        ]
        var ids = providers.map(\.id)
        if !ids.contains(provider) { ids.insert(provider, at: 0) }
        for id in ids {
            let descriptor = providers.first { $0.id == id }
            let available = descriptor?.available ?? true
            let action = UIAction(
                title: "\(displayName(id)) \(available ? "●" : "○")",
                subtitle: available
                    ? (id == provider ? String(localized: "当前对话") : nil) : (descriptor?.unavailableReason ?? String(localized: "不可用")),
                state: scope == .provider(id) ? .on : .off
            ) { [weak self] _ in self?.setScope(.provider(id)) }
            elements.append(action)
        }
        scopeButton.menu = UIMenu(children: elements)
    }
    private func setScope(_ value: Scope) {
        guard value != scope else { return }
        scope = value
        renderScope()
        refresh()
    }
    /// Desktop isCommonSource: shared/common catalog sources apply to every provider.
    private static func isCommonSource(_ source: String) -> Bool {
        let value = source.lowercased()
        return value.contains("shared") || value.contains("common")
    }

    private func refresh() {
        generation += 1
        let current = generation
        let requestedKind = kind
        let requestedScope = scope
        let conversationProvider = provider
        task?.cancel()
        loading = true
        errorMessage = nil
        partialErrors = []
        items = []
        render()
        let workspace = workspace
        // The conversation's provider leads so its copy wins when entries are deduplicated.
        let ids: [String]
        switch requestedScope {
        case .common:
            ids = [provider] + providers.filter { $0.available && $0.id != provider }.map(\.id)
        case .provider(let id):
            ids = [id]
        }
        task = Task { [weak self, client, command] in
            do {
                guard !workspace.isEmpty else { throw TodexError.invalid(String(localized: "请先选择工作区")) }
                var loaded: [Item] = []
                var failures: [(String, any Error)] = []
                switch requestedKind {
                case .skills, .commands:
                    let path = requestedKind == .skills ? "/v2/catalog/skills" : "/v2/providers/commands"
                    let key = requestedKind == .skills ? "skills" : "commands"
                    let results = await withTaskGroup(of: (String, Result<JSONValue, any Error>).self) { group in
                        for id in ids {
                            group.addTask {
                                do {
                                    let value = try await client.request(
                                        path: path, query: ["provider": id, "workspace": workspace])
                                    return (id, .success(value))
                                } catch { return (id, .failure(error)) }
                            }
                        }
                        var collected: [String: Result<JSONValue, any Error>] = [:]
                        for await (id, result) in group { collected[id] = result }
                        return collected
                    }
                    try Task.checkCancellation()
                    var index: [String: Int] = [:]
                    for id in ids {
                        guard let result = results[id] else { continue }
                        do {
                            for value in try SettingsResponse.array(try result.get(), key: key) {
                                if requestedScope == .common, requestedKind == .skills,
                                    !Self.isCommonSource(value["source"].stringValue)
                                {
                                    continue
                                }
                                let dedupe =
                                    requestedKind == .skills
                                    ? "\(value["resourceId"].stringValue):\(value["name"].stringValue)"
                                    : value["invocation"].optionalString ?? value["name"].stringValue
                                if let existing = index[dedupe] {
                                    loaded[existing].providers.append(id)
                                } else {
                                    index[dedupe] = loaded.count
                                    loaded.append(Item(value: value, providers: [id]))
                                }
                            }
                        } catch { failures.append((id, error)) }
                    }
                    if failures.count == ids.count, let first = failures.first { throw first.1 }
                case .mcp:
                    // MCP listing is bound to this conversation's provider on the backend;
                    // the common view keeps only shared-source servers from it. Another
                    // agent's scope must not present (or call tools on) those servers.
                    if case .provider(let id) = requestedScope, id != conversationProvider {
                        throw TodexError.invalid(
                            String(localized: "MCP 只能查看当前对话所用 Agent 的服务，请切换到该 Agent 或通用视图。"))
                    }
                    let value = try await command("mcp.list", [:], 45)
                    loaded = try SettingsResponse.array(value, key: "servers")
                        .filter { requestedScope != .common || Self.isCommonSource($0["source"].stringValue) }
                        .map { Item(value: $0) }
                }
                try Task.checkCancellation()
                guard let self, generation == current else { return }
                items = loaded
                partialErrors = failures.map {
                    String(localized: "\(displayName($0.0))：\(SettingsResponse.errorMessage($0.1, feature: String(localized: "所选目录")))")
                }
                loading = false
                task = nil
                refreshControl?.endRefreshing()
                render()
            } catch {
                guard let self, !Task.isCancelled, generation == current else { return }
                errorMessage = SettingsResponse.errorMessage(error, feature: String(localized: "所选目录"))
                loading = false
                task = nil
                refreshControl?.endRefreshing()
                render()
            }
        }
    }

    private func render() {
        navigationItem.rightBarButtonItem?.isEnabled = !loading
        let heading: String
        switch scope {
        case .common: heading = String(localized: "通用 · \(connection.name)")
        case .provider(let id): heading = "\(displayName(id)) · \(connection.name)"
        }
        let footer =
            scope == .common && kind == .mcp
            ? String(localized: "\(workspace)\nMCP 列表由当前对话的 Agent 提供，通用视图仅显示其中共享来源的服务。") : workspace
        sections = [SettingsSection(title: heading, footer: footer, rows: [])]
        if loading {
            sections.append(
                SettingsSection(
                    title: String(localized: "状态"),
                    rows: [
                        SettingsRow(
                            title: String(localized: "正在读取…"), symbol: "arrow.triangle.2.circlepath", id: "catalog.loading", activity: true
                        )
                    ]))
        }
        if let errorMessage {
            sections.append(
                SettingsSection(
                    title: String(localized: "读取失败"),
                    rows: [
                        SettingsRow(
                            title: errorMessage, detail: String(localized: "点按重试"), symbol: "exclamationmark.triangle",
                            id: "catalog.error", color: .systemRed
                        ) { [weak self] in self?.refresh() }
                    ]))
        }
        if !partialErrors.isEmpty {
            sections.append(
                SettingsSection(
                    title: String(localized: "部分 Agent 读取失败"),
                    rows: partialErrors.enumerated().map { index, text in
                        SettingsRow(
                            title: text, detail: String(localized: "点按重试"), symbol: "exclamationmark.triangle",
                            id: "catalog.partial.\(index)", color: .systemOrange
                        ) { [weak self] in self?.refresh() }
                    }))
        }
        let attached = kind == .skills ? attachedSkills() : []
        let rows = items.enumerated().map { index, entry in
            let item = entry.value
            let id = item["resourceId"].optionalString ?? String(index)
            let isAttached = kind == .skills && attached.contains(id)
            var detail = item["description"].stringValue
            switch kind {
            case .skills:
                let state =
                    !item["valid"].boolValue
                    ? String(localized: "无效") : item["active"].boolValue ? String(localized: "当前启用") : !item["shadowedBy"].isNull ? String(localized: "被覆盖") : String(localized: "未启用")
                detail += "\n\(state) · \(item["scope"].stringValue) · \(item["source"].stringValue)"
                if isAttached { detail += String(localized: "\n已附加到草稿 · 点按移除") }
                if let error = item["error"].optionalString { detail += "\n\(error)" }
            case .mcp:
                detail +=
                    "\n\(item["transport"].stringValue) · \(item["scope"].stringValue) · \(item["source"].stringValue)"
                if let error = item["error"].optionalString { detail += "\n\(error)" }
            case .commands:
                detail += "\n\(item["invocation"].stringValue)"
                if let hint = item["argumentHint"].optionalString { detail += " \(hint)" }
            }
            if scope == .common, !entry.providers.isEmpty {
                detail += String(localized: "\n可用于：") + entry.providers.map(displayName).joined(separator: String(localized: "、"))
            }
            return SettingsRow(
                title: item["name"].optionalString ?? String(localized: "未命名"),
                detail: detail.trimmingCharacters(in: .whitespacesAndNewlines), id: "catalog.item.\(id)",
                enabled: !loading, checked: isAttached
            ) { [weak self] in
                guard let self else { return }
                switch kind {
                case .skills:
                    if isAttached {
                        insertSkill(id, item["name"].stringValue)
                        render()
                    } else {
                        openSkill(item, from: entry.providers.first)
                    }
                case .mcp:
                    navigationController?.pushViewController(
                        MCPServerViewController(server: item, command: command), animated: true)
                case .commands: openCommand(item)
                }
            }
        }
        if !rows.isEmpty {
            sections.append(SettingsSection(title: String(localized: "目录"), rows: rows))
        } else if !loading && errorMessage == nil {
            sections.append(SettingsSection(title: String(localized: "目录"), rows: [SettingsRow(title: String(localized: "没有找到可用项目"), id: "catalog.empty")]))
        }
        redraw()
    }

    /// `source` is the provider whose catalog listed the skill (common view).
    private func openSkill(_ item: JSONValue, from source: String?) {
        guard item["valid"].boolValue, let id = item["resourceId"].optionalString, !id.isEmpty else {
            showError(TodexError.invalid(item["error"].optionalString ?? String(localized: "此 Skill 无效或缺少资源标识")))
            return
        }
        generation += 1
        let current = generation
        task?.cancel()
        loading = true
        errorMessage = nil
        render()
        let skillProvider: String
        switch scope {
        case .common: skillProvider = source ?? provider
        case .provider(let value): skillProvider = value
        }
        let query = ["provider": skillProvider, "workspace": workspace]
        task = Task { [weak self, client] in
            do {
                let value = try await client.request(path: "/v2/catalog/skills/\(HTTPClient.segment(id))", query: query)
                try Task.checkCancellation()
                guard let content = value["content"].optionalString else { throw TodexError.invalid(String(localized: "后端未返回 Skill 正文")) }
                guard let self, generation == current else { return }
                loading = false
                task = nil
                render()
                let name = item["name"].stringValue
                let detail = SettingsTextController(
                    title: name, text: content,
                    detail: String(localized: "\(item["source"].stringValue) · 附加后，Backend 在下一条消息读取并注入此 Skill；再次点按目录中的已附加项可移除。"),
                    actionTitle: String(localized: "附加")
                ) { [weak self] _ in
                    guard let self else { throw CancellationError() }
                    // insertSkill toggles, so never call it for an already attached skill here.
                    guard !attachedSkills().contains(id) else { throw TodexError.invalid(String(localized: "此 Skill 已附加到待发送消息")) }
                    insertSkill(id, name)
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
            showError(TodexError.invalid(String(localized: "命令缺少后端提供的 invocation，无法插入")))
            return
        }
        let detail = SettingsTextController(
            title: item["name"].stringValue, text: item.prettyPrinted, detail: String(localized: "将原样插入 \(invocation)。可在消息输入框补充参数。"),
            actionTitle: String(localized: "插入")
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
                guard value["resourceId"].stringValue == id else { throw TodexError.invalid(String(localized: "MCP 刷新响应的资源标识不匹配")) }
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
                title: String(localized: "服务"), footer: String(localized: "刷新工具会由 Backend 连接此 MCP；调用结果在详情页显示。"),
                rows: [
                    SettingsRow(
                        title: enabled ? String(localized: "可用") : String(localized: "已禁用"),
                        detail: "\(server["transport"].stringValue) · \(server["source"].stringValue)",
                        id: "mcp.server.status"),
                    SettingsRow(
                        title: loading ? String(localized: "正在发现工具…") : String(localized: "刷新工具"), symbol: "arrow.clockwise", id: "mcp.tools.refresh",
                        enabled: enabled && !loading && !id.isEmpty
                    ) { [weak self] in self?.refreshTools() },
                ])
        ]
        if let error = failure ?? server["error"].optionalString {
            sections.append(
                SettingsSection(
                    title: String(localized: "服务错误"), rows: [SettingsRow(title: error, id: "mcp.server.error", color: .systemRed)]))
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
                title: String(localized: "工具"),
                rows: rows.isEmpty
                    ? [SettingsRow(title: loading ? String(localized: "正在读取…") : String(localized: "尚未列出工具，请先刷新"), id: "mcp.tools.empty")] : rows))
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
                title: String(localized: "工具"), footer: tool["description"].optionalString,
                rows: [
                    SettingsRow(
                        title: String(localized: "参数说明"),
                        detail: tool["inputSchema"].isNull
                            ? String(localized: "此后端未提供参数 Schema，请按工具说明填写 JSON 对象。") : String(localized: "查看后端提供的 JSON Schema"), id: "mcp.tool.schema",
                        enabled: !tool["inputSchema"].isNull
                    ) { [weak self] in
                        guard let self else { return }
                        navigationController?.pushViewController(
                            SettingsTextController(title: String(localized: "参数 Schema"), text: tool["inputSchema"].prettyPrinted),
                            animated: true)
                    },
                    SettingsRow(
                        title: String(localized: "编辑参数 JSON"), detail: String(arguments.prettyPrinted.prefix(400)),
                        id: "mcp.tool.arguments", enabled: !loading
                    ) { [weak self] in self?.editArguments() },
                    SettingsRow(
                        title: loading ? String(localized: "正在调用…") : String(localized: "调用工具"), symbol: "play", id: "mcp.tool.call", color: Theme.accent,
                        enabled: !loading
                    ) { [weak self] in self?.callTool() },
                ])
        ]
        if let failure {
            sections.append(
                SettingsSection(
                    title: String(localized: "调用失败"), rows: [SettingsRow(title: failure, id: "mcp.tool.error", color: .systemRed)]))
        }
        if let result {
            let isError = result["result"]["isError"].boolValue || result["isError"].boolValue
            sections.append(
                SettingsSection(
                    title: String(localized: "结果"),
                    rows: [
                        SettingsRow(
                            title: isError ? String(localized: "工具报告错误 · 查看结果") : String(localized: "查看完整调用结果"),
                            detail: String(result.prettyPrinted.prefix(600)), id: "mcp.tool.result",
                            color: isError ? .systemRed : .label
                        ) { [weak self] in
                            self?.navigationController?.pushViewController(
                                SettingsTextController(title: String(localized: "MCP 结果"), text: result.prettyPrinted), animated: true)
                        }
                    ]))
        }
        redraw()
    }

    private func editArguments() {
        let editor = SettingsTextController(
            title: String(localized: "参数 JSON"), text: arguments.prettyPrinted, detail: String(localized: "请输入 JSON 对象；参数不会自动填入或猜测。"), editable: true,
            actionTitle: String(localized: "保存")
        ) { [weak self] text in
            guard text.utf8.count <= 1_048_576 else { throw TodexError.invalid(String(localized: "参数 JSON 不能超过 1 MiB")) }
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            guard case .object = value else { throw TodexError.invalid(String(localized: "工具参数必须是 JSON 对象，例如 {}")) }
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
