import TodexCore
import UIKit

@MainActor
final class CLIViewController: SettingsListController {
    private let connection: BackendConnection
    private let client: HTTPClient
    private var clis: [JSONValue] = []
    private var operation: JSONValue?
    private var loading = false
    private var submitting = false
    private var requiresRefresh = false
    private var errorMessage: String?
    private var requestTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var generation = 0

    init(connection: BackendConnection) {
        self.connection = connection
        client = HTTPClient(connection: connection)
        super.init(title: String(localized: "CLI 管理"))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .refresh, primaryAction: UIAction { [weak self] _ in self?.refresh() })
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "cli.refresh"
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
            pollTask?.cancel()
            requestTask = nil
            pollTask = nil
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
        pollTask?.cancel()
        loading = true
        errorMessage = nil
        render()
        requestTask = Task { [weak self, client] in
            do {
                let value = try await client.request(path: "/v2/providers/versions")
                try Task.checkCancellation()
                let clis = try SettingsResponse.array(value, key: "clis")
                guard let self, generation == current else { return }
                self.clis = clis
                operation = value["activeOperation"].isNull ? nil : try validatedOperation(value["activeOperation"])
                requiresRefresh = false
                loading = false
                requestTask = nil
                render()
                startPolling()
            } catch {
                guard let self, !Task.isCancelled, generation == current else { return }
                clis = []
                errorMessage = SettingsResponse.errorMessage(error, feature: String(localized: " CLI 管理"))
                loading = false
                requestTask = nil
                render()
            }
            self?.refreshControl?.endRefreshing()
        }
    }

    private func validatedOperation(_ value: JSONValue) throws -> JSONValue {
        guard let id = value["id"].optionalString, !id.isEmpty,
            ["running", "succeeded", "failed"].contains(value["status"].stringValue)
        else {
            throw TodexError.invalid(String(localized: "后端返回了无效的 CLI 升级状态；请刷新核对"))
        }
        return value
    }

    private func beginUpgrade(_ cli: JSONValue) {
        guard !loading, !submitting, !requiresRefresh, operation?["status"].stringValue != "running",
            cli["kind"].stringValue == "managed", cli["upgradeSupported"].boolValue,
            let provider = cli["id"].optionalString, !provider.isEmpty
        else { return }
        confirm(
            title: String(localized: "升级 \(cli["name"].stringValue)？"),
            message: String(localized: "将升级后端“\(connection.name)”（\(connection.serverURL)）上的 CLI。后端有正在运行的 Agent 时会拒绝升级。")
        ) { [weak self] in
            self?.submitUpgrade(provider)
        }
    }

    private func submitUpgrade(_ provider: String) {
        guard !loading, !submitting, !requiresRefresh, operation?["status"].stringValue != "running" else { return }
        generation += 1
        let current = generation
        submitting = true
        errorMessage = nil
        pollTask?.cancel()
        render()
        requestTask = Task { [weak self, client] in
            do {
                let value = try await client.request(
                    .post, path: "/v2/providers/\(HTTPClient.segment(provider))/upgrade")
                try Task.checkCancellation()
                guard let self, generation == current else { return }
                operation = try validatedOperation(value)
                submitting = false
                requestTask = nil
                render()
                startPolling()
            } catch {
                guard let self, !Task.isCancelled, generation == current else { return }
                submitting = false
                requestTask = nil
                requiresRefresh = true
                errorMessage = SettingsResponse.errorMessage(error, feature: String(localized: " CLI 升级")) + String(localized: "\n请先刷新版本及现有操作，再决定是否重试。")
                render()
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        guard let operation, operation["status"].stringValue == "running" else { return }
        let id = operation["id"].stringValue
        let current = generation
        pollTask = Task { [weak self, client] in
            var delay: UInt64 = 1_200_000_000
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: delay)
                    let value = try await client.request(path: "/v2/providers/upgrades/\(HTTPClient.segment(id))")
                    try Task.checkCancellation()
                    guard let self, generation == current else { return }
                    guard value["id"].stringValue == id else { throw TodexError.invalid(String(localized: "后端返回的升级操作标识不匹配")) }
                    self.operation = try validatedOperation(value)
                    errorMessage = nil
                    render()
                    if value["status"].stringValue == "succeeded" {
                        // The version response may omit a completed operation; preserve the result for this visit.
                        let versions = try await client.request(path: "/v2/providers/versions")
                        try Task.checkCancellation()
                        guard generation == current else { return }
                        clis = try SettingsResponse.array(versions, key: "clis")
                        render()
                        return
                    }
                    if value["status"].stringValue == "failed" { return }
                    delay = 1_200_000_000
                } catch {
                    guard let self, !Task.isCancelled, generation == current else { return }
                    errorMessage = String(localized: "无法读取最新进度：\(error.localizedDescription)\n将自动重试；离开页面不会取消后端升级。")
                    render()
                    delay = 2_500_000_000
                }
            }
        }
    }

    private func render() {
        navigationItem.rightBarButtonItem?.isEnabled = !loading && !submitting
        sections = [
            SettingsSection(
                title: String(localized: "当前后端"),
                rows: [
                    SettingsRow(
                        title: connection.name, detail: connection.serverURL, symbol: "server.rack", id: "cli.backend")
                ])
        ]
        if loading || submitting {
            sections.append(
                SettingsSection(
                    title: String(localized: "状态"),
                    rows: [
                        SettingsRow(
                            title: submitting ? String(localized: "正在提交升级…") : String(localized: "正在读取 CLI 版本…"), symbol: "arrow.triangle.2.circlepath",
                            id: "cli.loading", activity: true)
                    ]))
        }
        if let errorMessage {
            sections.append(
                SettingsSection(
                    title: String(localized: "读取失败"),
                    rows: [
                        SettingsRow(
                            title: errorMessage, detail: String(localized: "点按刷新"), symbol: "exclamationmark.triangle", id: "cli.error",
                            color: .systemRed, enabled: !loading && !submitting
                        ) { [weak self] in self?.refresh() }
                    ]))
        }
        if let operation {
            let status = operation["status"].stringValue
            let statusText = ["running": String(localized: "升级进行中"), "succeeded": String(localized: "升级成功"), "failed": String(localized: "升级失败")][status] ?? String(localized: "未知状态")
            let detail = [
                operation["provider"].optionalString, operation["currentVersion"].optionalString,
                operation["error"].optionalString,
            ].compactMap { $0 }.joined(separator: "\n")
            sections.append(
                SettingsSection(
                    title: String(localized: "升级操作"), footer: String(localized: "关闭页面不会取消服务器上已经开始的升级。"),
                    rows: [
                        SettingsRow(
                            title: statusText, detail: detail, id: "cli.operation",
                            color: status == "failed" ? .systemRed : .label)
                    ]))
        }
        for cli in clis {
            let name = cli["name"].optionalString ?? cli["id"].stringValue
            let status =
                [
                    "upToDate": String(localized: "已是最新"), "updateAvailable": String(localized: "可升级"), "ahead": String(localized: "领先最新版"), "unknown": String(localized: "最新版未知"),
                    "notInstalled": String(localized: "未安装"), "external": String(localized: "外部管理"),
                ][cli["status"].stringValue] ?? String(localized: "状态未知")
            var rows = [
                SettingsRow(
                    title: status,
                    detail:
                        String(localized: "当前版本：\(cli["currentVersion"].optionalString ?? String(localized: "不可用"))\n最新版本：\(cli["latestVersion"].optionalString ?? String(localized: "未获取"))"),
                    symbol: "terminal", id: "cli.\(cli["id"].stringValue).version")
            ]
            if let error = cli["error"].optionalString {
                rows.append(SettingsRow(title: error, id: "cli.\(cli["id"].stringValue).error", color: .systemRed))
            }
            if cli["kind"].stringValue == "managed" {
                rows.append(
                    SettingsRow(
                        title: String(localized: "升级到最新版"), detail: cli["upgradeSupported"].boolValue ? "" : String(localized: "后端未允许升级此 CLI"),
                        symbol: "arrow.down.circle", id: "cli.\(cli["id"].stringValue).upgrade", color: Theme.accent,
                        enabled: cli["upgradeSupported"].boolValue && !loading && !submitting && !requiresRefresh
                            && operation?["status"].stringValue != "running"
                    ) { [weak self] in self?.beginUpgrade(cli) })
            }
            sections.append(SettingsSection(title: name, rows: rows))
        }
        if clis.isEmpty && !loading && errorMessage == nil {
            sections.append(SettingsSection(title: "CLI", rows: [SettingsRow(title: String(localized: "后端未返回 CLI"), id: "cli.empty")]))
        }
        redraw()
    }
}
