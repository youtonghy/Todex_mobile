import TodexCore
import UIKit
import WebKit

@MainActor
final class WorkbenchBrowserViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UITextFieldDelegate {
    private var descriptor: WorkbenchTab
    private let connection: BackendConnection
    private let http: HTTPClient
    private let insertReference: @MainActor (String) -> Void
    private let update: @MainActor (WorkbenchTab) -> Void
    private let address = UITextField()
    private let info = UILabel()
    private let web: WKWebView
    private var currentURL: URL?
    // Workspace HTML preview (desktop srcDoc): the file text is loaded with a nil
    // base URL, so the page has an opaque origin and cannot reach the local file
    // system or backend cookies (the data store is non-persistent). Page scripts
    // stay off by default because workspace HTML may be agent-generated; the user
    // can enable them for this tab only (never persisted).
    private var fileTask: Task<Void, Never>?
    private var fileScripts = false
    private let scriptsButton = Theme.iconButton("curlybraces")
    // Element inspect mode (desktop BrowserPane picker). The picker runs in the
    // app's own content world, isolated from page scripts, which also means it
    // works while page JavaScript is disabled.
    private var inspecting = false
    private var inspected: InspectedElement?
    private let inspectButton = Theme.iconButton("scope")
    private let inspectBar = UIStackView()
    private let inspectLabel = UILabel()
    private let parentButton = WBUI.button(String(localized: "父元素"), "arrow.up.left.square") {}
    private let referenceButton = WBUI.button(String(localized: "引用"), "text.quote") {}
    private var isFileMode: Bool { descriptor.filePath != nil && descriptor.url == nil }

    private struct InspectedElement {
        var selector: String
        var text: String
        var html: String
    }

    init(
        tab descriptor: WorkbenchTab, connection: BackendConnection,
        insertReference: @escaping @MainActor (String) -> Void,
        update: @escaping @MainActor (WorkbenchTab) -> Void
    ) {
        self.descriptor = descriptor
        self.connection = connection
        http = HTTPClient(connection: connection)
        self.insertReference = insertReference
        self.update = update
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let handler = WeakInspectHandler()
        config.userContentController.add(handler, contentWorld: .defaultClient, name: "todexInspect")
        web = WKWebView(frame: .zero, configuration: config)
        super.init(nibName: nil, bundle: nil)
        handler.target = self
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { fileTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        address.borderStyle = .roundedRect
        address.placeholder = String(localized: "http(s):// 地址或工作区 HTML 绝对路径")
        address.keyboardType = .URL
        address.autocapitalizationType = .none
        address.autocorrectionType = .no
        address.clearButtonMode = .whileEditing
        address.returnKeyType = .go
        address.delegate = self
        // Long URLs or file paths truncate instead of pushing the toolbar buttons off-screen.
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        address.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        address.text = isFileMode ? descriptor.filePath : descriptor.url ?? connection.serverURL
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (self: WorkbenchBrowserViewController, _: UITraitCollection) in
            self.web.superview?.layer.borderColor = UIColor.separator.cgColor
        }
        address.accessibilityIdentifier = "workbench.browser.address"
        web.accessibilityIdentifier = "workbench.browser.page"
        info.accessibilityIdentifier = "workbench.browser.status"
        info.numberOfLines = 0
        info.font = .preferredFont(forTextStyle: .caption1)
        info.textColor = .secondaryLabel
        info.isHidden = true
        let refresh = Theme.iconButton("arrow.clockwise")
        refresh.accessibilityLabel = String(localized: "刷新")
        refresh.addAction(UIAction { [weak self] _ in self?.submitAddress() }, for: .primaryActionTriggered)
        scriptsButton.accessibilityIdentifier = "workbench.browser.scripts"
        scriptsButton.addAction(
            UIAction { [weak self] _ in self?.toggleFileScripts() }, for: .primaryActionTriggered)
        inspectButton.accessibilityIdentifier = "workbench.browser.inspect"
        inspectButton.addAction(UIAction { [weak self] _ in self?.toggleInspect() }, for: .primaryActionTriggered)
        let addressRow = UIStackView(arrangedSubviews: [address, refresh, scriptsButton, inspectButton])
        addressRow.spacing = 6
        addressRow.alignment = .center
        inspectLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        inspectLabel.textColor = .secondaryLabel
        inspectLabel.numberOfLines = 2
        inspectLabel.lineBreakMode = .byTruncatingMiddle
        inspectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        parentButton.addAction(UIAction { [weak self] _ in self?.selectParent() }, for: .primaryActionTriggered)
        referenceButton.addAction(
            UIAction { [weak self] _ in self?.insertInspectedReference() }, for: .primaryActionTriggered)
        [inspectLabel, parentButton, referenceButton].forEach(inspectBar.addArrangedSubview)
        inspectBar.spacing = 6
        inspectBar.alignment = .center
        inspectBar.isHidden = true
        let surface = UIView()
        surface.backgroundColor = Theme.surface
        surface.layer.cornerRadius = 12
        surface.layer.cornerCurve = .continuous
        surface.layer.borderWidth = 0.5
        surface.layer.borderColor = UIColor.separator.cgColor
        surface.clipsToBounds = true
        surface.addSubview(web)
        WBUI.pin(web, to: surface)
        WBUI.installStack(in: view, views: [addressRow, info, inspectBar, surface], keyboard: true)
        renderControls()
        if isFileMode, let path = descriptor.filePath { loadFile(path) } else { navigate() }
    }
    private func setInfo(_ text: String?) {
        info.text = text
        info.isHidden = (text ?? "").isEmpty
    }
    private func renderControls() {
        scriptsButton.isHidden = !isFileMode
        scriptsButton.configuration?.baseForegroundColor = fileScripts ? Theme.accent : .secondaryLabel
        scriptsButton.accessibilityLabel = fileScripts ? String(localized: "禁用页面脚本") : String(localized: "启用页面脚本")
        inspectButton.configuration?.baseForegroundColor = inspecting ? Theme.accent : .label
        inspectButton.accessibilityLabel = inspecting ? String(localized: "退出检查") : String(localized: "选择元素")
        inspectBar.isHidden = !inspecting
        inspectLabel.text = inspected.map { $0.selector } ?? String(localized: "点按页面中的元素以选择")
        parentButton.isEnabled = inspected != nil
        referenceButton.isEnabled = inspected != nil
    }
    private func validatedURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty,
            url.user == nil, url.password == nil
        else { throw TodexError.invalid(String(localized: "请输入不含用户名密码的 HTTP 或 HTTPS 地址，或工作区 HTML 文件的绝对路径")) }
        return url
    }
    /// An absolute path previews a workspace file; anything else must be an HTTP(S) URL.
    private func submitAddress() {
        let raw = (address.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("/") {
            address.resignFirstResponder()
            loadFile(raw)
        } else {
            navigate()
        }
    }
    private func navigate() {
        do {
            let url = try validatedURL(address.text ?? "")
            address.resignFirstResponder()
            fileTask?.cancel()
            web.stopLoading()
            currentURL = url
            fileScripts = false
            descriptor.url = url.absoluteString
            descriptor.filePath = nil
            descriptor.title = url.host ?? String(localized: "网页")
            update(descriptor)
            renderControls()
            setInfo(String(localized: "正在加载 \(url.absoluteString)…"))
            web.load(URLRequest(url: url))
        } catch { WBUI.error(error, on: self) }
    }
    private func loadFile(_ path: String) {
        fileTask?.cancel()
        web.stopLoading()
        currentURL = nil
        // Script consent covers one file; another file starts with scripts off.
        if path != descriptor.filePath { fileScripts = false }
        descriptor.filePath = path
        descriptor.url = nil
        descriptor.title = (path as NSString).lastPathComponent
        update(descriptor)
        address.text = path
        renderControls()
        setInfo(String(localized: "正在读取 \(path)…"))
        fileTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await self.http.request(.get, path: "/v2/workspace/file", query: ["path": path])
                try Task.checkCancellation()
                guard let text = value["text"].optionalString else {
                    throw TodexError.invalid(String(localized: "该网页文件无法作为文本加载"))
                }
                self.setInfo(
                    self.fileScripts
                        ? String(localized: "工作区文件预览 · 已为此标签启用页面脚本；相对路径资源不会加载。")
                        : String(localized: "工作区文件预览 · 页面脚本已禁用（可点按 { } 启用）；相对路径资源不会加载。"))
                self.web.loadHTMLString(text, baseURL: nil)
            } catch {
                guard !Task.isCancelled else { return }
                self.setInfo(String(localized: "网页文件读取失败：\(error.localizedDescription)"))
            }
        }
    }
    private func toggleFileScripts() {
        guard isFileMode, let path = descriptor.filePath else { return }
        if fileScripts {
            fileScripts = false
            loadFile(path)
            return
        }
        WBUI.confirm(
            on: self, title: String(localized: "启用页面脚本？"), message: String(localized: "仅对此标签生效。工作区 HTML 可能由 Agent 生成，脚本可以从此设备发起网络请求。"),
            action: String(localized: "启用")
        ) { [weak self] in
            guard let self, self.isFileMode, let path = self.descriptor.filePath else { return }
            self.fileScripts = true
            self.loadFile(path)
        }
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submitAddress()
        return true
    }

    // MARK: Element inspect

    private func toggleInspect() {
        inspecting.toggle()
        inspected = nil
        renderControls()
        if inspecting {
            installInspector()
        } else {
            run(Self.stopInspectorScript)
        }
    }
    private func installInspector() {
        run(Self.inspectorScript) { [weak self] error in
            guard let self else { return }
            self.inspecting = false
            self.renderControls()
            self.setInfo(String(localized: "该页面禁止读取元素，无法使用检查功能：\(error.localizedDescription)"))
        }
    }
    private func selectParent() {
        run("window.__todexInspect && window.__todexInspect.parent(); true;")
    }
    /// Evaluates in the app's content world; failures are reported, never ignored.
    private func run(_ script: String, onError: (@MainActor (any Error) -> Void)? = nil) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.web.evaluateJavaScript(script, contentWorld: .defaultClient)
            } catch {
                if let onError { onError(error) } else { self.setInfo(String(localized: "检查脚本执行失败：\(error.localizedDescription)")) }
            }
        }
    }
    fileprivate func receiveInspect(_ body: Any) {
        guard inspecting, let value = body as? [String: Any] else { return }
        func field(_ key: String, limit: Int) -> String {
            String((value[key] as? String ?? "").prefix(limit))
        }
        let selector = field("selector", limit: 300)
        guard !selector.isEmpty else { return }
        inspected = InspectedElement(
            selector: selector, text: field("text", limit: 160), html: field("html", limit: 1200))
        renderControls()
    }
    /// Desktop reference shape `[网页元素 …]`, plus a bounded outerHTML excerpt.
    private func insertInspectedReference() {
        guard let element = inspected else { return }
        let source = isFileMode ? descriptor.filePath ?? "" : currentURL?.absoluteString ?? ""
        // Longer than any backtick run in the page, so the HTML cannot close it.
        let longestRun = element.html.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        // Localized like the desktop's `workbench.webElement` reference.
        var reference = String(localized: "[网页元素 \(element.selector)\(element.text.isEmpty ? "" : ": \(element.text)")]")
        if !source.isEmpty { reference += String(localized: "\n来源：\(source)") }
        if !element.html.isEmpty { reference += "\n\(fence)html\n\(element.html)\n\(fence)" }
        insertReference(reference)
    }

    // MARK: Navigation

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel, preferences)
            return
        }
        // loadHTMLString with a nil base URL commits about:blank; only the file preview may use it.
        if url.scheme?.lowercased() == "about" {
            guard isFileMode else {
                decisionHandler(.cancel, preferences)
                return
            }
            preferences.allowsContentJavaScript = fileScripts
            decisionHandler(.allow, preferences)
            return
        }
        guard (try? validatedURL(url.absoluteString)) != nil else {
            decisionHandler(.cancel, preferences)
            setInfo(String(localized: "已阻止非 HTTP(S) 页面跳转。"))
            return
        }
        decisionHandler(.allow, preferences)
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse {
            setInfo("HTTP \(response.statusCode)")
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            // A link followed from a file preview turns the tab into a normal URL tab.
            currentURL = url
            address.text = url.absoluteString
            descriptor.url = url.absoluteString
            descriptor.filePath = nil
            descriptor.title = String((webView.title ?? url.host ?? String(localized: "网页")).prefix(32))
            update(descriptor)
        } else if isFileMode, let title = webView.title, !title.isEmpty {
            descriptor.title = String(title.prefix(32))
            update(descriptor)
        }
        // Each document starts without the picker; reinstall it while inspecting.
        if inspecting { inspected = nil }
        renderControls()
        if inspecting { installInspector() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed(error) }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed(TodexError.invalid(String(localized: "网页进程已退出，请刷新"))) }
    private func failed(_ error: any Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        setInfo(String(localized: "网页加载失败：\(error.localizedDescription)"))
    }
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
            (try? validatedURL(url.absoluteString)) != nil
        {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // Tap selects via pointer events (they fire for every element on touch,
    // unlike delegated clicks); clicks are swallowed so links do not navigate
    // while inspecting. Scrolling still works because pointer events pass through.
    private static let inspectorScript = #"""
        (() => {
          if (window.__todexInspect) { return true; }
          const overlay = document.createElement('div');
          overlay.setAttribute('aria-hidden', 'true');
          Object.assign(overlay.style, {
            position: 'fixed', pointerEvents: 'none', zIndex: '2147483647', border: '2px solid #128DDB',
            background: 'rgba(18, 141, 219, 0.12)', boxSizing: 'border-box', display: 'none'
          });
          (document.body || document.documentElement).appendChild(overlay);
          let selected = null;
          let start = null;
          const place = () => {
            if (!selected || !selected.isConnected) { overlay.style.display = 'none'; return; }
            const r = selected.getBoundingClientRect();
            Object.assign(overlay.style, {
              display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px'
            });
          };
          const esc = (v) => (window.CSS && CSS.escape) ? CSS.escape(v) : String(v).replace(/[^a-zA-Z0-9_-]/g, '\\$&');
          const selectorOf = (el) => {
            const parts = [];
            let node = el;
            while (node && node.nodeType === 1 && node !== document.documentElement && parts.length < 5) {
              let part = node.tagName.toLowerCase();
              if (node.id) { parts.unshift(part + '#' + esc(node.id)); break; }
              const classes = Array.from(node.classList).slice(0, 2);
              if (classes.length) { part += '.' + classes.map(esc).join('.'); }
              const parent = node.parentElement;
              if (parent) {
                const same = Array.from(parent.children).filter((c) => c.tagName === node.tagName);
                if (same.length > 1) { part += ':nth-of-type(' + (same.indexOf(node) + 1) + ')'; }
              }
              parts.unshift(part);
              node = parent;
            }
            return parts.join(' > ');
          };
          const report = () => {
            if (!selected) { return; }
            place();
            window.webkit.messageHandlers.todexInspect.postMessage({
              selector: selectorOf(selected),
              text: (selected.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 160),
              html: (selected.outerHTML || '').slice(0, 1200)
            });
          };
          const down = (e) => { start = { x: e.clientX, y: e.clientY }; };
          const up = (e) => {
            if (!start || Math.abs(e.clientX - start.x) > 10 || Math.abs(e.clientY - start.y) > 10) { start = null; return; }
            start = null;
            const target = e.target;
            if (target && target.nodeType === 1 && target !== overlay) { selected = target; report(); }
          };
          const click = (e) => { e.preventDefault(); e.stopPropagation(); };
          const reposition = () => place();
          document.addEventListener('pointerdown', down, true);
          document.addEventListener('pointerup', up, true);
          document.addEventListener('click', click, true);
          document.addEventListener('scroll', reposition, true);
          window.addEventListener('resize', reposition);
          window.__todexInspect = {
            parent: () => {
              if (selected && selected.parentElement && selected.parentElement !== document.documentElement) {
                selected = selected.parentElement;
                report();
              }
            },
            stop: () => {
              document.removeEventListener('pointerdown', down, true);
              document.removeEventListener('pointerup', up, true);
              document.removeEventListener('click', click, true);
              document.removeEventListener('scroll', reposition, true);
              window.removeEventListener('resize', reposition);
              overlay.remove();
              delete window.__todexInspect;
            }
          };
          return true;
        })();
        """#
    private static let stopInspectorScript = "window.__todexInspect && window.__todexInspect.stop(); true;"
}

private final class WeakInspectHandler: NSObject, WKScriptMessageHandler {
    weak var target: WorkbenchBrowserViewController?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receiveInspect(message.body)
    }
}
