import TodexCore
import UIKit

final class DirectoryPicker: UITableViewController {
    private let http: HTTPClient
    private var current = ""
    private var root = ""
    private var roots: [String] = []
    private var parentPath: String?
    private var entries: [JSONValue] = []
    private let choose: (String) -> Void
    private var showsRoots: Bool { roots.count > 1 }
    private var parentSection: Int { showsRoots ? 1 : 0 }
    init(connection: BackendConnection, choose: @escaping (String) -> Void) {
        http = HTTPClient(connection: connection)
        self.choose = choose
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "选择后端目录"
        view.backgroundColor = Theme.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "选择",
            primaryAction: UIAction { [weak self] _ in
                guard let self, !current.isEmpty else { return }
                dismiss(animated: true) { self.choose(self.current) }
            })
        navigationItem.rightBarButtonItem?.isEnabled = false
        Task { await load(nil) }
    }
    private func load(_ path: String?) async {
        do {
            let result = try await http.request(
                path: "/v2/workspace/directories", query: path.map { ["path": $0] } ?? [:])
            current = result["current"].stringValue
            root = result["root"].stringValue
            roots = result["roots"].arrayValue.map(\.stringValue).filter { !$0.isEmpty }
            parentPath = result["parent"].optionalString
            entries = result["entries"].arrayValue
            navigationItem.rightBarButtonItem?.isEnabled = !current.isEmpty
            tableView.reloadData()
        } catch { showError(error) }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { showsRoots ? 3 : 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if showsRoots && section == 0 { return roots.count }
        return section == parentSection ? (parentPath == nil ? 0 : 1) : entries.count
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if showsRoots && section == 0 { return "根目录" }
        return section == parentSection ? current : "文件夹"
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var config = cell.defaultContentConfiguration()
        if showsRoots && indexPath.section == 0 {
            config.text = roots[indexPath.row]
            config.image = Theme.icon("folder")
            cell.accessoryType = roots[indexPath.row] == root ? .checkmark : .disclosureIndicator
        } else {
            config.text = indexPath.section == parentSection ? "上级目录" : entries[indexPath.row]["name"].stringValue
            config.image = Theme.icon(indexPath.section == parentSection ? "arrow.turn.up.left" : "folder")
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = config
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let path: String?
        if showsRoots && indexPath.section == 0 {
            path = roots[indexPath.row]
        } else {
            path = indexPath.section == parentSection ? parentPath : entries[indexPath.row]["path"].optionalString
        }
        if let path, path != current { Task { await load(path) } }
    }
}
