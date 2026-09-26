import TodexCore
import UIKit

@MainActor
struct SettingsRow {
    var title: String
    var detail: String = ""
    var symbol: String? = nil
    var id: String
    var color: UIColor = .label
    var enabled = true
    var checked = false
    var activity = false
    var action: (@MainActor () -> Void)? = nil
}

@MainActor
struct SettingsSection {
    var title: String
    var footer: String? = nil
    var rows: [SettingsRow]
}

@MainActor
class SettingsListController: UITableViewController {
    var sections: [SettingsSection] = []

    init(title: String) {
        super.init(style: .insetGrouped)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(title:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.keyboardDismissMode = .interactive
        tableView.backgroundColor = Theme.background
        tableView.tintColor = Theme.accent
        tableView.accessibilityIdentifier = "settings.\(String(describing: type(of: self))).list"
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = row.title
        content.secondaryText = row.detail.isEmpty ? nil : row.detail
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        content.textProperties.color = row.enabled ? row.color : .secondaryLabel
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = row.symbol.flatMap { UIImage(systemName: $0) }
        content.imageProperties.tintColor = row.enabled ? row.color : .tertiaryLabel
        content.directionalLayoutMargins.top = 16
        content.directionalLayoutMargins.bottom = 16
        cell.contentConfiguration = content
        cell.backgroundColor = Theme.surface
        cell.accessibilityIdentifier = row.id
        cell.accessoryType = row.checked ? .checkmark : (row.action == nil ? .none : .disclosureIndicator)
        if row.activity {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            spinner.accessibilityLabel = String(localized: "正在处理")
            cell.accessoryView = spinner
        }
        cell.selectionStyle = row.enabled && row.action != nil ? .default : .none
        if row.action != nil { cell.accessibilityTraits.insert(.button) }
        if !row.enabled { cell.accessibilityTraits.insert(.notEnabled) }
        if row.checked { cell.accessibilityTraits.insert(.selected) }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = sections[indexPath.section].rows[indexPath.row]
        if row.enabled { row.action?() }
    }

    func redraw() { if isViewLoaded { tableView.reloadData() } }

    func choose(
        title: String, choices: [(String, String)], selected: String, apply: @escaping @MainActor (String) -> Void
    ) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for (key, label) in choices {
            alert.addAction(
                UIAlertAction(title: key == selected ? "✓ \(label)" : label, style: .default) { _ in apply(key) })
        }
        alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.safeAreaInsets.top + 22, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        present(alert, animated: true)
    }

    func editField(
        title: String, value: String, id: String, secure: Bool = false, keyboard: UIKeyboardType = .default,
        apply: @escaping @MainActor (String) -> Void
    ) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = value
            field.isSecureTextEntry = secure
            field.keyboardType = keyboard
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.smartQuotesType = .no
            field.smartDashesType = .no
            field.accessibilityIdentifier = id
            field.accessibilityLabel = title
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "保存"), style: .default) { [weak alert] _ in
                apply(alert?.textFields?.first?.text ?? "")
            })
        present(alert, animated: true)
    }
}

/// A native, selectable text surface for complete Skill bodies, JSON parameters and results.
@MainActor
final class SettingsTextController: UIViewController {
    let textView = UITextView()
    private let initialText: String
    private let detail: String?
    private let actionTitle: String?
    private let action: (@MainActor (String) async throws -> Void)?
    private let editable: Bool
    private var task: Task<Void, Never>?
    private let message = UILabel()

    init(
        title: String, text: String, detail: String? = nil, editable: Bool = false, actionTitle: String? = nil,
        action: (@MainActor (String) async throws -> Void)? = nil
    ) {
        initialText = text
        self.detail = detail
        self.editable = editable
        self.actionTitle = actionTitle
        self.action = action
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(title:text:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        textView.text = initialText
        textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: 15, weight: .regular))
        textView.adjustsFontForContentSizeCategory = true
        textView.isEditable = editable
        textView.isSelectable = true
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.accessibilityIdentifier = "settings.text.content"
        textView.accessibilityLabel = title
        message.text = detail
        message.numberOfLines = 0
        message.font = .preferredFont(forTextStyle: .footnote)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = .secondaryLabel
        message.accessibilityIdentifier = "settings.text.status"
        let stack = UIStackView(arrangedSubviews: [message, textView])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        if let actionTitle {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: actionTitle, primaryAction: UIAction { [weak self] _ in self?.performAction() })
            navigationItem.rightBarButtonItem?.accessibilityIdentifier = "settings.text.submit"
        }
    }

    private func performAction() {
        guard task == nil, let action else { return }
        let text = textView.text ?? ""
        navigationItem.rightBarButtonItem?.isEnabled = false
        textView.isEditable = false
        message.text = String(localized: "正在处理…")
        message.textColor = .secondaryLabel
        task = Task { [weak self] in
            do {
                try await action(text)
                try Task.checkCancellation()
                self?.message.text = String(localized: "已完成")
            } catch {
                if !Task.isCancelled {
                    self?.message.text = error.localizedDescription
                    self?.message.textColor = .systemRed
                }
            }
            self?.navigationItem.rightBarButtonItem?.isEnabled = true
            self?.textView.isEditable = self?.editable ?? false
            self?.task = nil
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            task?.cancel()
            task = nil
        }
    }
}

enum SettingsResponse {
    static func array(_ value: JSONValue, key: String) throws -> [JSONValue] {
        guard case .array(let items) = value[key] else { throw TodexError.invalid(String(localized: "后端响应缺少 \(key) 数组，请检查后端版本")) }
        return items
    }

    static func errorMessage(_ error: any Error, feature: String) -> String {
        if case TodexError.server(let code, _) = error,
            ["404", "405", "501", "NOT_FOUND", "UNSUPPORTED"].contains(code.uppercased())
        {
            return String(localized: "此后端不支持\(feature)，请更新后端后重试。")
        }
        return error.localizedDescription
    }
}
