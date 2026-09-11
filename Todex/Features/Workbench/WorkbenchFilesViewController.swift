import TodexCore
import UIKit

@MainActor
final class WorkbenchFilesViewController: UIViewController, UITableViewDataSource, UITableViewDelegate,
    UISearchBarDelegate, UITextViewDelegate
{
    private var descriptor: WorkbenchTab
    private let http: HTTPClient
    private let workspacePath: String
    private let insertReference: @MainActor (String) -> Void
    private let update: @MainActor (WorkbenchTab) -> Void
    private let openFileTab: @MainActor (String) -> Void
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let search = UISearchBar()
    private let info = UILabel()
    private let preview = UIView()
    private let editor = UITextView()
    private let imageView = UIImageView()
    private let modes = UISegmentedControl(items: ["预览", "源码"])
    private var searchActive = false
    private var entries: [JSONValue] = []
    private var parentPath: String?
    private var directoriesOnly = false
    private var file: JSONValue?
    private var originalText: String?
    private var editingText = false
    private(set) var isSaving = false
    private var task: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var revision = UUID()
    var hasUnsavedChanges: Bool { editingText && editor.text != originalText }

    init(
        tab descriptor: WorkbenchTab, connection: BackendConnection, workspacePath: String,
        insertReference: @escaping @MainActor (String) -> Void, update: @escaping @MainActor (WorkbenchTab) -> Void,
        openFile: @escaping @MainActor (String) -> Void
    ) {
        self.descriptor = descriptor
        self.http = HTTPClient(connection: connection)
        self.workspacePath = workspacePath
        self.insertReference = insertReference
        self.update = update
        self.openFileTab = openFile
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        task?.cancel()
        saveTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .onDrag
        search.placeholder = "搜索相对路径（含隐藏文件时输入 .）"
        search.delegate = self
        search.autocapitalizationType = .none
        search.autocorrectionType = .no
        search.isHidden = true
        search.showsCancelButton = true
        info.font = .preferredFont(forTextStyle: .caption1)
        info.numberOfLines = 0
        info.textColor = .secondaryLabel
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.isEditable = false
        editor.delegate = self
        editor.autocorrectionType = .no
        editor.autocapitalizationType = .none
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.smartInsertDeleteType = .no
        editor.adjustsFontForContentSizeCategory = true
        editor.accessibilityIdentifier = "workbench.file.editor"
        info.accessibilityIdentifier = "workbench.file.status"
        imageView.contentMode = .scaleAspectFit
        imageView.isHidden = true
        preview.addSubview(editor)
        preview.addSubview(imageView)
        WBUI.pin(editor, to: preview)
        WBUI.pin(imageView, to: preview)
        modes.selectedSegmentIndex = 0
        modes.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        let back = Theme.iconButton("chevron.left")
        back.accessibilityLabel = "返回"
        back.addAction(UIAction { [weak self] _ in self?.back() }, for: .primaryActionTriggered)
        let more = Theme.iconButton("ellipsis", pointSize: 11)
        more.accessibilityLabel = "文件选项"
        more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] provide in
                provide(self?.fileMenuElements() ?? [])
            }
        ])
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [back, info, more])
        header.axis = .horizontal
        header.spacing = 6
        header.alignment = .center
        WBUI.installStack(
            in: view,
            views: [header, search, modes, table, preview])
        showFileUI(false)
        if let path = descriptor.filePath { loadFile(path) } else { loadDirectory() }
    }
    private func showFileUI(_ visible: Bool) {
        table.isHidden = visible
        preview.isHidden = !visible
        search.isHidden = visible || !searchActive
        modes.isHidden = !visible || editingText
        modes.isEnabled = !editingText
    }
    private func fileMenuElements() -> [UIMenuElement] {
        var elements: [UIMenuElement] = []
        if descriptor.filePath != nil {
            elements.append(
                UIAction(
                    title: "编辑", image: Theme.icon("pencil", pointSize: 13),
                    attributes: originalText != nil && !editingText ? [] : .disabled
                ) { [weak self] _ in self?.beginEditing() })
            elements.append(
                UIAction(
                    title: "保存", image: Theme.icon("square.and.arrow.down", pointSize: 13),
                    attributes: hasUnsavedChanges && !isSaving ? [] : .disabled
                ) { [weak self] _ in self?.saveFile() })
        } else {
            elements.append(
                UIAction(title: "搜索…", image: Theme.icon("magnifyingglass", pointSize: 13)) {
                    [weak self] _ in
                    self?.showSearch()
                })
        }
        elements.append(
            UIAction(title: "引用", image: Theme.icon("at", pointSize: 13)) {
                [weak self] _ in self?.referenceCurrent()
            })
        elements.append(
            UIMenu(
                title: "", options: .displayInline,
                children: [
                    UIAction(title: "目录浏览", image: Theme.icon("folder", pointSize: 13)) {
                        [weak self] _ in self?.chooseDirectoryMode()
                    },
                    UIAction(title: "刷新", image: Theme.icon("arrow.clockwise", pointSize: 13)) {
                        [weak self] _ in
                        guard let self else { return }
                        self.discardIfNeeded { [weak self] in
                            guard let self else { return }
                            if let path = self.descriptor.filePath {
                                self.loadFile(path)
                            } else {
                                self.loadDirectory()
                            }
                        }
                    },
                ]))
        return elements
    }
    private func showSearch() {
        searchActive = true
        search.isHidden = false
        search.becomeFirstResponder()
    }
    private func absolutePath(_ entry: JSONValue) -> String {
        let path = entry["path"].stringValue
        return path.hasPrefix("/") ? path : (descriptor.path as NSString).appendingPathComponent(path)
    }
    private func loadDirectory() {
        task?.cancel()
        revision = UUID()
        let currentRevision = revision
        file = nil
        originalText = nil
        editingText = false
        descriptor.filePath = nil
        editor.text = ""
        imageView.image = nil
        editor.isEditable = false
        entries = []
        table.reloadData()
        showFileUI(false)
        let path = descriptor.path
        let query = search.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        info.text = "正在读取 \(path)…"
        descriptor.title = (path as NSString).lastPathComponent
        update(descriptor)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                async let directory = self.http.request(
                    .get, path: "/v2/workspace/directories", query: ["path": path, "limit": "300"])
                async let listing = self.http.request(
                    .get, path: "/v2/workspace/entries", query: ["cwd": path, "query": query, "limit": "100"])
                let (dir, items) = try await (directory, listing)
                guard self.revision == currentRevision, !Task.isCancelled else { return }
                guard case .array = dir["entries"], case .array = items["entries"] else {
                    throw TodexError.invalid("目录响应缺少 entries")
                }
                self.parentPath = dir["parent"].optionalString
                self.entries = self.directoriesOnly ? dir["entries"].arrayValue : items["entries"].arrayValue
                let limit = self.directoriesOnly ? 300 : 100
                self.info.text =
                    "\(path)\n\(self.entries.count) 项" + (self.entries.count >= limit ? " · 达到后端上限，请搜索更具体的路径" : "")
                self.table.reloadData()
            } catch {
                guard self.revision == currentRevision, !Task.isCancelled else { return }
                self.info.text = "读取失败：\(error.localizedDescription)"
            }
        }
    }
    private func loadFile(_ path: String) {
        task?.cancel()
        revision = UUID()
        let currentRevision = revision
        descriptor.filePath = path
        descriptor.title = (path as NSString).lastPathComponent
        update(descriptor)
        file = nil
        originalText = nil
        editingText = false
        editor.text = ""
        editor.isEditable = false
        imageView.image = nil
        imageView.isHidden = true
        editor.isHidden = false
        showFileUI(true)
        info.text = "正在读取 \(path)…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await self.http.request(.get, path: "/v2/workspace/file", query: ["path": path])
                guard self.revision == currentRevision, !Task.isCancelled else { return }
                guard value["path"].optionalString != nil, value["mimeType"].optionalString != nil else {
                    throw TodexError.invalid("文件响应无效")
                }
                self.file = value
                self.originalText = value["text"].optionalString
                self.descriptor.filePath = value["path"].stringValue
                self.update(self.descriptor)
                self.info.text =
                    "\(value["path"].stringValue)\n\(value["mimeType"].stringValue) · \(value["sizeBytes"].intValue) bytes"
                self.renderPreview()
                self.showFileUI(true)
            } catch {
                guard self.revision == currentRevision, !Task.isCancelled else { return }
                self.info.text = "预览失败：\(error.localizedDescription)"
            }
        }
    }
    private func renderPreview() {
        guard let file else { return }
        editor.isHidden = false
        imageView.isHidden = true
        if let text = originalText {
            let ext = (file["name"].stringValue as NSString).pathExtension.lowercased()
            if ["md", "markdown"].contains(ext), modes.selectedSegmentIndex == 0 {
                do {
                    editor.attributedText = try renderedMarkdown(text)
                } catch {
                    editor.text = text
                    info.text = "Markdown 渲染失败，显示源码：\(error.localizedDescription)"
                }
            } else {
                editor.attributedText = nil
                editor.text = text
                editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            }
            editor.textColor = .label
        } else if let url = file["dataUrl"].optionalString, let comma = url.firstIndex(of: ","),
            url[..<comma].hasSuffix(";base64"), let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
            let image = UIImage(data: data)
        {
            imageView.image = image
            imageView.isHidden = false
            editor.isHidden = true
        } else {
            editor.text = "此格式没有可用的文本或原生图片预览。后端未提供可编辑文本。"
        }
    }
    private func renderedMarkdown(_ text: String) throws -> NSAttributedString {
        let parsed = try AttributedString(markdown: text, options: .init(interpretedSyntax: .full))
        let output = NSMutableAttributedString(string: "")
        var previousBlock: Int?
        var previousTableRow: Int?
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            var heading: Int?
            var listOrdinal: Int?
            var ordered = false
            var quote = false
            var code = false
            var tableRow: Int?
            for component in components {
                switch component.kind {
                case .header(let level): heading = level
                case .listItem(let ordinal): listOrdinal = ordinal
                case .orderedList: ordered = true
                case .blockQuote: quote = true
                case .codeBlock: code = true
                case .tableRow, .tableHeaderRow: tableRow = component.identity
                default: break
                }
            }
            if block != previousBlock {
                if output.length > 0 {
                    let separator =
                        tableRow != nil && tableRow == previousTableRow ? "\t" : (listOrdinal == nil ? "\n\n" : "\n")
                    output.append(NSAttributedString(string: separator))
                }
                if let listOrdinal { output.append(NSAttributedString(string: ordered ? "\(listOrdinal). " : "• ")) }
                if quote { output.append(NSAttributedString(string: "▎ ")) }
                previousBlock = block
                previousTableRow = tableRow
            }
            let intent = run.inlinePresentationIntent ?? []
            let base = UIFont.preferredFont(forTextStyle: .body)
            var font =
                code || intent.contains(.code)
                ? UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular) : base
            if let heading { font = .systemFont(ofSize: max(base.pointSize, 30 - CGFloat(heading) * 2), weight: .bold) }
            var traits = font.fontDescriptor.symbolicTraits
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                font = UIFont(descriptor: descriptor, size: font.pointSize)
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
            if code || intent.contains(.code) { attributes[.backgroundColor] = UIColor.secondarySystemBackground }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link, ["https", "http"].contains(link.scheme?.lowercased() ?? "") {
                attributes[.link] = link
            }
            output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return output
    }
    @objc private func modeChanged() {
        guard !editingText else { return }
        renderPreview()
    }
    private func beginEditing() {
        guard let originalText, !isSaving else { return }
        editingText = true
        modes.selectedSegmentIndex = 1
        editor.attributedText = nil
        editor.text = originalText
        editor.isEditable = true
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.textColor = .label
        showFileUI(true)
        editor.becomeFirstResponder()
    }
    private func saveFile() {
        guard !isSaving, hasUnsavedChanges, let path = descriptor.filePath, let expected = originalText else { return }
        let text = editor.text ?? ""
        guard text.utf8.count <= 1024 * 1024 else {
            WBUI.message(on: self, title: "文件过大", text: "文本编辑上限为 1 MiB。")
            return
        }
        isSaving = true
        editor.isEditable = false
        info.text = "保存中…"
        saveTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isSaving = false
                self.editor.isEditable = self.editingText
                self.showFileUI(true)
            }
            do {
                let result = try await self.http.request(
                    .put, path: "/v2/workspace/file",
                    body: ["path": .string(path), "text": .string(text), "expectedText": .string(expected)])
                guard result["saved"] == .bool(true) else { throw TodexError.unknownOutcome("后端没有确认文件保存") }
                self.originalText = text
                self.file?["text"] = .string(text)
                self.info.text = "已保存 · \(path)"
            } catch TodexError.server(let code, let message) where code == "CONFLICT" || code == "409" {
                self.info.text = "保存冲突 · 本地编辑已保留"
                self.offerConflict(path: path, message: message)
            } catch {
                self.info.text = "保存未确认 · 本地编辑已保留"
                WBUI.error(error, on: self)
            }
        }
    }
    private func offerConflict(path: String, message: String) {
        let alert = UIAlertController(
            title: "文件已被修改", message: message + "\n读取最新版本后可手动合并；不会覆盖远端。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "保留编辑", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "比较并合并", style: .default) { [weak self] _ in self?.mergeConflict(path: path) })
        WBUI.presentModal(alert, on: self)
    }
    private func mergeConflict(path: String) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let latest = try await self.http.request(.get, path: "/v2/workspace/file", query: ["path": path])
                guard self.descriptor.filePath == path, let remote = latest["text"].optionalString else {
                    throw TodexError.invalid("最新文件不再是可编辑文本")
                }
                let local = self.editor.text ?? ""
                let merged = "<<<<<<< 本地编辑\n\(local)\n=======\n\(remote)\n>>>>>>> 远端最新版本"
                WBUI.textSheet(
                    on: self, title: "手动合并（删除冲突标记）", text: merged, editable: true,
                    actions: [
                        (
                            "采用合并结果，稍后保存",
                            { [weak self] text in
                                guard let self, self.descriptor.filePath == path else { return }
                                guard !text.contains("<<<<<<< 本地编辑"), !text.contains(">>>>>>> 远端最新版本"),
                                    !text.components(separatedBy: "\n").contains("=======")
                                else {
                                    WBUI.message(on: self, title: "仍有冲突标记", text: "未采用该版本；原本地编辑仍保留，请再次保存并完成合并。")
                                    return
                                }
                                self.originalText = remote
                                self.editor.text = text
                                self.editingText = true
                                self.file = latest
                                self.info.text = "合并结果尚未保存；保存时仍会校验远端版本。"
                                self.showFileUI(true)
                            }
                        )
                    ])
            } catch { WBUI.error(error, on: self) }
        }
    }
    private func referenceCurrent() {
        let path = descriptor.filePath ?? descriptor.path
        if descriptor.filePath != nil, editor.selectedRange.length > 0,
            let range = Range(editor.selectedRange, in: editor.text ?? "")
        {
            let text = editor.text ?? ""
            let line = text[..<range.lowerBound].filter { $0 == "\n" }.count + 1
            let rendered =
                ["md", "markdown"].contains((path as NSString).pathExtension.lowercased())
                && modes.selectedSegmentIndex == 0 && !editingText
            let location = rendered ? " · Markdown 预览选区" : ":\(line)"
            insertReference("[文件 \(path)\(location)]\n\(String(text[range].prefix(2000)))")
        } else {
            insertReference("@\(path)")
        }
        info.text = "已插入引用到对话草稿 · \(path)"
    }
    private func discardIfNeeded(_ action: @escaping @MainActor () -> Void) {
        guard !isSaving else {
            WBUI.message(on: self, title: "保存进行中", text: "请等待后端确认。")
            return
        }
        if hasUnsavedChanges {
            WBUI.confirm(on: self, title: "放弃未保存编辑？", message: "本地编辑不会自动保存。", action: "放弃编辑", perform: action)
        } else {
            action()
        }
    }
    private func back() {
        discardIfNeeded { [weak self] in
            guard let self else { return }
            if self.descriptor.filePath != nil {
                self.descriptor.filePath = nil
                self.loadDirectory()
            } else if let parent = self.parentPath {
                self.descriptor.path = parent
                self.search.text = ""
                self.loadDirectory()
            }
        }
    }
    private func chooseDirectoryMode() {
        let sheet = UIAlertController(title: "文件浏览", message: "每次只读取当前目录；搜索可查找其子目录文件。", preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: "工作区目录（文件与文件夹）", style: .default) { [weak self] _ in
                self?.discardIfNeeded { [weak self] in
                    guard let self else { return }
                    self.descriptor.path = self.workspacePath
                    self.directoriesOnly = false
                    self.search.text = ""
                    self.loadDirectory()
                }
            })
        sheet.addAction(
            UIAlertAction(title: "仅浏览目录", style: .default) { [weak self] _ in
                self?.discardIfNeeded { [weak self] in
                    self?.directoriesOnly = true
                    self?.loadDirectory()
                }
            })
        sheet.addAction(
            UIAlertAction(title: "输入后端文件绝对路径", style: .default) { [weak self] _ in
                guard let self else { return }
                WBUI.form(on: self, title: "打开文件", fields: [("绝对路径", "")]) { [weak self] values in
                    guard let self, let path = values.first, path.hasPrefix("/") else { return }
                    self.discardIfNeeded { [weak self] in self?.loadFile(path) }
                }
            })
        WBUI.presentSheet(sheet, on: self)
    }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        directoriesOnly = false
        loadDirectory()
    }
    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        searchBar.text = ""
        searchActive = false
        search.isHidden = true
        directoriesOnly = false
        loadDirectory()
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let entry = entries[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = entry["name"].stringValue
        content.secondaryText = entry["path"].stringValue
        content.secondaryTextProperties.numberOfLines = 2
        content.image = UIImage(systemName: entry["kind"].stringValue == "directory" ? "folder" : "doc.text")
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = entries[indexPath.row]
        let path = absolutePath(entry)
        if entry["kind"].stringValue == "directory" {
            descriptor.path = path
            search.text = ""
            loadDirectory()
        } else {
            loadFile(path)
        }
    }
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint)
        -> UIContextMenuConfiguration?
    {
        let entry = entries[indexPath.row]
        let path = absolutePath(entry)
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            var actions = [
                UIAction(title: "引用路径", image: UIImage(systemName: "at")) { _ in self?.insertReference("@\(path)") }
            ]
            if entry["kind"].stringValue == "file" {
                actions.append(
                    UIAction(title: "在新标签打开", image: UIImage(systemName: "plus.square.on.square")) { _ in
                        self?.openFileTab(path)
                    })
            }
            return UIMenu(children: actions)
        })
    }
}
