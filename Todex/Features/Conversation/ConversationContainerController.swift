import TodexCore
import UIKit

final class ConversationContainerController: UIViewController {
    private let session: AppSession
    private let conversation: ConversationManifest
    private let chat: ChatViewController
    private var workbench: WorkbenchViewController?
    private let panes = UIStackView()
    private let picker = UISegmentedControl(items: [String(localized: "对话"), String(localized: "操作台")])
    private var chatWidth: NSLayoutConstraint?
    private var splitRatio: CGFloat = 0.51
    private var splitDragStart: CGFloat = 0
    private let divider = UIView()
    private var sidebarCollapsed: Bool {
        get { workbench?.sidebarCollapsed ?? false }
        set { workbench?.sidebarCollapsed = newValue }
    }
    private var sidebarToggle: UIBarButtonItem?
    private var trailingItems: [UIBarButtonItem] = []
    private var subagentItem = UIBarButtonItem()
    private let subagentButton = UIButton(type: .system)
    private var observer: UUID?
    // Header Git summary (desktop GitStatusIndicator): branch, changed files, +/- lines.
    private let gitButton = UIButton(type: .system)
    private var gitSummary: GitHeaderSummary?
    private var lastAgentBusy = false
    private var lastConnected = false
    private var visible = false
    init(session: AppSession, conversation: ConversationManifest) {
        self.session = session
        self.conversation = conversation
        chat = ChatViewController(session: session, conversation: conversation)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { if let observer { session.removeObserver(observer) } }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if session.activeConversationID != conversation.id { session.select(conversation) }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        if UIApplication.shared.applicationState != .background { workbench?.gitController.startStatusPolling() }
    }
    /// Busy = the desktop `writingBlocked` inputs: a running turn, a pending
    /// approval, or a submission still awaiting confirmation.
    private var agentBusy: Bool {
        let status =
            session.runtimes[conversation.id]?.status
            ?? session.conversations.first { $0.id == conversation.id }?.status ?? conversation.status
        return ["running", "waitingPermission", "waiting_permission"].contains(status)
            || session.pendingSends[conversation.id] != nil
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = conversation.title ?? String(localized: "新对话")
        view.backgroundColor = Theme.background
        navigationItem.largeTitleDisplayMode = .never
        picker.selectedSegmentIndex = 0
        picker.accessibilityIdentifier = "conversation.panes"
        picker.addAction(UIAction { [weak self] _ in self?.layoutPanes() }, for: .valueChanged)
        navigationItem.titleView = picker
        panes.axis = .horizontal
        panes.spacing = 1
        panes.alignment = .fill
        panes.backgroundColor = .separator
        view.addSubview(panes)
        panes.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            panes.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panes.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panes.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            panes.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        addChild(chat)
        panes.addArrangedSubview(chat.view)
        chat.didMove(toParent: self)
        if let connection = session.connection {
            let workspace =
                session.workspace(for: conversation)
                ?? WorkspaceRecord(
                    name: (conversation.workspace as NSString).lastPathComponent, path: conversation.workspace)
            let workbench = WorkbenchViewController(
                connection: connection, workspace: workspace, conversationId: conversation.id,
                command: { [weak session] type, payload, timeout in
                    guard let session else { throw TodexError.disconnected }
                    return try await session.command(type, payload, timeout: timeout)
                }, events: session.wireEvents(),
                insertReference: { [weak self] text in
                    self?.chat.insert(text)
                    self?.picker.selectedSegmentIndex = 0
                    self?.layoutPanes()
                },
                addReference: { [weak self] attachment in
                    self?.chat.addReference(attachment)
                    self?.picker.selectedSegmentIndex = 0
                    self?.layoutPanes()
                },
                agentBusy: { [weak self] in self?.agentBusy ?? true },
                sendToAgent: { [weak self] text in
                    guard let self else { throw TodexError.disconnected }
                    return try await self.sendToAgent(text)
                },
                openWorktree: { [weak self] path in
                    guard let self else { throw TodexError.disconnected }
                    try await self.openWorktree(path)
                })
            self.workbench = workbench
            addChild(workbench)
            panes.addArrangedSubview(workbench.view)
            workbench.didMove(toParent: self)
            chat.openFile = { [weak self] path in
                self?.workbench?.openFile(path)
                self?.picker.selectedSegmentIndex = 1
                self?.layoutPanes()
            }
            chat.openGit = { [weak self] in
                self?.workbench?.openGit()
                self?.picker.selectedSegmentIndex = 1
                self?.layoutPanes()
            }
            chat.openCatalog = { [weak self] in self?.showCatalog() }
            chatWidth = chat.view.widthAnchor.constraint(equalToConstant: 0)
            // Drag handle overlaid on the 1pt separator between the two panes.
            divider.isHidden = true
            divider.backgroundColor = .clear
            divider.accessibilityIdentifier = "conversation.split"
            let grip = UIView()
            grip.backgroundColor = .tertiaryLabel
            grip.layer.cornerRadius = 2
            grip.translatesAutoresizingMaskIntoConstraints = false
            divider.addSubview(grip)
            view.addSubview(divider)
            divider.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                divider.centerXAnchor.constraint(equalTo: chat.view.trailingAnchor, constant: 0.5),
                divider.topAnchor.constraint(equalTo: panes.topAnchor),
                divider.bottomAnchor.constraint(equalTo: panes.bottomAnchor),
                divider.widthAnchor.constraint(equalToConstant: 18),
                grip.centerXAnchor.constraint(equalTo: divider.centerXAnchor),
                grip.centerYAnchor.constraint(equalTo: divider.centerYAnchor),
                grip.widthAnchor.constraint(equalToConstant: 4),
                grip.heightAnchor.constraint(equalToConstant: 32),
            ])
            divider.addGestureRecognizer(
                UIPanGestureRecognizer(target: self, action: #selector(dragSplit(_:))))
        }
        let more = UIBarButtonItem(
            image: Theme.icon("ellipsis.circle"),
            menu: UIMenu(children: [
                UIAction(title: String(localized: "能力目录"), image: Theme.icon("square.grid.2x2")) { [weak self] _ in self?.showCatalog() },
                UIAction(title: String(localized: "使用统计"), image: Theme.icon("chart.bar")) { [weak self] _ in self?.showUsage() },
                UIAction(title: String(localized: "子代理与记忆"), image: Theme.icon("brain")) { [weak self] _ in self?.showAuxiliary() },
                UIAction(title: String(localized: "导出对话"), image: Theme.icon("square.and.arrow.up")) { [weak self] _ in self?.export() },
            ]))
        more.accessibilityLabel = String(localized: "对话菜单")
        // Desktop parity: a subagents entry with a live count appears while any
        // subagent of this conversation is running or queued.
        // A custom view: a plain bar item would show only the icon, not the count.
        subagentButton.addAction(UIAction { [weak self] _ in self?.showAuxiliary() }, for: .touchUpInside)
        subagentButton.accessibilityIdentifier = "conversation.subagents"
        subagentItem = UIBarButtonItem(customView: subagentButton)
        subagentItem.isHidden = true
        var items = [more, subagentItem]
        if let workbench {
            gitButton.menu = workbench.gitMenu(host: self)
            gitButton.showsMenuAsPrimaryAction = true
            gitButton.accessibilityLabel = String(localized: "Git 操作")
            gitButton.accessibilityIdentifier = "conversation.git"
            renderGitButton()
            registerForTraitChanges([UITraitHorizontalSizeClass.self]) {
                (self: ConversationContainerController, _: UITraitCollection) in self.renderGitButton()
            }
            items.append(UIBarButtonItem(customView: gitButton))
            workbench.gitController.onHeaderStatus = { [weak self] summary in
                self?.gitSummary = summary
                self?.renderGitButton()
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(enteredForeground), name: UIApplication.willEnterForegroundNotification,
                object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(enteredBackground), name: UIApplication.didEnterBackgroundNotification,
                object: nil)
        }
        trailingItems = items
        if workbench != nil {
            let toggle = UIBarButtonItem(
                image: Theme.icon("sidebar.trailing"),
                primaryAction: UIAction { [weak self] _ in self?.toggleSidebar() })
            toggle.accessibilityLabel = String(localized: "切换操作台侧栏")
            toggle.accessibilityIdentifier = "conversation.sidebarToggle"
            sidebarToggle = toggle
        }
        navigationItem.rightBarButtonItems = items
        lastAgentBusy = agentBusy
        observer = session.observe { [weak self] in
            guard let self else { return }
            self.title = self.session.conversations.first { $0.id == self.conversation.id }?.title ?? String(localized: "对话")
            self.sessionChanged()
        }
        sessionChanged()
    }
    private func sessionChanged() {
        let active = (session.runtimes[conversation.id]?.subagents ?? []).filter {
            ["running", "queued"].contains($0["status"].stringValue)
        }.count
        subagentItem.isHidden = active == 0
        var config = UIButton.Configuration.plain()
        config.image = Theme.icon("person.2")
        config.imagePadding = 4
        config.title = "\(active)"
        config.contentInsets = .init(top: 4, leading: 4, bottom: 4, trailing: 4)
        subagentButton.configuration = config
        subagentButton.accessibilityLabel = String(localized: "子代理，\(active) 个运行或排队中")
        guard let workbench else { return }
        workbench.updateLatency(
            session.isConnected ? session.healthLatencyMs.map { "\($0) ms" } ?? String(localized: "检测中") : String(localized: "未连接"))
        let busy = agentBusy
        let connected = session.isConnected
        let reconnected = connected && !lastConnected
        if connected != lastConnected {
            lastConnected = connected
            renderGitButton()
        }
        // Poll right away when the Agent starts/stops or the backend comes back.
        if busy != lastAgentBusy || reconnected {
            lastAgentBusy = busy
            workbench.gitController.agentStateChanged()
        }
    }
    @objc private func enteredForeground() {
        if visible { workbench?.gitController.startStatusPolling() }
    }
    @objc private func enteredBackground() {
        workbench?.gitController.stopStatusPolling()
    }
    /// Compact "branch · N +a −d" title; long branch names truncate in the middle.
    private func renderGitButton() {
        var config = UIButton.Configuration.plain()
        config.image = Theme.icon("point.3.connected.trianglepath.dotted")
        config.imagePadding = 4
        config.contentInsets = .init(top: 4, leading: 4, bottom: 4, trailing: 4)
        config.titleLineBreakMode = .byTruncatingMiddle
        let font = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .medium)
        let title = NSMutableAttributedString()
        func add(_ text: String, _ color: UIColor = .label) {
            title.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        var detail = ""
        if !session.isConnected {
            add(String(localized: "未连接"), .secondaryLabel)
            detail = String(localized: "后端未连接，Git 状态暂不可用")
        } else if let summary = gitSummary {
            // Phones keep the pane picker readable: branch and file count only.
            let regular = traitCollection.horizontalSizeClass == .regular
            let limit = regular ? 24 : 10
            if let error = summary.error {
                add(String(localized: "Git 不可用"), .systemOrange)
                detail = String(localized: "Git 状态不可用：\(error)")
            } else if !summary.initialized {
                add(String(localized: "未初始化"), .secondaryLabel)
                detail = String(localized: "尚未初始化 Git · \(summary.repositoryPath)")
            } else {
                var branch = summary.branch ?? "Detached"
                if let name = summary.repositoryName { branch = "\(name):\(branch)" }
                if branch.count > limit { branch = String(branch.prefix(limit - 1)) + "…" }
                add(branch)
                if summary.changedFiles > 0 {
                    let more = summary.truncated ? "…" : ""
                    add(" \(summary.changedFiles)\(more)", .secondaryLabel)
                    if regular {
                        add(" +\(summary.additions)", .systemGreen)
                        add(" −\(summary.deletions)", .systemRed)
                    }
                }
                detail =
                    String(localized: "\(summary.repositoryPath) · 分支 \(summary.branch ?? "Detached HEAD") · \(summary.changedFiles) 个变更文件 +\(summary.additions) −\(summary.deletions)")
                    + (summary.truncated ? String(localized: "（统计已截断）") : "")
            }
        }
        config.attributedTitle = title.length > 0 ? AttributedString(title) : nil
        gitButton.configuration = config
        gitButton.accessibilityValue = detail.isEmpty ? nil : detail
        gitButton.sizeToFit()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPanes()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        visible = false
        workbench?.gitController.stopStatusPolling()
        if isMovingFromParent {
            if let observer { session.removeObserver(observer) }
            session.persist()
        }
    }
    private func layoutPanes() {
        let canSplit =
            view.bounds.width >= 900 && traitCollection.horizontalSizeClass == .regular
            && workbench != nil
        let wide = canSplit && !sidebarCollapsed
        if let chatWidth {
            chatWidth.isActive = wide
            if wide { chatWidth.constant = panes.bounds.width * splitRatio - 0.5 }
        }
        divider.isHidden = !wide
        if !wide, picker.selectedSegmentIndex == 1 { chat.view.endEditing(true) }
        if !wide, picker.selectedSegmentIndex == 0 { workbench?.view.endEditing(true) }
        chat.view.isHidden = !wide && picker.selectedSegmentIndex == 1 && workbench != nil
        workbench?.view.isHidden = !wide && picker.selectedSegmentIndex == 0
        navigationItem.titleView = wide ? nil : picker
        var items = trailingItems
        if canSplit, let sidebarToggle { items.append(sidebarToggle) }
        navigationItem.rightBarButtonItems = items
    }
    private func toggleSidebar() {
        sidebarCollapsed.toggle()
        if sidebarCollapsed { picker.selectedSegmentIndex = 0 }
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut) {
            self.layoutPanes()
            self.view.layoutIfNeeded()
        }
    }
    @objc private func dragSplit(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            splitDragStart = chatWidth?.constant ?? chat.view.bounds.width
        case .changed:
            let total = panes.bounds.width
            guard total > 0 else { return }
            // Keep both panes usable: at least 320pt for chat, 280 for workbench.
            let width = min(max(splitDragStart + gesture.translation(in: view).x, 320), total - 281)
            chatWidth?.constant = width
            splitRatio = width / total
        default:
            break
        }
    }
    /// Goes through the composer send pipeline so a busy Agent queues the
    /// request; returns true when it was queued rather than submitted.
    private func sendToAgent(_ text: String) async throws -> Bool {
        let busy = ["running", "waitingPermission", "waiting_permission"].contains(
            session.runtimes[conversation.id]?.status ?? "")
        try await session.send(ComposerDraft(text: text), in: conversation)
        // A busy Agent receives it through the local or the Agent's own queue.
        return busy
    }
    /// Desktop openGitWorktree: reuse or register the worktree as a workspace,
    /// then open its latest conversation or create one with this conversation's
    /// Agent and preferences.
    private func openWorktree(_ path: String) async throws {
        guard let api = session.api, let connection = session.connection, session.isConnected else {
            throw TodexError.disconnected
        }
        func standardized(_ value: String) -> String { URL(fileURLWithPath: value).standardizedFileURL.path }
        func match() -> WorkspaceRecord? {
            session.workspaces.first { $0.path == path || standardized($0.path) == standardized(path) }
        }
        if match() == nil {
            let source = session.workspace(for: conversation)
            var record = WorkspaceRecord(
                name: (path as NSString).lastPathComponent, path: path,
                tenantId: source.map { $0.tenantId.isEmpty ? connection.tenantId : $0.tenantId } ?? connection.tenantId)
            if let source {
                record.model = source.model
                record.reasoningEffort = source.reasoningEffort
                record.approvalPolicy = source.approvalPolicy
                record.sandboxMode = source.sandboxMode
            }
            _ = try await HTTPClient(connection: connection).request(
                .put, path: "/v2/workspaces", body: ["workspaces": .array([try JSONValue(encoding: record)])])
            try await session.refresh()
        }
        guard let workspace = match() else {
            throw TodexError.invalid(String(localized: "后端未接受此工作区路径（可能不在允许的工作区根目录内）"))
        }
        var target = session.conversations
            .filter { $0.archivedAt == nil && ($0.workspaceId == workspace.id || $0.workspace == workspace.path) }
            .max { $0.updatedAt < $1.updatedAt }
        if target == nil {
            let created = try await api.createConversation(
                workspace: workspace, provider: conversation.provider, profile: conversation.providerProfile)
            try await session.refresh()
            session.updatePreferences(session.preferences(for: conversation), for: created)
            target = session.conversations.first { $0.id == created.id } ?? created
        }
        guard let target, let navigationController else { return }
        session.select(target)
        navigationController.pushViewController(
            ConversationContainerController(session: session, conversation: target), animated: true)
    }
    private func showCatalog() {
        guard let connection = session.connection else { return }
        let catalog = CatalogViewController(
            connection: connection, workspace: conversation.workspace, provider: conversation.provider,
            providers: session.providers,
            command: { [weak self] type, payload, timeout in
                guard let self else { throw TodexError.disconnected }
                var value = payload
                if type.hasPrefix("mcp.") { value["conversationId"] = .string(conversation.id) }
                return try await session.command(type, value, timeout: timeout)
            }, insertSkill: { [weak self] id, name in self?.chat.insertSkill(id, name: name) },
            attachedSkills: { [weak self] in
                guard let self else { return [] }
                return Set(session.drafts[conversation.id]?.skills.map(\.id) ?? [])
            },
            insertText: { [weak self] in self?.chat.insert($0) })
        presentPage(catalog)
    }
    private func showUsage() {
        presentPage(UsageViewController(records: session.runtimes[conversation.id]?.usageRecords ?? []))
    }
    private func showAuxiliary() {
        presentPage(AuxiliaryViewController(session: session, conversation: conversation))
    }
    private func export() {
        let messages = session.runtimes[conversation.id]?.messages.reversed() ?? []
        let text =
            "# \(title ?? "TodeX")\n\n" + messages.map { "## \($0.role)\n\n\($0.text)" }.joined(separator: "\n\n")
        let share = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        share.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(share, animated: true)
    }
    private func presentPage(_ page: UIViewController) {
        let nav = UINavigationController(rootViewController: page)
        page.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
        present(nav, animated: true)
    }
}
