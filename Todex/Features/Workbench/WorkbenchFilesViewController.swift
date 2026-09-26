import SafariServices
import TodexCore
import UIKit
import WebKit

@MainActor
final class WorkbenchFilesViewController: UIViewController, UITableViewDataSource, UITableViewDelegate,
    UISearchBarDelegate, UITextViewDelegate, WKScriptMessageHandler, WKNavigationDelegate
{
    private var descriptor: WorkbenchTab
    private let http: HTTPClient
    private let workspacePath: String
    private let insertReference: @MainActor (String) -> Void
    private let addReference: @MainActor (MessageAttachment) -> Void
    private let update: @MainActor (WorkbenchTab) -> Void
    private let openFileTab: @MainActor (String) -> Void
    private let openInBrowser: @MainActor (String) -> Void
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let search = UISearchBar()
    private let info = UILabel()
    private let preview = UIView()
    private let editor = UITextView()
    private let imageView = UIImageView()
    private var markdownView: WKWebView?
    private var markdownLoaded = false
    private var markdownPending: String?
    private let modes = UISegmentedControl(items: [String(localized: "预览"), String(localized: "源码")])
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
    private var highlightTask: Task<Void, Never>?
    private var revision = UUID()
    var hasUnsavedChanges: Bool { editingText && editor.text != originalText }

    init(
        tab descriptor: WorkbenchTab, connection: BackendConnection, workspacePath: String,
        insertReference: @escaping @MainActor (String) -> Void,
        addReference: @escaping @MainActor (MessageAttachment) -> Void,
        update: @escaping @MainActor (WorkbenchTab) -> Void,
        openFile: @escaping @MainActor (String) -> Void,
        openInBrowser: @escaping @MainActor (String) -> Void
    ) {
        self.descriptor = descriptor
        self.http = HTTPClient(connection: connection)
        self.workspacePath = workspacePath
        self.insertReference = insertReference
        self.addReference = addReference
        self.update = update
        self.openFileTab = openFile
        self.openInBrowser = openInBrowser
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        task?.cancel()
        saveTask?.cancel()
        highlightTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .onDrag
        search.placeholder = String(localized: "搜索相对路径（含隐藏文件时输入 .）")
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
        back.accessibilityLabel = String(localized: "返回")
        back.addAction(UIAction { [weak self] _ in self?.back() }, for: .primaryActionTriggered)
        let more = Theme.iconButton("ellipsis", pointSize: 11)
        more.accessibilityLabel = String(localized: "文件选项")
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
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (self: WorkbenchFilesViewController, _: UITraitCollection) in
            guard let text = self.originalText, self.markdownView?.isHidden == false else { return }
            self.renderMarkdown(text)
        }
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
                    title: String(localized: "编辑"), image: Theme.icon("pencil", pointSize: 13),
                    attributes: originalText != nil && !editingText ? [] : .disabled
                ) { [weak self] _ in self?.beginEditing() })
            elements.append(
                UIAction(
                    title: String(localized: "保存"), image: Theme.icon("square.and.arrow.down", pointSize: 13),
                    attributes: hasUnsavedChanges && !isSaving ? [] : .disabled
                ) { [weak self] _ in self?.saveFile() })
        } else {
            elements.append(
                UIAction(title: String(localized: "搜索…"), image: Theme.icon("magnifyingglass", pointSize: 13)) {
                    [weak self] _ in
                    self?.showSearch()
                })
        }
        if let path = descriptor.filePath, Self.isWebPage(path) {
            elements.append(
                UIAction(title: String(localized: "在网页中预览"), image: Theme.icon("globe", pointSize: 13)) {
                    [weak self] _ in self?.openInBrowser(path)
                })
        }
        elements.append(
            UIAction(title: String(localized: "引用"), image: Theme.icon("at", pointSize: 13)) {
                [weak self] _ in self?.referenceCurrent()
            })
        elements.append(
            UIMenu(
                title: "", options: .displayInline,
                children: [
                    UIAction(title: String(localized: "目录浏览"), image: Theme.icon("folder", pointSize: 13)) {
                        [weak self] _ in self?.chooseDirectoryMode()
                    },
                    UIAction(title: String(localized: "刷新"), image: Theme.icon("arrow.clockwise", pointSize: 13)) {
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
    /// Desktop routes these workspace files to a browser tab (helpers.ts browser-file).
    private static func isWebPage(_ path: String) -> Bool {
        ["html", "htm", "xhtml"].contains((path as NSString).pathExtension.lowercased())
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
        highlightTask?.cancel()
        revision = UUID()
        let currentRevision = revision
        file = nil
        originalText = nil
        editingText = false
        descriptor.filePath = nil
        editor.text = ""
        imageView.image = nil
        markdownView?.isHidden = true
        markdownPending = nil
        editor.isEditable = false
        entries = []
        table.reloadData()
        showFileUI(false)
        let path = descriptor.path
        let query = search.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        info.text = String(localized: "正在读取 \(path)…")
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
                    throw TodexError.invalid(String(localized: "目录响应缺少 entries"))
                }
                self.parentPath = dir["parent"].optionalString
                self.entries = self.directoriesOnly ? dir["entries"].arrayValue : items["entries"].arrayValue
                let limit = self.directoriesOnly ? 300 : 100
                self.info.text =
                    String(localized: "\(path)\n\(self.entries.count) 项") + (self.entries.count >= limit ? String(localized: " · 达到后端上限，请搜索更具体的路径") : "")
                self.table.reloadData()
            } catch {
                guard self.revision == currentRevision, !Task.isCancelled else { return }
                self.info.text = String(localized: "读取失败：\(error.localizedDescription)")
            }
        }
    }
    private func loadFile(_ path: String) {
        task?.cancel()
        highlightTask?.cancel()
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
        markdownView?.isHidden = true
        markdownPending = nil
        editor.isHidden = false
        showFileUI(true)
        info.text = String(localized: "正在读取 \(path)…")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await self.http.request(.get, path: "/v2/workspace/file", query: ["path": path])
                guard self.revision == currentRevision, !Task.isCancelled else { return }
                guard value["path"].optionalString != nil, value["mimeType"].optionalString != nil else {
                    throw TodexError.invalid(String(localized: "文件响应无效"))
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
                self.info.text = String(localized: "预览失败：\(error.localizedDescription)")
            }
        }
    }
    private func renderPreview() {
        guard let file else { return }
        highlightTask?.cancel()
        editor.isHidden = false
        imageView.isHidden = true
        markdownView?.isHidden = true
        if let text = originalText {
            let ext = (file["name"].stringValue as NSString).pathExtension.lowercased()
            if ["md", "markdown"].contains(ext), modes.selectedSegmentIndex == 0 {
                editor.isHidden = true
                showMarkdown(text)
            } else if modes.selectedSegmentIndex == 0 {
                renderHighlightedSource(text: text, name: file["name"].stringValue)
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
            editor.text = String(localized: "此格式没有可用的文本或原生图片预览。后端未提供可编辑文本。")
        }
    }
    /// Preview mode shows plain text first, then swaps in the highlighted
    /// rendering once JavaScriptCore finishes. Stale results are dropped via
    /// the revision/mode guards.
    private func renderHighlightedSource(text: String, name: String) {
        editor.attributedText = nil
        editor.text = text
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        guard text.utf8.count <= CodeHighlighter.byteLimit else { return }
        let currentRevision = revision
        highlightTask = Task { [weak self] in
            guard let self else { return }
            let highlighted = await CodeHighlighter.shared.highlight(text, fileName: name)
            guard let highlighted, !Task.isCancelled, self.revision == currentRevision,
                !self.editingText, self.modes.selectedSegmentIndex == 0
            else { return }
            self.editor.attributedText = highlighted
        }
    }
    /// Markdown preview renders in a bundled WKWebView (markdown-it + KaTeX +
    /// highlight.js, same resources as the conversation timeline) so code blocks
    /// scroll horizontally instead of wrapping, tables and math render, and the
    /// result matches the desktop document preview.
    private func showMarkdown(_ text: String) {
        if markdownView == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.userContentController.add(WeakMarkdownHandler(self), name: "chat")
            config.userContentController.addUserScript(ChatWebStrings.userScript())
            let web = WKWebView(frame: .zero, configuration: config)
            web.isOpaque = false
            web.backgroundColor = Theme.background
            web.scrollView.backgroundColor = Theme.background
            web.navigationDelegate = self
            web.accessibilityIdentifier = "workbench.file.markdown"
            preview.addSubview(web)
            WBUI.pin(web, to: preview)
            if let url = Bundle.main.url(forResource: "preview", withExtension: "html", subdirectory: "Chat") {
                web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
            markdownView = web
        }
        markdownView?.isHidden = false
        guard markdownLoaded else {
            markdownPending = text
            return
        }
        renderMarkdown(text)
    }
    private func renderMarkdown(_ text: String) {
        Task { [weak self] in
            guard let self, let web = self.markdownView else { return }
            _ = try? await web.callAsyncJavaScript(
                "window.renderDocument(text, fontSize)",
                arguments: [
                    "text": text,
                    "fontSize": UIFont.preferredFont(forTextStyle: .body).pointSize,
                ], in: nil, contentWorld: .page)
        }
    }
    /// Relative markdown links resolve against the current file's directory and
    /// open as a workbench file tab; http(s) links open in Safari.
    private func openMarkdownLink(_ raw: String) {
        let cleaned = raw.replacingOccurrences(of: "#.*$", with: "", options: .regularExpression)
        guard !cleaned.isEmpty else { return }
        if let scheme = URL(string: cleaned)?.scheme?.lowercased(), scheme != "file" {
            if ["http", "https"].contains(scheme), let url = URL(string: cleaned) {
                present(SFSafariViewController(url: url), animated: true)
            }
            return
        }
        guard let current = descriptor.filePath else { return }
        let decoded = cleaned.removingPercentEncoding ?? cleaned
        let base = (current as NSString).deletingLastPathComponent
        let resolved =
            decoded.hasPrefix("/")
            ? (decoded as NSString).standardizingPath
            : ((base as NSString).appendingPathComponent(decoded) as NSString).standardizingPath
        openFileTab(resolved)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: String] else { return }
        switch body["action"] {
        case "ready":
            markdownLoaded = true
            if let pending = markdownPending {
                markdownPending = nil
                renderMarkdown(pending)
            }
        case "copy":
            UIPasteboard.general.string = body["text"]
            UIAccessibility.post(notification: .announcement, argument: String(localized: "已复制"))
        case "link":
            openMarkdownLink(body["url"] ?? "")
        default: break
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy
    {
        navigationAction.request.url?.isFileURL == true ? .allow : .cancel
    }
    @objc private func modeChanged() {
        guard !editingText else { return }
        renderPreview()
    }
    private func beginEditing() {
        guard let originalText, !isSaving else { return }
        highlightTask?.cancel()
        editingText = true
        modes.selectedSegmentIndex = 1
        markdownView?.isHidden = true
        editor.isHidden = false
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
            WBUI.message(on: self, title: String(localized: "文件过大"), text: String(localized: "文本编辑上限为 1 MiB。"))
            return
        }
        isSaving = true
        editor.isEditable = false
        info.text = String(localized: "保存中…")
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
                guard result["saved"] == .bool(true) else { throw TodexError.unknownOutcome(String(localized: "后端没有确认文件保存")) }
                self.originalText = text
                self.file?["text"] = .string(text)
                self.info.text = String(localized: "已保存 · \(path)")
            } catch TodexError.server(let code, let message) where code == "CONFLICT" || code == "409" {
                self.info.text = String(localized: "保存冲突 · 本地编辑已保留")
                self.offerConflict(path: path, message: message)
            } catch {
                self.info.text = String(localized: "保存未确认 · 本地编辑已保留")
                WBUI.error(error, on: self)
            }
        }
    }
    private func offerConflict(path: String, message: String) {
        let alert = UIAlertController(
            title: String(localized: "文件已被修改"), message: message + String(localized: "\n读取最新版本后可手动合并；不会覆盖远端。"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "保留编辑"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "比较并合并"), style: .default) { [weak self] _ in self?.mergeConflict(path: path) })
        WBUI.presentModal(alert, on: self)
    }
    private func mergeConflict(path: String) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let latest = try await self.http.request(.get, path: "/v2/workspace/file", query: ["path": path])
                guard self.descriptor.filePath == path, let remote = latest["text"].optionalString else {
                    throw TodexError.invalid(String(localized: "最新文件不再是可编辑文本"))
                }
                let local = self.editor.text ?? ""
                let merged = "<<<<<<< 本地编辑\n\(local)\n=======\n\(remote)\n>>>>>>> 远端最新版本"
                WBUI.textSheet(
                    on: self, title: String(localized: "手动合并（删除冲突标记）"), text: merged, editable: true,
                    actions: [
                        (
                            String(localized: "采用合并结果，稍后保存"),
                            { @MainActor [weak self] text in
                                guard let self, self.descriptor.filePath == path else { return }
                                guard !text.contains("<<<<<<< 本地编辑"), !text.contains(">>>>>>> 远端最新版本"),
                                    !text.components(separatedBy: "\n").contains("=======")
                                else {
                                    WBUI.message(on: self, title: String(localized: "仍有冲突标记"), text: String(localized: "未采用该版本；原本地编辑仍保留，请再次保存并完成合并。"))
                                    return
                                }
                                self.originalText = remote
                                self.editor.text = text
                                self.editingText = true
                                self.file = latest
                                self.info.text = String(localized: "合并结果尚未保存；保存时仍会校验远端版本。")
                                self.showFileUI(true)
                            }
                        )
                    ])
            } catch { WBUI.error(error, on: self) }
        }
    }
    private func referenceCurrent() {
        let path = descriptor.filePath ?? descriptor.path
        if descriptor.filePath != nil, editor.selectedRange.length > 0 {
            addSelectionReference(editor.selectedRange)
        } else {
            insertReference("@\(path)")
            info.text = String(localized: "已插入引用到对话草稿 · \(path)")
        }
    }
    private func addSelectionReference(_ selectedRange: NSRange) {
        let path = descriptor.filePath ?? descriptor.path
        guard descriptor.filePath != nil, selectedRange.length > 0,
            let range = Range(selectedRange, in: editor.text ?? "")
        else { return }
        let text = editor.text ?? ""
        let excerpt = String(text[range].prefix(2000))
        let rendered =
            ["md", "markdown"].contains((path as NSString).pathExtension.lowercased())
            && modes.selectedSegmentIndex == 0 && !editingText
        var reference = MessageAttachment.Reference(path: path)
        if !rendered {
            reference.lineStart = text[..<range.lowerBound].filter { $0 == "\n" }.count + 1
            reference.lineEnd = text[..<range.upperBound].filter { $0 == "\n" }.count + 1
        }
        let baseName = (path as NSString).lastPathComponent
        let name =
            reference.lineStart.map {
                "\(baseName):\($0)\(reference.lineEnd != $0 ? "-\(reference.lineEnd ?? $0)" : "")"
            } ?? String(localized: "\(baseName) 摘录")
        addReference(
            MessageAttachment(name: name, mimeType: "text/plain", data: Data(excerpt.utf8), reference: reference))
        editor.selectedRange = NSRange(location: selectedRange.location, length: 0)
        info.text = String(localized: "已添加引用到对话")
    }
    func textView(
        _ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard textView === editor, descriptor.filePath != nil, range.length > 0 else { return nil }
        let add = UIAction(title: String(localized: "添加到对话"), image: Theme.icon("text.quote", pointSize: 13)) {
            [weak self] _ in
            self?.addSelectionReference(range)
        }
        return UIMenu(children: suggestedActions + [add])
    }
    private func discardIfNeeded(_ action: @escaping @MainActor () -> Void) {
        guard !isSaving else {
            WBUI.message(on: self, title: String(localized: "保存进行中"), text: String(localized: "请等待后端确认。"))
            return
        }
        if hasUnsavedChanges {
            WBUI.confirm(on: self, title: String(localized: "放弃未保存编辑？"), message: String(localized: "本地编辑不会自动保存。"), action: String(localized: "放弃编辑"), perform: action)
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
        let sheet = UIAlertController(title: String(localized: "文件浏览"), message: String(localized: "每次只读取当前目录；搜索可查找其子目录文件。"), preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: String(localized: "工作区目录（文件与文件夹）"), style: .default) { [weak self] _ in
                self?.discardIfNeeded { [weak self] in
                    guard let self else { return }
                    self.descriptor.path = self.workspacePath
                    self.directoriesOnly = false
                    self.search.text = ""
                    self.loadDirectory()
                }
            })
        sheet.addAction(
            UIAlertAction(title: String(localized: "仅浏览目录"), style: .default) { [weak self] _ in
                self?.discardIfNeeded { [weak self] in
                    self?.directoriesOnly = true
                    self?.loadDirectory()
                }
            })
        sheet.addAction(
            UIAlertAction(title: String(localized: "输入后端文件绝对路径"), style: .default) { [weak self] _ in
                guard let self else { return }
                WBUI.form(on: self, title: String(localized: "打开文件"), fields: [(String(localized: "绝对路径"), "")]) { [weak self] values in
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
                UIAction(title: String(localized: "引用路径"), image: UIImage(systemName: "at")) { _ in self?.insertReference("@\(path)") }
            ]
            if entry["kind"].stringValue == "file" {
                actions.append(
                    UIAction(title: String(localized: "在新标签打开"), image: UIImage(systemName: "plus.square.on.square")) { _ in
                        self?.openFileTab(path)
                    })
                if Self.isWebPage(path) {
                    actions.append(
                        UIAction(title: String(localized: "在网页中预览"), image: UIImage(systemName: "globe")) { _ in
                            self?.openInBrowser(path)
                        })
                }
            }
            return UIMenu(children: actions)
        })
    }
}

private final class WeakMarkdownHandler: NSObject, WKScriptMessageHandler {
    weak var target: WorkbenchFilesViewController?
    init(_ target: WorkbenchFilesViewController) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
