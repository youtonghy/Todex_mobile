import TodexCore
import UIKit

final class ConversationContainerController: UIViewController {
    private let session: AppSession
    private let conversation: ConversationManifest
    private let chat: ChatViewController
    private var workbench: WorkbenchViewController?
    private let panes = UIStackView()
    private let picker = UISegmentedControl(items: ["对话", "操作台"])
    private var wideConstraint: NSLayoutConstraint?
    private var observer: UUID?
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
    override func viewDidLoad() {
        super.viewDidLoad()
        title = conversation.title ?? "新对话"
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
            wideConstraint = chat.view.widthAnchor.constraint(
                equalTo: panes.widthAnchor, multiplier: 0.51, constant: -0.5)
        }
        let more = UIBarButtonItem(
            image: Theme.icon("ellipsis.circle"),
            menu: UIMenu(children: [
                UIAction(title: "能力目录", image: Theme.icon("square.grid.2x2")) { [weak self] _ in self?.showCatalog() },
                UIAction(title: "使用统计", image: Theme.icon("chart.bar")) { [weak self] _ in self?.showUsage() },
                UIAction(title: "子代理与记忆", image: Theme.icon("brain")) { [weak self] _ in self?.showAuxiliary() },
                UIAction(title: "导出对话", image: Theme.icon("square.and.arrow.up")) { [weak self] _ in self?.export() },
            ]))
        more.accessibilityLabel = "对话菜单"
        var items = [more]
        if let workbench {
            let git = UIBarButtonItem(
                image: Theme.icon("point.3.connected.trianglepath.dotted"),
                menu: workbench.gitMenu(host: self))
            git.accessibilityLabel = "Git 操作"
            items.append(git)
        }
        navigationItem.rightBarButtonItems = items
        observer = session.observe { [weak self] in
            self?.title = self?.session.conversations.first { $0.id == self?.conversation.id }?.title ?? "对话"
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPanes()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent {
            if let observer { session.removeObserver(observer) }
            session.persist()
        }
    }
    private func layoutPanes() {
        let wide = view.bounds.width >= 900 && traitCollection.horizontalSizeClass == .regular && workbench != nil
        wideConstraint?.isActive = wide
        if !wide, picker.selectedSegmentIndex == 1 { chat.view.endEditing(true) }
        if !wide, picker.selectedSegmentIndex == 0 { workbench?.view.endEditing(true) }
        chat.view.isHidden = !wide && picker.selectedSegmentIndex == 1 && workbench != nil
        workbench?.view.isHidden = !wide && picker.selectedSegmentIndex == 0
        navigationItem.titleView = wide ? nil : picker
    }
    private func showCatalog() {
        guard let connection = session.connection else { return }
        let catalog = CatalogViewController(
            connection: connection, workspace: conversation.workspace, provider: conversation.provider,
            command: { [weak self] type, payload, timeout in
                guard let self else { throw TodexError.disconnected }
                var value = payload
                if type.hasPrefix("mcp.") { value["conversationId"] = .string(conversation.id) }
                return try await session.command(type, value, timeout: timeout)
            }, insertSkill: { [weak self] id, name in self?.chat.insertSkill(id, name: name) },
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
