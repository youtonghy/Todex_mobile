import TodexCore
import UIKit

typealias WorkbenchCommand = @MainActor (String, JSONValue, TimeInterval) async throws -> JSONValue

/// Only routing metadata is persisted. File contents, terminal output and credentials stay in memory.
struct WorkbenchTab: Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case terminal, files, browser, git
        var title: String {
            switch self {
            case .terminal: "终端"
            case .files: "文件"
            case .browser: "网页"
            case .git: "Git"
            }
        }
        var symbol: String {
            switch self {
            case .terminal: "terminal"
            case .files: "folder"
            case .browser: "globe"
            case .git: "point.3.connected.trianglepath.dotted"
            }
        }
    }
    var id = UUID().uuidString
    var kind: Kind
    var title: String
    var path: String
    var filePath: String?
    var terminalId: String?
    var url: String?
    var backendPreview = false
}

@MainActor
final class WorkbenchViewController: UIViewController {
    enum SharingScope: String, Codable { case conversation, workspace }
    private struct Layout: Codable {
        var tabs: [WorkbenchTab]
        var selected: String?
    }
    private let connection: BackendConnection
    private let workspace: WorkspaceRecord
    private let conversationId: String
    private let command: WorkbenchCommand
    private let events: AsyncStream<JSONValue>
    private let insertReference: @MainActor (String) -> Void
    private var eventTask: Task<Void, Never>?
    private var tabs: [WorkbenchTab] = []
    private var selected: String?
    private var controllers: [String: UIViewController] = [:]
    // One Git surface is shared by the tab and the conversation header menu so
    // write protection and legacy-diff event matching stay consistent.
    private var sharedGit: WorkbenchGitViewController?
    private var current: UIViewController?
    private let tabStack = UIStackView()
    private let tabScroll = UIScrollView()
    private let content = UIView()
    private let notice = UILabel()
    private let empty = Theme.label("暂无打开的标签", style: .subheadline, color: .secondaryLabel)
    private(set) var sharingScope: SharingScope = .conversation

    init(
        connection: BackendConnection, workspace: WorkspaceRecord, conversationId: String,
        command: @escaping @MainActor (String, JSONValue, TimeInterval) async throws -> JSONValue,
        events: AsyncStream<JSONValue>, insertReference: @escaping @MainActor (String) -> Void
    ) {
        self.connection = connection
        self.workspace = workspace
        self.conversationId = conversationId
        self.command = command
        self.events = events
        self.insertReference = insertReference
        super.init(nibName: nil, bundle: nil)
        sharingScope =
            SharingScope(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .conversation
        title = "操作台"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { eventTask?.cancel() }

    private var identity: String {
        // Encoding each component avoids delimiter collisions; the token is deliberately excluded.
        [
            connection.id, (try? connection.normalizedURL().absoluteString) ?? connection.serverURL,
            workspace.tenantId, workspace.id,
        ].map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
    }
    private var preferenceKey: String { "workbenchSharing" }
    private var layoutKey: String {
        "todex.workbench.layout.v1.\(identity).\(sharingScope.rawValue)."
            + (sharingScope == .conversation ? Data(conversationId.utf8).base64EncodedString() : "shared")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let add = Theme.iconButton("plus")
        add.accessibilityLabel = "新标签"
        add.addAction(
            UIAction { [weak self] _ in self?.showAddMenu() }, for: .primaryActionTriggered)
        let more = Theme.iconButton("ellipsis", pointSize: 11)
        more.accessibilityLabel = "工作台选项"
        more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] provide in
                provide(self?.optionsMenuElements() ?? [])
            }
        ])
        tabStack.axis = .horizontal
        tabStack.spacing = 0
        tabStack.alignment = .center
        let scroll = tabScroll
        scroll.showsHorizontalScrollIndicator = false
        scroll.addSubview(tabStack)
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tabStack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            tabStack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            tabStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            tabStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            tabStack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 44),
        ])
        let bar = UIStackView(arrangedSubviews: [scroll, add, more])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 4
        bar.isLayoutMarginsRelativeArrangement = true
        bar.directionalLayoutMargins = .init(top: 3, leading: 0, bottom: 3, trailing: 6)
        let barWrap = UIView()
        barWrap.backgroundColor = Theme.secondary
        barWrap.layer.cornerRadius = 12
        barWrap.clipsToBounds = true
        barWrap.addSubview(bar)
        bar.pinEdges(to: barWrap)
        notice.font = .preferredFont(forTextStyle: .caption1)
        notice.numberOfLines = 0
        notice.textColor = .secondaryLabel
        notice.isHidden = true
        content.addSubview(empty)
        empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        WBUI.installStack(in: view, views: [barWrap, notice, content], keyboard: true)
        restore()
        let stream = events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
            guard !Task.isCancelled else { return }
            self?.markStreamGap("实时事件流已结束；终端输出可能缺失。重新连接后经「终端选项」核对 PTY。")
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(enteredBackground), name: UIApplication.didEnterBackgroundNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sharingChanged), name: Notification.Name("Todex.workbenchSharingChanged"),
            object: nil)
    }

    /// May also be called by the host's settings UI. Current in-memory edits are retained across scopes.
    func setSharingScope(_ scope: SharingScope) {
        guard scope != sharingScope else { return }
        save()
        sharingScope = scope
        UserDefaults.standard.set(scope.rawValue, forKey: preferenceKey)
        if isViewLoaded { restore() }
        NotificationCenter.default.post(name: Notification.Name("Todex.workbenchSharingChanged"), object: nil)
    }

    private func restore() {
        if let data = UserDefaults.standard.data(forKey: layoutKey),
            let layout = try? JSONDecoder().decode(Layout.self, from: data)
        {
            var ids = Set<String>()
            tabs = layout.tabs.filter { !$0.id.isEmpty && ids.insert($0.id).inserted }.prefix(20).map { $0 }
            selected = layout.selected
        } else {
            tabs = [WorkbenchTab(kind: .files, title: "文件", path: workspace.path)]
            selected = tabs.first?.id
        }
        for tab in tabs where tab.kind == .terminal { controller(for: tab).loadViewIfNeeded() }
        if !tabs.contains(where: { $0.id == selected }) { selected = tabs.first?.id }
        renderTabs()
        showSelected()
    }
    private func save() {
        guard let data = try? JSONEncoder().encode(Layout(tabs: tabs, selected: selected)) else { return }
        UserDefaults.standard.set(data, forKey: layoutKey)
    }
    private func select(_ id: String) {
        selected = id
        renderTabs()
        showSelected()
        save()
    }
    private func renderTabs() {
        tabStack.arrangedSubviews.forEach {
            tabStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, tab) in tabs.enumerated() {
            let isSelected = tab.id == selected
            var config = UIButton.Configuration.plain()
            config.image = Theme.icon(tab.kind.symbol, pointSize: 12)
            config.imagePadding = 5
            config.attributedTitle = AttributedString(
                tab.title,
                attributes: AttributeContainer([.font: UIFont.preferredFont(forTextStyle: .footnote)]))
            config.baseForegroundColor = isSelected ? .label : .secondaryLabel
            config.titleLineBreakMode = .byTruncatingMiddle
            config.contentInsets = .init(top: 4, leading: 9, bottom: 4, trailing: isSelected ? 3 : 9)
            let button = TabButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                self?.select(tab.id)
            })
            button.tabId = tab.id
            button.accessibilityLabel = tab.title
            button.titleLabel?.numberOfLines = 1
            button.addInteraction(UIContextMenuInteraction(delegate: self))
            if isSelected { button.accessibilityTraits.insert(.selected) }
            let cell = UIStackView(arrangedSubviews: [button])
            cell.axis = .horizontal
            cell.alignment = .center
            cell.spacing = 0
            cell.backgroundColor = isSelected ? .systemBackground : .clear
            cell.heightAnchor.constraint(equalToConstant: 38).isActive = true
            if isSelected { cell.layer.cornerRadius = 8 }
            if isSelected {
                var closeConfig = UIButton.Configuration.plain()
                closeConfig.image = Theme.icon("xmark", pointSize: 9)
                closeConfig.baseForegroundColor = .secondaryLabel
                closeConfig.contentInsets = .init(top: 4, leading: 2, bottom: 4, trailing: 8)
                let close = UIButton(
                    configuration: closeConfig,
                    primaryAction: UIAction { [weak self] _ in self?.requestClose(tab.id) })
                close.accessibilityLabel = "关闭 \(tab.title)"
                cell.addArrangedSubview(close)
            }
            cell.widthAnchor.constraint(lessThanOrEqualToConstant: 190).isActive = true
            tabStack.addArrangedSubview(cell)
            if index < tabs.count - 1 {
                let separator = UIView()
                separator.backgroundColor = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
                separator.heightAnchor.constraint(equalToConstant: 18).isActive = true
                tabStack.addArrangedSubview(separator)
            }
        }
        tabScroll.layoutIfNeeded()
        if let index = tabs.firstIndex(where: { $0.id == selected }) {
            // Cells and separators interleave, so the selected cell sits at index * 2.
            let cell = tabStack.arrangedSubviews[index * 2]
            tabScroll.scrollRectToVisible(cell.convert(cell.bounds, to: tabScroll), animated: false)
        }
    }
    private func showSelected() {
        current?.willMove(toParent: nil)
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        current = nil
        empty.isHidden = !tabs.isEmpty
        guard let tab = tabs.first(where: { $0.id == selected }) else { return }
        let child = controller(for: tab)
        current = child
        addChild(child)
        content.addSubview(child.view)
        WBUI.pin(child.view, to: content)
        child.didMove(toParent: self)
    }
    private func controller(for tab: WorkbenchTab) -> UIViewController {
        if let cached = controllers[tab.id] { return cached }
        let update: @MainActor (WorkbenchTab) -> Void = { [weak self] changed in
            guard let self, let index = self.tabs.firstIndex(where: { $0.id == changed.id }) else { return }
            self.tabs[index] = changed
            self.save()
            self.renderTabs()
        }
        let child: UIViewController
        switch tab.kind {
        case .terminal:
            child = WorkbenchTerminalViewController(tab: tab, workspace: workspace, command: command, update: update)
        case .files:
            child = WorkbenchFilesViewController(
                tab: tab, connection: connection, workspacePath: workspace.path,
                insertReference: insertReference, update: update,
                openFile: { [weak self] path in self?.addTab(.files, path: path) })
        case .browser:
            child = WorkbenchBrowserViewController(tab: tab, connection: connection, update: update)
        case .git:
            child = git()
        }
        controllers[tab.id] = child
        return child
    }
    /// Shared Git controller: exists independently of any open tab so the
    /// conversation header can drive Git operations at any time.
    private func git() -> WorkbenchGitViewController {
        if let sharedGit { return sharedGit }
        let controller = WorkbenchGitViewController(
            connection: connection, workspace: workspace, conversationId: conversationId,
            command: command, insertReference: insertReference)
        controller.loadViewIfNeeded()
        sharedGit = controller
        return controller
    }
    func gitMenu(host: UIViewController) -> UIMenu { git().gitMenu(host: host) }
    private func addTab(_ kind: WorkbenchTab.Kind, path: String? = nil) {
        guard tabs.count < 20 else {
            WBUI.message(on: self, title: "标签已满", text: "最多打开 20 个标签，请先关闭部分标签。")
            return
        }
        let tab = WorkbenchTab(
            kind: kind, title: path.map { ($0 as NSString).lastPathComponent } ?? kind.title,
            path: workspace.path, filePath: kind == .files ? path : nil,
            terminalId: kind == .terminal ? "terminal_\(UUID().uuidString)" : nil)
        tabs.append(tab)
        selected = tab.id
        renderTabs()
        showSelected()
        save()
    }
    func openFile(_ path: String) {
        loadViewIfNeeded()
        let absolute = path.hasPrefix("/") ? path : (workspace.path as NSString).appendingPathComponent(path)
        if let tab = tabs.first(where: { $0.kind == .files && $0.filePath == absolute }) {
            selected = tab.id
            renderTabs()
            showSelected()
            save()
        } else {
            addTab(.files, path: absolute)
        }
    }
    private func showAddMenu() {
        let sheet = UIAlertController(title: "新建标签", message: nil, preferredStyle: .actionSheet)
        for kind in WorkbenchTab.Kind.allCases {
            sheet.addAction(UIAlertAction(title: kind.title, style: .default) { [weak self] _ in self?.addTab(kind) })
        }
        WBUI.presentSheet(sheet, on: self)
    }
    private func optionsMenuElements() -> [UIMenuElement] {
        var elements: [UIMenuElement] = [
            UIMenu(
                title: "共享范围", options: .displayInline,
                children: [
                    UIAction(title: "当前对话", state: sharingScope == .conversation ? .on : .off) {
                        [weak self] _ in self?.setSharingScope(.conversation)
                    },
                    UIAction(title: "工作区共享", state: sharingScope == .workspace ? .on : .off) {
                        [weak self] _ in self?.setSharingScope(.workspace)
                    },
                ])
        ]
        if selected != nil {
            elements.append(
                UIAction(title: "关闭当前标签", image: Theme.icon("xmark", pointSize: 13)) {
                    [weak self] _ in
                    guard let self, let selected = self.selected else { return }
                    self.requestClose(selected)
                })
        }
        return elements
    }
    private func requestClose(_ id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        if let file = controllers[id] as? WorkbenchFilesViewController, file.isSaving {
            WBUI.message(on: self, title: "保存进行中", text: "请等待保存结果后关闭标签。")
            return
        }
        if let git = controllers[id] as? WorkbenchGitViewController, git.hasUnresolvedOperation {
            WBUI.message(on: self, title: "Git 操作仍需核对", text: "请等待操作结束；结果未知时先核对实际状态并解除写保护，再关闭此标签。")
            return
        }
        let remove: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let removedIndex = self.tabs.firstIndex { $0.id == id } ?? 0
            self.tabs.removeAll { $0.id == id }
            self.controllers.removeValue(forKey: id)
            if self.selected == id {
                self.selected =
                    removedIndex < self.tabs.count ? self.tabs[removedIndex].id : self.tabs.last?.id
            }
            self.renderTabs()
            self.showSelected()
            self.save()
        }
        if let terminal = controllers[id] as? WorkbenchTerminalViewController {
            let sheet = UIAlertController(title: "关闭终端标签", message: "离开标签不会自动结束后端 PTY。", preferredStyle: .actionSheet)
            sheet.addAction(
                UIAlertAction(title: "停止 PTY 并关闭", style: .destructive) { [weak self, weak terminal] _ in
                    Task { @MainActor in
                        do {
                            try await terminal?.stop()
                            remove()
                        } catch { if let self { WBUI.error(error, on: self) } }
                    }
                })
            sheet.addAction(UIAlertAction(title: "保留 PTY，仅关闭标签", style: .default) { _ in remove() })
            WBUI.presentSheet(sheet, on: self)
        } else if let file = controllers[id] as? WorkbenchFilesViewController, file.hasUnsavedChanges {
            WBUI.confirm(on: self, title: "放弃未保存编辑？", message: "关闭标签会丢失当前文件的本地编辑。", action: "放弃并关闭", perform: remove)
        } else {
            remove()
        }
    }
    private func receive(_ event: JSONValue) {
        let data = WBEvent.data(event)
        let type = event["type"].stringValue
        let code = data["code"].stringValue
        if ["EVENT_STREAM_LAGGED", "EVENT_STREAM_CLOSED", "STREAM_LAGGED", "STREAM_CLOSED"].contains(code)
            || ["connection.disconnected", "connection.closed", "connection.gap"].contains(type)
        {
            markStreamGap("实时连接中断或丢失事件；PTY 不支持历史重放，缺失输出无法补回。")
        }
        if type == "connection.ready" {
            controllers.values.compactMap { $0 as? WorkbenchTerminalViewController }.forEach { $0.refreshStatus() }
        }
        for controller in controllers.values {
            (controller as? WorkbenchTerminalViewController)?.receive(event)
            (controller as? WorkbenchGitViewController)?.receive(event)
        }
        if let git = sharedGit, !controllers.values.contains(where: { $0 === git }) {
            git.receive(event)
        }
    }
    private func markStreamGap(_ text: String) {
        notice.text = text
        notice.isHidden = false
        controllers.values.compactMap { $0 as? WorkbenchTerminalViewController }.forEach { $0.markGap(text) }
    }
    @objc private func enteredBackground() { markStreamGap("应用进入后台；期间可能缺失终端输出。返回后将核对 PTY 状态。") }
    @objc private func becameActive() {
        controllers.values.compactMap { $0 as? WorkbenchTerminalViewController }.forEach { $0.refreshStatus() }
    }
    @objc private func sharingChanged() {
        let scope = SharingScope(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .conversation
        guard scope != sharingScope else { return }
        save()
        sharingScope = scope
        restore()
    }
}

extension WorkbenchViewController: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let button = interaction.view as? TabButton else { return nil }
        let id = button.tabId
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [
                UIAction(title: "关闭标签", image: UIImage(systemName: "xmark")) { _ in
                    self.requestClose(id)
                }
            ])
        })
    }
}

private final class TabButton: UIButton {
    var tabId = ""
}

enum WBEvent {
    static func data(_ value: JSONValue) -> JSONValue {
        let payload = value["payload"]
        if !payload["data"].objectValue.isEmpty { return payload["data"] }
        return payload.isNull ? value : payload
    }
    static func requestId(_ value: JSONValue) -> String? {
        let data = data(value)
        return data["requestId"].optionalString ?? data["request_id"].optionalString ?? value["id"].optionalString
    }
    static func failure(_ value: JSONValue) -> String? {
        let data = data(value)
        let error = data["error"]
        if !error.isNull { return error["message"].optionalString ?? error.optionalString ?? error.prettyPrinted }
        if value["type"].stringValue == "error" || value["ok"] == .bool(false) {
            return data["message"].optionalString ?? value.prettyPrinted
        }
        return nil
    }
}

@MainActor
enum WBUI {
    static func button(_ title: String, _ symbol: String, action: @escaping @MainActor () -> Void) -> UIButton {
        var config = UIButton.Configuration.tinted()
        config.title = title
        config.image = UIImage(systemName: symbol)
        config.imagePadding = 5
        config.cornerStyle = .medium
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var result = incoming
            result.font = .preferredFont(forTextStyle: .subheadline)
            return result
        }
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = title
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return button
    }
    static func row(_ views: [UIView]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal
        row.spacing = 8
        row.distribution = .fillEqually
        return row
    }
    static func pin(_ child: UIView, to parent: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }
    @discardableResult static func installStack(in view: UIView, views: [UIView], keyboard: Bool = false) -> UIStackView
    {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = 8
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(
                equalTo: keyboard ? view.keyboardLayoutGuide.topAnchor : view.safeAreaLayoutGuide.bottomAnchor,
                constant: -8),
        ])
        return stack
    }
    static func message(on host: UIViewController, title: String, text: String) {
        let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .cancel))
        presentModal(alert, on: host)
    }
    static func error(_ error: any Error, on host: UIViewController) {
        message(on: host, title: "操作未完成", text: error.localizedDescription)
    }
    static func confirm(
        on host: UIViewController, title: String, message: String, action: String = "确认",
        perform: @escaping @MainActor () -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: action, style: .destructive) { _ in perform() })
        presentModal(alert, on: host)
    }
    static func presentSheet(_ sheet: UIAlertController, on host: UIViewController) {
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = host.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: host.view.bounds.midX, y: 44, width: 1, height: 1)
        presentModal(sheet, on: host)
    }
    static func form(
        on host: UIViewController, title: String, message: String? = nil, fields: [(String, String)],
        submit: String = "继续", action: @escaping @MainActor ([String]) -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        fields.forEach { label, value in
            alert.addTextField {
                $0.placeholder = label
                $0.text = value
                $0.accessibilityLabel = label
                $0.autocapitalizationType = .none
                $0.autocorrectionType = .no
            }
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(
            UIAlertAction(title: submit, style: .default) { [weak alert] _ in
                action(alert?.textFields?.map { $0.text ?? "" } ?? [])
            })
        presentModal(alert, on: host)
    }
    static func textSheet(
        on host: UIViewController, title: String, text: String, editable: Bool = false,
        actions: [(String, @MainActor (String) -> Void)] = []
    ) {
        let page = UIViewController()
        page.title = title
        page.view.backgroundColor = .systemBackground
        let editor = UITextView()
        editor.text = text
        editor.isEditable = editable
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.adjustsFontForContentSizeCategory = true
        editor.autocorrectionType = .no
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        var views: [UIView] = [editor]
        for (label, action) in actions {
            views.append(
                button(label, "paperplane") { [weak page, weak editor] in
                    let value = editor?.text ?? ""
                    page?.dismiss(animated: true) { action(value) }
                })
        }
        installStack(in: page.view, views: views, keyboard: true)
        let nav = UINavigationController(rootViewController: page)
        page.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
        nav.presentationController?.delegate = nil
        nav.isModalInPresentation = editable
        presentModal(nav, on: host)
    }
    static func presentModal(_ modal: UIViewController, on host: UIViewController) {
        // Action-sheet handlers run while the old sheet is still presented.
        // Wait for dismissal so the next form/confirmation is not silently rejected by UIKit.
        if let presented = host.presentedViewController {
            if presented is UIAlertController {
                presented.dismiss(animated: true) { [weak host] in
                    guard let host else { return }
                    presentModal(modal, on: host)
                }
            } else {
                presentModal(modal, on: presented)
            }
            return
        }
        guard host.viewIfLoaded?.window != nil else { return }
        host.present(modal, animated: true)
    }
}
