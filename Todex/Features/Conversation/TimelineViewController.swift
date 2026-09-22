import SafariServices
import TodexCore
import UIKit
import WebKit

final class TimelineViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {
    private(set) var web: WKWebView!
    private var loaded = false
    private var messages: [TimelineMessage] = []
    private var provider = "TodeX"
    private var sentAttachments: [SentAttachmentRecord] = []
    private var history = (more: false, loading: false)
    var insertText: ((String) -> Void)?
    var openFile: ((String) -> Void)?
    var addReference: ((MessageAttachment) -> Void)?
    /// Fetch full process details for a folded group: (group key, fromSequence, toSequence).
    var loadActivity: ((String, Int, Int) -> Void)?
    /// Fetch the next page of older history when the scroll view nears the top.
    var loadEarlier: (() -> Void)?
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
    func update(
        _ messages: [TimelineMessage], provider: String,
        sentAttachments: [SentAttachmentRecord] = [],
        hasEarlier: Bool = false, loadingEarlier: Bool = false
    ) {
        let history = (more: hasEarlier, loading: loadingEarlier)
        guard self.messages != messages || self.provider != provider
            || self.sentAttachments != sentAttachments || self.history != history
        else { return }
        self.messages = messages
        self.provider = provider
        self.sentAttachments = sentAttachments
        self.history = history
        render()
    }
    /// Scroll the timeline so the source message of a reference is visible.
    func scrollToMessage(_ id: String) {
        let escaped = id
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        web.evaluateJavaScript(
            "document.querySelector('[data-id=\\'\(escaped)\\']')?.scrollIntoView({block:'center',behavior:'smooth'})")
    }
    /// Tell the web view a lazy process-detail load failed so it can offer a retry.
    func activityLoadFailed(_ key: String) {
        let escaped = key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        web.evaluateJavaScript("window.activityLoadFailed?.('\(escaped)')")
    }
    /// Tell the web view the earlier-history page failed so it can offer a retry.
    func historyLoadFailed() {
        web.evaluateJavaScript("window.historyLoadFailed?.()")
    }
    /// Display name for a tool call: the provider-reported name when present,
    /// the command itself for shell executions, otherwise a generic label.
    private static func toolName(of message: TimelineMessage) -> String {
        guard message.category == "tool" else { return "" }
        let detail = message.detail
        let candidates = [
            detail["toolName"], detail["tool_name"],
            detail["toolCall"]["name"], detail["tool_call"]["name"],
            detail["tool"]["name"], detail["tool"]["title"], detail["tool"],
            detail["title"], detail["name"],
            detail["item"]["name"], detail["item"]["toolName"], detail["item"]["tool_name"],
            detail["command"], detail["item"]["command"],
        ]
        return candidates.lazy.compactMap(\.optionalString).first { !$0.isEmpty } ?? "工具调用"
    }
    private func render() {
        guard loaded else { return }
        let receipts = Dictionary(
            sentAttachments.map { ($0.requestId, $0) }, uniquingKeysWith: { _, last in last })
        let values: [[String: Any]] = messages.reversed().map { message in
            var value: [String: Any] = [
                "id": message.id, "role": message.role, "category": message.category,
                "text": message.text, "status": message.status, "tool": Self.toolName(of: message),
                "stub": message.detail["detailStub"].boolValue, "sequence": message.sequence,
            ]
            if message.role == "user",
                let requestId = message.detail["clientRequestId"].optionalString
                    ?? message.detail["requestId"].optionalString,
                let record = receipts[requestId]
            {
                value["attachments"] = record.attachments.map { attachment in
                    [
                        "id": attachment.id, "kind": attachment.kind, "name": attachment.name,
                        "mimeType": attachment.mimeType, "sizeBytes": attachment.sizeBytes ?? 0,
                        "preview": attachment.preview ?? "",
                    ] as [String: Any]
                }
            }
            return value
        }
        Task { [weak self] in
            guard let self else { return }
            _ = try? await web.callAsyncJavaScript(
                "window.renderTimeline(messages, provider, fontSize, history)",
                arguments: [
                    "messages": values, "provider": provider,
                    "fontSize": UIFont.preferredFont(forTextStyle: .body).pointSize,
                    "history": ["more": history.more, "loading": history.loading],
                ], in: nil, contentWorld: .page)
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: String] else { return }
        switch body["action"] {
        case "ready":
            loaded = true
            render()
        case "loadActivity":
            guard let key = body["key"], !key.isEmpty,
                let from = Int(body["from"] ?? ""), let to = Int(body["to"] ?? ""), to >= from
            else { return }
            loadActivity?(key, from, to)
        case "loadEarlier":
            loadEarlier?()
        case "copy":
            UIPasteboard.general.string = body["text"]
            UIAccessibility.post(notification: .announcement, argument: "已复制")
        case "quote":
            let text = body["text"] ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let messageId = body["id"].flatMap { $0.isEmpty ? nil : $0 }
            addReference?(
                MessageAttachment(
                    name: "对话摘录", mimeType: "text/plain", data: Data(text.utf8),
                    reference: .init(messageId: messageId)))
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
            menu.addAction(
                UIAlertAction(title: "添加为引用", style: .default) { [weak self] _ in
                    self?.addReference?(
                        MessageAttachment(
                            name: "对话摘录", mimeType: "text/plain", data: Data(text.utf8),
                            reference: .init(messageId: body["id"].flatMap { $0.isEmpty ? nil : $0 })))
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
