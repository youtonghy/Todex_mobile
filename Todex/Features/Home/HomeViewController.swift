import TodexCore
import UIKit

final class HomeViewController: UIViewController, UITableViewDataSource, UITableViewDelegate,
    UISearchResultsUpdating
{
    let session: AppSession
    private var observer: UUID?
    private let search = UISearchController(searchResultsController: nil)
    private let filter = UISegmentedControl(items: ["工作区", "任务", "归档"])
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let board = TaskBoardView()
    private enum HomeRow {
        case conversation(ConversationManifest)
    }
    private var groups: [(WorkspaceRecord, [HomeRow])] = []
    private var collapsed: Set<String> = []
    private var expanded: Set<String> = []
    private let statusLabel = Theme.label("尚未连接", style: .subheadline, color: .secondaryLabel)

    init(session: AppSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "TodeX"
        view.backgroundColor = Theme.background
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        search.searchResultsUpdater = self
        search.searchBar.placeholder = "搜索工作区与对话"
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        let settings = UIBarButtonItem(
            image: Theme.icon("slider.horizontal.3"), primaryAction: UIAction { [weak self] _ in self?.showSettings() })
        settings.accessibilityLabel = "连接与设置"
        let add = UIBarButtonItem(
            image: Theme.icon("plus"),
            menu: UIMenu(children: [
                UIAction(title: "添加工作区", image: Theme.icon("folder.badge.plus")) { [weak self] _ in self?.addWorkspace()
                },
                UIAction(title: "新建对话", image: Theme.icon("square.and.pencil")) { [weak self] _ in
                    self?.chooseWorkspaceForConversation()
                },
            ]))
        add.accessibilityLabel = "新建"
        navigationItem.leftBarButtonItem = settings
        navigationItem.rightBarButtonItem = add
        filter.selectedSegmentIndex = 0
        filter.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
        filter.accessibilityIdentifier = "home.filter"
        filter.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        filter.setContentCompressionResistancePriority(.required, for: .vertical)
        let header = UIStackView(arrangedSubviews: [filter, statusLabel])
        header.axis = .vertical
        header.spacing = 14
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = .init(top: 10, leading: 20, bottom: 12, trailing: 20)
        view.addSubview(header)
        view.addSubview(table)
        view.addSubview(board)
        for child in [header, table, board] { child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.topAnchor.constraint(equalTo: header.bottomAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            board.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            board.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            board.topAnchor.constraint(equalTo: header.bottomAnchor),
            board.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        table.dataSource = self
        table.delegate = self
        table.accessibilityIdentifier = "home.list"
        board.isHidden = true
        board.handlers = .init(
            open: { [weak self] task in self?.openTask(task) },
            enterWorkspace: { [weak self] workspace in self?.enterWorkspace(workspace) },
            addTask: { [weak self] workspace in
                self?.askText(title: "新建任务", message: workspace.name, value: "") { title in
                    self?.session.addTask(workspaceId: workspace.id, title: title)
                }
            },
            statusMenu: { [weak self] task in self?.taskStatusMenu(task) ?? UIMenu() },
            attachMenu: { [weak self] task, workspace in
                self?.attachMenu(task, workspace: workspace) ?? UIMenu()
            },
            moreMenu: { [weak self] task, workspace in
                self?.taskMenu(task, workspace: workspace) ?? UIMenu()
            },
            linkedTitle: { [weak self] task in
                guard let self, task.conversationId != nil else { return nil }
                return self.linkedConversation(task)?.title?.isEmpty == false
                    ? self.linkedConversation(task)?.title : "对话已失效"
            })
        table.refreshControl = UIRefreshControl()
        table.refreshControl?.addAction(
            UIAction { [weak self] _ in
                Task { [weak self] in
                    guard let self else { return }
                    do { try await session.refresh() } catch { showError(error) }
                    table.refreshControl?.endRefreshing()
                }
            }, for: .valueChanged)
        observer = session.observe { [weak self] in self?.reload() }
        reload()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        session.activeConversationID = nil
        Theme.applyAppearance(to: view.window)
        reload()
    }
    isolated deinit { if let observer { session.removeObserver(observer) } }
    func updateSearchResults(for searchController: UISearchController) { reload() }
    private func reload() {
        let query = (search.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sortedWorkspaces = session.workspaces.sorted { left, right in
            let a = session.pinnedWorkspaces.firstIndex(of: left.id) ?? Int.max
            let b = session.pinnedWorkspaces.firstIndex(of: right.id) ?? Int.max
            return a == b ? left.name.localizedStandardCompare(right.name) == .orderedAscending : a < b
        }
        let showingBoard = filter.selectedSegmentIndex == 1
        table.isHidden = showingBoard
        board.isHidden = !showingBoard
        if showingBoard {
            // Task plan: desktop-parity vertical kanban, one column per workspace.
            board.reload(workspaces: sortedWorkspaces) { workspace in
                session.tasks(for: workspace.id).filter {
                    query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                        || workspace.name.localizedCaseInsensitiveContains(query)
                }
            }
            groups = []
        } else {
            groups = sortedWorkspaces.compactMap { workspace in
                let records = session.conversations.filter { conversation in
                    guard conversation.workspaceId == workspace.id || conversation.workspace == workspace.path else {
                        return false
                    }
                    guard (filter.selectedSegmentIndex == 2) == (conversation.archivedAt != nil) else {
                        return false
                    }
                    return query.isEmpty || (conversation.title ?? "").localizedCaseInsensitiveContains(query)
                        || workspace.name.localizedCaseInsensitiveContains(query)
                }.sorted { left, right in
                    let a = session.pinnedConversations.firstIndex(of: left.id) ?? Int.max
                    let b = session.pinnedConversations.firstIndex(of: right.id) ?? Int.max
                    return a == b ? left.updatedAt > right.updatedAt : a < b
                }
                return (!query.isEmpty || filter.selectedSegmentIndex != 0) && records.isEmpty
                    ? nil : (workspace, records.map(HomeRow.conversation))
            }
        }
        statusLabel.text = [session.connection?.name, session.status].compactMap { $0 }.joined(separator: " · ")
        statusLabel.textColor = session.isConnected ? Theme.accent : .secondaryLabel
        if showingBoard ? sortedWorkspaces.isEmpty : groups.isEmpty {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = Theme.icon(
                session.connections.isEmpty ? "network" : "bubble.left.and.bubble.right", pointSize: 40)
            config.text =
                session.connections.isEmpty
                ? "连接你的工作区"
                : (filter.selectedSegmentIndex == 2
                    ? "没有归档对话" : (filter.selectedSegmentIndex == 1 ? "还没有工作区可管理任务" : "从一个想法开始"))
            config.secondaryText =
                session.connections.isEmpty
                ? "连接 TodeX 后端，随时继续你的对话与工作。"
                : session.lastError
                    ?? (filter.selectedSegmentIndex == 1
                        ? "添加工作区后，可在这里按工作区管理任务并贴到对话。" : "添加后端上的项目目录，创建你的第一个对话。")
            config.button.title = session.connections.isEmpty ? "连接后端" : (session.isConnected ? "添加工作区" : "重新连接")
            config.buttonProperties.primaryAction = UIAction { [weak self] _ in
                guard let self else { return }
                if session.connections.isEmpty {
                    showSettings()
                } else if session.isConnected {
                    addWorkspace()
                } else {
                    Task { await session.connect() }
                }
            }
            contentUnavailableConfiguration = config
        } else {
            contentUnavailableConfiguration = nil
        }
        table.reloadData()
    }
    func numberOfSections(in tableView: UITableView) -> Int { groups.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let (workspace, items) = groups[section]
        if collapsed.contains(workspace.id) { return 0 }
        return min(items.count, expanded.contains(workspace.id) ? Int.max : 5) + 1
    }
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let workspace = groups[section].0
        let name = UIButton(type: .system)
        name.contentHorizontalAlignment = .leading
        var config = UIButton.Configuration.plain()
        config.title = Self.displayName(workspace)
        config.titleLineBreakMode = .byTruncatingMiddle
        config.image = Theme.icon(collapsed.contains(workspace.id) ? "chevron.right" : "folder")
        config.imagePadding = 9
        config.baseForegroundColor = .secondaryLabel
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var value = $0
            value.font = .preferredFont(forTextStyle: .headline)
            return value
        }
        name.configuration = config
        name.titleLabel?.numberOfLines = 1
        name.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                if !collapsed.insert(workspace.id).inserted { collapsed.remove(workspace.id) }
                reload()
            }, for: .touchUpInside)
        let more = UIButton(type: .system)
        more.setImage(Theme.icon("ellipsis"), for: .normal)
        more.showsMenuAsPrimaryAction = true
        more.menu = workspaceMenu(workspace)
        more.accessibilityLabel = "\(workspace.name) 操作"
        more.widthAnchor.constraint(equalToConstant: 44).isActive = true
        more.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let stack = UIStackView(arrangedSubviews: [name, more])
        stack.alignment = .center
        stack.spacing = 8
        return stack
    }
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        max(54, UIFont.preferredFont(forTextStyle: .headline).lineHeight + 20)
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let (workspace, items) = groups[indexPath.section]
        let visible = min(items.count, expanded.contains(workspace.id) ? Int.max : 5)
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var config = cell.defaultContentConfiguration()
        if indexPath.row >= visible {
            config.text = visible < items.count ? "显示其余 \(items.count - visible) 个对话" : "新建对话"
            config.image = Theme.icon(visible < items.count ? "chevron.down" : "plus.bubble")
            config.textProperties.color = Theme.accent
        } else {
            switch items[indexPath.row] {
            case .conversation(let item):
                let runtime = session.runtimes[item.id]
                let state = runtime?.status ?? item.status
                config.text = item.title?.isEmpty == false ? item.title : "新对话"
                let unread = (session.readSequences[item.id] ?? 0) < item.lastSequence
                config.secondaryText = [
                    item.provider, statusText(state), unread ? "有新消息" : nil,
                    session.taskConversationIDs.contains(item.id) ? "有任务" : nil,
                ].compactMap { $0 }.joined(separator: " · ")
                config.secondaryTextProperties.color = .secondaryLabel
                config.image = Theme.icon(
                    session.pinnedConversations.contains(item.id)
                        ? "pin.fill" : (state == "running" ? "circle.dotted.circle" : "bubble.left"))
                config.imageProperties.tintColor = unread || state == "running" ? Theme.accent : .secondaryLabel
                config.textProperties.numberOfLines = 2
                cell.accessoryType = .disclosureIndicator
                cell.accessibilityIdentifier = "conversation.\(item.id)"
            }
        }
        cell.contentConfiguration = config
        cell.backgroundColor = Theme.surface
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let (workspace, items) = groups[indexPath.section]
        let visible = min(items.count, expanded.contains(workspace.id) ? Int.max : 5)
        if indexPath.row >= visible {
            if visible < items.count {
                expanded.insert(workspace.id)
                reload()
            } else {
                createConversation(workspace)
            }
            return
        }
        switch items[indexPath.row] {
        case .conversation(let item): open(item)
        }
    }
    func open(_ conversation: ConversationManifest) {
        search.isActive = false
        session.select(conversation)
        navigationController?.pushViewController(
            ConversationContainerController(session: session, conversation: conversation), animated: true)
    }
    func tableView(
        _ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint
    ) -> UIContextMenuConfiguration? {
        let group = groups[indexPath.section]
        guard indexPath.row < min(group.1.count, expanded.contains(group.0.id) ? Int.max : 5) else { return nil }
        switch group.1[indexPath.row] {
        case .conversation(let item):
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in self?.conversationMenu(item) })
        }
    }
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration?
    {
        let group = groups[indexPath.section]
        guard indexPath.row < min(group.1.count, expanded.contains(group.0.id) ? Int.max : 5) else { return nil }
        switch group.1[indexPath.row] {
        case .conversation(let item):
            let action = UIContextualAction(style: .normal, title: item.archivedAt == nil ? "归档" : "恢复") {
                [weak self] _, _, done in
                self?.archive(item, archived: item.archivedAt == nil)
                done(true)
            }
            action.backgroundColor = Theme.accent
            return UISwipeActionsConfiguration(actions: [action])
        }
    }
    private func conversationMenu(_ item: ConversationManifest) -> UIMenu {
        let pinned = session.pinnedConversations.contains(item.id)
        var actions: [UIMenuElement] = [
            UIAction(title: pinned ? "取消置顶" : "置顶", image: Theme.icon("pin")) { [weak self] _ in
                guard let self else { return }
                if pinned {
                    session.pinnedConversations.removeAll { $0 == item.id }
                } else {
                    session.pinnedConversations.insert(item.id, at: 0)
                }
                session.persist()
                reload()
            },
            UIAction(title: "重命名", image: Theme.icon("pencil")) { [weak self] _ in
                self?.askText(title: "对话名称", value: item.title ?? "") { name in
                    self?.update(item, patch: ["title": .string(name)])
                }
            },
            UIAction(title: item.archivedAt == nil ? "归档" : "恢复", image: Theme.icon("archivebox")) { [weak self] _ in
                self?.archive(item, archived: item.archivedAt == nil)
            },
        ]
        if session.provider(for: item)?.capabilities["controlActions"].arrayValue.contains("fork") == true {
            actions.append(
                UIAction(title: "分叉对话", image: Theme.icon("arrow.triangle.branch")) { [weak self] _ in
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            let result = try await session.control("fork", conversation: item)
                            try await session.refresh()
                            if let conversation = session.conversations.first(where: {
                                $0.id == result["conversationId"].stringValue
                            }) {
                                open(conversation)
                            }
                        } catch { showError(error) }
                    }
                })
        }
        if item.archivedAt != nil {
            actions.append(
                UIAction(title: "永久删除", image: Theme.icon("trash"), attributes: .destructive) { [weak self] _ in
                    self?.confirm(title: "永久删除对话？", message: "将从后端删除此对话及历史，无法撤销。", destructive: true) {
                        self?.delete(item)
                    }
                })
        }
        return UIMenu(children: actions)
    }
    private func workspaceConversations(_ workspace: WorkspaceRecord) -> [ConversationManifest] {
        session.conversations
            .filter {
                ($0.workspaceId == workspace.id || $0.workspace == workspace.path) && $0.archivedAt == nil
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    private func linkedConversation(_ task: KanbanTask) -> ConversationManifest? {
        task.conversationId.flatMap { id in session.conversations.first { $0.id == id } }
    }
    private func attachMenu(_ task: KanbanTask, workspace: WorkspaceRecord) -> UIMenuElement {
        let conversations = workspaceConversations(workspace)
        var children: [UIMenuElement] = conversations.prefix(12).map { conversation in
            UIAction(
                title: conversation.title?.isEmpty == false ? conversation.title! : "新对话",
                state: task.conversationId == conversation.id ? .on : .off
            ) { [weak self] _ in
                self?.session.attachTask(task.id, conversationId: conversation.id)
            }
        }
        if task.conversationId != nil {
            children.append(
                UIAction(title: "取消关联", attributes: .destructive) { [weak self] _ in
                    self?.session.attachTask(task.id, conversationId: nil)
                })
        }
        if conversations.isEmpty { children = [UIAction(title: "这个工作区还没有对话", attributes: .disabled) { _ in }] }
        return UIMenu(
            title: task.conversationId == nil ? "关联到对话" : "更换关联对话",
            image: Theme.icon("pin", pointSize: 13), children: children)
    }
    private func taskStatusMenu(_ task: KanbanTask) -> UIMenu {
        UIMenu(
            title: "任务状态",
            children: KanbanTask.Status.allCases.map { status in
                UIAction(
                    title: status.label, image: Theme.icon(status.symbol, pointSize: 13),
                    state: task.status == status ? .on : .off
                ) { [weak self] _ in self?.session.setTaskStatus(task.id, status) }
            })
    }
    /// Board actions: open the linked conversation, or offer task operations.
    private func openTask(_ task: KanbanTask) {
        if let linked = linkedConversation(task) {
            open(linked)
        } else if let workspace = session.workspaces.first(where: { $0.id == task.workspaceId }) {
            presentTaskSheet(task, workspace: workspace)
        }
    }
    /// Column header arrow: open the workspace's latest conversation or create one.
    private func enterWorkspace(_ workspace: WorkspaceRecord) {
        if let latest = workspaceConversations(workspace).first {
            open(latest)
        } else {
            createConversation(workspace)
        }
    }
    private func taskMenu(_ task: KanbanTask, workspace: WorkspaceRecord) -> UIMenu {
        var elements: [UIMenuElement] = [
            UIMenu(
                title: "任务状态", options: .displayInline,
                children: taskStatusMenu(task).children),
            attachMenu(task, workspace: workspace),
        ]
        if let linked = linkedConversation(task) {
            elements.append(
                UIAction(title: "写入对话草稿", image: Theme.icon("square.and.pencil", pointSize: 13)) {
                    [weak self] _ in
                    guard let self else { return }
                    var draft = session.drafts[linked.id] ?? ComposerDraft()
                    draft.text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "任务：\(task.title)" : "\(draft.text)\n任务：\(task.title)"
                    session.drafts[linked.id] = draft
                    session.saveSoon()
                    open(linked)
                })
            elements.append(
                UIAction(title: "打开对话", image: Theme.icon("bubble.left", pointSize: 13)) {
                    [weak self] _ in self?.open(linked)
                })
        }
        elements.append(
            UIAction(title: "重命名", image: Theme.icon("pencil", pointSize: 13)) { [weak self] _ in
                self?.askText(title: "任务标题", value: task.title) { name in
                    self?.session.renameTask(task.id, title: name)
                }
            })
        elements.append(
            UIAction(title: "删除任务", image: Theme.icon("trash", pointSize: 13), attributes: .destructive) {
                [weak self] _ in self?.session.removeTask(task.id)
            })
        return UIMenu(children: elements)
    }
    /// Tap on an unlinked task presents the same operations as an action sheet.
    private func presentTaskSheet(_ task: KanbanTask, workspace: WorkspaceRecord) {
        let sheet = UIAlertController(title: task.title, message: "状态：\(task.status.label)", preferredStyle: .actionSheet)
        for status in KanbanTask.Status.allCases where status != task.status {
            sheet.addAction(
                UIAlertAction(title: "标记为\(status.label)", style: .default) { [weak self] _ in
                    self?.session.setTaskStatus(task.id, status)
                })
        }
        sheet.addAction(
            UIAlertAction(
                title: task.conversationId == nil ? "关联到对话" : "更换关联对话", style: .default
            ) { [weak self] _ in
                guard let self else { return }
                let conversations = workspaceConversations(workspace)
                guard !conversations.isEmpty else {
                    WBUI.message(on: self, title: "没有可关联的对话", text: "这个工作区还没有对话。")
                    return
                }
                let picker = UIAlertController(title: "关联到对话", message: nil, preferredStyle: .actionSheet)
                for conversation in conversations.prefix(12) {
                    picker.addAction(
                        UIAlertAction(
                            title: conversation.title?.isEmpty == false ? conversation.title! : "新对话",
                            style: .default
                        ) { [weak self] _ in
                            self?.session.attachTask(task.id, conversationId: conversation.id)
                        })
                }
                if task.conversationId != nil {
                    picker.addAction(
                        UIAlertAction(title: "取消关联", style: .destructive) { [weak self] _ in
                            self?.session.attachTask(task.id, conversationId: nil)
                        })
                }
                WBUI.presentSheet(picker, on: self)
            })
        sheet.addAction(
            UIAlertAction(title: "重命名", style: .default) { [weak self] _ in
                self?.askText(title: "任务标题", value: task.title) { name in
                    self?.session.renameTask(task.id, title: name)
                }
            })
        sheet.addAction(
            UIAlertAction(title: "删除任务", style: .destructive) { [weak self] _ in
                self?.session.removeTask(task.id)
            })
        WBUI.presentSheet(sheet, on: self)
    }
    private func workspaceMenu(_ workspace: WorkspaceRecord) -> UIMenu {
        let pinned = session.pinnedWorkspaces.contains(workspace.id)
        return UIMenu(children: [
            UIAction(title: "新建对话", image: Theme.icon("plus.bubble")) { [weak self] _ in
                self?.createConversation(workspace)
            },
            UIAction(title: pinned ? "取消置顶" : "置顶", image: Theme.icon("pin")) { [weak self] _ in
                guard let self else { return }
                if pinned {
                    session.pinnedWorkspaces.removeAll { $0 == workspace.id }
                } else {
                    session.pinnedWorkspaces.insert(workspace.id, at: 0)
                }
                session.persist()
                reload()
            },
            UIAction(title: "重命名", image: Theme.icon("pencil")) { [weak self] _ in
                self?.askText(title: "工作区名称", value: workspace.name) { name in
                    var updated = workspace
                    updated.name = name
                    self?.saveWorkspace(updated)
                }
            },
            UIAction(title: "添加其他目录", image: Theme.icon("folder.badge.plus")) { [weak self] _ in self?.addWorkspace() },
            UIAction(title: "工作区信任", image: Theme.icon("checkmark.shield")) { [weak self] _ in self?.trust(workspace) },
            UIAction(title: "移除工作区", image: Theme.icon("trash"), attributes: .destructive) { [weak self] _ in
                self?.confirm(title: "移除工作区？", message: "将撤销此工作区的执行信任，后端对话会保留。", destructive: true) { [weak self] in
                    Task { [weak self] in
                        guard let self, let api = session.api else { return }
                        do {
                            _ = try await api.http.request(
                                .delete, path: "/v2/workspaces/\(HTTPClient.segment(workspace.id))")
                            try await session.refresh()
                        } catch { showError(error) }
                    }
                }
            },
        ])
    }
    private func trust(_ workspace: WorkspaceRecord) {
        Task {
            guard let api = session.api else { return }
            do {
                let value = try await api.workspaceTrust(id: workspace.id)
                let trusted = value["trusted"].boolValue
                confirm(
                    title: trusted ? "撤销执行信任？" : "信任此工作区？",
                    message: "\(workspace.path)\n信任允许后端 Agent 执行项目中的任务；这不是文件系统沙箱。"
                ) {
                    Task {
                        do {
                            _ = try await api.updateWorkspaceTrust(id: workspace.id, trusted: !trusted)
                            self.showNotice(title: "信任状态已更新", message: trusted ? "已撤销执行信任" : "已信任工作区")
                        } catch { self.showError(error) }
                    }
                }
            } catch { showError(error) }
        }
    }
    private func archive(_ item: ConversationManifest, archived: Bool) {
        update(item, patch: ["archived": .bool(archived)])
    }
    private func update(_ item: ConversationManifest, patch: JSONValue) {
        Task {
            do {
                _ = try await session.api?.updateConversation(id: item.id, patch: patch)
                try await session.refresh()
            } catch { showError(error) }
        }
    }
    private func delete(_ item: ConversationManifest) {
        Task {
            do {
                _ = try await session.api?.http.request(
                    .delete, path: "/v2/conversations/\(HTTPClient.segment(item.id))")
                try await session.refresh()
            } catch { showError(error) }
        }
    }
    private func saveWorkspace(_ workspace: WorkspaceRecord) {
        Task {
            do {
                _ = try await session.api?.http.request(
                    .put, path: "/v2/workspaces", body: ["workspaces": .array([try JSONValue(encoding: workspace)])])
                try await session.refresh()
            } catch { showError(error) }
        }
    }
    private func addWorkspace() {
        guard session.isConnected, let connection = session.connection else {
            showSettings()
            return
        }
        present(
            UINavigationController(
                rootViewController: DirectoryPicker(connection: connection) { [weak self] path in
                    self?.askText(
                        title: "添加并信任工作区", message: "Agent 将能够在此后端目录执行任务：\n\(path)",
                        value: URL(fileURLWithPath: path).lastPathComponent
                    ) { name in self?.saveWorkspace(WorkspaceRecord(name: name, path: path)) }
                }), animated: true)
    }
    private func chooseWorkspaceForConversation() {
        guard !session.workspaces.isEmpty else {
            addWorkspace()
            return
        }
        let alert = UIAlertController(title: "选择工作区", message: nil, preferredStyle: .actionSheet)
        for workspace in session.workspaces {
            alert.addAction(
                UIAlertAction(title: Self.displayName(workspace), style: .default) { [weak self] _ in
                    self?.createConversation(workspace)
                })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(alert, animated: true)
    }
    private func createConversation(_ workspace: WorkspaceRecord) {
        guard session.isConnected else {
            showNotice(title: "尚未连接", message: "请先连接此工作区的后端")
            return
        }
        let alert = UIAlertController(title: "选择 Agent", message: Self.displayName(workspace), preferredStyle: .actionSheet)
        var options: [(provider: ProviderDescriptor, profile: String?, title: String)] = []
        for provider in session.providers {
            if provider.id == "acp" && !provider.profiles.isEmpty {
                for profile in provider.profiles {
                    options.append((provider, profile, "ACP · \(profile)"))
                }
            } else {
                options.append((provider, nil, provider.displayName + (provider.available ? "" : " · 不可用")))
            }
        }
        // The agent used for the previous conversation leads the list.
        if let last = session.lastAgent,
            let index = options.firstIndex(where: { $0.provider.id == last.provider && $0.profile == last.profile })
        {
            let match = options.remove(at: index)
            options.insert((match.provider, match.profile, "\(match.title) · 上次使用"), at: 0)
        }
        for option in options {
            let action = UIAlertAction(title: option.title, style: .default) { [weak self] _ in
                self?.create(workspace, provider: option.provider.id, profile: option.profile)
            }
            action.isEnabled = option.provider.available
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.popoverPresentationController?.sourceView = view
        alert.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: 100, width: 1, height: 1)
        present(alert, animated: true)
    }
    private func create(_ workspace: WorkspaceRecord, provider: String, profile: String?) {
        Task {
            guard let api = session.api else { return }
            do {
                let conversation = try await api.createConversation(
                    workspace: workspace, provider: provider, profile: profile, title: nil)
                session.rememberAgent(provider: provider, profile: profile)
                try await session.refresh()
                if let remembered = session.rememberedPreferences(for: provider) {
                    session.updatePreferences(remembered, for: conversation)
                }
                open(conversation)
            } catch { showError(error) }
        }
    }
    private func showSettings() {
        let settings = SettingsViewController(
            connections: session.connections, selectedID: session.selectedID, session: session,
            onSave: { [weak self] values, selected in
                do { try self?.session.saveConnections(values, selected: selected) } catch { self?.showError(error) }
            }, onConnect: { [weak self] connection in Task { await self?.session.connect(connection) } })
        present(UINavigationController(rootViewController: settings), animated: true)
    }
    /// Workspaces named by their full path show only the last directory component;
    /// custom names are kept as-is.
    private static func displayName(_ workspace: WorkspaceRecord) -> String {
        workspace.name.contains("/")
            ? URL(fileURLWithPath: workspace.name).lastPathComponent : workspace.name
    }
    private func statusText(_ value: String) -> String {
        switch value {
        case "running": "进行中"
        case "waiting_permission", "waitingPermission": "等待回应"
        case "failed": "未完成"
        case "interrupted", "cancelled": "已停止"
        default: "对话"
        }
    }
}
