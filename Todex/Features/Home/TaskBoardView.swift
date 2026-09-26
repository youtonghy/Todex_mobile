import TodexCore
import UIKit

/// Desktop-parity vertical kanban: one tinted column per workspace, task cards
/// grouped by status inside the column. Columns scroll horizontally; each
/// column scrolls vertically on its own. All mutations go through Handlers
/// supplied by the host so session/persistence logic stays in HomeViewController.
/// Long-pressing a column header drags the column to a new position.
final class TaskBoardView: UIView, UIDragInteractionDelegate, UIDropInteractionDelegate {
    struct Handlers {
        var open: (KanbanTask) -> Void
        var enterWorkspace: (WorkspaceRecord) -> Void
        var addTask: (WorkspaceRecord) -> Void
        var statusMenu: (KanbanTask) -> UIMenu
        var attachMenu: (KanbanTask, WorkspaceRecord) -> UIMenuElement
        var moreMenu: (KanbanTask, WorkspaceRecord) -> UIMenu
        var linkedTitle: (KanbanTask) -> String?
        /// Attention dot of the linked conversation (working / issue / unread).
        var linkedStatus: (KanbanTask) -> (color: UIColor, label: String)?
        /// Moves the source column before (or after) the target column.
        var moveColumn: (_ source: String, _ target: String, _ after: Bool) -> Void
    }
    var handlers: Handlers?

    /// Column container tagged with its workspace for drag and drop.
    private final class ColumnView: UIView {
        let workspaceId: String
        init(workspaceId: String) {
            self.workspaceId = workspaceId
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    private let scroll = UIScrollView()
    private let columns = UIStackView()
    /// Workspace ids whose 已完成 group is expanded; collapsed by default.
    private var expandedDone = Set<String>()
    /// A rebuild mid-drag would remove the drop targets; it waits for the drop.
    private var dragging = false
    private var deferredColumns: [(WorkspaceRecord, [KanbanTask])]?
    // Mirror the desktop column palette: accent, warning, danger, success.
    private static let palette: [UIColor] = [Theme.accent, .systemOrange, .systemRed, .systemGreen]

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        columns.axis = .horizontal
        columns.spacing = 12
        // Columns hug their content height; the inner list scroll gets an
        // explicit hug constraint so .top no longer collapses it to zero.
        columns.alignment = .top
        scroll.addSubview(columns)
        addSubview(scroll)
        for view in [scroll, columns] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            columns.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            columns.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            columns.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
            columns.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
            columns.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload(
        workspaces: [WorkspaceRecord], tasksFor: (WorkspaceRecord) -> [KanbanTask]
    ) {
        let data = workspaces.map { ($0, tasksFor($0)) }
        if dragging {
            deferredColumns = data
        } else {
            render(data)
        }
    }

    private func render(_ data: [(WorkspaceRecord, [KanbanTask])]) {
        columns.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let ids = data.map(\.0.id)
        for (index, (workspace, tasks)) in data.enumerated() {
            let card = column(workspace, tint: Self.palette[index % Self.palette.count], tasks: tasks)
            card.addInteraction(UIDropInteraction(delegate: self))
            columns.addArrangedSubview(card)
            // Cap at the board height: taller content falls back to the inner
            // list scroll instead of overflowing the column stack. Activated only
            // once the card shares a view hierarchy with `columns`.
            card.heightAnchor.constraint(lessThanOrEqualTo: columns.heightAnchor).isActive = true
            // VoiceOver equivalent of dragging the column header.
            var moves: [UIAccessibilityCustomAction] = []
            if index > 0 {
                moves.append(
                    UIAccessibilityCustomAction(name: String(localized: "左移")) { [weak self] _ in
                        self?.handlers?.moveColumn(workspace.id, ids[index - 1], false)
                        return true
                    })
            }
            if index + 1 < ids.count {
                moves.append(
                    UIAccessibilityCustomAction(name: String(localized: "右移")) { [weak self] _ in
                        self?.handlers?.moveColumn(workspace.id, ids[index + 1], true)
                        return true
                    })
            }
            card.accessibilityCustomActions = moves
        }
    }

    private func column(_ workspace: WorkspaceRecord, tint: UIColor, tasks: [KanbanTask]) -> ColumnView {
        let card = ColumnView(workspaceId: workspace.id)
        card.backgroundColor = tint.withAlphaComponent(0.07)
        card.layer.cornerRadius = 18
        card.clipsToBounds = true
        card.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let header = UIStackView()
        header.alignment = .center
        header.spacing = 8
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = .init(top: 10, leading: 14, bottom: 6, trailing: 8)

        let pill = UIView()
        pill.backgroundColor = tint.withAlphaComponent(0.15)
        pill.layer.cornerRadius = 13
        let dot = UIView()
        dot.backgroundColor = tint
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let name = Theme.label(Self.displayName(workspace), style: .subheadline)
        name.font = Self.bold(.subheadline)
        name.lineBreakMode = .byTruncatingMiddle
        let pillStack = UIStackView(arrangedSubviews: [dot, name])
        pillStack.alignment = .center
        pillStack.spacing = 6
        pillStack.isLayoutMarginsRelativeArrangement = true
        pillStack.directionalLayoutMargins = .init(top: 5, leading: 10, bottom: 5, trailing: 12)
        pill.addSubview(pillStack)
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        pillStack.pinEdges(to: pill)

        let count = Theme.label("\(tasks.count)", style: .headline, color: tint)
        let enter = UIButton(type: .system)
        enter.setImage(Theme.icon("arrow.right", pointSize: 12), for: .normal)
        enter.tintColor = tint
        enter.accessibilityLabel = String(localized: "进入 \(workspace.name)")
        enter.addAction(
            UIAction { [weak self] _ in self?.handlers?.enterWorkspace(workspace) }, for: .touchUpInside)
        enter.widthAnchor.constraint(equalToConstant: 36).isActive = true
        enter.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let grip = UIImageView(image: Theme.icon("line.3.horizontal", pointSize: 12))
        grip.tintColor = .secondaryLabel
        grip.contentMode = .center
        grip.accessibilityLabel = String(localized: "拖拽调整工作区顺序")
        grip.widthAnchor.constraint(equalToConstant: 28).isActive = true
        header.addArrangedSubview(pill)
        header.addArrangedSubview(count)
        header.addArrangedSubview(UIView())
        header.addArrangedSubview(grip)
        header.addArrangedSubview(enter)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // iPhone disables drag interactions by default.
        let drag = UIDragInteraction(delegate: self)
        drag.isEnabled = true
        header.addInteraction(drag)

        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 8
        list.isLayoutMarginsRelativeArrangement = true
        list.directionalLayoutMargins = .init(top: 4, leading: 12, bottom: 4, trailing: 12)
        if tasks.isEmpty {
            let empty = Theme.label(String(localized: "暂无任务，点击下方新建"), style: .caption1, color: .secondaryLabel)
            empty.textAlignment = .center
            list.addArrangedSubview(empty)
            empty.translatesAutoresizingMaskIntoConstraints = false
            empty.heightAnchor.constraint(equalToConstant: 48).isActive = true
        } else {
            for status in KanbanTask.Status.allCases {
                let items = tasks.filter { $0.status == status }
                guard !items.isEmpty else { continue }
                if status == .done {
                    let cards = UIStackView()
                    cards.axis = .vertical
                    cards.spacing = 8
                    for task in items { cards.addArrangedSubview(taskCard(task, workspace: workspace)) }
                    cards.isHidden = !expandedDone.contains(workspace.id)
                    list.addArrangedSubview(doneHeader(items.count, workspace: workspace, cards: cards))
                    list.addArrangedSubview(cards)
                } else {
                    list.addArrangedSubview(
                        Theme.label(
                            "\(status.label) · \(items.count)", style: .caption1, color: .secondaryLabel))
                    for task in items { list.addArrangedSubview(taskCard(task, workspace: workspace)) }
                }
            }
        }
        let listScroll = UIScrollView()
        listScroll.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: listScroll.contentLayoutGuide.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: listScroll.contentLayoutGuide.trailingAnchor),
            list.topAnchor.constraint(equalTo: listScroll.contentLayoutGuide.topAnchor),
            list.bottomAnchor.constraint(equalTo: listScroll.contentLayoutGuide.bottomAnchor),
            list.widthAnchor.constraint(equalTo: listScroll.frameLayoutGuide.widthAnchor),
        ])
        // Hug the list content so short columns stay compact; the card's
        // board-height cap takes precedence when the list overflows.
        let hug = listScroll.heightAnchor.constraint(equalTo: list.heightAnchor)
        hug.priority = .init(740)
        hug.isActive = true

        var createConfig = UIButton.Configuration.plain()
        createConfig.title = String(localized: "新建任务")
        createConfig.image = Theme.icon("plus", pointSize: 11)
        createConfig.imagePadding = 5
        createConfig.baseForegroundColor = tint
        createConfig.contentInsets = .init(top: 10, leading: 12, bottom: 12, trailing: 12)
        createConfig.titleTextAttributesTransformer = .init { value in
            var result = value
            result.font = .preferredFont(forTextStyle: .subheadline)
            return result
        }
        let create = UIButton(configuration: createConfig)
        create.accessibilityLabel = String(localized: "新建任务 \(workspace.name)")
        create.addAction(
            UIAction { [weak self] _ in self?.handlers?.addTask(workspace) }, for: .touchUpInside)
        let createWrap = UIView()
        createWrap.backgroundColor = tint.withAlphaComponent(0.05)
        createWrap.addSubview(create)
        create.translatesAutoresizingMaskIntoConstraints = false
        create.pinEdges(to: createWrap)

        let stack = UIStackView(arrangedSubviews: [header, listScroll, createWrap])
        stack.axis = .vertical
        stack.spacing = 0
        card.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.pinEdges(to: card)
        return card
    }

    /// Collapsible 已完成 group header: chevron + count, toggles the cards list.
    private func doneHeader(_ count: Int, workspace: WorkspaceRecord, cards: UIView) -> UIButton {
        let expanded = expandedDone.contains(workspace.id)
        var config = UIButton.Configuration.plain()
        config.title = "\(KanbanTask.Status.done.label) · \(count)"
        config.image = Theme.icon(expanded ? "chevron.down" : "chevron.right", pointSize: 9)
        config.imagePlacement = .trailing
        config.imagePadding = 5
        config.contentInsets = .init(top: 2, leading: 0, bottom: 2, trailing: 0)
        config.baseForegroundColor = .secondaryLabel
        config.titleTextAttributesTransformer = .init { value in
            var result = value
            result.font = .preferredFont(forTextStyle: .caption1)
            return result
        }
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.accessibilityIdentifier = "taskboard.done.\(workspace.id)"
        button.addAction(
            UIAction { [weak self, weak cards, weak button] _ in
                guard let self else { return }
                let expanded = !self.expandedDone.contains(workspace.id)
                if expanded {
                    self.expandedDone.insert(workspace.id)
                } else {
                    self.expandedDone.remove(workspace.id)
                }
                cards?.isHidden = !expanded
                if var config = button?.configuration {
                    config.image = Theme.icon(expanded ? "chevron.down" : "chevron.right", pointSize: 9)
                    button?.configuration = config
                }
                UIView.animate(withDuration: 0.25) { self.layoutIfNeeded() }
            }, for: .touchUpInside)
        return button
    }

    private func taskCard(_ task: KanbanTask, workspace: WorkspaceRecord) -> UIView {
        let card = UIView()
        card.backgroundColor = Theme.surface
        card.layer.cornerRadius = 12
        card.accessibilityIdentifier = "task.\(task.id)"
        card.isAccessibilityElement = false

        let color: UIColor =
            task.status == .done ? .systemGreen : (task.status == .inProgress ? Theme.accent : .secondaryLabel)
        let dot = UIView()
        dot.backgroundColor = color
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let title = Theme.label(task.title, style: .subheadline)
        title.font = Self.bold(.subheadline)
        title.numberOfLines = 0
        let titleRow = UIStackView(arrangedSubviews: [dot, title])
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 8

        let body = UIStackView(arrangedSubviews: [titleRow])
        body.axis = .vertical
        body.spacing = 8
        body.isLayoutMarginsRelativeArrangement = true
        body.directionalLayoutMargins = .init(top: 10, leading: 12, bottom: 10, trailing: 10)

        if let description = task.description, !description.isEmpty {
            let text = Theme.label(description, style: .caption1, color: .secondaryLabel)
            text.numberOfLines = 2
            body.addArrangedSubview(text)
        }
        if let due = task.dueDate, !due.isEmpty {
            let overdue = task.isOverdue
            let tint: UIColor = overdue ? .systemRed : .secondaryLabel
            let icon = UIImageView(image: Theme.icon("calendar", pointSize: 11))
            icon.tintColor = tint
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let date = Theme.label(overdue ? String(localized: "\(due)（已逾期）") : due, style: .caption1, color: tint)
            date.numberOfLines = 1
            let row = UIStackView(arrangedSubviews: [icon, date])
            row.alignment = .center
            row.spacing = 4
            row.accessibilityLabel = overdue ? String(localized: "截止日期 \(due)，已逾期") : String(localized: "截止日期 \(due)")
            row.isAccessibilityElement = true
            body.addArrangedSubview(row)
        }

        if let linked = handlers?.linkedTitle(task) {
            let link = UIButton(type: .system)
            var config = UIButton.Configuration.plain()
            config.title = linked.isEmpty ? String(localized: "对话已失效") : linked
            config.image = Theme.icon("bubble.left", pointSize: 10)
            config.imagePadding = 5
            config.contentInsets = .zero
            config.baseForegroundColor = linked.isEmpty ? .secondaryLabel : Theme.accent
            config.titleLineBreakMode = .byTruncatingTail
            config.titleTextAttributesTransformer = .init { value in
                var result = value
                result.font = .preferredFont(forTextStyle: .caption1)
                return result
            }
            link.configuration = config
            link.contentHorizontalAlignment = .leading
            link.addAction(
                UIAction { [weak self] _ in self?.handlers?.open(task) }, for: .touchUpInside)
            // Desktop shows the linked conversation's attention state on open tasks.
            if task.status != .done, !linked.isEmpty, let status = handlers?.linkedStatus(task) {
                let marker = UIView()
                marker.backgroundColor = status.color
                marker.layer.cornerRadius = 3.5
                marker.isAccessibilityElement = true
                marker.accessibilityLabel = status.label
                marker.translatesAutoresizingMaskIntoConstraints = false
                marker.widthAnchor.constraint(equalToConstant: 7).isActive = true
                marker.heightAnchor.constraint(equalToConstant: 7).isActive = true
                let row = UIStackView(arrangedSubviews: [link, marker])
                row.alignment = .center
                row.spacing = 6
                link.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                body.addArrangedSubview(row)
            } else {
                body.addArrangedSubview(link)
            }
        }

        var chipConfig = UIButton.Configuration.gray()
        chipConfig.cornerStyle = .capsule
        chipConfig.baseBackgroundColor = color.withAlphaComponent(0.14)
        chipConfig.baseForegroundColor = color
        chipConfig.contentInsets = .init(top: 4, leading: 10, bottom: 4, trailing: 10)
        chipConfig.titleTextAttributesTransformer = .init { value in
            var result = value
            result.font = .preferredFont(forTextStyle: .caption1)
            return result
        }
        let chip = UIButton(configuration: chipConfig)
        chip.configuration?.title = task.status.label
        chip.menu = handlers?.statusMenu(task)
        chip.showsMenuAsPrimaryAction = true
        chip.accessibilityLabel = String(localized: "任务状态：\(task.status.label)")

        let pin = UIButton(type: .system)
        pin.setImage(Theme.icon("pin", pointSize: 12), for: .normal)
        pin.tintColor = .secondaryLabel
        pin.menu = (handlers?.attachMenu(task, workspace)).map { UIMenu(children: [$0]) }
        pin.showsMenuAsPrimaryAction = true
        pin.accessibilityLabel = String(localized: "贴到对话")
        pin.widthAnchor.constraint(equalToConstant: 32).isActive = true
        pin.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let more = UIButton(type: .system)
        more.setImage(Theme.icon("ellipsis", pointSize: 12), for: .normal)
        more.tintColor = .secondaryLabel
        more.menu = handlers?.moreMenu(task, workspace)
        more.showsMenuAsPrimaryAction = true
        more.accessibilityLabel = String(localized: "任务操作")
        more.widthAnchor.constraint(equalToConstant: 32).isActive = true
        more.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let actions = UIStackView(arrangedSubviews: [chip, UIView(), pin, more])
        actions.alignment = .center
        body.addArrangedSubview(actions)

        card.addSubview(body)
        body.translatesAutoresizingMaskIntoConstraints = false
        body.pinEdges(to: card)
        return card
    }

    // MARK: Column drag and drop

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession)
        -> [UIDragItem]
    {
        guard let column = Self.column(containing: interaction.view) else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = column.workspaceId
        return [item]
    }
    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: any UIDragSession)
        -> UITargetedDragPreview?
    {
        guard let column = Self.column(containing: interaction.view), column.window != nil else { return nil }
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: column.bounds, cornerRadius: 18)
        return UITargetedDragPreview(view: column, parameters: parameters)
    }
    /// Freeze re-renders from the lift on: a redraw during the long press would
    /// remove the header carrying this interaction and cancel the drag.
    func dragInteraction(
        _ interaction: UIDragInteraction, willAnimateLiftWith animator: any UIDragAnimating,
        session: any UIDragSession
    ) {
        dragging = true
        animator.addCompletion { [weak self] position in
            // `.start` means the lift was cancelled before a session began.
            if position == .start { self?.endDrag() }
        }
    }
    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: any UIDragSession) {
        dragging = true
    }
    func dragInteraction(
        _ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation
    ) {
        endDrag()
    }
    private func endDrag() {
        dragging = false
        if let data = deferredColumns {
            deferredColumns = nil
            render(data)
        }
    }
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        session.localDragSession?.items.first?.localObject is String
    }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession)
        -> UIDropProposal
    {
        guard let target = interaction.view as? ColumnView,
            let source = session.localDragSession?.items.first?.localObject as? String, source != target.workspaceId
        else { return UIDropProposal(operation: .cancel) }
        target.layer.borderColor = Theme.accent.cgColor
        target.layer.borderWidth = 2
        return UIDropProposal(operation: .move)
    }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
        interaction.view?.layer.borderWidth = 0
    }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) {
        interaction.view?.layer.borderWidth = 0
    }
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        guard let target = interaction.view as? ColumnView,
            let source = session.localDragSession?.items.first?.localObject as? String
        else { return }
        target.layer.borderWidth = 0
        // Dropping on the trailing half places the column after the target.
        let after = session.location(in: target).x > target.bounds.midX
        handlers?.moveColumn(source, target.workspaceId, after)
    }
    private static func column(containing view: UIView?) -> ColumnView? {
        var current = view
        while let candidate = current {
            if let column = candidate as? ColumnView { return column }
            current = candidate.superview
        }
        return nil
    }

    private static func bold(_ style: UIFont.TextStyle) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        guard
            let descriptor = base.fontDescriptor.withSymbolicTraits(
                base.fontDescriptor.symbolicTraits.union(.traitBold))
        else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }
    private static func displayName(_ workspace: WorkspaceRecord) -> String {
        workspace.name.contains("/")
            ? URL(fileURLWithPath: workspace.name).lastPathComponent : workspace.name
    }
}

extension KanbanTask {
    /// Desktop `isKanbanTaskOverdue`: an unfinished task whose due date is
    /// before today in the local calendar.
    var isOverdue: Bool {
        guard let dueDate, status != .done else { return false }
        return dueDate < KanbanTaskEditor.dateFormatter.string(from: Date())
    }
    /// Desktop `kanbanTaskDraftText`, the lines written into a chat draft.
    var draftText: String {
        var lines = [String(localized: "任务：\(title)")]
        if let description, !description.isEmpty { lines.append(String(localized: "描述：\(description)")) }
        if let dueDate, !dueDate.isEmpty { lines.append(String(localized: "截止日期：\(dueDate)")) }
        return lines.joined(separator: "\n")
    }
}

/// Create/edit form for a kanban task: title, optional description and
/// optional due date (desktop KanbanPanel's inline form).
final class KanbanTaskEditor: UIViewController, UITextViewDelegate {
    struct Values {
        var title: String
        var description: String?
        var dueDate: String?
    }
    /// `YYYY-MM-DD` in the local calendar, the wire format desktop uses.
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private let task: KanbanTask?
    private let subtitle: String
    private let save: (Values) -> Void
    private let titleField = UITextField()
    private let descriptionView = UITextView()
    private let placeholder = Theme.label(String(localized: "任务描述（可选）"), color: .placeholderText)
    private let dueSwitch = UISwitch()
    private let datePicker = UIDatePicker()

    init(task: KanbanTask?, subtitle: String, save: @escaping (Values) -> Void) {
        self.task = task
        self.subtitle = subtitle
        self.save = save
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = task == nil ? String(localized: "新建任务") : String(localized: "编辑任务")
        view.backgroundColor = Theme.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: task == nil ? String(localized: "添加") : String(localized: "保存"), primaryAction: UIAction { [weak self] _ in self?.submit() })

        titleField.text = task?.title
        titleField.placeholder = String(localized: "任务标题")
        titleField.font = .preferredFont(forTextStyle: .body)
        titleField.adjustsFontForContentSizeCategory = true
        titleField.borderStyle = .none
        titleField.returnKeyType = .next
        titleField.accessibilityIdentifier = "task.editor.title"
        titleField.addAction(UIAction { [weak self] _ in self?.updateSaveState() }, for: .editingChanged)
        titleField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        descriptionView.text = task?.description
        descriptionView.font = .preferredFont(forTextStyle: .body)
        descriptionView.adjustsFontForContentSizeCategory = true
        descriptionView.backgroundColor = .clear
        descriptionView.textContainerInset = .init(top: 10, left: 0, bottom: 10, right: 0)
        descriptionView.textContainer.lineFragmentPadding = 0
        descriptionView.delegate = self
        descriptionView.accessibilityLabel = String(localized: "任务描述（可选）")
        descriptionView.accessibilityIdentifier = "task.editor.description"
        descriptionView.heightAnchor.constraint(equalToConstant: 110).isActive = true
        descriptionView.addSubview(placeholder)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: descriptionView.leadingAnchor),
            placeholder.topAnchor.constraint(equalTo: descriptionView.topAnchor, constant: 10),
        ])
        placeholder.isHidden = !descriptionView.text.isEmpty

        let dueLabel = Theme.label(String(localized: "截止日期"))
        dueSwitch.isOn = task?.dueDate != nil
        dueSwitch.accessibilityLabel = String(localized: "设置截止日期")
        dueSwitch.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                datePicker.isHidden = !dueSwitch.isOn
            }, for: .valueChanged)
        datePicker.datePickerMode = .date
        datePicker.preferredDatePickerStyle = .compact
        datePicker.accessibilityLabel = String(localized: "截止日期（可选）")
        datePicker.date = task?.dueDate.flatMap(Self.dateFormatter.date(from:)) ?? Date()
        datePicker.isHidden = !dueSwitch.isOn
        let dueRow = UIStackView(arrangedSubviews: [dueLabel, UIView(), datePicker, dueSwitch])
        dueRow.alignment = .center
        dueRow.spacing = 10
        dueRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let form = UIStackView(arrangedSubviews: [
            Self.card([titleField]), Self.card([descriptionView]), Self.card([dueRow]),
            Theme.label(subtitle, style: .footnote, color: .secondaryLabel),
        ])
        form.axis = .vertical
        form.spacing = 12
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        scroll.addSubview(form)
        view.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        form.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            form.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            form.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            form.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            form.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
        ])
        updateSaveState()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if task == nil { titleField.becomeFirstResponder() }
    }
    func textViewDidChange(_ textView: UITextView) { placeholder.isHidden = !textView.text.isEmpty }

    private func updateSaveState() {
        navigationItem.rightBarButtonItem?.isEnabled =
            !(titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func submit() {
        let name = (titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let text = descriptionView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = Values(
            title: name, description: text.isEmpty ? nil : text,
            dueDate: dueSwitch.isOn ? Self.dateFormatter.string(from: datePicker.date) : nil)
        dismiss(animated: true) { [save] in save(values) }
    }
    private static func card(_ views: [UIView]) -> UIView {
        let card = UIView()
        card.backgroundColor = Theme.surface
        card.layer.cornerRadius = 12
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: 2, leading: 14, bottom: 2, trailing: 14)
        card.addSubview(stack)
        stack.pinEdges(to: card)
        return card
    }
}
