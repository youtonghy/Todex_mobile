import Foundation
import TodexCore
import UIKit

/// cc-switch 同款的多供应商/账户管理：每个 Agent 一份档案库。独占型（Codex、
/// Claude Code、Grok Build）激活时改写该 Agent 的全局配置文件；叠加型（Pi、OpenCode）
/// 保存档案即把 provider 节点写入全局配置，可多个并存，界面只保留编辑入口。
/// settingsConfig 中的密钥由后端脱敏返回，原样写回即保留已存密钥。
@MainActor
final class AgentProvidersViewController: SettingsListController {
    private static let agentIDs = ["codex", "claude-code", "grok-build", "pi", "opencode"]
    private static let agentTitles: [String: String] = [
        "codex": "Codex CLI",
        "claude-code": "Claude Code",
        "grok-build": "Grok Build",
        "pi": "Pi",
        "opencode": "OpenCode",
    ]
    private static let additiveAgents: Set<String> = ["pi", "opencode"]

    private let connection: BackendConnection
    private let api: APIClient
    private var buckets: [String: JSONValue] = [:]
    private var loading = false
    private var submitting = false
    private var errorMessage: String?
    private var requestTask: Task<Void, Never>?
    private var generation = 0

    init(connection: BackendConnection) {
        self.connection = connection
        api = APIClient(connection: connection)
        super.init(title: String(localized: "Agent 账户"))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .refresh, primaryAction: UIAction { [weak self] _ in self?.refresh() })
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "agentProviders.refresh"
        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            generation += 1
            requestTask?.cancel()
            requestTask = nil
            loading = false
            submitting = false
        }
    }

    private func refresh() {
        guard !submitting else {
            refreshControl?.endRefreshing()
            return
        }
        generation += 1
        let current = generation
        requestTask?.cancel()
        loading = true
        errorMessage = nil
        render()
        requestTask = Task { [weak self, api] in
            do {
                let value = try await api.agentProviders()
                try Task.checkCancellation()
                var buckets: [String: JSONValue] = [:]
                for (agent, block) in value["agents"].objectValue {
                    buckets[agent] = block
                }
                guard let self, generation == current else { return }
                self.buckets = buckets
                loading = false
                requestTask = nil
                render()
            } catch {
                guard let self, !Task.isCancelled, generation == current else { return }
                buckets = [:]
                errorMessage = SettingsResponse.errorMessage(error, feature: String(localized: " Agent 账户管理"))
                loading = false
                requestTask = nil
                render()
            }
            self?.refreshControl?.endRefreshing()
        }
    }

    private func mutate(_ action: @escaping @Sendable (APIClient) async throws -> Void) {
        guard !submitting else { return }
        generation += 1
        let current = generation
        submitting = true
        errorMessage = nil
        render()
        requestTask = Task { [weak self, api] in
            do {
                try await action(api)
                try Task.checkCancellation()
                let value = try await api.agentProviders()
                try Task.checkCancellation()
                var buckets: [String: JSONValue] = [:]
                for (agent, block) in value["agents"].objectValue {
                    buckets[agent] = block
                }
                guard let self, generation == current else { return }
                self.buckets = buckets
                submitting = false
                requestTask = nil
                render()
            } catch {
                guard let self, !Task.isCancelled, generation == current else { return }
                submitting = false
                requestTask = nil
                errorMessage = SettingsResponse.errorMessage(error, feature: String(localized: " Agent 账户操作"))
                render()
            }
        }
    }

    // MARK: - 操作

    private func providerActions(agent: String, bucket: JSONValue, profile: JSONValue) {
        let id = profile["id"].stringValue
        let name = profile["name"].stringValue
        let isCurrent = bucket["currentProviderId"].stringValue == id
        let additive = Self.additiveAgents.contains(agent)
        let alert = UIAlertController(title: name, message: nil, preferredStyle: .actionSheet)

        // 叠加型 Agent 的供应商保存即全部生效，不提供"设为当前"；独占型才需要
        // 通过激活改写全局配置。
        if !additive, !isCurrent {
            alert.addAction(UIAlertAction(title: String(localized: "设为当前"), style: .default) { [weak self] _ in
                self?.submitActivate(agent: agent, id: id)
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "获取模型列表"), style: .default) { [weak self] _ in
            self?.fetchModels(agent: agent, id: id, name: name)
        })
        alert.addAction(UIAlertAction(title: String(localized: "编辑"), style: .default) { [weak self] _ in
            self?.openEditor(agent: agent, kind: .edit(profile))
        })
        alert.addAction(UIAlertAction(title: String(localized: "删除"), style: .destructive) { [weak self] _ in
            self?.confirm(
                title: String(localized: "删除供应商“\(name)”？"),
                message: additive ? String(localized: "将同时从 live 配置中移除该节点。") : String(localized: "档案将被移除；当前生效的 live 配置保持不变。"),
                destructive: true
            ) { [weak self] in
                self?.mutate { api in _ = try await api.deleteAgentProvider(agent: agent, id: id) }
            }
        })
        alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        present(alert, animated: true)
    }

    private func submitActivate(agent: String, id: String) {
        confirm(
            title: String(localized: "切换供应商？"),
            message: String(localized: "将改写该 Agent 的全局配置文件，对 TodeX 内外的新会话同时生效；运行中的会话不受影响。")
        ) { [weak self] in
            self?.mutate { api in
                _ = try await api.activateAgentProvider(agent: agent, id: id)
            }
        }
    }

    private func fetchModels(agent: String, id: String, name: String) {
        navigationItem.rightBarButtonItem?.isEnabled = false
        Task { [weak self, api] in
            defer { self?.navigationItem.rightBarButtonItem?.isEnabled = true }
            do {
                let value = try await api.agentProviderModels(agent: agent, id: id)
                let lines = value["models"].arrayValue
                    .map { $0["name"].optionalString ?? $0["id"].stringValue }
                    .joined(separator: "\n")
                self?.navigationController?.pushViewController(
                    SettingsTextController(
                        title: String(localized: "\(name) 模型"),
                        text: lines.isEmpty ? String(localized: "未返回模型") : lines),
                    animated: true)
            } catch {
                self?.errorMessage = SettingsResponse.errorMessage(error, feature: String(localized: " 模型列表"))
                self?.render()
            }
        }
    }

    /// Desktop ProviderEditor parity: new, edit, and adopting an unmanaged
    /// live node all share one form/JSON editor.
    private func openEditor(agent: String, kind: AgentProviderEditorViewController.Kind) {
        let editor = AgentProviderEditorViewController(
            agent: agent, agentTitle: Self.agentTitles[agent] ?? agent, kind: kind, api: api
        ) { [weak self] id, name, settings in
            guard let self else { throw CancellationError() }
            try await save(agent: agent, id: id, name: name, settings: settings, adopt: kind.isAdopt)
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    private func save(agent: String, id: String, name: String, settings: JSONValue, adopt: Bool) async throws {
        if adopt {
            // Adopting first registers the live node; an existing profile of the
            // same id (409) is fine because the upsert below overwrites it.
            do {
                _ = try await api.importLiveAgentProvider(agent: agent, id: id, name: name)
            } catch TodexError.server(let code, _) where ["409", "CONFLICT"].contains(code.uppercased()) {}
        }
        // The editor pops on success; viewWillAppear then reloads the list.
        _ = try await api.upsertAgentProvider(
            agent: agent, id: id, profile: ["name": .string(name), "settingsConfig": settings])
    }

    private func importLive(agent: String, id: String = "imported", name: String = String(localized: "已导入")) {
        mutate { api in _ = try await api.importLiveAgentProvider(agent: agent, id: id, name: name) }
    }

    private static func modelSummary(_ ids: [String]) -> String {
        guard !ids.isEmpty else { return "" }
        let shown = ids.prefix(3).joined(separator: ", ")
        return ids.count > 3 ? String(localized: "\(shown) 等 \(ids.count) 个模型") : shown
    }

    // MARK: - 渲染

    private func render() {
        navigationItem.rightBarButtonItem?.isEnabled = !loading && !submitting
        var sections = [
            SettingsSection(
                title: String(localized: "当前后端"),
                footer: String(localized: "独占型（Codex、Claude Code、Grok Build）激活时改写全局配置文件，对 TodeX 内外的新会话同时生效；叠加型（Pi、OpenCode）保存即写入全局配置、可多个并存，「默认」为该 Agent 的启动默认选中，在 Agent 侧修改。"),
                rows: [
                    SettingsRow(
                        title: connection.name, detail: connection.serverURL, symbol: "server.rack",
                        id: "agentProviders.backend")
                ])
        ]
        if loading || submitting {
            sections.append(
                SettingsSection(
                    title: String(localized: "状态"),
                    rows: [
                        SettingsRow(
                            title: submitting ? String(localized: "正在提交…") : String(localized: "正在读取供应商…"),
                            symbol: "arrow.triangle.2.circlepath", id: "agentProviders.loading",
                            activity: true)
                    ]))
        }
        if let errorMessage {
            sections.append(
                SettingsSection(
                    title: String(localized: "提示"),
                    rows: [
                        SettingsRow(
                            title: errorMessage, detail: String(localized: "点按刷新"), symbol: "exclamationmark.triangle",
                            id: "agentProviders.error", color: .systemRed,
                            enabled: !loading && !submitting
                        ) { [weak self] in self?.refresh() }
                    ]))
        }

        for agent in Self.agentIDs {
            guard let bucket = buckets[agent] else { continue }
            let title = Self.agentTitles[agent] ?? agent
            let additive = Self.additiveAgents.contains(agent)
            var rows: [SettingsRow] = []

            // 叠加型 Agent 的"默认"取 live.selection——settings.json 里的真实
            // 默认选中，比在 Agent 侧改动后可能漂移的 currentProviderId 更准。
            let selection = bucket["live"]["selection"]
            for profile in bucket["providers"].arrayValue {
                let id = profile["id"].stringValue
                let isCurrent = !additive && bucket["currentProviderId"].stringValue == id
                let isDefault = additive && selection["providerId"].stringValue == id
                let defaultModel = isDefault ? selection["modelId"].optionalString : nil
                let modelIDs = additive ? AgentProviderForm.modelIDs(agent: agent, settings: profile["settingsConfig"]) : []
                let detail = [
                    AgentProviderForm.baseURL(agent: agent, settings: profile["settingsConfig"]),
                    Self.modelSummary(modelIDs),
                    isCurrent ? String(localized: "当前") : "",
                    isDefault ? String(localized: "默认") : "",
                    defaultModel ?? "",
                ].filter { !$0.isEmpty }.joined(separator: " · ")
                rows.append(
                    SettingsRow(
                        title: profile["name"].stringValue, detail: detail,
                        symbol: isCurrent || isDefault ? "checkmark.circle.fill" : "person.crop.circle",
                        id: "agentProviders.\(agent).\(id)",
                        enabled: !loading && !submitting, checked: isCurrent || isDefault
                    ) { [weak self] in
                        self?.providerActions(agent: agent, bucket: bucket, profile: profile)
                    })
            }

            // 叠加型 Agent：live 文件里未托管的节点显示为可收编项。
            if additive {
                for nodeId in bucket["live"]["unmanagedProviders"].arrayValue.compactMap(\.optionalString) {
                    let isDefault = selection["providerId"].stringValue == nodeId
                    let node = bucket["live"]["providers"][nodeId]
                    let detail = [
                        AgentProviderForm.baseURL(agent: agent, settings: node),
                        Self.modelSummary(AgentProviderForm.modelIDs(agent: agent, settings: node)),
                        isDefault ? String(localized: "未托管 · 默认 · 点按收编") : String(localized: "未托管 · 点按收编"),
                    ].filter { !$0.isEmpty }.joined(separator: " · ")
                    rows.append(
                        SettingsRow(
                            title: nodeId, detail: detail,
                            symbol: "questionmark.circle", id: "agentProviders.\(agent).unmanaged.\(nodeId)",
                            enabled: !loading && !submitting
                        ) { [weak self] in
                            self?.openEditor(agent: agent, kind: .adopt(nodeId: nodeId, node: node))
                        })
                }
            } else {
                // 独占型 Agent：live 与当前档案不一致时提供导入口。
                let live = bucket["live"]
                let mismatch = live["configured"].boolValue && !live["matchesCurrent"].boolValue
                if mismatch {
                    rows.append(
                        SettingsRow(
                            title: String(localized: "导入当前生效配置"), detail: String(localized: "live 配置与所选供应商不一致"),
                            symbol: "square.and.arrow.down", id: "agentProviders.\(agent).importLive",
                            color: Theme.accent, enabled: !loading && !submitting
                        ) { [weak self] in self?.importLive(agent: agent) })
                }
            }

            rows.append(
                SettingsRow(
                    title: String(localized: "添加供应商"), symbol: "plus.circle", id: "agentProviders.\(agent).add",
                    color: Theme.accent, enabled: !loading && !submitting
                ) { [weak self] in self?.openEditor(agent: agent, kind: .new) })
            sections.append(SettingsSection(title: title, rows: rows))
        }

        if buckets.isEmpty && !loading && errorMessage == nil {
            sections.append(
                SettingsSection(
                    title: String(localized: "供应商"), rows: [SettingsRow(title: String(localized: "后端未返回供应商数据"), id: "agentProviders.empty")]))
        }
        self.sections = sections
        redraw()
    }
}

/// Provider editor: a structured form per agent (desktop ProviderEditor) with a
/// JSON mode for fields the form does not model. The form always rebuilds from
/// the source settingsConfig, so unknown keys survive either mode.
@MainActor
final class AgentProviderEditorViewController: SettingsListController {
    enum Kind {
        case new
        case edit(JSONValue)
        case adopt(nodeId: String, node: JSONValue)
        var isAdopt: Bool { if case .adopt = self { true } else { false } }
    }

    private let agent: String
    private let agentTitle: String
    private let kind: Kind
    private let api: APIClient
    private let onSave: @MainActor (String, String, JSONValue) async throws -> Void
    /// settingsConfig the form merges into; JSON edits replace it.
    private var source: JSONValue?
    private var form: AgentProviderForm.Values
    private var providerID: String
    private var jsonMode = false
    private var jsonText: String
    private var formDirty = false
    private var fetchedModels: [(id: String, name: String)] = []
    private var fetching = false
    private var saving = false
    private var message: String?
    private var task: Task<Void, Never>?

    init(
        agent: String, agentTitle: String, kind: Kind, api: APIClient,
        onSave: @escaping @MainActor (String, String, JSONValue) async throws -> Void
    ) {
        self.agent = agent
        self.agentTitle = agentTitle
        self.kind = kind
        self.api = api
        self.onSave = onSave
        switch kind {
        case .new:
            source = nil
            providerID = ""
            form = AgentProviderForm.extract(agent: agent, settings: nil)
        case .edit(let profile):
            source = profile["settingsConfig"]
            providerID = profile["id"].stringValue
            form = AgentProviderForm.extract(
                agent: agent, name: profile["name"].stringValue, settings: profile["settingsConfig"])
        case .adopt(let nodeId, let node):
            source = node
            providerID = nodeId
            let name = node["name"].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            form = AgentProviderForm.extract(agent: agent, name: name.isEmpty ? nodeId : name, settings: node)
        }
        jsonText = (source ?? .object([:])).prettyPrinted
        let title =
            switch kind {
            case .new: String(localized: "添加供应商")
            case .edit: String(localized: "编辑供应商")
            case .adopt: String(localized: "收编供应商")
            }
        super.init(title: title)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "保存"), primaryAction: UIAction { [weak self] _ in self?.save() })
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "agentProviders.editor.save"
        render()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            task?.cancel()
            task = nil
        }
    }

    private var idLocked: Bool { if case .new = kind { false } else { true } }
    private var busy: Bool { saving || fetching }

    private func update(_ change: (inout AgentProviderForm.Values) -> Void) {
        change(&form)
        formDirty = true
        message = nil
        render()
    }

    // MARK: - 模式与保存

    private func setJSONMode(_ enabled: Bool) {
        guard enabled != jsonMode else { return }
        if enabled {
            if !idLocked || formDirty {
                jsonText = AgentProviderForm.build(agent: agent, form: form, existing: source).prettyPrinted
                formDirty = false
            }
        } else {
            // Returning to the form re-reads the JSON so its edits are not lost.
            do {
                let parsed = try Self.parseSettings(jsonText)
                if parsed != AgentProviderForm.build(agent: agent, form: form, existing: source) {
                    let name = form.name
                    source = parsed
                    form = AgentProviderForm.extract(agent: agent, name: name, settings: parsed)
                }
            } catch {
                message = error.localizedDescription
                render()
                return
            }
        }
        jsonMode = enabled
        message = nil
        render()
    }

    private static func parseSettings(_ text: String) throws -> JSONValue {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
            case .object = value
        else { throw TodexError.invalid(String(localized: "配置必须是 JSON 对象")) }
        return value
    }

    private func save() {
        guard !busy else { return }
        let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !id.isEmpty else {
            message = String(localized: "名称与供应商 ID 必填")
            render()
            return
        }
        let settings: JSONValue
        do {
            if jsonMode {
                settings = try Self.parseSettings(jsonText)
            } else {
                if let invalid = AgentProviderForm.validate(agent: agent, form: form, existing: source) { throw invalid }
                settings = AgentProviderForm.build(agent: agent, form: form, existing: source)
            }
        } catch {
            message = error.localizedDescription
            render()
            return
        }
        saving = true
        message = nil
        render()
        task = Task { [weak self, onSave] in
            do {
                try await onSave(id, name, settings)
                try Task.checkCancellation()
                guard let self else { return }
                saving = false
                task = nil
                navigationController?.popViewController(animated: true)
            } catch {
                guard let self, !Task.isCancelled else { return }
                saving = false
                task = nil
                message = SettingsResponse.errorMessage(error, feature: String(localized: " Agent 账户管理"))
                render()
            }
        }
    }

    // MARK: - 模型

    /// POST preview: the backend resolves masked secrets against the stored
    /// profile or the live node of the same id, so this works before saving.
    private func fetchModels() {
        guard !busy else { return }
        let settings: JSONValue
        do {
            settings =
                jsonMode
                ? try Self.parseSettings(jsonText) : AgentProviderForm.build(agent: agent, form: form, existing: source)
        } catch {
            message = error.localizedDescription
            render()
            return
        }
        let id = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        fetching = true
        message = nil
        render()
        task = Task { [weak self, api, agent] in
            do {
                let value = try await api.previewAgentProviderModels(
                    agent: agent, id: id.isEmpty ? "preview" : id, settingsConfig: settings)
                try Task.checkCancellation()
                guard let self else { return }
                var seen = Set<String>()
                fetchedModels = value["models"].arrayValue.compactMap { model in
                    let id = model["id"].stringValue
                    guard !id.isEmpty, seen.insert(id).inserted else { return nil }
                    return (id, model["name"].stringValue)
                }
                fetching = false
                task = nil
                render()
                if fetchedModels.isEmpty {
                    message = String(localized: "未返回模型")
                    render()
                } else if !jsonMode {
                    openModelPicker()
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                fetching = false
                task = nil
                message = SettingsResponse.errorMessage(error, feature: String(localized: " 模型列表"))
                render()
            }
        }
    }

    private func setModelIDs(_ ids: [String]) {
        update { form in
            form.models = ids.map { id in form.models.first { $0.id == id } ?? AgentProviderForm.Model(id: id) }
        }
    }

    private func openModelPicker() {
        var options = fetchedModels
        for model in form.models where !options.contains(where: { $0.id == model.id }) {
            options.append((model.id, ""))
        }
        let picker = AgentProviderModelPickerViewController(
            options: options, selected: form.models.map(\.id)
        ) { [weak self] ids in self?.setModelIDs(ids) }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func addModels() {
        editField(title: String(localized: "添加模型（逗号或空格分隔）"), value: "", id: "agentProviders.editor.addModel") { [weak self] text in
            guard let self else { return }
            let current = form.models.map(\.id)
            var additions: [String] = []
            for id in AgentProviderForm.modelIDs(fromText: text) where !current.contains(id) && !additions.contains(id) {
                additions.append(id)
            }
            guard !additions.isEmpty else { return }
            setModelIDs(current + additions)
        }
    }

    private func openModel(_ id: String) {
        guard let model = form.models.first(where: { $0.id == id }) else { return }
        let detail = AgentProviderModelViewController(
            agent: agent, model: model,
            onChange: { [weak self] updated in
                self?.update { form in
                    if let index = form.models.firstIndex(where: { $0.id == updated.id }) { form.models[index] = updated }
                }
            },
            onRemove: { [weak self] in
                self?.update { $0.models.removeAll { $0.id == id } }
            })
        navigationController?.pushViewController(detail, animated: true)
    }

    // MARK: - 字段

    private func textRow(
        _ title: String, value: String, id: String, placeholder: String = String(localized: "未填写"), keyboard: UIKeyboardType = .default,
        apply: @escaping @MainActor (inout AgentProviderForm.Values, String) -> Void
    ) -> SettingsRow {
        SettingsRow(title: title, detail: value.isEmpty ? placeholder : value, id: id, enabled: !busy) { [weak self] in
            self?.editField(title: title, value: value, id: "\(id).input", keyboard: keyboard) { [weak self] text in
                self?.update { apply(&$0, text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
        }
    }

    /// Never echo a secret: the backend returns stored keys masked, and a typed
    /// key is only acknowledged as present.
    private func apiKeyRow() -> SettingsRow {
        let key = form.apiKey
        let detail =
            key.isEmpty
            ? String(localized: "未填写") : key == AgentProviderForm.maskedSecret ? String(localized: "已保存 · 保持不变即沿用已存密钥") : String(localized: "已填写 · 保存后生效")
        return SettingsRow(
            title: String(localized: "API 密钥"), detail: detail, symbol: "key", id: "agentProviders.editor.apiKey", enabled: !busy
        ) { [weak self] in
            self?.editField(title: String(localized: "API 密钥"), value: key, id: "agentProviders.editor.apiKey.input", secure: true) {
                [weak self] text in
                self?.update { $0.apiKey = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
    }

    private func chooseContextWindow(current: String, apply: @escaping @MainActor (String) -> Void) {
        let presets = AgentProviderForm.contextPresets.map { ($0.value, String(localized: "\($0.label)（\($0.value)）")) }
        choose(title: String(localized: "上下文窗口"), choices: presets + [("custom", String(localized: "自定义…")), ("clear", String(localized: "清除"))], selected: current) {
            [weak self] value in
            switch value {
            case "custom":
                self?.editField(
                    title: String(localized: "上下文窗口"), value: current, id: "agentProviders.editor.contextWindow.input",
                    keyboard: .numberPad
                ) { text in apply(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            case "clear": apply("")
            default: apply(value)
            }
        }
    }

    // MARK: - 渲染

    private func render() {
        navigationItem.rightBarButtonItem?.isEnabled = !busy
        navigationItem.hidesBackButton = saving
        var sections: [SettingsSection] = []
        var basics = [
            SettingsRow(
                title: String(localized: "编辑方式"), detail: jsonMode ? "JSON" : String(localized: "表单"), symbol: jsonMode ? "curlybraces" : "list.bullet.rectangle",
                id: "agentProviders.editor.mode", enabled: !busy
            ) { [weak self] in
                guard let self else { return }
                choose(
                    title: String(localized: "编辑方式"), choices: [("form", String(localized: "表单")), ("json", "JSON")], selected: jsonMode ? "json" : "form"
                ) { [weak self] value in self?.setJSONMode(value == "json") }
            },
            textRow(String(localized: "名称"), value: form.name, id: "agentProviders.editor.name") { $0.name = $1 },
        ]
        basics.append(
            idLocked
                ? SettingsRow(title: String(localized: "供应商 ID"), detail: providerID, id: "agentProviders.editor.id")
                : SettingsRow(
                    title: String(localized: "供应商 ID"), detail: providerID.isEmpty ? String(localized: "未填写，如 my-provider") : providerID,
                    id: "agentProviders.editor.id", enabled: !busy
                ) { [weak self] in
                    guard let self else { return }
                    editField(title: String(localized: "供应商 ID"), value: providerID, id: "agentProviders.editor.id.input") { [weak self] text in
                        self?.providerID = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        self?.render()
                    }
                })
        let footer: String? =
            switch kind {
            case .adopt: String(localized: "已从当前配置解析供应商与模型信息，可修改后保存。")
            default: nil
            }
        sections.append(SettingsSection(title: agentTitle, footer: footer, rows: basics))

        if saving || fetching {
            sections.append(
                SettingsSection(
                    title: String(localized: "状态"),
                    rows: [
                        SettingsRow(
                            title: saving ? String(localized: "正在保存…") : String(localized: "正在获取模型列表…"), symbol: "arrow.triangle.2.circlepath",
                            id: "agentProviders.editor.loading", activity: true)
                    ]))
        }
        if let message {
            sections.append(
                SettingsSection(
                    title: String(localized: "提示"),
                    rows: [
                        SettingsRow(
                            title: message, symbol: "exclamationmark.triangle", id: "agentProviders.editor.error",
                            color: .systemRed)
                    ]))
        }

        if jsonMode {
            let preview = jsonText.split(separator: "\n", omittingEmptySubsequences: false).prefix(6)
                .joined(separator: "\n")
            sections.append(
                SettingsSection(
                    title: String(localized: "配置（JSON）"), footer: String(localized: "密钥显示为掩码；保持掩码不变即沿用已存密钥。"),
                    rows: [
                        SettingsRow(
                            title: String(localized: "编辑 JSON"), detail: preview, symbol: "curlybraces", id: "agentProviders.editor.json",
                            enabled: !busy
                        ) { [weak self] in self?.editJSON() }
                    ]))
        } else {
            sections.append(contentsOf: formSections())
        }
        self.sections = sections
        redraw()
    }

    private func editJSON() {
        let editor = SettingsTextController(
            title: String(localized: "配置（JSON）"), text: jsonText, detail: String(localized: "填写该 Agent 的供应商配置 JSON 对象。"), editable: true,
            actionTitle: String(localized: "完成")
        ) { [weak self] text in
            _ = try Self.parseSettings(text)
            guard let self else { return }
            jsonText = text
            message = nil
            render()
            navigationController?.popViewController(animated: true)
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    private func formSections() -> [SettingsSection] {
        let isGrok = agent == "grok-build"
        let subscription = isGrok && form.authMode == .subscription
        let additive = agent == "pi" || agent == "opencode"
        var rows: [SettingsRow] = []
        if isGrok {
            rows.append(
                SettingsRow(
                    title: String(localized: "认证方式"), detail: subscription ? String(localized: "官方订阅（grok login）") : String(localized: "API 密钥"),
                    id: "agentProviders.editor.authMode", enabled: !busy
                ) { [weak self] in
                    self?.choose(
                        title: String(localized: "认证方式"), choices: [("subscription", String(localized: "官方订阅（grok login）")), ("api", String(localized: "API 密钥"))],
                        selected: subscription ? "subscription" : "api"
                    ) { [weak self] value in
                        guard let mode = AgentProviderForm.GrokAuthMode(rawValue: value) else { return }
                        self?.update { $0.authMode = mode }
                    }
                })
        }
        if !subscription {
            rows.append(
                textRow(
                    "Base URL", value: form.baseURL, id: "agentProviders.editor.baseURL",
                    placeholder: isGrok ? String(localized: "留空使用 xAI 官方 API（\(AgentProviderForm.grokXAIBaseURL)）") : String(localized: "未填写"),
                    keyboard: .URL
                ) { $0.baseURL = $1 })
            rows.append(apiKeyRow())
        }
        if ["claude-code", "codex", "grok-build"].contains(agent) {
            rows.append(
                textRow(
                    String(localized: "模型"), value: form.model, id: "agentProviders.editor.model",
                    placeholder: subscription ? String(localized: "可选，写入 [models].default，如 grok-build") : String(localized: "未填写")
                ) { $0.model = $1 })
        }
        if isGrok && !subscription {
            rows.append(
                SettingsRow(
                    title: String(localized: "API 类型"), detail: form.apiKind.isEmpty ? String(localized: "默认（\(AgentProviderForm.grokAPIBackends[0])）") : form.apiKind,
                    id: "agentProviders.editor.apiKind", enabled: !busy
                ) { [weak self] in
                    guard let self else { return }
                    choose(
                        title: String(localized: "API 类型"), choices: AgentProviderForm.grokAPIBackends.map { ($0, $0) },
                        selected: form.apiKind
                    ) { [weak self] value in self?.update { $0.apiKind = value } }
                })
        }
        if agent == "codex" {
            rows.append(
                textRow(String(localized: "推理强度"), value: form.reasoningEffort, id: "agentProviders.editor.reasoningEffort") {
                    $0.reasoningEffort = $1
                })
            rows.append(
                SettingsRow(
                    title: String(localized: "上下文窗口"), detail: form.contextWindow.isEmpty ? String(localized: "未填写") : form.contextWindow,
                    id: "agentProviders.editor.contextWindow", enabled: !busy
                ) { [weak self] in
                    guard let self else { return }
                    chooseContextWindow(current: form.contextWindow) { [weak self] value in
                        self?.update { $0.contextWindow = value }
                    }
                })
        }
        if agent == "pi" {
            let kinds =
                form.apiKind.isEmpty || AgentProviderForm.piAPIKinds.contains(form.apiKind)
                ? AgentProviderForm.piAPIKinds : AgentProviderForm.piAPIKinds + [form.apiKind]
            rows.append(
                SettingsRow(
                    title: String(localized: "API 类型"), detail: form.apiKind.isEmpty ? String(localized: "未选择") : form.apiKind,
                    id: "agentProviders.editor.apiKind", enabled: !busy
                ) { [weak self] in
                    guard let self else { return }
                    choose(title: String(localized: "API 类型"), choices: kinds.map { ($0, $0) }, selected: form.apiKind) { [weak self] value in
                        self?.update { $0.apiKind = value }
                    }
                })
        }
        let footer =
            subscription
            ? String(localized: "订阅账户使用 grok login 写入的 auth.json 会话。先在后端主机运行 grok login，再点「导入当前生效配置」保存为供应商；切换时会先备份当前会话再替换。新建的空订阅供应商激活后需重新运行 grok login。")
            : String(localized: "密钥由后端脱敏返回；保持掩码值不变即沿用已存密钥。")
        var sections = [SettingsSection(title: String(localized: "连接"), footer: footer, rows: rows)]

        if additive {
            var modelRows = form.models.map { model in
                let summary = [
                    model.name.isEmpty ? "" : model.id,
                    model.contextWindow.isEmpty ? "" : "\(model.contextWindow) ctx",
                    model.reasoning ? model.efforts.joined(separator: "/") : "",
                ].filter { !$0.isEmpty }.joined(separator: " · ")
                return SettingsRow(
                    title: model.name.isEmpty ? model.id : model.name, detail: summary, symbol: "cube",
                    id: "agentProviders.editor.model.\(model.id)", enabled: !busy
                ) { [weak self] in self?.openModel(model.id) }
            }
            modelRows.append(
                SettingsRow(
                    title: String(localized: "添加模型"), symbol: "plus.circle", id: "agentProviders.editor.addModel", color: Theme.accent,
                    enabled: !busy
                ) { [weak self] in self?.addModels() })
            modelRows.append(
                SettingsRow(
                    title: String(localized: "获取模型列表"), detail: fetchedModels.isEmpty ? String(localized: "按当前表单向供应商请求模型目录") : String(localized: "已获取 \(fetchedModels.count) 个模型 · 点按选择"),
                    symbol: "arrow.down.circle", id: "agentProviders.editor.fetchModels", color: Theme.accent,
                    enabled: !busy
                ) { [weak self] in
                    guard let self else { return }
                    if fetchedModels.isEmpty { fetchModels() } else { openModelPicker() }
                })
            sections.append(
                SettingsSection(
                    title: String(localized: "模型（\(form.models.count)）"), footer: String(localized: "选择或输入模型 ID，逐项展开可配置上下文与思考强度。"),
                    rows: modelRows))
        }
        return sections
    }
}

/// Multi-select over fetched catalog ids plus ids already in the form.
@MainActor
final class AgentProviderModelPickerViewController: SettingsListController {
    private let options: [(id: String, name: String)]
    private var selected: [String]
    private let onChange: @MainActor ([String]) -> Void

    init(options: [(id: String, name: String)], selected: [String], onChange: @escaping @MainActor ([String]) -> Void) {
        self.options = options
        self.selected = selected
        self.onChange = onChange
        super.init(title: String(localized: "选择模型"))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    private func render() {
        sections = [
            SettingsSection(
                title: String(localized: "已选 \(selected.count) 个"), footer: String(localized: "点按切换；未在列表中的模型可返回后通过“添加模型”输入。"),
                rows: options.map { option in
                    let isSelected = selected.contains(option.id)
                    return SettingsRow(
                        title: option.name.isEmpty ? option.id : option.name,
                        detail: option.name.isEmpty || option.name == option.id ? "" : option.id,
                        id: "agentProviders.picker.\(option.id)", checked: isSelected
                    ) { [weak self] in
                        guard let self else { return }
                        if isSelected { selected.removeAll { $0 == option.id } } else { selected.append(option.id) }
                        onChange(selected)
                        render()
                    }
                })
        ]
        redraw()
    }
}

/// Per-model limits and thinking levels for the additive agents.
@MainActor
final class AgentProviderModelViewController: SettingsListController {
    private let agent: String
    private var model: AgentProviderForm.Model
    private let onChange: @MainActor (AgentProviderForm.Model) -> Void
    private let onRemove: @MainActor () -> Void

    init(
        agent: String, model: AgentProviderForm.Model, onChange: @escaping @MainActor (AgentProviderForm.Model) -> Void,
        onRemove: @escaping @MainActor () -> Void
    ) {
        self.agent = agent
        self.model = model
        self.onChange = onChange
        self.onRemove = onRemove
        super.init(title: model.id)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    private func change(_ apply: (inout AgentProviderForm.Model) -> Void) {
        apply(&model)
        onChange(model)
        render()
    }

    private func number(_ title: String, value: String, id: String, apply: @escaping @MainActor (String) -> Void) {
        editField(title: title, value: value, id: id, keyboard: .numberPad) { text in
            apply(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func render() {
        var rows = [
            SettingsRow(title: String(localized: "显示名"), detail: model.name.isEmpty ? String(localized: "未填写") : model.name, id: "agentProviders.model.name") {
                [weak self] in
                guard let self else { return }
                editField(title: String(localized: "显示名"), value: model.name, id: "agentProviders.model.name.input") { [weak self] text in
                    self?.change { $0.name = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            },
            SettingsRow(
                title: String(localized: "上下文窗口"), detail: model.contextWindow.isEmpty ? String(localized: "未填写") : model.contextWindow,
                id: "agentProviders.model.contextWindow"
            ) { [weak self] in
                guard let self else { return }
                let presets = AgentProviderForm.contextPresets.map { ($0.value, String(localized: "\($0.label)（\($0.value)）")) }
                choose(
                    title: String(localized: "上下文窗口"), choices: presets + [("custom", String(localized: "自定义…")), ("clear", String(localized: "清除"))],
                    selected: model.contextWindow
                ) { [weak self] value in
                    guard let self else { return }
                    switch value {
                    case "custom":
                        number(String(localized: "上下文窗口"), value: model.contextWindow, id: "agentProviders.model.contextWindow.input") {
                            [weak self] text in self?.change { $0.contextWindow = text }
                        }
                    case "clear": change { $0.contextWindow = "" }
                    default: change { $0.contextWindow = value }
                    }
                }
            },
            SettingsRow(
                title: String(localized: "最大输出"), detail: model.maxTokens.isEmpty ? String(localized: "未填写") : model.maxTokens,
                id: "agentProviders.model.maxTokens"
            ) { [weak self] in
                guard let self else { return }
                number(String(localized: "最大输出"), value: model.maxTokens, id: "agentProviders.model.maxTokens.input") { [weak self] text in
                    self?.change { $0.maxTokens = text }
                }
            },
            SettingsRow(
                title: String(localized: "支持思考"), detail: model.reasoning ? String(localized: "已开启") : String(localized: "已关闭"), symbol: "brain",
                id: "agentProviders.model.reasoning", checked: model.reasoning
            ) { [weak self] in
                guard let self else { return }
                change {
                    $0.reasoning.toggle()
                    if $0.reasoning, $0.efforts.isEmpty { $0.efforts = AgentProviderForm.defaultEfforts(for: self.agent) }
                }
            },
        ]
        rows.append(
            SettingsRow(title: String(localized: "移除模型"), symbol: "trash", id: "agentProviders.model.remove", color: .systemRed) {
                [weak self] in
                self?.onRemove()
                self?.navigationController?.popViewController(animated: true)
            })
        sections = [
            SettingsSection(
                title: String(localized: "模型"), footer: agent == "opencode" ? String(localized: "OpenCode 需要同时给出上下文窗口与最大输出。") : nil, rows: rows)
        ]
        if model.reasoning {
            sections.append(
                SettingsSection(
                    title: String(localized: "启用的思考强度"),
                    rows: AgentProviderForm.thinkingLevels(for: agent).map { level in
                        let enabled = model.efforts.contains(level)
                        return SettingsRow(title: level, id: "agentProviders.model.effort.\(level)", checked: enabled) {
                            [weak self] in
                            self?.change { model in
                                if enabled { model.efforts.removeAll { $0 == level } } else { model.efforts.append(level) }
                            }
                        }
                    }))
        }
        redraw()
    }
}
