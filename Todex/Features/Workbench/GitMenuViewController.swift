import TodexCore
import UIKit

/// Desktop GitActionsModal: a read-only status page (GitStatusOverview) and
/// the searchable action list in one sheet. Actions, forms and write guards
/// stay in `WorkbenchGitViewController`; this page only renders its state and
/// reads the commit history and PR summary for the status page.
final class GitMenuViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private enum Page: Int { case status, operations }
    private enum StatusRow {
        case loading
        case note(String, UIColor)
        case notRepository
        case changes(JSONValue)
        case file(JSONValue)
        case remote(NSAttributedString)
        case commit(JSONValue, head: Bool)
        case showEarlierCommits(Int)
        case collapseCommits
        case pullRequest(JSONValue)
        case branch(NSAttributedString)
        case worktree(JSONValue)
    }
    private struct StatusSection {
        var title: String?
        var icon: String?
        /// Jump-button label and the action group it opens.
        var jump: (title: String, group: String)?
        var rows: [StatusRow]
    }

    /// Desktop GIT_LOG_PAGE_SIZE: the latest commit first, then this many more per expand.
    private static let logPageSize = 5
    private static let visibleFiles = 5
    /// The backend admits two concurrent Git reads and answers 409 once a
    /// request has queued for two seconds; scans and PR lookups hold slots longer.
    private static let busyRetryDelays: [Double] = [0.5, 1.5, 3]

    private let git: WorkbenchGitViewController
    private let api: APIClient
    private let pages = UISegmentedControl(items: [String(localized: "状态"), String(localized: "操作")])
    private let pathLabel = UILabel()
    private let stripLabel = UILabel()
    private let searchBar = UISearchBar()
    private let statusTable = UITableView(frame: .zero, style: .insetGrouped)
    private let actionTable = UITableView(frame: .zero, style: .insetGrouped)
    private lazy var actionPage = UIStackView(arrangedSubviews: [stripLabel, searchBar, actionTable])
    private var sections: [StatusSection] = []
    private var groups: [GitMenuGroup] = []
    private var query = ""
    // Status-page reads beyond the shared Git snapshot, keyed by repository and snapshot time.
    private var overviewPath: String?
    private var overviewReadAt: Date?
    private var overviewTask: Task<Void, Never>?
    private var moreCommitsTask: Task<Void, Never>?
    private var commits: [JSONValue] = []
    private var commitsHasMore = false
    private var commitsError: String?
    private var commitsLoading = false
    /// The backend predates GET /v2/git/log (404), so there is no history to show.
    private var commitsUnsupported = false
    private var shownCommits = 1
    private var pullRequestSnapshot: JSONValue?
    private var pullRequestError: String?

    init(git: WorkbenchGitViewController, api: APIClient) {
        self.git = git
        self.api = api
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        overviewTask?.cancel()
        moreCommitsTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Git 操作")
        view.backgroundColor = .systemGroupedBackground
        let close = UIBarButtonItem(
            systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        close.accessibilityLabel = String(localized: "关闭 Git 操作")
        navigationItem.leftBarButtonItem = close
        pathLabel.font = .preferredFont(forTextStyle: .caption1)
        pathLabel.textColor = .secondaryLabel
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pages.selectedSegmentIndex = Page.status.rawValue
        pages.accessibilityIdentifier = "git.menu.pages"
        pages.addAction(UIAction { [weak self] _ in self?.showPage() }, for: .valueChanged)
        stripLabel.font = .preferredFont(forTextStyle: .footnote)
        stripLabel.numberOfLines = 0
        searchBar.searchBarStyle = .minimal
        searchBar.placeholder = String(localized: "搜索分支、工作树、PR…")
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.delegate = self
        actionPage.axis = .vertical
        actionPage.spacing = 4
        for table in [statusTable, actionTable] {
            table.dataSource = self
            table.delegate = self
            table.keyboardDismissMode = .onDrag
        }
        statusTable.accessibilityIdentifier = "git.menu.status"
        actionTable.accessibilityIdentifier = "git.menu.actions"
        statusTable.refreshControl = UIRefreshControl()
        statusTable.refreshControl?.addAction(UIAction { [weak self] _ in self?.git.refresh() }, for: .valueChanged)
        WBUI.installStack(in: view, views: [pathLabel, pages, statusTable, actionPage], keyboard: true)
        showPage()
        gitStateChanged()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // A closed menu no longer needs its history or PR reads.
        if navigationController?.isBeingDismissed ?? isBeingDismissed { resetOverview() }
    }

    /// Called (coalesced) whenever the shared Git state changes.
    func gitStateChanged() {
        guard isViewLoaded else { return }
        if !git.isReading { statusTable.refreshControl?.endRefreshing() }
        pathLabel.text = git.repositoryPath
        renderNavigationItems()
        loadOverviewIfNeeded()
        render()
    }

    private func renderNavigationItems() {
        let refresh = UIBarButtonItem(
            image: Theme.icon("arrow.clockwise"), primaryAction: UIAction { [weak self] _ in self?.git.refresh() })
        refresh.accessibilityLabel = String(localized: "刷新状态")
        var items = [refresh]
        // Desktop shows the repository picker only when there is a choice to make.
        if git.repositoryCount > 1 {
            let repositories = UIBarButtonItem(
                image: Theme.icon("externaldrive.connected.to.line.below"), menu: git.repositoryMenu())
            repositories.accessibilityLabel = String(localized: "目标仓库")
            items.append(repositories)
        }
        navigationItem.rightBarButtonItems = items
    }

    private func render() {
        let changed = git.statusSummary?["changedFiles"].intValue ?? 0
        pages.setTitle(
            changed > 0 ? "\(String(localized: "状态")) \(changed)" : String(localized: "状态"),
            forSegmentAt: Page.status.rawValue)
        stripLabel.attributedText = strip()
        stripLabel.isHidden = stripLabel.attributedText?.length ?? 0 == 0
        sections = statusSections()
        groups = filteredGroups()
        statusTable.reloadData()
        actionTable.reloadData()
        actionTable.backgroundView = groups.isEmpty ? emptyLabel(String(localized: "没有匹配的 Git 操作")) : nil
    }

    private func showPage() {
        let operations = pages.selectedSegmentIndex == Page.operations.rawValue
        statusTable.isHidden = operations
        actionPage.isHidden = !operations
        if !operations { searchBar.resignFirstResponder() }
    }

    /// Status-section jump: open the actions page at the matching group.
    private func jump(to group: String) {
        pages.selectedSegmentIndex = Page.operations.rawValue
        showPage()
        if !query.isEmpty {
            query = ""
            searchBar.text = ""
            render()
        }
        guard let section = groups.firstIndex(where: { $0.id == group }), !groups[section].actions.isEmpty else { return }
        actionTable.layoutIfNeeded()
        actionTable.scrollToRow(at: IndexPath(row: 0, section: section), at: .top, animated: true)
    }

    // MARK: Overview reads

    /// Reloads history and the PR after every new snapshot of the shared Git
    /// controller (menu open, refresh, after a write). Reads run one after
    /// another, after the snapshot read, so the menu never takes both read slots.
    private func loadOverviewIfNeeded() {
        let path = git.repositoryPath
        if overviewPath != path {
            // A different repository: never show the previous one's history or PR.
            resetOverview()
            overviewPath = path
        }
        guard let snapshot = git.workspaceSnapshot, let readAt = git.lastReadAt, readAt != overviewReadAt else { return }
        overviewReadAt = readAt
        guard snapshot["initialized"].boolValue else {
            resetOverview()
            overviewPath = path
            overviewReadAt = readAt
            return
        }
        overviewTask?.cancel()
        moreCommitsTask?.cancel()
        commitsLoading = true
        overviewTask = Task { [weak self] in await self?.loadOverview(path: path) }
    }
    private func resetOverview() {
        overviewTask?.cancel()
        moreCommitsTask?.cancel()
        overviewTask = nil
        moreCommitsTask = nil
        overviewPath = nil
        overviewReadAt = nil
        commits = []
        commitsHasMore = false
        commitsError = nil
        commitsLoading = false
        commitsUnsupported = false
        shownCommits = 1
        pullRequestSnapshot = nil
        pullRequestError = nil
    }
    private func loadOverview(path: String) async {
        do {
            let page = try await retryWhenBusy { try await self.api.gitLog(workspacePath: path, skip: 0, limit: 1) }
            guard !Task.isCancelled else { return }
            guard case .array(let items) = page["commits"] else {
                throw TodexError.invalid(String(localized: "Git 提交记录响应缺少 commits"))
            }
            commits = items
            commitsHasMore = page["hasMore"].boolValue
            commitsError = nil
            commitsUnsupported = false
        } catch {
            guard !Task.isCancelled else { return }
            commits = []
            commitsHasMore = false
            commitsUnsupported = Self.isMissingRoute(error)
            commitsError = commitsUnsupported ? nil : error.localizedDescription
        }
        commitsLoading = false
        shownCommits = 1
        render()
        do {
            let snapshot = try await retryWhenBusy { try await self.api.gitPullRequest(workspacePath: path) }
            guard !Task.isCancelled else { return }
            pullRequestSnapshot = snapshot
            pullRequestError = nil
        } catch {
            guard !Task.isCancelled else { return }
            pullRequestSnapshot = nil
            pullRequestError = error.localizedDescription
        }
        render()
    }
    /// Reveals `logPageSize` more commits, fetching the next page when needed.
    private func showEarlierCommits() {
        let target = shownCommits + Self.logPageSize
        guard commits.count < target, commitsHasMore else {
            shownCommits = target
            render()
            return
        }
        guard !commitsLoading, let path = overviewPath else { return }
        commitsLoading = true
        commitsError = nil
        render()
        let skip = commits.count
        moreCommitsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.retryWhenBusy {
                    try await self.api.gitLog(workspacePath: path, skip: skip, limit: Self.logPageSize)
                }
                guard !Task.isCancelled else { return }
                self.commits += page["commits"].arrayValue
                self.commitsHasMore = page["hasMore"].boolValue
            } catch {
                guard !Task.isCancelled else { return }
                self.commitsError = error.localizedDescription
            }
            self.commitsLoading = false
            self.shownCommits = target
            self.render()
        }
    }
    private func retryWhenBusy(_ read: () async throws -> JSONValue) async throws -> JSONValue {
        var attempt = 0
        while true {
            do {
                return try await read()
            } catch {
                guard attempt < Self.busyRetryDelays.count, !Task.isCancelled, Self.isReadBusy(error) else { throw error }
                try await Task.sleep(for: .seconds(Self.busyRetryDelays[attempt]))
                attempt += 1
            }
        }
    }
    private static func isReadBusy(_ error: any Error) -> Bool {
        guard case TodexError.server(let code, _) = error else { return false }
        return code == "CONFLICT" || code == "409"
    }
    private static func isMissingRoute(_ error: any Error) -> Bool {
        guard case TodexError.server(let code, _) = error else { return false }
        return code == "404" || code == "NOT_FOUND"
    }

    // MARK: Status page

    private func statusSections() -> [StatusSection] {
        guard let status = git.statusSummary else {
            let row: StatusRow =
                git.readError.map { .note(String(localized: "读取失败：\($0)"), .systemOrange) } ?? .loading
            return [StatusSection(rows: [row])]
        }
        guard status["initialized"].boolValue else { return [StatusSection(rows: [.notRepository])] }
        var changes: [StatusRow] = [.changes(status)]
        if status["changedFiles"].intValue > 0 {
            let files = git.scannedFiles
            changes += files.prefix(Self.visibleFiles).map { .file($0) }
            let hidden = max(0, files.count - Self.visibleFiles)
            if hidden > 0 || git.scannedFilesTruncated {
                changes.append(
                    .note(
                        String(localized: "还有 \(hidden) 个文件")
                            + (git.scannedFilesTruncated ? String(localized: "，统计为部分结果") : ""),
                        .secondaryLabel))
            }
        }
        var history: [StatusRow] = []
        if let remote = remoteText(status) { history.append(.remote(remote)) }
        history += commitRows()
        let pr = pullRequestSnapshot?["pullRequest"]
        let prRow: StatusRow =
            if let pr, !pr.isNull, !pr.objectValue.isEmpty {
                .pullRequest(pr)
            } else if let pullRequestError {
                .note(String(localized: "读取失败：\(pullRequestError)"), .systemOrange)
            } else if let branch = pullRequestSnapshot?["branch"].optionalString {
                .note(
                    branch.isEmpty ? String(localized: "当前处于分离 HEAD，没有对应的 PR。") : String(localized: "当前分支 \(branch) 没有对应的 PR。"),
                    .secondaryLabel)
            } else {
                .loading
            }
        let hasPullRequest = if case .pullRequest = prRow { true } else { false }
        var branches: [StatusRow] = [.branch(branchText(status))]
        let worktrees = git.workspaceSnapshot?["worktrees"].arrayValue ?? []
        if worktrees.count > 1 { branches += worktrees.map { .worktree($0) } }
        return [
            StatusSection(
                title: String(localized: "修改状态"), icon: "doc.badge.ellipsis",
                jump: (String(localized: "提交操作"), "repository"), rows: changes),
            StatusSection(
                title: String(localized: "提交状态"), icon: "smallcircle.filled.circle",
                jump: (String(localized: "推送操作"), "repository"), rows: history),
            StatusSection(
                title: String(localized: "Pull Request"), icon: "arrow.triangle.pull",
                jump: (hasPullRequest ? String(localized: "PR 操作") : String(localized: "创建 PR"), "pull-requests"),
                rows: [prRow]),
            StatusSection(
                title: String(localized: "分支与工作树"), icon: "arrow.triangle.branch",
                jump: (String(localized: "分支 / 工作树操作"), "branches"), rows: branches),
        ]
    }
    private func commitRows() -> [StatusRow] {
        guard !commits.isEmpty else {
            if commitsUnsupported {
                return [.note(String(localized: "当前后端版本不支持提交记录，更新并重启后端后可查看。"), .secondaryLabel)]
            }
            if commitsLoading { return [.loading] }
            if let commitsError { return [.note(String(localized: "读取失败：\(commitsError)"), .systemOrange)] }
            return [.note(String(localized: "还没有提交"), .secondaryLabel)]
        }
        let visible = commits.prefix(shownCommits)
        var rows: [StatusRow] = visible.enumerated().map { .commit($1, head: $0 == 0) }
        if let commitsError { rows.append(.note(String(localized: "读取失败：\(commitsError)"), .systemOrange)) }
        if commits.count > shownCommits || commitsHasMore {
            rows.append(
                .showEarlierCommits(
                    commitsHasMore ? Self.logPageSize : min(Self.logPageSize, commits.count - shownCommits)))
        }
        if shownCommits > 1 { rows.append(.collapseCommits) }
        return rows
    }
    /// Push state against the upstream; older backends omit these fields, so say nothing.
    private func remoteText(_ status: JSONValue) -> NSAttributedString? {
        guard status.objectValue["ahead"] != nil else { return nil }
        var parts: [(String, UIColor)] = []
        let ahead = status["ahead"].intValue
        let behind = status["behind"].intValue
        if let upstream = status["upstream"].optionalString {
            if ahead > 0 { parts.append(("↑ " + String(localized: "\(ahead) 个提交未推送"), .systemOrange)) }
            if behind > 0 { parts.append(("↓ " + String(localized: "落后 \(behind) 个提交"), .systemBlue)) }
            if ahead == 0 && behind == 0 { parts.append(("✓ " + String(localized: "已与 \(upstream) 同步"), .systemGreen)) }
        } else if !status["ahead"].isNull {
            parts.append((String(localized: "未设置上游"), .secondaryLabel))
            if ahead > 0 { parts.append(("↑ " + String(localized: "\(ahead) 个提交不在任何远端"), .systemOrange)) }
        } else if status["branch"].optionalString != nil {
            parts.append((String(localized: "没有远端"), .secondaryLabel))
        }
        guard !parts.isEmpty else { return nil }
        let text = NSMutableAttributedString(
            string: String(localized: "远端") + "  ", attributes: [.foregroundColor: UIColor.secondaryLabel])
        for (index, part) in parts.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: " · ", attributes: [.foregroundColor: UIColor.tertiaryLabel])) }
            text.append(NSAttributedString(string: part.0, attributes: [.foregroundColor: part.1]))
        }
        return text
    }
    private func branchText(_ status: JSONValue) -> NSAttributedString {
        let mono = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        let text = NSMutableAttributedString(
            string: status["branch"].optionalString ?? String(localized: "未提交或分离 HEAD"), attributes: [.font: mono])
        let secondary: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .footnote), .foregroundColor: UIColor.secondaryLabel,
        ]
        switch status["worktreeKind"].optionalString {
        case "linked": text.append(NSAttributedString(string: "  " + String(localized: "关联工作树"), attributes: secondary))
        case "main": text.append(NSAttributedString(string: "  " + String(localized: "主工作树"), attributes: secondary))
        default: break
        }
        if let snapshot = git.workspaceSnapshot {
            let branches = snapshot["branches"].arrayValue
            let remote = branches.filter { $0["remote"].boolValue }.count
            let counts = String(
                localized: "本地分支 \(branches.count - remote) · 远端 \(remote) · 工作树 \(snapshot["worktrees"].arrayValue.count)")
            text.append(NSAttributedString(string: "\n" + counts, attributes: secondary))
        }
        return text
    }

    // MARK: Actions page

    /// Branch, PR and operation counts above the search field (desktop strip).
    private func strip() -> NSAttributedString? {
        guard let status = git.statusSummary, status["initialized"].boolValue else { return nil }
        let text = NSMutableAttributedString()
        func add(_ value: String, _ color: UIColor) {
            if text.length > 0 { text.append(NSAttributedString(string: "  ·  ", attributes: [.foregroundColor: UIColor.tertiaryLabel])) }
            text.append(NSAttributedString(string: value, attributes: [.foregroundColor: color]))
        }
        add(status["branch"].optionalString ?? String(localized: "分离 HEAD"), .label)
        let changed = status["changedFiles"].intValue
        if changed > 0 {
            add(String(localized: "\(changed) 个文件"), .systemOrange)
        } else {
            add(String(localized: "工作区干净"), .systemGreen)
        }
        if status["ahead"].intValue > 0 { add("↑\(status["ahead"].intValue)", .systemOrange) }
        if let number = pullRequestSnapshot?["pullRequest"]["number"].doubleValue { add("PR #\(Int(number))", .systemBlue) }
        return text
    }
    private func filteredGroups() -> [GitMenuGroup] {
        let all = git.menuGroups
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }
        return all.compactMap { group in
            if group.title.localizedCaseInsensitiveContains(needle) { return group }
            var match = group
            match.actions = group.actions.filter {
                $0.title.localizedCaseInsensitiveContains(needle)
                    || ($0.subtitle?.localizedCaseInsensitiveContains(needle) ?? false)
            }
            return match.actions.isEmpty ? nil : match
        }
    }
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        query = searchText
        render()
    }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }

    // MARK: Table

    func numberOfSections(in tableView: UITableView) -> Int {
        tableView === statusTable ? sections.count : groups.count
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tableView === statusTable ? sections[section].rows.count : groups[section].actions.count
    }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        tableView === statusTable ? nil : groups[section].title
    }
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard tableView === statusTable, let title = sections[section].title else { return nil }
        let header = UITableViewHeaderFooterView(reuseIdentifier: nil)
        var content = UIListContentConfiguration.prominentInsetGroupedHeader()
        content.text = title
        content.textProperties.font = .preferredFont(forTextStyle: .subheadline).bold()
        content.image = sections[section].icon.flatMap { Theme.icon($0, pointSize: 13) }
        header.contentConfiguration = content
        if let jump = sections[section].jump {
            var config = UIButton.Configuration.plain()
            config.title = jump.title
            config.image = Theme.icon("chevron.right", pointSize: 10)
            config.imagePlacement = .trailing
            config.imagePadding = 2
            config.contentInsets = .init(top: 4, leading: 6, bottom: 4, trailing: 0)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var result = incoming
                result.font = .preferredFont(forTextStyle: .footnote)
                return result
            }
            let group = jump.group
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.jump(to: group) })
            button.translatesAutoresizingMaskIntoConstraints = false
            header.contentView.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: header.contentView.layoutMarginsGuide.trailingAnchor),
                button.centerYAnchor.constraint(equalTo: header.contentView.centerYAnchor),
            ])
        }
        return header
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        tableView === statusTable
            ? statusCell(sections[indexPath.section].rows[indexPath.row])
            : actionCell(groups[indexPath.section].actions[indexPath.row])
    }
    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        if tableView === actionTable { return groups[indexPath.section].actions[indexPath.row].enabled }
        switch sections[indexPath.section].rows[indexPath.row] {
        case .showEarlierCommits, .collapseCommits: return true
        case .pullRequest(let pr): return Self.browserURL(pr["url"].stringValue) != nil
        default: return false
        }
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if tableView === actionTable {
            let action = groups[indexPath.section].actions[indexPath.row]
            searchBar.resignFirstResponder()
            if action.enabled { action.run() }
            return
        }
        switch sections[indexPath.section].rows[indexPath.row] {
        case .showEarlierCommits: showEarlierCommits()
        case .collapseCommits:
            // Keeps the loaded pages so expanding again does not refetch.
            shownCommits = 1
            render()
        case .pullRequest(let pr):
            if let url = Self.browserURL(pr["url"].stringValue) { UIApplication.shared.open(url) }
        default: break
        }
    }

    private func actionCell(_ action: GitMenuAction) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.subtitleCell()
        content.text = action.title
        content.secondaryText = action.subtitle
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = Theme.icon(action.icon, pointSize: 15)
        if !action.enabled {
            content.textProperties.color = .tertiaryLabel
            content.imageProperties.tintColor = .tertiaryLabel
            cell.accessibilityTraits.insert(.notEnabled)
        }
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = action.accessibilityIdentifier
        cell.accessoryType = action.enabled ? .disclosureIndicator : .none
        return cell
    }
    private func statusCell(_ row: StatusRow) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = UIListContentConfiguration.subtitleCell()
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
        switch row {
        case .loading:
            content.text = String(localized: "正在读取…")
            content.textProperties.color = .secondaryLabel
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessoryView = spinner
        case .note(let text, let color):
            content.text = text
            content.textProperties.color = color
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
        case .notRepository:
            content.image = Theme.icon("folder.badge.plus", pointSize: 22)
            content.text = String(localized: "当前目录还不是 Git 仓库")
            content.secondaryText = String(localized: "可在「操作」页初始化仓库。")
        case .changes(let status):
            let changed = status["changedFiles"].intValue
            if changed == 0 {
                content.text = String(localized: "工作区干净")
                content.secondaryText = String(localized: "没有未提交的更改")
            } else {
                let more = status["statsTruncated"].boolValue ? "…" : ""
                let text = NSMutableAttributedString(
                    string: String(localized: "\(changed) 个文件已更改") + "  ",
                    attributes: [.font: UIFont.preferredFont(forTextStyle: .subheadline).bold()])
                text.append(
                    NSAttributedString(
                        string: "+\(status["additions"].intValue)\(more)", attributes: [.foregroundColor: UIColor.systemGreen]))
                text.append(
                    NSAttributedString(
                        string: " −\(status["deletions"].intValue)\(more)", attributes: [.foregroundColor: UIColor.systemRed]))
                content.attributedText = text
            }
        case .file(let file):
            let badge = Self.fileBadge(file["status"].stringValue)
            content.image = Theme.icon(badge.symbol, pointSize: 15)
            content.imageProperties.tintColor = badge.color
            let path = file["path"].stringValue
            let slash = path.range(of: "/", options: .backwards)
            let mono = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
            let text = NSMutableAttributedString(
                string: slash.map { String(path[..<$0.upperBound]) } ?? "",
                attributes: [.font: mono, .foregroundColor: UIColor.secondaryLabel])
            text.append(
                NSAttributedString(
                    string: slash.map { String(path[$0.upperBound...]) } ?? path,
                    attributes: [.font: mono.bold(), .foregroundColor: UIColor.label]))
            content.attributedText = text
            // Keep the file name visible when a long directory path is truncated.
            content.textProperties.numberOfLines = 1
            content.textProperties.lineBreakMode = .byTruncatingHead
            cell.accessibilityLabel = "\(badge.label) \(path)"
            cell.accessoryView = Self.lineCounts(file)
        case .remote(let text):
            content.attributedText = text
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
        case .commit(let commit, let head):
            let unpushed = commit["pushed"] == .bool(false)
            content.image = Theme.icon(unpushed ? "circle.circle.fill" : "circle.circle", pointSize: 13)
            content.imageProperties.tintColor = unpushed ? .systemOrange : .tertiaryLabel
            content.text = commit["subject"].stringValue
            content.textProperties.numberOfLines = 1
            let detail = NSMutableAttributedString(
                string: String(commit["sha"].stringValue.prefix(7)),
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular),
                    .foregroundColor: UIColor.tintColor,
                ])
            let authored = Date(timeIntervalSince1970: commit["authoredAt"].doubleValue ?? 0)
            var rest = " · \(commit["authorName"].stringValue) · \(Self.relativeTime(authored))"
            if unpushed { rest += " · " + String(localized: "未推送") }
            if head { rest += " · HEAD" }
            detail.append(NSAttributedString(string: rest))
            content.secondaryAttributedText = detail
        case .showEarlierCommits(let count):
            content.text = String(localized: "显示更早的 \(count) 个提交")
            content.textProperties.color = .tintColor
            content.image = Theme.icon("chevron.down", pointSize: 12)
            if commitsLoading {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessoryView = spinner
            }
            cell.selectionStyle = .default
        case .collapseCommits:
            content.text = String(localized: "收起")
            content.textProperties.color = .secondaryLabel
            content.image = Theme.icon("chevron.up", pointSize: 12)
            cell.selectionStyle = .default
        case .pullRequest(let pr):
            let state = pr["state"].stringValue
            content.image = Theme.icon("arrow.triangle.pull", pointSize: 15)
            content.imageProperties.tintColor =
                state == "merged" ? .systemPurple : state == "closed" ? .systemRed : .systemGreen
            content.text = "#\(pr["number"].intValue) \(pr["title"].stringValue)"
            content.secondaryText = Self.pullRequestDetail(pr)
            content.secondaryTextProperties.numberOfLines = 0
            if Self.browserURL(pr["url"].stringValue) != nil {
                cell.accessoryView = UIImageView(image: Theme.icon("safari", pointSize: 15))
                cell.accessibilityHint = String(localized: "浏览器打开")
                cell.selectionStyle = .default
            }
        case .branch(let text):
            content.attributedText = text
            content.textProperties.numberOfLines = 0
        case .worktree(let tree):
            content.image = Theme.icon("square.stack.3d.up", pointSize: 13)
            var tags: [String] = []
            if tree["main"].boolValue { tags.append(String(localized: "主工作树")) }
            if tree["current"].boolValue { tags.append(String(localized: "当前")) }
            if tree["dirty"].boolValue { tags.append(String(localized: "有未提交更改")) }
            if tree["locked"].boolValue { tags.append(String(localized: "已锁定")) }
            if !tree["accessible"].boolValue { tags.append(String(localized: "不可访问")) }
            content.text =
                (tree["branch"].optionalString ?? String(localized: "分离 HEAD"))
                + (tags.isEmpty ? "" : "  ·  " + tags.joined(separator: " · "))
            content.textProperties.font = .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
            content.secondaryText = tree["path"].stringValue
            content.secondaryTextProperties.numberOfLines = 1
            content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
            if tree["current"].boolValue { cell.backgroundColor = .tintColor.withAlphaComponent(0.1) }
        }
        cell.contentConfiguration = content
        return cell
    }

    private static func pullRequestDetail(_ pr: JSONValue) -> String {
        let state =
            pr["draft"].boolValue
            ? String(localized: "草稿")
            : pr["state"] == "merged" ? String(localized: "已合并")
            : pr["state"] == "closed" ? String(localized: "已关闭") : String(localized: "开放")
        let mergeState: [String: String] = [
            "clean": String(localized: "干净"), "dirty": String(localized: "有冲突"),
            "blocked": String(localized: "被保护规则阻止"), "behind": String(localized: "落后目标分支"),
            "unstable": String(localized: "检查未通过"), "unknown": String(localized: "计算中"),
        ]
        let merge =
            switch pr["mergeable"].stringValue {
            case "mergeable": String(localized: "可合并")
            case "unknown": String(localized: "计算中")
            default:
                String(localized: "不可合并") + (mergeState[pr["mergeState"].stringValue].map { " · \($0)" } ?? "")
            }
        let checks = pr["checks"]
        let checkText = [
            String(localized: "\(checks["passing"].intValue) 项检查通过"),
            checks["failing"].intValue > 0 ? String(localized: "\(checks["failing"].intValue) 项失败") : nil,
            checks["pending"].intValue > 0 ? String(localized: "\(checks["pending"].intValue) 项待运行") : nil,
        ].compactMap { $0 }.joined(separator: " · ")
        let reviews = pr["reviews"]
        return [
            "\(pr["headRef"].stringValue) → \(pr["baseRef"].stringValue)",
            "\(state) · \(merge)",
            checkText,
            String(
                localized: "审查 \(reviews["approved"].intValue) 批准 · \(reviews["changesRequested"].intValue) 请求修改 · \(reviews["commented"].intValue) 评论"),
        ].joined(separator: "\n")
    }
    /// Porcelain v1 `XY` status → letter badge (desktop GitStatusOverview).
    private static func fileBadge(_ status: String) -> (symbol: String, color: UIColor, label: String) {
        let xy = Array(status.padding(toLength: 2, withPad: " ", startingAt: 0))
        if xy == ["?", "?"] { return ("u.square.fill", .systemGreen, String(localized: "未跟踪")) }
        if xy.contains("U") || xy == ["A", "A"] || xy == ["D", "D"] {
            return ("exclamationmark.square.fill", .systemRed, String(localized: "冲突"))
        }
        switch xy[0] != " " ? xy[0] : xy[1] {
        case "D": return ("d.square.fill", .systemRed, String(localized: "已删除"))
        case "A", "C": return ("a.square.fill", .systemGreen, String(localized: "新增"))
        case "R": return ("r.square.fill", .systemBlue, String(localized: "重命名"))
        default: return ("m.square.fill", .systemOrange, String(localized: "已修改"))
        }
    }
    private static func lineCounts(_ file: JSONValue) -> UIView? {
        let added = file["additions"].intValue
        let removed = file["deletions"].intValue
        guard added > 0 || removed > 0 else { return nil }
        let text = NSMutableAttributedString()
        let font = UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        if added > 0 { text.append(NSAttributedString(string: "+\(added)", attributes: [.font: font, .foregroundColor: UIColor.systemGreen])) }
        if removed > 0 {
            text.append(NSAttributedString(string: (added > 0 ? " " : "") + "−\(removed)", attributes: [.font: font, .foregroundColor: UIColor.systemRed]))
        }
        let label = UILabel()
        label.attributedText = text
        label.sizeToFit()
        return label
    }
    private static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    /// PR links open in the system browser; only http(s) URLs are handed over.
    private static func browserURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
    private func emptyLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .footnote)
        return label
    }
}

private extension UIFont {
    func bold() -> UIFont {
        fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? self
    }
}
