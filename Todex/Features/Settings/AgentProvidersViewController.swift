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
        super.init(title: "Agent 账户")
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
                errorMessage = SettingsResponse.errorMessage(error, feature: " Agent 账户管理")
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
                errorMessage = SettingsResponse.errorMessage(error, feature: " Agent 账户操作")
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
            alert.addAction(UIAlertAction(title: "设为当前", style: .default) { [weak self] _ in
                self?.submitActivate(agent: agent, id: id)
            })
        }
        alert.addAction(UIAlertAction(title: "获取模型列表", style: .default) { [weak self] _ in
            self?.fetchModels(agent: agent, id: id, name: name)
        })
        alert.addAction(UIAlertAction(title: "编辑配置", style: .default) { [weak self] _ in
            self?.editProfile(agent: agent, id: id, name: name, settings: profile["settingsConfig"])
        })
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.confirm(
                title: "删除供应商“\(name)”？",
                message: additive ? "将同时从 live 配置中移除该节点。" : "档案将被移除；当前生效的 live 配置保持不变。",
                destructive: true
            ) { [weak self] in
                self?.mutate { api in _ = try await api.deleteAgentProvider(agent: agent, id: id) }
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        present(alert, animated: true)
    }

    private func submitActivate(agent: String, id: String) {
        confirm(
            title: "切换供应商？",
            message: "将改写该 Agent 的全局配置文件，对 TodeX 内外的新会话同时生效；运行中的会话不受影响。"
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
                        title: "\(name) 模型",
                        text: lines.isEmpty ? "未返回模型" : lines),
                    animated: true)
            } catch {
                self?.errorMessage = SettingsResponse.errorMessage(error, feature: " 模型列表")
                self?.render()
            }
        }
    }

    private func editProfile(agent: String, id: String, name: String, settings: JSONValue) {
        navigationController?.pushViewController(
            SettingsTextController(
                title: name,
                text: settings.prettyPrinted,
                detail: "密钥显示为掩码；保持掩码不变即沿用已存密钥。",
                editable: true,
                actionTitle: "保存"
            ) { [weak self] text in
                let parsed = try Self.parseSettings(text)
                try await self?.mutateSave(agent: agent, id: id, name: name, settings: parsed)
            },
            animated: true)
    }

    /// SettingsTextController 的 action 是 async throws；其中再提交 upsert。
    private func mutateSave(agent: String, id: String, name: String, settings: JSONValue) async throws {
        _ = try await api.upsertAgentProvider(
            agent: agent, id: id,
            profile: ["name": .string(name), "settingsConfig": settings])
        refresh()
    }

    private func addProvider(agent: String) {
        editField(title: "供应商 ID", value: "", id: "agentProviders.newId") { [weak self] id in
            let providerId = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !providerId.isEmpty else { return }
            self.editField(title: "显示名称", value: providerId, id: "agentProviders.newName") { [weak self] name in
                let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self, !displayName.isEmpty else { return }
                self.navigationController?.pushViewController(
                    SettingsTextController(
                        title: displayName,
                        text: Self.template(for: agent),
                        detail: "填写该 Agent 的供应商配置 JSON。",
                        editable: true,
                        actionTitle: "保存"
                    ) { [weak self] text in
                        let parsed = try Self.parseSettings(text)
                        try await self?.mutateSave(agent: agent, id: providerId, name: displayName, settings: parsed)
                    },
                    animated: true)
            }
        }
    }

    private func importLive(agent: String, id: String = "imported", name: String = "已导入") {
        mutate { api in _ = try await api.importLiveAgentProvider(agent: agent, id: id, name: name) }
    }

    private static func parseSettings(_ text: String) throws -> JSONValue {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
            case .object = value
        else {
            throw TodexError.invalid("配置必须是 JSON 对象")
        }
        return value
    }

    /// live 文件中未托管节点 / 档案 settingsConfig 的摘要行。
    private static func summary(agent: String, settings: JSONValue) -> String {
        switch agent {
        case "claude-code":
            return settings["env"]["ANTHROPIC_BASE_URL"].stringValue
        case "codex":
            return firstMatch(in: settings["config"].stringValue, pattern: #"base_url\s*=\s*"([^"]*)""#)
        case "grok-build":
            // 订阅档案显示 grok login 的账户邮箱，API 档案显示 base_url。
            let email = settings["auth"].objectValue.values.lazy
                .compactMap { $0["email"].optionalString }.first
            return email
                ?? firstMatch(in: settings["config"].stringValue, pattern: #"base_url\s*=\s*"([^"]*)""#)
        case "opencode":
            return settings["options"]["baseURL"].optionalString
                ?? settings["options"]["baseUrl"].stringValue
        case "pi":
            return settings["baseUrl"].stringValue
        default:
            return ""
        }
    }

    private static func firstMatch(in text: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else { return "" }
        return String(text[range])
    }

    private static func template(for agent: String) -> String {
        switch agent {
        case "claude-code":
            return #"{"env":{"ANTHROPIC_BASE_URL":"","ANTHROPIC_AUTH_TOKEN":"","ANTHROPIC_MODEL":""}}"#
        case "codex":
            return #"{"auth":{"OPENAI_API_KEY":""},"config":"model_provider = \"custom\"\nmodel = \"gpt-5\"\n\n[model_providers.custom]\nname = \"Custom\"\nbase_url = \"https://example.com/v1\"\nwire_api = \"responses\"\nrequires_openai_auth = true\n"}"#
        case "grok-build":
            // API 密钥档案；官方订阅请先在后端主机 grok login，再用"导入当前生效配置"。
            return #"{"auth":null,"config":"[models]\ndefault = \"grok-4.7\"\n\n[model.\"grok-4.7\"]\nmodel = \"grok-4.7\"\nbase_url = \"https://api.x.ai/v1\"\napi_key = \"\"\n"}"#
        case "opencode":
            return #"{"options":{"baseURL":"","apiKey":""},"models":{"model-id":{}}}"#
        case "pi":
            return #"{"baseUrl":"","api":"openai-completions","apiKey":"","models":[{"id":"model-id"}]}"#
        default:
            return "{}"
        }
    }

    // MARK: - 渲染

    private func render() {
        navigationItem.rightBarButtonItem?.isEnabled = !loading && !submitting
        var sections = [
            SettingsSection(
                title: "当前后端",
                footer: "独占型（Codex、Claude Code、Grok Build）激活时改写全局配置文件，对 TodeX 内外的新会话同时生效；叠加型（Pi、OpenCode）保存即写入全局配置、可多个并存，「默认」为该 Agent 的启动默认选中，在 Agent 侧修改。",
                rows: [
                    SettingsRow(
                        title: connection.name, detail: connection.serverURL, symbol: "server.rack",
                        id: "agentProviders.backend")
                ])
        ]
        if loading || submitting {
            sections.append(
                SettingsSection(
                    title: "状态",
                    rows: [
                        SettingsRow(
                            title: submitting ? "正在提交…" : "正在读取供应商…",
                            symbol: "arrow.triangle.2.circlepath", id: "agentProviders.loading",
                            activity: true)
                    ]))
        }
        if let errorMessage {
            sections.append(
                SettingsSection(
                    title: "提示",
                    rows: [
                        SettingsRow(
                            title: errorMessage, detail: "点按刷新", symbol: "exclamationmark.triangle",
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
                let detail = [
                    Self.summary(agent: agent, settings: profile["settingsConfig"]),
                    isCurrent ? "当前" : "",
                    isDefault ? "默认" : "",
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
                    rows.append(
                        SettingsRow(
                            title: nodeId,
                            detail: isDefault ? "未托管 · 默认 · 点按收编" : "未托管 · 点按收编",
                            symbol: "questionmark.circle", id: "agentProviders.\(agent).unmanaged.\(nodeId)",
                            enabled: !loading && !submitting
                        ) { [weak self] in
                            self?.importLive(agent: agent, id: nodeId, name: nodeId)
                        })
                }
            } else {
                // 独占型 Agent：live 与当前档案不一致时提供导入口。
                let live = bucket["live"]
                let mismatch = live["configured"].boolValue && !live["matchesCurrent"].boolValue
                if mismatch {
                    rows.append(
                        SettingsRow(
                            title: "导入当前生效配置", detail: "live 配置与所选供应商不一致",
                            symbol: "square.and.arrow.down", id: "agentProviders.\(agent).importLive",
                            color: Theme.accent, enabled: !loading && !submitting
                        ) { [weak self] in self?.importLive(agent: agent) })
                }
            }

            rows.append(
                SettingsRow(
                    title: "添加供应商", symbol: "plus.circle", id: "agentProviders.\(agent).add",
                    color: Theme.accent, enabled: !loading && !submitting
                ) { [weak self] in self?.addProvider(agent: agent) })
            sections.append(SettingsSection(title: title, rows: rows))
        }

        if buckets.isEmpty && !loading && errorMessage == nil {
            sections.append(
                SettingsSection(
                    title: "供应商", rows: [SettingsRow(title: "后端未返回供应商数据", id: "agentProviders.empty")]))
        }
        self.sections = sections
        redraw()
    }
}
