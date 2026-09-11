import TodexCore
import UIKit

@MainActor
final class WorkbenchGitViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let http: HTTPClient
    private let workspace: WorkspaceRecord
    private let conversationId: String
    private let command: WorkbenchCommand
    private let insertReference: @MainActor (String) -> Void
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let info = UILabel()
    private let operationInfo = UILabel()
    private var snapshot: JSONValue?
    private var summary: JSONValue?
    private var repository: JSONValue?
    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private var writing = false
    private var outcomeUnknown = false
    private var refreshedAfterUnknown = false
    // Used only if a host returns an acknowledgement containing an ID instead of the correlated result.
    private var controlResults: [(String, JSONValue)] = []
    private var readRevision = UUID()
    // When the header Git menu drives operations while this tab is off-screen,
    // sheets and alerts anchor to the conversation container instead.
    private weak var presentationHost: UIViewController?
    private var presenter: UIViewController { presentationHost ?? self }
    var hasUnresolvedOperation: Bool { writing || outcomeUnknown }

    init(
        connection: BackendConnection, workspace: WorkspaceRecord, conversationId: String,
        command: @escaping WorkbenchCommand, insertReference: @escaping @MainActor (String) -> Void
    ) {
        http = HTTPClient(connection: connection)
        self.workspace = workspace
        self.conversationId = conversationId
        self.command = command
        self.insertReference = insertReference
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        readTask?.cancel()
        writeTask?.cancel()
        diffTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        table.dataSource = self
        table.delegate = self
        info.font = .preferredFont(forTextStyle: .caption1)
        info.numberOfLines = 0
        operationInfo.font = .preferredFont(forTextStyle: .caption1)
        operationInfo.numberOfLines = 0
        operationInfo.textColor = .secondaryLabel
        table.refreshControl = UIRefreshControl()
        table.refreshControl?.addAction(
            UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
        WBUI.installStack(in: view, views: [info, operationInfo, table])
        self.refresh()
    }
    private func endRefreshing() {
        table.refreshControl?.endRefreshing()
    }

    /// Header entry point: returns a menu whose items rebuild on every open and
    /// present sheets on the conversation container while the tab is hidden.
    func gitMenu(host: UIViewController) -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] provide in
                guard let self else { provide([]); return }
                self.presentationHost = host
                if self.snapshot == nil { self.refresh() }
                provide(self.menuElements())
            }
        ])
    }
    private func menuElements() -> [UIMenuElement] {
        var elements: [UIMenuElement] = [
            UIAction(title: "刷新状态", image: Theme.icon("arrow.clockwise", pointSize: 13)) {
                [weak self] _ in self?.refresh()
            }
        ]
        var operations: [UIMenuElement] = []
        func op(_ title: String, _ icon: String, enabled: Bool, action: @escaping @MainActor () -> Void) {
            let item = UIAction(title: title, image: Theme.icon(icon, pointSize: 13)) { _ in action() }
            if !enabled { item.attributes = .disabled }
            operations.append(item)
        }
        op("初始化仓库", "plus.square", enabled: canWrite && !initialized) { [weak self] in
            self?.confirmOperation(["action": "init"], title: "初始化仓库")
        }
        op("提交更改…", "checkmark.square", enabled: canWrite && initialized && dirty) { [weak self] in
            self?.commitForm()
        }
        op("推送当前分支", "arrow.up.circle", enabled: canWrite && initialized && !branch.isEmpty) { [weak self] in
            self?.confirmOperation(["action": "push"], title: "推送当前分支")
        }
        op("创建分支…", "arrow.triangle.branch", enabled: canWrite && initialized) { [weak self] in
            self?.branchForm(worktree: false)
        }
        op("创建工作树…", "square.stack.3d.up", enabled: canWrite && initialized) { [weak self] in
            self?.branchForm(worktree: true)
        }
        op("创建 PR…", "arrow.up.doc", enabled: canWrite && initialized && !branch.isEmpty) { [weak self] in
            self?.prForm()
        }
        if outcomeUnknown {
            let unlock = UIAction(
                title: "已核对实际结果，解除写保护",
                image: Theme.icon("lock.open", pointSize: 13)
            ) { [weak self] _ in
                guard let self else { return }
                WBUI.confirm(
                    on: presenter, title: "已核对仓库和远端？", message: "状态刷新不能证明提交、推送或 PR 是否成功。确认已检查实际结果后才可继续。", action: "已核对"
                ) { [weak self] in
                    self?.outcomeUnknown = false
                    self?.refreshedAfterUnknown = false
                    self?.operationInfo.text = "已由用户解除写保护；请避免重复已生效的操作。"
                }
            }
            if !(refreshedAfterUnknown && !writing) { unlock.attributes = .disabled }
            operations.insert(
                UIAction(
                    title: "上次写入结果未知，请先核对仓库和远端",
                    attributes: UIMenuElement.Attributes.disabled
                ) { _ in },
                at: 0)
            operations.insert(unlock, at: 1)
        }
        elements.append(UIMenu(title: "Git 操作", children: operations))
        elements.append(
            UIMenu(
                title: "分支（\(branches.count)）",
                children: branches.map { branch in
                    UIAction(
                        title: branch["name"].stringValue,
                        image: Theme.icon(
                            branch["current"].boolValue ? "checkmark.circle" : "arrow.triangle.branch",
                            pointSize: 13)
                    ) { [weak self] _ in self?.showBranch(branch) }
                }))
        elements.append(
            UIMenu(
                title: "工作树（\(worktrees.count)）",
                children: worktrees.map { tree in
                    UIAction(
                        title: (tree["path"].stringValue as NSString).lastPathComponent,
                        subtitle: tree["branch"].optionalString,
                        image: Theme.icon("square.stack.3d.up", pointSize: 13)
                    ) { [weak self] _ in self?.showWorktree(tree) }
                }))
        elements.append(
            UIMenu(
                title: "委托 Agent", image: Theme.icon("person.crop.circle.badge.questionmark", pointSize: 13),
                children: Self.agentGroups.map { group in
                    UIMenu(
                        title: group.0,
                        children: group.1.map { item in
                            UIAction(title: item.0) { [weak self] _ in
                                self?.delegate(title: item.0, request: item.1)
                            }
                        })
                }))
        elements.append(
            UIAction(
                title: "Legacy Diff", image: Theme.icon("doc.text.magnifyingglass", pointSize: 13)
            ) { [weak self] _ in self?.loadDiff() })
        return elements
    }
    private var canWrite: Bool { !writing && !outcomeUnknown && snapshot != nil }
    private var initialized: Bool { snapshot?["initialized"].boolValue ?? false }
    private var dirty: Bool { snapshot?["dirty"].boolValue ?? true }
    private var branch: String { snapshot?["currentBranch"].optionalString ?? "" }
    private var branches: [JSONValue] { snapshot?["branches"].arrayValue ?? [] }
    private var worktrees: [JSONValue] { snapshot?["worktrees"].arrayValue ?? [] }
    private var changedFiles: [JSONValue] { repository?["files"].arrayValue ?? [] }

    private func refresh() {
        readTask?.cancel()
        readRevision = UUID()
        let revision = readRevision
        info.text = "正在读取 Git 状态…"
        // Old snapshots remain inspectable but cannot authorize a write while a fresh read is pending.
        snapshot = nil
        summary = nil
        repository = nil
        table.reloadData()
        readTask = Task { [weak self] in
            guard let self else { return }
            do {
                let query = ["workspacePath": self.workspace.path]
                async let workspaceResult = self.http.request(.get, path: "/v2/git/workspace", query: query)
                async let summaryResult = self.http.request(.get, path: "/v2/git/status", query: query)
                async let scanResult = self.http.request(.get, path: "/v2/git/scan", query: query)
                let (snapshot, summary, scan) = try await (workspaceResult, summaryResult, scanResult)
                guard revision == self.readRevision, !Task.isCancelled else { return }
                guard case .bool = snapshot["initialized"], case .array = snapshot["branches"],
                    case .array = snapshot["worktrees"],
                    case .bool = snapshot["dirty"], snapshot["repositoryPath"].optionalString != nil,
                    case .array = scan["repositories"], case .bool = summary["initialized"],
                    summary["changedFiles"].doubleValue != nil, summary["additions"].doubleValue != nil,
                    summary["deletions"].doubleValue != nil
                else { throw TodexError.invalid("Git 响应缺少状态字段") }
                self.snapshot = snapshot
                self.summary = summary
                self.repository = scan["repositories"].arrayValue.first {
                    $0["path"].stringValue == snapshot["repositoryPath"].stringValue
                }
                self.info.text =
                    "\(snapshot["repositoryPath"].stringValue)\n"
                    + (snapshot["initialized"].boolValue
                        ? "\(self.branch.isEmpty ? "Detached HEAD / 无分支" : self.branch) · \(snapshot["dirty"].boolValue ? "有未提交更改" : "工作树干净")"
                        : "尚未初始化 Git")
                if self.outcomeUnknown { self.refreshedAfterUnknown = true }
                self.table.reloadData()
                self.endRefreshing()
            } catch {
                guard revision == self.readRevision, !Task.isCancelled else { return }
                self.info.text = "Git 状态不可用：\(error.localizedDescription)"
                self.endRefreshing()
            }
        }
    }
    func numberOfSections(in tableView: UITableView) -> Int { 2 }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "状态" : "变更文件\(repository?["filesTruncated"].boolValue == true ? "（后端已截断）" : "")"
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? (summary == nil ? 0 : 1) : changedFiles.count
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.secondaryTextProperties.numberOfLines = 0
        if indexPath.section == 0 {
            if let summary {
                content.text =
                    "\(summary["changedFiles"].intValue) 个变更文件 · +\(summary["additions"].intValue) −\(summary["deletions"].intValue)"
                content.secondaryText = summary["statsTruncated"].boolValue ? "统计被截断，以上不是完整数量。" : "来源：后端 Git 状态"
                content.image = UIImage(systemName: "checklist")
            }
        } else {
            let file = changedFiles[indexPath.row]
            content.text = file["path"].stringValue
            content.secondaryText = "Git 状态：\(file["status"].stringValue) · 点击引用"
            content.image = UIImage(systemName: "doc.text")
        }
        cell.contentConfiguration = content
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        let path = (workspace.path as NSString).appendingPathComponent(
            changedFiles[indexPath.row]["path"].stringValue)
        insertReference("@\(path)")
        operationInfo.text = "已插入文件路径到对话草稿。"
    }

    private func showBranch(_ value: JSONValue) {
        let name = value["name"].stringValue
        let sheet = UIAlertController(title: name, message: "切换分支要求当前工作树干净，且目标未被其它工作树占用。", preferredStyle: .actionSheet)
        let change = UIAlertAction(title: "切换到此分支", style: .default) { [weak self] _ in
            self?.confirmOperation(["action": "switch-branch", "branchName": .string(name)], title: "切换分支")
        }
        change.isEnabled =
            canWrite && !dirty && !value["current"].boolValue && !value["remote"].boolValue
            && (value["worktreePath"].optionalString ?? "").isEmpty
        sheet.addAction(change)
        sheet.addAction(
            UIAlertAction(title: "插入分支引用", style: .default) { [weak self] _ in self?.insertReference("[Git 分支 \(name)]")
            })
        WBUI.presentSheet(sheet, on: presenter)
    }
    private func showWorktree(_ value: JSONValue) {
        let path = value["path"].stringValue
        let sheet = UIAlertController(
            title: value["branch"].optionalString ?? "工作树", message: path, preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: "插入路径引用", style: .default) { [weak self] _ in
                self?.insertReference("[Git 工作树 \(path)]")
            })
        sheet.addAction(
            UIAlertAction(title: "请求切换或交接（Agent）", style: .default) { [weak self] _ in
                self?.delegate(
                    title: "切换工作树",
                    request:
                        "请将当前任务切换或交接到工作树 \(JSONValue.string(path).prettyPrinted)。保留未提交更改和任务上下文。先核实会话工作目录切换能力；若宿主无法切换会话，提供具体下一步，不得宣称已经切换。本移动端操作台没有改变会话工作目录。"
                )
            })
        let remove = UIAlertAction(title: "移除此工作树", style: .destructive) { [weak self] _ in
            self?.confirmOperation(["action": "remove-worktree", "path": .string(path)], title: "移除工作树（保留分支）")
        }
        remove.isEnabled =
            canWrite && value["accessible"].boolValue && !value["main"].boolValue && !value["current"].boolValue
            && !value["dirty"].boolValue && !value["locked"].boolValue
        sheet.addAction(remove)
        WBUI.presentSheet(sheet, on: presenter)
    }
    private func branchForm(worktree: Bool) {
        var fields = [("分支名称", ""), ("起点（可留空）", "")]
        if worktree { fields.append(("新工作树绝对路径", "")) }
        WBUI.form(on: presenter, title: worktree ? "创建工作树" : "创建分支", fields: fields) { [weak self] values in
            guard let self, values.count == fields.count else { return }
            let name = values[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                WBUI.message(on: presenter, title: "缺少名称", text: "请输入分支名称。")
                return
            }
            var operation: JSONValue = [
                "action": .string(worktree ? "create-worktree" : "create-branch"), "branchName": .string(name),
            ]
            if !values[1].isEmpty { operation["startPoint"] = .string(values[1]) }
            if worktree {
                guard values[2].hasPrefix("/") else {
                    WBUI.message(on: presenter, title: "路径无效", text: "请输入后端新工作树的绝对路径。")
                    return
                }
                operation["path"] = .string(values[2])
            }
            self.confirmOperation(operation, title: worktree ? "创建工作树" : "创建分支（不自动切换）")
        }
    }
    private func commitForm() {
        WBUI.form(
            on: presenter, title: "提交更改", message: "下一步选择仅提交已暂存文件，或先暂存全部更改。", fields: [("提交说明（最多 512 UTF-8 bytes）", "")]
        ) { [weak self] values in
            guard let self, let message = values.first,
                !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.utf8.count <= 512
            else { return }
            let sheet = UIAlertController(title: "选择提交范围", message: message, preferredStyle: .actionSheet)
            for include in [false, true] {
                sheet.addAction(
                    UIAlertAction(title: include ? "暂存所有更改并提交" : "仅提交已经暂存的更改", style: include ? .destructive : .default)
                    { [weak self] _ in
                        self?.confirmOperation(
                            ["action": "commit", "message": .string(message), "includeUnstaged": .bool(include)],
                            title: "提交更改", legacyRun: true)
                    })
            }
            WBUI.presentSheet(sheet, on: presenter)
        }
    }
    private func prForm() {
        WBUI.form(
            on: presenter, title: "创建 PR", message: "当前分支必须已推送；请明确填写目标仓库和基准分支。",
            fields: [("标题", ""), ("目标仓库（owner/repo）", ""), ("基准分支", "")]
        ) { [weak self] values in
            guard let self, values.count == 3,
                values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { return }
            WBUI.textSheet(
                on: presenter, title: "PR 描述", text: "", editable: true,
                actions: [false, true].map { draft in
                    (
                        draft ? "继续创建草稿 PR" : "继续创建 PR",
                        { @MainActor [weak self] body in
                            self?.confirmOperation(
                                [
                                    "action": "create-pr", "title": .string(values[0]),
                                    "repository": .string(values[1]), "baseBranch": .string(values[2]),
                                    "body": .string(body), "draft": .bool(draft),
                                ], title: draft ? "创建草稿 PR" : "创建 PR")
                        }
                    )
                })
        }
    }
    private func confirmOperation(_ operation: JSONValue, title: String, legacyRun: Bool = false) {
        guard canWrite else {
            WBUI.message(on: presenter, title: "当前不可写入", text: "请先读取状态、等待当前操作完成，或核对结果未知的操作。")
            return
        }
        WBUI.confirm(
            on: presenter, title: title, message: "目录：\(workspace.path)\n分支：\(branch)\n\(operation.prettyPrinted)",
            action: "确认执行"
        ) { [weak self] in
            self?.perform(operation, legacyRun: legacyRun)
        }
    }
    private func perform(_ operation: JSONValue, legacyRun: Bool) {
        guard canWrite else { return }
        writing = true
        operationInfo.text = "正在执行 \(operation["action"].stringValue)…"
        writeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.writing = false
                self.refresh()
            }
            do {
                var body: JSONValue
                if legacyRun {
                    body = operation
                    body["workspacePath"] = .string(self.workspace.path)
                } else {
                    body = ["workspacePath": .string(self.workspace.path), "operation": operation]
                }
                let result = try await self.http.request(
                    .post, path: legacyRun ? "/v2/git/run" : "/v2/git/operation", body: body)
                guard result["action"] == operation["action"], let output = result["output"].optionalString,
                    result["repositoryPath"].optionalString != nil
                else { throw TodexError.unknownOutcome("Git 返回内容没有确认此动作") }
                self.operationInfo.text = "后端已确认 \(result["action"].stringValue)"
                WBUI.textSheet(on: presenter, title: "Git 操作结果", text: "\(result["repositoryPath"].stringValue)\n\(output)")
            } catch {
                self.outcomeUnknown = Self.isUnknown(error)
                self.refreshedAfterUnknown = false
                self.operationInfo.text = (self.outcomeUnknown ? "结果未知；写操作已暂停。" : "操作失败。") + error.localizedDescription
                WBUI.error(error, on: presenter)
            }
        }
    }
    private static func isUnknown(_ error: any Error) -> Bool {
        switch error {
        case TodexError.unknownOutcome: true
        case TodexError.server(let code, _):
            [
                "GIT_PARTIAL_SUCCESS", "GIT_COMMAND_TIMED_OUT", "GIT_COMMAND_TIMEOUT", "GIT_OUTCOME_UNKNOWN",
                "GIT_PROCESS_ERROR", "INTERNAL_SERVER_ERROR",
            ].contains(code) || (Int(code) ?? 0) >= 500
        default: true
        }
    }

    func receive(_ event: JSONValue) {
        guard ["codex.control.response", "codex.control.error"].contains(event["type"].stringValue),
            let id = WBEvent.requestId(event)
        else { return }
        let data = WBEvent.data(event)
        let session =
            data["codexSessionId"].optionalString ?? event["codex_session_id"].optionalString
            ?? event["payload"]["codex_session_id"].optionalString
        guard session == nil || session == workspace.sessionId else { return }
        controlResults.append((id, event))
        // Never persist diffs; keep a small race buffer for response-before-ack ordering.
        if controlResults.count > 8 { controlResults.removeFirst(controlResults.count - 8) }
    }
    private func loadDiff() {
        guard diffTask == nil else { return }
        guard !workspace.sessionId.isEmpty else {
            WBUI.message(on: presenter, title: "Legacy Diff 不可用", text: "工作区没有 Legacy Codex session；普通 Git 状态仍可使用。")
            return
        }
        operationInfo.text = "请求 Legacy gitDiffToRemote…"
        diffTask = Task { [weak self] in
            guard let self else { return }
            defer { self.diffTask = nil }
            do {
                let response = try await self.command(
                    "codex.local.request",
                    [
                        "codexSessionId": .string(self.workspace.sessionId),
                        "tenantId": .string(self.workspace.tenantId), "method": "gitDiffToRemote",
                        "params": ["cwd": .string(self.workspace.path)],
                    ], 20)
                var result = WBEvent.data(response)
                if !result["result"].isNull { result = result["result"] }
                if result["diff"].optionalString == nil {
                    guard let id = WBEvent.requestId(response) else {
                        throw TodexError.invalid("宿主未返回关联请求 ID 或最终 Diff，无法确认异步结果")
                    }
                    var matched: JSONValue?
                    for _ in 0..<150 {
                        if let event = self.controlResults.last(where: { $0.0 == id })?.1 {
                            matched = event
                            break
                        }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard let matched else { throw TodexError.invalid("等待对应 codex.control.response 超时") }
                    if let failure = WBEvent.failure(matched) { throw TodexError.invalid(failure) }
                    result = WBEvent.data(matched)["result"]
                }
                guard let diff = result["diff"].optionalString else {
                    throw TodexError.invalid("后端未提供 diff 字段；该 Legacy capability 不可用")
                }
                self.operationInfo.text = "Legacy Diff 已返回"
                WBUI.textSheet(
                    on: presenter, title: "Git Diff",
                    text: "SHA: \(result["sha"].optionalString ?? "未提供")\n\n\(diff.isEmpty ? "后端返回空 diff。" : diff)",
                    actions: [
                        (
                            "插入 Diff 引用",
                            { [weak self] _ in
                                self?.insertReference(
                                    "[Git Diff \(self?.workspace.path ?? "")]\n\(String(diff.prefix(12000)))")
                            }
                        )
                    ])
            } catch {
                self.operationInfo.text = "Legacy Diff 不可用：\(error.localizedDescription)"
                WBUI.message(
                    on: presenter, title: "Legacy Diff 不可用",
                    text:
                        "\(error.localizedDescription)\n需要已运行且支持 gitDiffToRemote 的 Legacy Codex session；普通 V2 会话不保证支持。未自动启动旧适配器。"
                )
            }
        }
    }

    private func delegate(title: String, request: String) {
        let prompt =
            "工作区名称：\(JSONValue.string(workspace.name).prettyPrinted)\n工作区路径：\(JSONValue.string(workspace.path).prettyPrinted)\n\n\(request)\n\nPR 操作只针对这个工作区当前分支的 PR。若无法唯一确定目标，先列出候选并询问我。核实实际能力和执行结果，不得将请求已发送视为操作完成。"
        WBUI.textSheet(
            on: presenter, title: "审阅：\(title)", text: prompt, editable: true,
            actions: [
                (
                    "插入对话草稿",
                    { [weak self] text in
                        self?.insertReference(text)
                        self?.operationInfo.text = "请求已插入草稿；尚未发送给 Agent。"
                    }
                ),
                (
                    "发送给 Agent 执行",
                    { [weak self] text in
                        guard let self, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        WBUI.confirm(
                            on: presenter, title: "发送此委托？", message: "将把已审阅的「\(title)」请求发送到当前对话。Agent 将按请求执行，可能修改仓库或 PR。",
                            action: "发送"
                        ) { [weak self] in self?.sendAgent(text) }
                    }
                ),
            ])
    }
    private func sendAgent(_ text: String) {
        guard !writing, !outcomeUnknown else {
            WBUI.message(on: presenter, title: "请先核对当前操作", text: "当前写操作尚未结束或结果未知，请先核对，避免重复执行。")
            return
        }
        writing = true
        operationInfo.text = "正在发送 Agent 请求…"
        writeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.writing = false }
            do {
                var payload: JSONValue = ["conversationId": .string(self.conversationId), "text": .string(text)]
                if !self.workspace.model.isEmpty { payload["model"] = .string(self.workspace.model) }
                let result = try await self.command("conversation.prompt", payload, 30)
                guard let turn = result["turnId"].optionalString else {
                    throw TodexError.unknownOutcome("后端未确认 Agent turn")
                }
                self.operationInfo.text = "已发送给 Agent · turn \(turn)；执行结果请查看对话。"
            } catch {
                self.outcomeUnknown = Self.isUnknown(error)
                self.refreshedAfterUnknown = false
                self.operationInfo.text = "Agent 请求未确认：\(error.localizedDescription)"
                WBUI.error(error, on: presenter)
            }
        }
    }
    private static let agentGroups: [(String, [(String, String)])] = [
        (
            "仓库与交接",
            [
                ("提交更改", "请检查当前工作树，按仓库规范完成相关验证，只提交本次任务的更改，保留无关本地修改，报告提交 ID。"),
                ("提交并推送", "请检查工作树并验证，只提交本次任务更改并正常推送当前分支。远端或上游不明确时询问我，保留无关本地修改，报告提交 ID 和推送结果。"),
                ("Handoff", "请检查分支、工作树和未提交更改，列出交接目标供我选择，完整保留更改和任务上下文。核实交接能力；无法迁移会话时提供交接内容和下一步，不能宣称已迁移。"),
                (
                    "创建 PR（Agent）",
                    "请为当前任务创建 PR，按仓库规范验证、提交并正常推送本次任务更改，保留无关修改。按模板撰写 PR 信息；远端或基准不明确时询问我；检查已有 PR 避免重复创建。不要自动合并或删除分支、工作树。"
                ),
            ]
        ),
        (
            "PR 阅读与修复",
            [
                ("查看 PR", "请只读查看 PR 标题、描述、分支、审查、检查、冲突和合并状态，返回链接与建议，不修改 PR。"),
                ("解释代码更改", "请只读解释 PR diff 的关键更改、目的、行为影响、验证和风险，引用具体文件，区分事实与推测。"),
                ("处理审查评论", "请检查未解决审查评论，修复有效问题并验证、提交和推送本次修复，保留无关修改；不要擅自发布评论或关闭审查线程。"),
                ("修复失败检查", "请检查失败 CI 日志，修复原因并验证、提交和正常推送，保留无关修改，报告剩余失败。"),
                ("解决合并冲突", "请核对目标分支并获取最新远端，保留双方有效更改和无关本地修改，解决冲突、验证、提交并正常推送。产品决策不明确时询问我；不要自动合并 PR。"),
                ("处理全部 PR 问题", "请检查未解决评论、失败检查与合并冲突，修复有效问题，保留双方更改及无关本地修改，验证、提交并正常推送，报告已解决与剩余问题。不要自动合并、发布评论或关闭线程。"),
            ]
        ),
        (
            "PR 合并",
            [
                (
                    "合并 PR",
                    "请核对 PR 最新 head、审查、必要检查及冲突，满足仓库要求后使用允许的默认方式合并。不能唯一确定方式时询问我。执行绑定已核实 head，head 变化重新检查；不绕过保护或强制合并，不删除分支或工作树。"
                ),
                ("启用自动合并", "请为 PR 启用自动合并，遵守仓库方式、审查及检查要求，不绕过保护；不支持时说明原因，不改为立即合并。核对实际状态，不删除分支或工作树。"),
                ("取消自动合并", "请取消 PR 自动合并，核对状态并报告；若已合并说明现状，不撤销合并。"),
            ]
        ),
        (
            "PR 管理",
            [
                ("管理 PR", "请查看 PR 信息、标签、审查人和状态，仅按对话中明确要求修改；没有明确要求时列出操作并询问我。不要默认关闭或合并。"),
                ("转为草稿", "请将尚未合并的 PR 转为草稿，核对实际状态并报告链接。"),
                ("标记可供审查", "请将草稿 PR 标记为可供审查，核对实际状态并报告链接；不要自动合并。"),
                ("关闭 PR", "请关闭尚未合并的 PR，保留分支和工作树，核对状态并报告链接。"),
                ("重新打开 PR", "请重新打开已关闭且未合并的 PR，核对状态并报告链接。"),
            ]
        ),
    ]
}
