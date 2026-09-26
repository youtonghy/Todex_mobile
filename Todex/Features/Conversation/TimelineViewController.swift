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
    /// Runtime usage records (newest first) for the per-reply usage summary.
    private var usage: [JSONValue] = []
    private var history = (more: false, loading: false)
    var insertText: ((String) -> Void)?
    var openFile: ((String) -> Void)?
    var addReference: ((MessageAttachment) -> Void)?
    /// Fetch full process details for a folded group: (group key, fromSequence, toSequence).
    var loadActivity: ((String, Int, Int) -> Void)?
    /// Fetch the next page of older history when the scroll view nears the top.
    var loadEarlier: (() -> Void)?
    /// Open the read-only preview of an attachment receipt on a sent message.
    var previewSentAttachment: ((SentAttachment) -> Void)?
    override func viewDidLoad() {
        super.viewDidLoad()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(WeakChatHandler(self), name: "chat")
        config.userContentController.addUserScript(ChatWebStrings.userScript())
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
        usage: [JSONValue] = [],
        hasEarlier: Bool = false, loadingEarlier: Bool = false
    ) {
        // Usage only feeds the long-press menu, so it never forces a re-render.
        self.usage = usage
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
    /// Desktop ChatTool parity: the card names the call and its key argument;
    /// arguments, output and error stay separate in the folded body.
    private static func toolInfo(of message: TimelineMessage) -> [String: Any]? {
        guard message.category == "tool" else { return nil }
        let tool = ToolPresentation.describe(message.detail, fallbackText: message.text)
        let label =
            switch tool.kind {
            case .command: String(localized: "命令")
            case .fileChange: String(localized: "文件修改")
            case .webSearch: String(localized: "网页搜索")
            case .tool: String(localized: "工具调用")
            }
        return [
            "name": tool.name.isEmpty ? label : tool.name, "summary": tool.summary, "args": tool.argsText,
            "output": tool.outputText ?? "", "error": tool.errorText ?? "", "failed": tool.status == .failed,
        ]
    }
    /// Desktop TurnUsageSummary: the turn's confirmed usage, one line per record.
    private func usageSummary(turnId: String) -> String? {
        let records = usage.filter { !turnId.isEmpty && $0["turnId"].stringValue == turnId }
        guard !records.isEmpty else { return nil }
        let value = { (record: JSONValue, key: String) in
            UsageCalculation.number(record, key).map(UsageCalculation.format) ?? String(localized: "未知")
        }
        return records.map { record in
            [
                String(localized: "模型：\(record["model"].optionalString ?? String(localized: "未报告"))"),
                String(localized: "输入 \(value(record, "inputTokens")) · 输出 \(value(record, "outputTokens"))"),
                String(localized: "缓存读取 \(value(record, "cachedInputTokens")) · 缓存写入 \(value(record, "cacheWriteTokens"))"),
                String(localized: "总计 \(UsageCalculation.total(record).map(UsageCalculation.format) ?? String(localized: "未知")) tokens"),
            ].joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
    private func render() {
        guard loaded else { return }
        let receipts = Dictionary(
            sentAttachments.map { ($0.requestId, $0) }, uniquingKeysWith: { _, last in last })
        let values: [[String: Any]] = messages.reversed().map { message in
            var value: [String: Any] = [
                "id": message.id, "role": message.role, "category": message.category,
                "text": message.text, "status": message.status,
                "stub": message.detail["detailStub"].boolValue, "sequence": message.sequence,
            ]
            if let tool = Self.toolInfo(of: message) { value["tool"] = tool }
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
        case "attachment":
            guard let message = messages.first(where: { $0.id == body["messageId"] }),
                let requestId = message.detail["clientRequestId"].optionalString
                    ?? message.detail["requestId"].optionalString,
                let attachment = sentAttachments.last(where: { $0.requestId == requestId })?.attachments
                    .first(where: { $0.id == body["attachmentId"] })
            else { return }
            previewSentAttachment?(attachment)
        case "copy":
            UIPasteboard.general.string = body["text"]
            UIAccessibility.post(notification: .announcement, argument: String(localized: "已复制"))
        case "quote":
            let text = body["text"] ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let messageId = body["id"].flatMap { $0.isEmpty ? nil : $0 }
            addReference?(
                MessageAttachment(
                    name: String(localized: "对话摘录"), mimeType: "text/plain", data: Data(text.utf8),
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
            let menu = UIAlertController(title: String(localized: "消息"), message: nil, preferredStyle: .actionSheet)
            menu.addAction(UIAlertAction(title: String(localized: "复制"), style: .default) { _ in UIPasteboard.general.string = text })
            menu.addAction(
                UIAlertAction(title: String(localized: "引用到输入框"), style: .default) { [weak self] _ in
                    self?.insertText?(
                        text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(
                            separator: "\n"))
                })
            menu.addAction(
                UIAlertAction(title: String(localized: "添加为引用"), style: .default) { [weak self] _ in
                    self?.addReference?(
                        MessageAttachment(
                            name: String(localized: "对话摘录"), mimeType: "text/plain", data: Data(text.utf8),
                            reference: .init(messageId: body["id"].flatMap { $0.isEmpty ? nil : $0 })))
                })
            let turnId = messages.first { $0.id == body["id"] }.flatMap {
                $0.category == "assistant_final" ? $0.turnId : nil
            }
            if let turnId, let summary = usageSummary(turnId: turnId) {
                menu.addAction(
                    UIAlertAction(title: String(localized: "本轮用量"), style: .default) { [weak self] _ in
                        guard let self else { return }
                        WBUI.textSheet(on: self, title: String(localized: "本轮用量"), text: summary, actions: [])
                    })
            }
            menu.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
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

/// Chat web resources (timeline.js, preview.js) keep their source text in
/// Simplified Chinese and look it up through `window.todexL10n`; this table is
/// the String Catalog entry point for those strings.
enum ChatWebStrings {
    static var table: [String: String] {
        [
            "[图片]": String(localized: "[图片]"),
            "↓ 最新消息": String(localized: "↓ 最新消息"),
            "一起把想法变成现实": String(localized: "一起把想法变成现实"),
            "你": String(localized: "你"),
            "加载更早的消息": String(localized: "加载更早的消息"),
            "加载更早的记录失败，点按重试": String(localized: "加载更早的记录失败，点按重试"),
            "加载过程记录失败，点按重试": String(localized: "加载过程记录失败，点按重试"),
            "参数": String(localized: "参数"),
            "回到最新消息": String(localized: "回到最新消息"),
            "图片": String(localized: "图片"),
            "复制": String(localized: "复制"),
            "复制代码": String(localized: "复制代码"),
            "对话记录": String(localized: "对话记录"),
            "工作过程": String(localized: "工作过程"),
            "工具活动": String(localized: "工具活动"),
            "工具调用": String(localized: "工具调用"),
            "已调用": String(localized: "已调用"),
            "思考过程": String(localized: "思考过程"),
            "把选中的内容添加到对话": String(localized: "把选中的内容添加到对话"),
            "描述你的任务，或从操作台引用文件。": String(localized: "描述你的任务，或从操作台引用文件。"),
            "文档预览": String(localized: "文档预览"),
            "正在加载更早的记录…": String(localized: "正在加载更早的记录…"),
            "正在加载过程记录…": String(localized: "正在加载过程记录…"),
            "正在工作 · ": String(localized: "正在工作 · "),
            "正在生成…": String(localized: "正在生成…"),
            "正在调用": String(localized: "正在调用"),
            "添加到对话": String(localized: "添加到对话"),
            "状态": String(localized: "状态"),
            "用量": String(localized: "用量"),
            "等待审批": String(localized: "等待审批"),
            "调用失败": String(localized: "调用失败"),
            "输出": String(localized: "输出"),
            "进度": String(localized: "进度"),
            "错误": String(localized: "错误"),
            "附件": String(localized: "附件"),
        ]
    }
    /// Injected before the page scripts run; user scripts are not subject to
    /// the pages' Content-Security-Policy.
    static func userScript() -> WKUserScript {
        let data = (try? JSONSerialization.data(withJSONObject: table)) ?? Data("{}".utf8)
        let language = Bundle.main.preferredLocalizations.first ?? "zh-Hans"
        let source =
            "window.todexL10n=\(String(decoding: data, as: UTF8.self));window.todexLang=\"\(language)\";"
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
}
