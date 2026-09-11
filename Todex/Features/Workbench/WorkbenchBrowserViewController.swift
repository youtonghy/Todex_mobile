import TodexCore
import UIKit
import WebKit

@MainActor
final class WorkbenchBrowserViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UITextFieldDelegate {
    private var descriptor: WorkbenchTab
    private let connection: BackendConnection
    private let update: @MainActor (WorkbenchTab) -> Void
    private let address = UITextField()
    private let info = UILabel()
    private let web: WKWebView
    private var currentURL: URL?

    init(
        tab descriptor: WorkbenchTab, connection: BackendConnection,
        update: @escaping @MainActor (WorkbenchTab) -> Void
    ) {
        self.descriptor = descriptor
        self.connection = connection
        self.update = update
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: config)
        super.init(nibName: nil, bundle: nil)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        address.borderStyle = .roundedRect
        address.placeholder = "http(s):// 此设备可达的地址"
        address.keyboardType = .URL
        address.autocapitalizationType = .none
        address.autocorrectionType = .no
        address.clearButtonMode = .whileEditing
        address.returnKeyType = .go
        address.delegate = self
        address.text = descriptor.url ?? connection.serverURL
        address.accessibilityIdentifier = "workbench.browser.address"
        web.accessibilityIdentifier = "workbench.browser.page"
        info.accessibilityIdentifier = "workbench.browser.status"
        info.numberOfLines = 0
        info.font = .preferredFont(forTextStyle: .caption1)
        info.textColor = .secondaryLabel
        info.isHidden = true
        let refresh = Theme.iconButton("arrow.clockwise")
        refresh.accessibilityLabel = "刷新"
        refresh.addAction(UIAction { [weak self] _ in self?.navigate() }, for: .primaryActionTriggered)
        let addressRow = UIStackView(arrangedSubviews: [address, refresh])
        addressRow.spacing = 6
        addressRow.alignment = .center
        let surface = UIView()
        surface.backgroundColor = Theme.surface
        surface.layer.cornerRadius = 12
        surface.layer.cornerCurve = .continuous
        surface.layer.borderWidth = 0.5
        surface.layer.borderColor = UIColor.separator.cgColor
        surface.clipsToBounds = true
        surface.addSubview(web)
        WBUI.pin(web, to: surface)
        WBUI.installStack(in: view, views: [addressRow, info, surface], keyboard: true)
        navigate()
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            web.superview?.layer.borderColor = UIColor.separator.cgColor
        }
    }
    private func setInfo(_ text: String?) {
        info.text = text
        info.isHidden = (text ?? "").isEmpty
    }
    private func validatedURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty,
            url.user == nil, url.password == nil
        else { throw TodexError.invalid("请输入不含用户名密码的 HTTP 或 HTTPS 地址") }
        return url
    }
    private func navigate() {
        do {
            let url = try validatedURL(address.text ?? "")
            address.resignFirstResponder()
            web.stopLoading()
            currentURL = url
            descriptor.url = url.absoluteString
            descriptor.title = url.host ?? "网页"
            update(descriptor)
            setInfo("正在加载 \(url.absoluteString)…")
            web.load(URLRequest(url: url))
        } catch { WBUI.error(error, on: self) }
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        navigate()
        return true
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
            (try? validatedURL(url.absoluteString)) != nil
        else {
            decisionHandler(.cancel)
            setInfo("已阻止非 HTTP(S) 页面跳转。")
            return
        }
        decisionHandler(.allow)
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
        currentURL = webView.url
        address.text = currentURL?.absoluteString
        descriptor.url = currentURL?.absoluteString
        descriptor.title = String((webView.title ?? currentURL?.host ?? "网页").prefix(32))
        update(descriptor)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed(error) }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed(TodexError.invalid("网页进程已退出，请刷新")) }
    private func failed(_ error: any Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        setInfo("网页加载失败：\(error.localizedDescription)")
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
}
