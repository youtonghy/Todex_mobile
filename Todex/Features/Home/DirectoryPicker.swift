import TodexCore
import UIKit

final class DirectoryPicker: UITableViewController {
    private let http: HTTPClient
    private var current = ""
    private var root = ""
    private var parentPath: String?
    private var entries: [JSONValue] = []
    private let choose: (String) -> Void
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
            parentPath = result["parent"].optionalString
            entries = result["entries"].arrayValue
            navigationItem.rightBarButtonItem?.isEnabled = !current.isEmpty
            tableView.reloadData()
        } catch { showError(error) }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? (parentPath == nil ? 0 : 1) : entries.count
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? current : "文件夹"
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var config = cell.defaultContentConfiguration()
        config.text = indexPath.section == 0 ? "上级目录" : entries[indexPath.row]["name"].stringValue
        config.image = Theme.icon(indexPath.section == 0 ? "arrow.turn.up.left" : "folder")
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let path = indexPath.section == 0 ? parentPath : entries[indexPath.row]["path"].optionalString
        if let path { Task { await load(path) } }
    }
}
