import TodexCore
import UIKit

/// Desktop-parity vertical kanban: one tinted column per workspace, task cards
/// grouped by status inside the column. Columns scroll horizontally; each
/// column scrolls vertically on its own. All mutations go through Handlers
/// supplied by the host so session/persistence logic stays in HomeViewController.
final class TaskBoardView: UIView {
    struct Handlers {
        var open: (KanbanTask) -> Void
        var enterWorkspace: (WorkspaceRecord) -> Void
        var addTask: (WorkspaceRecord) -> Void
        var statusMenu: (KanbanTask) -> UIMenu
        var attachMenu: (KanbanTask, WorkspaceRecord) -> UIMenuElement
        var moreMenu: (KanbanTask, WorkspaceRecord) -> UIMenu
        var linkedTitle: (KanbanTask) -> String?
    }
    var handlers: Handlers?

    private let scroll = UIScrollView()
    private let columns = UIStackView()
    // Mirror the desktop column palette: accent, warning, danger, success.
    private static let palette: [UIColor] = [Theme.accent, .systemOrange, .systemRed, .systemGreen]

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        columns.axis = .horizontal
        columns.spacing = 12
        // .fill stretches each column to the board height so the per-column
        // task list scroll view actually receives space; .top collapsed it.
        columns.alignment = .fill
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
        columns.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, workspace) in workspaces.enumerated() {
            columns.addArrangedSubview(
                column(workspace, tint: Self.palette[index % Self.palette.count], tasks: tasksFor(workspace)))
        }
    }

    private func column(_ workspace: WorkspaceRecord, tint: UIColor, tasks: [KanbanTask]) -> UIView {
        let card = UIView()
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
        enter.accessibilityLabel = "进入 \(workspace.name)"
        enter.addAction(
            UIAction { [weak self] _ in self?.handlers?.enterWorkspace(workspace) }, for: .touchUpInside)
        enter.widthAnchor.constraint(equalToConstant: 36).isActive = true
        enter.heightAnchor.constraint(equalToConstant: 36).isActive = true
        header.addArrangedSubview(pill)
        header.addArrangedSubview(count)
        header.addArrangedSubview(UIView())
        header.addArrangedSubview(enter)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 8
        list.isLayoutMarginsRelativeArrangement = true
        list.directionalLayoutMargins = .init(top: 4, leading: 12, bottom: 4, trailing: 12)
        if tasks.isEmpty {
            let empty = Theme.label("暂无任务，点击下方新建", style: .caption1, color: .secondaryLabel)
            empty.textAlignment = .center
            list.addArrangedSubview(empty)
            empty.translatesAutoresizingMaskIntoConstraints = false
            empty.heightAnchor.constraint(equalToConstant: 48).isActive = true
        } else {
            for status in KanbanTask.Status.allCases {
                let items = tasks.filter { $0.status == status }
                guard !items.isEmpty else { continue }
                list.addArrangedSubview(
                    Theme.label("\(status.label) · \(items.count)", style: .caption1, color: .secondaryLabel))
                for task in items { list.addArrangedSubview(taskCard(task, workspace: workspace)) }
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

        var createConfig = UIButton.Configuration.plain()
        createConfig.title = "新建任务"
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
        create.accessibilityLabel = "新建任务 \(workspace.name)"
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

        if let linked = handlers?.linkedTitle(task) {
            let link = UIButton(type: .system)
            var config = UIButton.Configuration.plain()
            config.title = linked.isEmpty ? "对话已失效" : linked
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
            body.addArrangedSubview(link)
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
        chip.accessibilityLabel = "任务状态：\(task.status.label)"

        let pin = UIButton(type: .system)
        pin.setImage(Theme.icon("pin", pointSize: 12), for: .normal)
        pin.tintColor = .secondaryLabel
        pin.menu = (handlers?.attachMenu(task, workspace)).map { UIMenu(children: [$0]) }
        pin.showsMenuAsPrimaryAction = true
        pin.accessibilityLabel = "贴到对话"
        pin.widthAnchor.constraint(equalToConstant: 32).isActive = true
        pin.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let more = UIButton(type: .system)
        more.setImage(Theme.icon("ellipsis", pointSize: 12), for: .normal)
        more.tintColor = .secondaryLabel
        more.menu = handlers?.moreMenu(task, workspace)
        more.showsMenuAsPrimaryAction = true
        more.accessibilityLabel = "任务操作"
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
