import SafariServices
import TodexCore
import UIKit
import WebKit

final class TimelineViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {
    private(set) var web: WKWebView!
    private var loaded = false
    private var messages: [TimelineMessage] = []
    private var provider = "TodeX"
    var insertText: ((String) -> Void)?
    var openFile: ((String) -> Void)?
    override func viewDidLoad() {
        super.viewDidLoad()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(WeakChatHandler(self), name: "chat")
        web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = Theme.background
        web.scrollView.backgroundColor = Theme.background
        web.scrollView.keyboardDismissMode = .interactive
        web.navigationDelegate = self
        web.accessibilityIdentifier = "chat.timeline"
        view.addSubview(web)
        web.pinEdges(to: view)
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Chat") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (self: TimelineViewController, _: UITraitCollection) in self.render()
        }
    }
    func update(_ messages: [TimelineMessage], provider: String) {
        guard self.messages != messages || self.provider != provider else { return }
        self.messages = messages
        self.provider = provider
        render()
    }
    private func render() {
        guard loaded else { return }
        let values: [[String: Any]] = messages.reversed().map {
            ["id": $0.id, "role": $0.role, "category": $0.category, "text": $0.text, "status": $0.status]
        }
        Task { [weak self] in
            guard let self else { return }
            _ = try? await web.callAsyncJavaScript(
                "window.renderTimeline(messages, provider, fontSize)",
                arguments: [
                    "messages": values, "provider": provider,
                    "fontSize": UIFont.preferredFont(forTextStyle: .body).pointSize,
                ], in: nil, contentWorld: .page)
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: String] else { return }
        switch body["action"] {
        case "ready":
            loaded = true
            render()
        case "copy":
            UIPasteboard.general.string = body["text"]
            UIAccessibility.post(notification: .announcement, argument: "已复制")
        case "link":
            guard let raw = body["url"] else { return }
            if raw.hasPrefix("/") || raw.hasPrefix("./") {
                let path = (raw.removingPercentEncoding ?? raw).replacingOccurrences(
                    of: #":\d+(?::\d+)?$|#L\d+$"#, with: "", options: .regularExpression)
                openFile?(path)
                return
            }
            guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            present(SFSafariViewController(url: url), animated: true)
        case "message":
            let text = body["text"] ?? ""
            let menu = UIAlertController(title: "消息", message: nil, preferredStyle: .actionSheet)
            menu.addAction(UIAlertAction(title: "复制", style: .default) { _ in UIPasteboard.general.string = text })
            menu.addAction(
                UIAlertAction(title: "引用到输入框", style: .default) { [weak self] _ in
                    self?.insertText?(
                        text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(
                            separator: "\n"))
                })
            menu.addAction(UIAlertAction(title: "取消", style: .cancel))
            menu.popoverPresentationController?.sourceView = view
            menu.popoverPresentationController?.sourceRect = CGRect(
                x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            present(menu, animated: true)
        default: break
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy
    {
        navigationAction.request.url?.isFileURL == true ? .allow : .cancel
    }
}

private final class WeakChatHandler: NSObject, WKScriptMessageHandler {
    weak var target: TimelineViewController?
    init(_ target: TimelineViewController) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
