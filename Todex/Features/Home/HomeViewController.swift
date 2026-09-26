import TodexCore
import UIKit

final class HomeViewController: UIViewController, UITableViewDataSource, UITableViewDelegate,
    UISearchResultsUpdating
{
    let session: AppSession
    private var observer: UUID?
    // Alerts once per mismatched backend version instead of on every reload.
    private var alertedBackendVersion: String?
    private let search = UISearchController(searchResultsController: nil)
    private let filter = UISegmentedControl(items: [String(localized: "工作区"), String(localized: "任务"), String(localized: "归档")])
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let board = TaskBoardView()
    private enum HomeRow {
        case conversation(ConversationManifest)
    }
    private var groups: [(WorkspaceRecord, [HomeRow])] = []
    /// Workspaces whose stored path the backend rejects: dimmed, not selectable.
    private var missing: [String: RejectedWorkspace] = [:]
    /// Other configured backends' cached workspaces (read-only, never merged
    /// into the active session); visible entries follow the search query.
    private struct OtherBackend {
        var connection: BackendConnection
        var workspaces: [WorkspaceRecord]
        var error: String?
    }
    private var otherCatalogs: [String: (workspaces: [WorkspaceRecord], error: String?)] = [:]
    private var otherBackends: [OtherBackend] = []
    private var otherBackendsKey = ""
    private var otherBackendsLoad: Task<Void, Never>?
    private var switchingBackend = false
    /// Row order key per conversation: the last settled updatedAt. A busy
    /// conversation keeps its key so streaming does not re-sort the list.
    private var completionKeys: [String: String] = [:]
    private var taskMeta: [String: (count: Int, pending: Int)] = [:]
    private var collapsed: Set<String> = []
    private var expanded: Set<String> = []
    private var reordering = false
    private var addButton: UIBarButtonItem?
    private let statusLabel = Theme.label(String(localized: "尚未连接"), style: .subheadline, color: .secondaryLabel)

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
        search.searchBar.placeholder = String(localized: "搜索工作区与对话")
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        let settings = UIBarButtonItem(
            image: Theme.icon("slider.horizontal.3"), primaryAction: UIAction { [weak self] _ in self?.showSettings() })
        settings.accessibilityLabel = String(localized: "连接与设置")
        let add = UIBarButtonItem(
            image: Theme.icon("plus"),
            menu: UIMenu(children: [
                UIAction(title: String(localized: "添加工作区"), image: Theme.icon("folder.badge.plus")) { [weak self] _ in self?.addWorkspace()
                },
                UIAction(title: String(localized: "新建对话"), image: Theme.icon("square.and.pencil")) { [weak self] _ in
                    self?.chooseWorkspaceForConversation()
                },
            ]))
        add.accessibilityLabel = String(localized: "新建")
        addButton = add
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
            addTask: { [weak self] workspace in self?.editTask(nil, workspace: workspace) },
            statusMenu: { [weak self] task in self?.taskStatusMenu(task) ?? UIMenu() },
            attachMenu: { [weak self] task, workspace in
                self?.attachMenu(task, workspace: workspace) ?? UIMenu()
            },
            moreMenu: { [weak self] task, workspace in
                self?.taskMenu(task, workspace: workspace) ?? UIMenu()
            },
            linkedTitle: { [weak self] task in
                guard let self, task.conversationId != nil else { return nil }
                guard let linked = self.linkedConversation(task) else { return "" }
                return linked.title?.isEmpty == false ? linked.title : String(localized: "新对话")
            },
            linkedStatus: { [weak self] task in
                guard let self, let linked = linkedConversation(task), let attention = attention(linked) else {
                    return nil
                }
                return (attention.color, attention.label)
            },
            moveColumn: { [weak self] source, target, after in
                self?.moveColumn(source, to: target, after: after)
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
        otherBackendsKey = ""  // Re-read other backends' caches; they may have changed meanwhile.
        reload()
    }
    isolated deinit {
        otherBackendsLoad?.cancel()
        if let observer { session.removeObserver(observer) }
    }
    func updateSearchResults(for searchController: UISearchController) { reload() }
    /// Ordering matches the desktop sidebar: pinned first (local pin order),
    /// then the synced manual sortOrder, then creation time and id.
    private func sortedWorkspaces() -> [WorkspaceRecord] {
        Self.ordered(session.workspaces, pinned: session.pinnedWorkspaces)
    }
    private static func ordered(_ workspaces: [WorkspaceRecord], pinned: [String]) -> [WorkspaceRecord] {
        workspaces.sorted { left, right in
            let a = pinned.firstIndex(of: left.id) ?? Int.max
            let b = pinned.firstIndex(of: right.id) ?? Int.max
            if a != b { return a < b }
            let leftOrder = left.sortOrder ?? 0
            let rightOrder = right.sortOrder ?? 0
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
            return left.id < right.id
        }
    }
    private func reload() {
        // A reload must not re-sort while the user is dragging rows.
        if reordering {
            table.reloadData()
            return
        }
        let query = (search.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sortedWorkspaces = sortedWorkspaces()
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
            missing = Dictionary(
                session.rejectedWorkspaces.filter { rejected in !sortedWorkspaces.contains { $0.id == rejected.id } }
                    .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            taskMeta = [:]
            for task in session.tasks where task.deletedAt == nil {
                guard let id = task.conversationId else { continue }
                taskMeta[id, default: (0, 0)].count += 1
                if task.status != .done { taskMeta[id, default: (0, 0)].pending += 1 }
            }
            for conversation in session.conversations {
                let state = session.runtimes[conversation.id]?.status ?? conversation.status
                if !Self.busy(state) || completionKeys[conversation.id] == nil {
                    completionKeys[conversation.id] = conversation.updatedAt
                }
            }
            // Missing workspaces list after the usable ones; their conversations
            // stay hidden until the path is fixed, like the desktop sidebar.
            let missingRecords = session.rejectedWorkspaces.filter { missing[$0.id] != nil }.map {
                WorkspaceRecord(id: $0.id, name: $0.name.isEmpty ? $0.path : $0.name, path: $0.path)
            }
            groups = (sortedWorkspaces + missingRecords).compactMap { workspace in
                if missing[workspace.id] != nil {
                    let visible =
                        filter.selectedSegmentIndex == 0
                        && (query.isEmpty || workspace.name.localizedCaseInsensitiveContains(query))
                    return visible ? (workspace, []) : nil
                }
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
                    if a != b { return a < b }
                    // Desktop order: last completed turn, then creation time, then id.
                    let leftKey = completionKeys[left.id] ?? left.updatedAt
                    let rightKey = completionKeys[right.id] ?? right.updatedAt
                    if leftKey != rightKey { return leftKey > rightKey }
                    if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
                    return left.id < right.id
                }
                return (!query.isEmpty || filter.selectedSegmentIndex != 0) && records.isEmpty
                    ? nil : (workspace, records.map(HomeRow.conversation))
            }
        }
        refreshOtherBackends(query: query, visible: filter.selectedSegmentIndex == 0)
        var statusParts = [session.connection?.name, session.status].compactMap { $0 }
        if session.isConnected {
            if let ms = session.healthLatencyMs {
                statusParts.append(ms < 1000 ? "\(ms)ms" : String(format: "%.1fs", Double(ms) / 1000))
            }
            if session.healthFailed { statusParts.append(String(localized: "不可达")) }
            if session.versionMismatch != nil { statusParts.append(String(localized: "版本不一致")) }
        }
        let statusColor: UIColor =
            session.isConnected ? (session.versionMismatch == nil ? Theme.accent : .systemOrange) : .secondaryLabel
        let statusFont = UIFont.preferredFont(forTextStyle: .subheadline)
        let statusText = NSMutableAttributedString()
        // The backend's label dot, as beside each desktop sidebar workspace.
        if let connection = session.connection, let dot = UIColor(labelHex: connection.labelColor) {
            statusText.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: dot, .font: statusFont]))
        }
        statusText.append(
            NSAttributedString(
                string: statusParts.joined(separator: " · "),
                attributes: [.foregroundColor: statusColor, .font: statusFont]))
        statusLabel.attributedText = statusText
        if let mismatch = session.versionMismatch {
            if alertedBackendVersion != mismatch.backend {
                alertedBackendVersion = mismatch.backend
                WBUI.message(
                    on: self, title: String(localized: "版本不一致"),
                    text: String(localized: "后端 \(mismatch.backend) 与本应用 \(mismatch.app) 版本不一致，请升级以避免不兼容。"))
            }
        } else {
            alertedBackendVersion = nil
        }
        if showingBoard ? sortedWorkspaces.isEmpty : groups.isEmpty && otherBackends.isEmpty {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = Theme.icon(
                session.connections.isEmpty ? "network" : "bubble.left.and.bubble.right", pointSize: 40)
            config.text =
                session.connections.isEmpty
                ? String(localized: "连接你的工作区")
                : (filter.selectedSegmentIndex == 2
                    ? String(localized: "没有归档对话") : (filter.selectedSegmentIndex == 1 ? String(localized: "还没有工作区可管理任务") : String(localized: "从一个想法开始")))
            config.secondaryText =
                session.connections.isEmpty
                ? String(localized: "连接 TodeX 后端，随时继续你的对话与工作。")
                : session.lastError
                    ?? (filter.selectedSegmentIndex == 1
                        ? String(localized: "添加工作区后，可在这里按工作区管理任务并贴到对话。") : String(localized: "添加后端上的项目目录，创建你的第一个对话。"))
            config.button.title = session.connections.isEmpty ? String(localized: "连接后端") : (session.isConnected ? String(localized: "添加工作区") : String(localized: "重新连接"))
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
    func numberOfSections(in tableView: UITableView) -> Int {
        reordering ? (groups.isEmpty ? 0 : 1) : groups.count + otherBackends.count
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if reordering { return groups.count }
        if section >= groups.count { return max(1, otherBackends[section - groups.count].workspaces.count) }
        let (workspace, items) = groups[section]
        if collapsed.contains(workspace.id) { return 0 }
        if missing[workspace.id] != nil { return 1 }
        return min(items.count, expanded.contains(workspace.id) ? Int.max : 5) + 1
    }
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        if reordering { return nil }
        if section >= groups.count { return backendHeader(otherBackends[section - groups.count].connection) }
        let workspace = groups[section].0
        let isMissing = missing[workspace.id] != nil
        let name = UIButton(type: .system)
        name.contentHorizontalAlignment = .leading
        var config = UIButton.Configuration.plain()
        config.title = Self.displayName(workspace)
        config.titleLineBreakMode = .byTruncatingMiddle
        config.image = Theme.icon(
            isMissing ? "exclamationmark.triangle" : (collapsed.contains(workspace.id) ? "chevron.right" : "folder"))
        config.imagePadding = 9
        config.baseForegroundColor = isMissing ? .tertiaryLabel : .secondaryLabel
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var value = $0
            value.font = .preferredFont(forTextStyle: .headline)
            return value
        }
        name.configuration = config
        name.titleLabel?.numberOfLines = 1
        if isMissing { name.accessibilityValue = String(localized: "目录在后端不可用") }
        name.addAction(
            UIAction { [weak self] _ in
                guard let self, !reordering else { return }
                if !collapsed.insert(workspace.id).inserted { collapsed.remove(workspace.id) }
                reload()
            }, for: .touchUpInside)
        let more = UIButton(type: .system)
        more.setImage(Theme.icon("ellipsis"), for: .normal)
        more.showsMenuAsPrimaryAction = true
        more.menu = workspaceMenu(workspace)
        more.accessibilityLabel = String(localized: "\(workspace.name) 操作")
        more.widthAnchor.constraint(equalToConstant: 44).isActive = true
        more.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let stack = UIStackView(arrangedSubviews: [name, more])
        stack.alignment = .center
        stack.spacing = 8
        stack.addGestureRecognizer(
            UILongPressGestureRecognizer(target: self, action: #selector(headerLongPressed(_:))))
        return stack
    }
    /// Section header for another configured backend: its label dot and name.
    private func backendHeader(_ connection: BackendConnection) -> UIView {
        let dot = UIView()
        dot.backgroundColor = UIColor(labelHex: connection.labelColor) ?? Theme.accent
        dot.layer.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        let name = Theme.label(
            connection.name.isEmpty ? String(localized: "未命名后端") : connection.name, style: .headline, color: .secondaryLabel)
        name.numberOfLines = 1
        name.lineBreakMode = .byTruncatingTail
        let hint = Theme.label(String(localized: "其他后端"), style: .caption1, color: .tertiaryLabel)
        hint.setContentHuggingPriority(.required, for: .horizontal)
        hint.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [dot, name, hint])
        stack.alignment = .center
        stack.spacing = 9
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: 0, leading: 20, bottom: 0, trailing: 20)
        stack.isAccessibilityElement = true
        stack.accessibilityTraits = .header
        stack.accessibilityLabel = String(localized: "其他后端：\(name.text ?? "")")
        return stack
    }
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        reordering ? .leastNormalMagnitude : max(54, UIFont.preferredFont(forTextStyle: .headline).lineHeight + 20)
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var config = cell.defaultContentConfiguration()
        if reordering {
            let workspace = groups[indexPath.row].0
            config.text = Self.displayName(workspace)
            config.secondaryText = workspace.path
            config.secondaryTextProperties.color = .secondaryLabel
            config.image = Theme.icon(session.pinnedWorkspaces.contains(workspace.id) ? "pin.fill" : "folder")
            cell.contentConfiguration = config
            cell.backgroundColor = Theme.surface
            cell.accessibilityIdentifier = "workspace.\(workspace.id)"
            return cell
        }
        if indexPath.section >= groups.count {
            let other = otherBackends[indexPath.section - groups.count]
            let tint = UIColor(labelHex: other.connection.labelColor) ?? Theme.accent
            if indexPath.row < other.workspaces.count {
                let workspace = other.workspaces[indexPath.row]
                config.text = Self.displayName(workspace)
                config.secondaryText = workspace.path
                config.image = Theme.icon("folder")
                cell.accessibilityIdentifier = "backend.\(other.connection.id).workspace.\(workspace.id)"
                cell.accessibilityHint = String(localized: "切换到此后端并打开工作区")
            } else {
                config.text = other.error.map { String(localized: "无法读取本地缓存：\($0)") } ?? String(localized: "尚无缓存的工作区")
                config.secondaryText = String(localized: "点按切换到此后端")
                config.image = Theme.icon("arrow.triangle.swap")
                cell.accessibilityIdentifier = "backend.\(other.connection.id).switch"
            }
            config.secondaryTextProperties.color = .secondaryLabel
            config.secondaryTextProperties.numberOfLines = 1
            config.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
            config.imageProperties.tintColor = tint
            cell.accessoryType = .disclosureIndicator
            cell.contentConfiguration = config
            cell.backgroundColor = Theme.surface
            return cell
        }
        let (workspace, items) = groups[indexPath.section]
        if let rejected = missing[workspace.id] {
            config.text = String(localized: "目录在后端不可用")
            config.secondaryText = [workspace.path, rejected.message].filter { !$0.isEmpty }.joined(separator: "\n")
            config.image = Theme.icon("folder.badge.questionmark")
            config.textProperties.color = .secondaryLabel
            config.secondaryTextProperties.color = .tertiaryLabel
            config.imageProperties.tintColor = .systemOrange
            cell.contentConfiguration = config
            cell.backgroundColor = Theme.surface
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = "workspace.missing.\(workspace.id)"
            return cell
        }
        let visible = min(items.count, expanded.contains(workspace.id) ? Int.max : 5)
        if indexPath.row >= visible {
            config.text = visible < items.count ? String(localized: "显示其余 \(items.count - visible) 个对话") : String(localized: "新建对话")
            config.image = Theme.icon(visible < items.count ? "chevron.down" : "plus.bubble")
            config.textProperties.color = Theme.accent
        } else {
            switch items[indexPath.row] {
            case .conversation(let item):
                configure(&config, cell: cell, conversation: item)
            }
        }
        cell.contentConfiguration = config
        cell.backgroundColor = Theme.surface
        return cell
    }
    /// Conversation row, desktop sidebar parity: label dot, task badge,
    /// attention marker and the latest message preview.
    private func configure(
        _ config: inout UIListContentConfiguration, cell: UITableViewCell, conversation item: ConversationManifest
    ) {
        let state = session.runtimes[item.id]?.status ?? item.status
        let attention = attention(item)
        let tasks = taskMeta[item.id]
        let tasksDone = tasks.map { $0.pending == 0 } ?? false
        let titleFont = UIFont.preferredFont(forTextStyle: .body)
        let title = NSMutableAttributedString()
        if let hex = session.conversationLabels[item.id], let color = UIColor(labelHex: hex) {
            title.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: color, .font: titleFont]))
        }
        title.append(
            NSAttributedString(
                string: item.title?.isEmpty == false ? item.title! : String(localized: "新对话"),
                attributes: [.foregroundColor: tasksDone ? UIColor.secondaryLabel : .label, .font: titleFont]))
        if tasks != nil {
            title.append(
                NSAttributedString(
                    string: tasksDone ? String(localized: "  已完成") : String(localized: "  计划中"),
                    attributes: [
                        .foregroundColor: tasksDone ? UIColor.secondaryLabel : Theme.accent,
                        .font: UIFont.preferredFont(forTextStyle: .caption1),
                    ]))
        }
        config.attributedText = title
        let status: String? =
            switch attention {
            case .working: statusText(state)
            case .issue: String(localized: "未完成")
            case .unread: String(localized: "有新消息")
            case nil: nil
            }
        config.secondaryText = [status, Self.preview(session.runtimes[item.id]) ?? item.provider]
            .compactMap { $0 }.joined(separator: " · ")
        config.secondaryTextProperties.color = .secondaryLabel
        config.secondaryTextProperties.numberOfLines = 2
        config.image = Theme.icon(
            session.pinnedConversations.contains(item.id)
                ? "pin.fill"
                : attention == .working
                    ? "circle.dotted.circle" : (attention == .issue ? "exclamationmark.circle" : "bubble.left"))
        config.imageProperties.tintColor = attention?.color ?? .secondaryLabel
        config.textProperties.numberOfLines = 2
        // All linked tasks done: the row steps back like the desktop sidebar.
        cell.contentView.alpha = tasksDone ? 0.6 : 1
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "conversation.\(item.id)"
        if let tasks {
            cell.accessibilityValue = String(localized: "\(tasks.count) 个关联任务，\(tasksDone ? String(localized: "已完成") : String(localized: "计划中"))")
        }
    }
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        reordering
    }
    func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        groups.insert(groups.remove(at: source.row), at: destination.row)
    }
    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath)
        -> UITableViewCell.EditingStyle
    {
        .none
    }
    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        false
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if reordering { return }
        if indexPath.section >= groups.count {
            let other = otherBackends[indexPath.section - groups.count]
            switchBackend(
                other.connection,
                open: indexPath.row < other.workspaces.count ? other.workspaces[indexPath.row] : nil)
            return
        }
        let (workspace, items) = groups[indexPath.section]
        if missing[workspace.id] != nil { return }
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
    /// Notification taps arrive before the catalog has loaded; refresh once
    /// before deciding the conversation is gone (deleted or another backend).
    func openConversation(id: String) {
        if let item = session.conversations.first(where: { $0.id == id }) {
            open(item)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            if !session.isConnected { await session.connect() }
            try? await session.refresh()
            if let item = session.conversations.first(where: { $0.id == id }) {
                open(item)
            } else {
                showNotice(title: String(localized: "对话不可用"), message: String(localized: "这条对话可能已删除，或属于其他后端。"))
            }
        }
    }
    func tableView(
        _ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !reordering, let item = conversation(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in self?.conversationMenu(item) })
    }
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration?
    {
        guard !reordering, let item = conversation(at: indexPath) else { return nil }
        let action = UIContextualAction(style: .normal, title: item.archivedAt == nil ? String(localized: "归档") : String(localized: "恢复")) {
            [weak self] _, _, done in
            self?.archive(item, archived: item.archivedAt == nil)
            done(true)
        }
        action.backgroundColor = Theme.accent
        return UISwipeActionsConfiguration(actions: [action])
    }
    /// The conversation shown at a row of the active backend's list, if any.
    private func conversation(at indexPath: IndexPath) -> ConversationManifest? {
        guard indexPath.section < groups.count else { return nil }
        let group = groups[indexPath.section]
        guard missing[group.0.id] == nil,
            indexPath.row < min(group.1.count, expanded.contains(group.0.id) ? Int.max : 5)
        else { return nil }
        switch group.1[indexPath.row] {
        case .conversation(let item): return item
        }
    }
    private func conversationMenu(_ item: ConversationManifest) -> UIMenu {
        let pinned = session.pinnedConversations.contains(item.id)
        var actions: [UIMenuElement] = [
            UIAction(title: pinned ? String(localized: "取消置顶") : String(localized: "置顶"), image: Theme.icon("pin")) { [weak self] _ in
                guard let self else { return }
                if pinned {
                    session.pinnedConversations.removeAll { $0 == item.id }
                } else {
                    session.pinnedConversations.insert(item.id, at: 0)
                }
                session.persist()
                reload()
            },
            UIAction(title: String(localized: "重命名"), image: Theme.icon("pencil")) { [weak self] _ in
                self?.askText(title: String(localized: "对话名称"), value: item.title ?? "") { name in
                    self?.update(item, patch: ["title": .string(name)])
                }
            },
            UIAction(title: item.archivedAt == nil ? String(localized: "归档") : String(localized: "恢复"), image: Theme.icon("archivebox")) { [weak self] _ in
                self?.archive(item, archived: item.archivedAt == nil)
            },
        ]
        if session.provider(for: item)?.capabilities["controlActions"].arrayValue.contains("fork") == true {
            actions.append(
                UIAction(title: String(localized: "分叉对话"), image: Theme.icon("arrow.triangle.branch")) { [weak self] _ in
                    Task { [weak self] in
                        guard let self else { return }
                        do { open(try await session.fork(item)) } catch { showError(error) }
                    }
                })
        }
        actions.append(labelMenu(item))
        if item.archivedAt != nil {
            actions.append(
                UIAction(title: String(localized: "永久删除"), image: Theme.icon("trash"), attributes: .destructive) { [weak self] _ in
                    self?.confirm(title: String(localized: "永久删除对话？"), message: String(localized: "将从后端删除此对话及历史，无法撤销。"), destructive: true) {
                        self?.delete(item)
                    }
                })
        }
        return UIMenu(children: actions)
    }
    /// Local-only label color (desktop palette), stored per backend namespace.
    private func labelMenu(_ item: ConversationManifest) -> UIMenu {
        let current = session.conversationLabels[item.id]
        var children: [UIMenuElement] = LabelPalette.colors.map { hex, name in
            UIAction(
                title: name,
                image: UIColor(labelHex: hex).flatMap {
                    Theme.icon("circle.fill", pointSize: 14)?.withTintColor($0, renderingMode: .alwaysOriginal)
                },
                state: current == hex ? .on : .off
            ) { [weak self] _ in self?.session.setConversationLabel(hex, for: item.id) }
        }
        if current != nil {
            children.append(
                UIAction(title: String(localized: "移除标签"), image: Theme.icon("xmark.circle"), attributes: .destructive) {
                    [weak self] _ in self?.session.setConversationLabel(nil, for: item.id)
                })
        }
        return UIMenu(title: String(localized: "标签颜色"), image: Theme.icon("paintpalette"), children: children)
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
                title: conversation.title?.isEmpty == false ? conversation.title! : String(localized: "新对话"),
                state: task.conversationId == conversation.id ? .on : .off
            ) { [weak self] _ in
                self?.session.attachTask(task.id, conversationId: conversation.id)
            }
        }
        if task.conversationId != nil {
            children.append(
                UIAction(title: String(localized: "取消关联"), attributes: .destructive) { [weak self] _ in
                    self?.session.attachTask(task.id, conversationId: nil)
                })
        }
        if conversations.isEmpty { children = [UIAction(title: String(localized: "这个工作区还没有对话"), attributes: .disabled) { _ in }] }
        return UIMenu(
            title: task.conversationId == nil ? String(localized: "关联到对话") : String(localized: "更换关联对话"),
            image: Theme.icon("pin", pointSize: 13), children: children)
    }
    private func taskStatusMenu(_ task: KanbanTask) -> UIMenu {
        UIMenu(
            title: String(localized: "任务状态"),
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
                title: String(localized: "任务状态"), options: .displayInline,
                children: taskStatusMenu(task).children),
            attachMenu(task, workspace: workspace),
        ]
        if let linked = linkedConversation(task) {
            elements.append(
                UIAction(title: String(localized: "写入对话草稿"), image: Theme.icon("square.and.pencil", pointSize: 13)) {
                    [weak self] _ in
                    guard let self else { return }
                    var draft = session.drafts[linked.id] ?? ComposerDraft()
                    draft.text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? task.draftText : "\(draft.text)\n\(task.draftText)"
                    session.drafts[linked.id] = draft
                    session.saveSoon()
                    open(linked)
                })
            elements.append(
                UIAction(title: String(localized: "打开对话"), image: Theme.icon("bubble.left", pointSize: 13)) {
                    [weak self] _ in self?.open(linked)
                })
        }
        elements.append(
            UIAction(title: String(localized: "编辑任务"), image: Theme.icon("pencil", pointSize: 13)) { [weak self] _ in
                self?.editTask(task, workspace: workspace)
            })
        elements.append(
            UIAction(title: String(localized: "删除任务"), image: Theme.icon("trash", pointSize: 13), attributes: .destructive) {
                [weak self] _ in self?.session.removeTask(task.id)
            })
        return UIMenu(children: elements)
    }
    /// Tap on an unlinked task presents the same operations as an action sheet.
    private func presentTaskSheet(_ task: KanbanTask, workspace: WorkspaceRecord) {
        let sheet = UIAlertController(title: task.title, message: String(localized: "状态：\(task.status.label)"), preferredStyle: .actionSheet)
        for status in KanbanTask.Status.allCases where status != task.status {
            sheet.addAction(
                UIAlertAction(title: String(localized: "标记为\(status.label)"), style: .default) { [weak self] _ in
                    self?.session.setTaskStatus(task.id, status)
                })
        }
        sheet.addAction(
            UIAlertAction(
                title: task.conversationId == nil ? String(localized: "关联到对话") : String(localized: "更换关联对话"), style: .default
            ) { [weak self] _ in
                guard let self else { return }
                let conversations = workspaceConversations(workspace)
                guard !conversations.isEmpty else {
                    WBUI.message(on: self, title: String(localized: "没有可关联的对话"), text: String(localized: "这个工作区还没有对话。"))
                    return
                }
                let picker = UIAlertController(title: String(localized: "关联到对话"), message: nil, preferredStyle: .actionSheet)
                for conversation in conversations.prefix(12) {
                    picker.addAction(
                        UIAlertAction(
                            title: conversation.title?.isEmpty == false ? conversation.title! : String(localized: "新对话"),
                            style: .default
                        ) { [weak self] _ in
                            self?.session.attachTask(task.id, conversationId: conversation.id)
                        })
                }
                if task.conversationId != nil {
                    picker.addAction(
                        UIAlertAction(title: String(localized: "取消关联"), style: .destructive) { [weak self] _ in
                            self?.session.attachTask(task.id, conversationId: nil)
                        })
                }
                WBUI.presentSheet(picker, on: self)
            })
        sheet.addAction(
            UIAlertAction(title: String(localized: "编辑任务"), style: .default) { [weak self] _ in
                self?.editTask(task, workspace: workspace)
            })
        sheet.addAction(
            UIAlertAction(title: String(localized: "删除任务"), style: .destructive) { [weak self] _ in
                self?.session.removeTask(task.id)
            })
        WBUI.presentSheet(sheet, on: self)
    }
    /// Create (task == nil) or edit a task's title, description and due date.
    private func editTask(_ task: KanbanTask?, workspace: WorkspaceRecord) {
        let editor = KanbanTaskEditor(task: task, subtitle: Self.displayName(workspace)) { [weak self] values in
            guard let self else { return }
            if let task {
                if values.title != task.title { session.renameTask(task.id, title: values.title) }
                session.updateTaskDetails(task.id, description: values.description, dueDate: values.dueDate)
            } else if session.addTask(
                workspaceId: workspace.id, title: values.title, description: values.description,
                dueDate: values.dueDate) == nil
            {
                showNotice(title: String(localized: "无法新建任务"), message: String(localized: "任务标题不能为空，且任务总数不能超过 500 个。"))
            }
        }
        let navigation = UINavigationController(rootViewController: editor)
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        present(navigation, animated: true)
    }
    /// Kanban column drag: same synced sortOrder write as the list's reorder mode.
    private func moveColumn(_ source: String, to target: String, after: Bool) {
        // Pins sort ahead of sortOrder, so a move across the pin boundary could
        // never stick; moves among pinned columns reorder the local pin list.
        let pinned = session.pinnedWorkspaces
        if pinned.contains(source) != pinned.contains(target) {
            showNotice(title: String(localized: "无法移动"), message: String(localized: "置顶工作区始终排在前面；请先取消置顶再调整顺序。"))
            reload()
            return
        }
        if pinned.contains(source) {
            var order = pinned
            guard source != target, let from = order.firstIndex(of: source) else { return }
            order.remove(at: from)
            guard var index = order.firstIndex(of: target) else { return }
            if after { index += 1 }
            order.insert(source, at: index)
            session.pinnedWorkspaces = order
            session.persist()
            reload()
            return
        }
        var order = sortedWorkspaces()
        guard source != target, let from = order.firstIndex(where: { $0.id == source }) else { return }
        let moved = order.remove(at: from)
        guard var index = order.firstIndex(where: { $0.id == target }) else { return }
        if after { index += 1 }
        order.insert(moved, at: index)
        persistOrder(order)
    }
    @objc private func headerLongPressed(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { setReordering(true) }
    }
    /// Workspace ordering mode: the list collapses to one row per workspace
    /// with drag handles; leaving the mode writes the synced sortOrder values.
    private func setReordering(_ on: Bool) {
        guard reordering != on else { return }
        if on {
            guard filter.selectedSegmentIndex == 0,
                (search.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                session.workspaces.count > 1
            else { return }
            search.isActive = false
            filter.isEnabled = false
            reordering = true
            // Missing workspaces are not part of the synced order.
            groups.removeAll { missing[$0.0.id] != nil }
            reload()
            table.setEditing(true, animated: true)
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                systemItem: .done,
                primaryAction: UIAction { [weak self] _ in self?.setReordering(false) })
        } else {
            reordering = false
            table.setEditing(false, animated: true)
            filter.isEnabled = true
            navigationItem.rightBarButtonItem = addButton
            persistOrder(groups.map(\.0))
        }
    }
    private func persistOrder(_ ordered: [WorkspaceRecord]) {
        var changed = false
        let now = Int(Date().timeIntervalSince1970 * 1_000)
        let updated = ordered.enumerated().map { index, workspace in
            var value = workspace
            if value.sortOrder != index {
                value.sortOrder = index
                value.updatedAt = now
                changed = true
            }
            return value
        }
        guard changed else {
            reload()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let api = session.api else { throw TodexError.disconnected }
                let records = try updated.map { try JSONValue(encoding: $0) }
                _ = try await api.http.request(
                    .put, path: "/v2/workspaces", body: ["workspaces": .array(records)])
                try await session.refresh()
            } catch { showError(error) }
            reload()
        }
    }
    private func workspaceMenu(_ workspace: WorkspaceRecord) -> UIMenu {
        let pinned = session.pinnedWorkspaces.contains(workspace.id)
        let editPath = UIAction(title: String(localized: "更改目录"), image: Theme.icon("folder.badge.gearshape")) { [weak self] _ in
            self?.editPath(workspace)
        }
        let remove = UIAction(title: String(localized: "移除工作区"), image: Theme.icon("trash"), attributes: .destructive) {
            [weak self] _ in self?.removeWorkspace(workspace)
        }
        // A workspace the backend rejects can only be repointed or removed.
        if missing[workspace.id] != nil { return UIMenu(children: [editPath, remove]) }
        return UIMenu(children: [
            UIAction(title: String(localized: "新建对话"), image: Theme.icon("plus.bubble")) { [weak self] _ in
                self?.createConversation(workspace)
            },
            UIAction(title: pinned ? String(localized: "取消置顶") : String(localized: "置顶"), image: Theme.icon("pin")) { [weak self] _ in
                guard let self else { return }
                if pinned {
                    session.pinnedWorkspaces.removeAll { $0 == workspace.id }
                } else {
                    session.pinnedWorkspaces.insert(workspace.id, at: 0)
                }
                session.persist()
                reload()
            },
            UIAction(title: String(localized: "重命名"), image: Theme.icon("pencil")) { [weak self] _ in
                self?.askText(title: String(localized: "工作区名称"), value: workspace.name) { name in
                    var updated = workspace
                    updated.name = name
                    self?.saveWorkspace(updated)
                }
            },
            editPath,
            UIAction(title: String(localized: "排序工作区"), image: Theme.icon("arrow.up.arrow.down")) { [weak self] _ in
                self?.setReordering(true)
            },
            UIAction(title: String(localized: "添加其他目录"), image: Theme.icon("folder.badge.plus")) { [weak self] _ in self?.addWorkspace() },
            UIAction(title: String(localized: "工作区信任"), image: Theme.icon("checkmark.shield")) { [weak self] _ in self?.trust(workspace) },
            remove,
        ])
    }
    /// Backend DELETE /v2/workspaces/{id}: revokes trust and stops the
    /// workspace's running turns; conversations stay on the backend.
    private func removeWorkspace(_ workspace: WorkspaceRecord) {
        confirm(
            title: String(localized: "移除工作区？"), message: String(localized: "\(workspace.path)\n将撤销执行信任并停止此工作区正在运行的任务，后端对话会保留。"),
            destructive: true
        ) { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                do {
                    guard let api = session.api else { throw TodexError.disconnected }
                    let backend = session.selectedID
                    do { _ = try await api.deleteWorkspace(id: workspace.id) } catch TodexError.server(let code, _)
                    where ["404", "NOT_FOUND"].contains(code) {
                        // The backend already holds no such record, the desired state.
                    }
                    // A backend switch mid-flight must not touch the new backend's state.
                    guard session.selectedID == backend else { return }
                    session.pinnedWorkspaces.removeAll { $0 == workspace.id }
                    try await session.refresh()
                } catch { showError(error) }
            }
        }
    }
    /// Repoint a workspace at another backend directory. The backend derives
    /// the workspace id from its path, so the edited record is stored as a new
    /// workspace and the old record is removed once the new one is accepted.
    private func editPath(_ workspace: WorkspaceRecord) {
        guard session.isConnected, let connection = session.connection else {
            showNotice(title: String(localized: "尚未连接"), message: String(localized: "请先连接此工作区的后端"))
            return
        }
        present(
            UINavigationController(
                rootViewController: DirectoryPicker(connection: connection) { [weak self] path in
                    guard path != workspace.path else { return }
                    self?.confirm(
                        title: String(localized: "更改工作区目录？"),
                        message: String(localized: "\(workspace.path)\n→ \(path)\nAgent 将能够在新目录执行任务；原目录的执行信任会被撤销，已有对话仍属于原目录。")
                    ) { self?.relocate(workspace, to: path) }
                }), animated: true)
    }
    private func relocate(_ workspace: WorkspaceRecord, to path: String) {
        Task {
            do {
                guard let api = session.api else { throw TodexError.disconnected }
                // The backend keys workspaces by path: saving onto another
                // workspace's directory would overwrite that record.
                if session.workspaces.contains(where: { $0.id != workspace.id && $0.path == path }) {
                    showNotice(title: String(localized: "目录已被使用"), message: String(localized: "该目录已是另一个工作区，请直接打开那个工作区。"))
                    return
                }
                let backend = session.selectedID
                let before = Set(session.workspaces.map(\.id) + session.rejectedWorkspaces.map(\.id))
                var updated = workspace
                updated.path = path
                updated.updatedAt = Int(Date().timeIntervalSince1970 * 1_000)
                let catalog = try WorkspaceCatalog(response: try await api.replaceWorkspaces([updated]))
                guard session.selectedID == backend else { return }
                if let rejected = catalog.rejected.first(where: { $0.id == workspace.id && $0.path == path }) {
                    throw TodexError.invalid(String(localized: "目录在后端不可用：\(rejected.message.isEmpty ? path : rejected.message)"))
                }
                // Only drop the old record when a new one was actually created;
                // an equivalent path keeps the same id and must not be deleted.
                // Identify the saved record by its path, never by "any new id"
                // (another client may add workspaces concurrently).
                let created = catalog.workspaces.contains {
                    $0.path == path && $0.id != workspace.id && !before.contains($0.id)
                }
                if created {
                    do { _ = try await api.deleteWorkspace(id: workspace.id) } catch TodexError.server(let code, _)
                    where ["404", "NOT_FOUND"].contains(code) {}
                    session.pinnedWorkspaces.removeAll { $0 == workspace.id }
                }
                try await session.refresh()
                if !created {
                    showNotice(title: String(localized: "目录未更改"), message: String(localized: "所选目录与现有工作区相同，未创建新的工作区。"))
                }
            } catch { showError(error) }
        }
    }
    /// Tapping another backend's workspace switches the active backend through
    /// the normal connect path (its own state namespace), then opens it.
    private func switchBackend(_ connection: BackendConnection, open workspace: WorkspaceRecord?) {
        guard !switchingBackend else { return }
        do { _ = try connection.normalizedURL() } catch {
            showError(error)
            return
        }
        search.isActive = false
        switchingBackend = true
        Task { [weak self] in
            guard let self else { return }
            defer { switchingBackend = false }
            await session.connect(connection)
            // A later switch or Settings change supersedes this one.
            guard session.selectedID == connection.id, let workspace else { return }
            if let match = session.workspaces.first(where: { $0.id == workspace.id || $0.path == workspace.path }),
                session.isConnected || !workspaceConversations(match).isEmpty
            {
                enterWorkspace(match)
            } else if !session.isConnected {
                showNotice(title: String(localized: "无法连接后端"), message: session.lastError ?? session.status)
            } else {
                showNotice(title: String(localized: "工作区不可用"), message: String(localized: "此工作区已不在该后端的列表中。"))
            }
        }
    }
    /// Loads other backends' cached workspaces when the backend set changes;
    /// `visible` limits them to the workspace list.
    private func refreshOtherBackends(query: String, visible: Bool) {
        let others = session.connections.filter { $0.id != session.selectedID }
        let key = others.map { LocalStore.namespace($0) }.joined(separator: "|")
        if key != otherBackendsKey {
            otherBackendsKey = key
            otherBackendsLoad?.cancel()
            otherBackendsLoad = Task { [weak self] in
                var result: [String: (workspaces: [WorkspaceRecord], error: String?)] = [:]
                for connection in others {
                    guard let self, !Task.isCancelled else { return }
                    do {
                        let snapshot = try await session.cachedSnapshot(for: connection)
                        let pinned = snapshot?.pinnedWorkspaces ?? []
                        result[connection.id] = (Self.ordered(snapshot?.workspaces ?? [], pinned: pinned), nil)
                    } catch {
                        result[connection.id] = ([], error.localizedDescription)
                    }
                }
                guard let self, !Task.isCancelled else { return }
                otherCatalogs = result
                reload()
            }
        }
        guard visible, !reordering else {
            otherBackends = []
            return
        }
        otherBackends = others.compactMap { connection in
            guard let cached = otherCatalogs[connection.id] else { return nil }
            let workspaces = cached.workspaces.filter {
                query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                    || connection.name.localizedCaseInsensitiveContains(query)
            }
            if !query.isEmpty, workspaces.isEmpty { return nil }
            return OtherBackend(connection: connection, workspaces: workspaces, error: cached.error)
        }
    }
    private func trust(_ workspace: WorkspaceRecord) {
        Task {
            guard let api = session.api else { return }
            do {
                let value = try await api.workspaceTrust(id: workspace.id)
                let trusted = value["trusted"].boolValue
                confirm(
                    title: trusted ? String(localized: "撤销执行信任？") : String(localized: "信任此工作区？"),
                    message: String(localized: "\(workspace.path)\n信任允许后端 Agent 执行项目中的任务；这不是文件系统沙箱。")
                ) {
                    Task {
                        do {
                            _ = try await api.updateWorkspaceTrust(id: workspace.id, trusted: !trusted)
                            self.showNotice(title: String(localized: "信任状态已更新"), message: trusted ? String(localized: "已撤销执行信任") : String(localized: "已信任工作区"))
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
                        title: String(localized: "添加并信任工作区"), message: String(localized: "Agent 将能够在此后端目录执行任务：\n\(path)"),
                        value: URL(fileURLWithPath: path).lastPathComponent
                    ) { name in self?.saveWorkspace(WorkspaceRecord(name: name, path: path)) }
                }), animated: true)
    }
    private func chooseWorkspaceForConversation() {
        guard !session.workspaces.isEmpty else {
            addWorkspace()
            return
        }
        let alert = UIAlertController(title: String(localized: "选择工作区"), message: nil, preferredStyle: .actionSheet)
        for workspace in sortedWorkspaces() {
            alert.addAction(
                UIAlertAction(title: Self.displayName(workspace), style: .default) { [weak self] _ in
                    self?.createConversation(workspace)
                })
        }
        alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        alert.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(alert, animated: true)
    }
    private func createConversation(_ workspace: WorkspaceRecord) {
        guard session.isConnected else {
            showNotice(title: String(localized: "尚未连接"), message: String(localized: "请先连接此工作区的后端"))
            return
        }
        let alert = UIAlertController(title: String(localized: "选择 Agent"), message: Self.displayName(workspace), preferredStyle: .actionSheet)
        var options: [(provider: ProviderDescriptor, profile: String?, title: String)] = []
        for provider in session.providers {
            if provider.id == "acp" && !provider.profiles.isEmpty {
                for profile in provider.profiles {
                    options.append((provider, profile, "ACP · \(profile)"))
                }
            } else {
                options.append((provider, nil, provider.displayName + (provider.available ? "" : String(localized: " · 不可用"))))
            }
        }
        // The agent used for the previous conversation leads the list.
        if let last = session.lastAgent,
            let index = options.firstIndex(where: { $0.provider.id == last.provider && $0.profile == last.profile })
        {
            let match = options.remove(at: index)
            options.insert((match.provider, match.profile, String(localized: "\(match.title) · 上次使用")), at: 0)
        }
        for option in options {
            let action = UIAlertAction(title: option.title, style: .default) { [weak self] _ in
                self?.create(workspace, provider: option.provider.id, profile: option.profile)
            }
            action.isEnabled = option.provider.available
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
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
        case "running": String(localized: "进行中")
        case "waiting_permission", "waitingPermission": String(localized: "等待回应")
        case "failed": String(localized: "未完成")
        case "interrupted", "cancelled": String(localized: "已停止")
        default: String(localized: "对话")
        }
    }
    private static func busy(_ state: String) -> Bool {
        ["running", "waiting_permission", "waitingPermission"].contains(state)
    }
    /// Desktop `getConversationStatus`: a running turn beats an unseen
    /// failure, which beats a plain unread marker. Failure and unread markers
    /// clear once the conversation has been viewed (read up to its tail).
    private enum Attention {
        case working, issue, unread
        var color: UIColor {
            switch self {
            case .working: .systemGreen
            case .issue: .systemOrange
            case .unread: .systemBlue
            }
        }
        var label: String {
            switch self {
            case .working: String(localized: "正在工作")
            case .issue: String(localized: "遇到问题")
            case .unread: String(localized: "有未读回复")
            }
        }
    }
    private func attention(_ item: ConversationManifest) -> Attention? {
        let state = session.runtimes[item.id]?.status ?? item.status
        if Self.busy(state) { return .working }
        guard (session.readSequences[item.id] ?? 0) < item.lastSequence else { return nil }
        return state == "failed" ? .issue : .unread
    }
    /// The backend list carries no message preview; a loaded runtime supplies
    /// its newest user or assistant text (messages are newest first).
    private static func preview(_ runtime: ConversationRuntime?) -> String? {
        guard
            let text = runtime?.messages.first(where: {
                ($0.role == "assistant" || $0.role == "user")
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })?.text
        else { return nil }
        let line = text.split(whereSeparator: \.isWhitespace).prefix(60).joined(separator: " ")
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }
}

/// Desktop `BACKEND_LABEL_COLORS` with their names; backend and conversation
/// labels share it.
enum LabelPalette {
    static let colors: [(String, String)] = Array(
        zip(BackendConnection.labelColors, [String(localized: "蓝色"), String(localized: "紫色"), String(localized: "粉色"), String(localized: "红色"), String(localized: "橙色"), String(localized: "黄色"), String(localized: "绿色"), String(localized: "青色")]))
}

extension UIColor {
    /// A `#rrggbb` label color; nil for anything else.
    convenience init?(labelHex value: String) {
        guard let hex = BackendConnection.normalizeLabelColor(value), let rgb = UInt32(hex.dropFirst(), radix: 16)
        else { return nil }
        self.init(
            red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}
