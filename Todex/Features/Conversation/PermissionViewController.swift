import SafariServices
import TodexCore
import UIKit

@MainActor
final class PermissionViewController: UIViewController, UITextViewDelegate {
    private let session: AppSession
    private let conversationId: String
    private let permission: PendingPermission
    private let requestKey: RequestKey
    private let form: PermissionForm
    private let options: [PermissionOption]
    private var observer: UUID?
    private var invalidation: String?
    private var inputs: [PermissionInputView] = []
    private var actionButtons: [(PermissionOption, UIButton)] = []
    private var feedback: UITextView?
    private var openURLButton: UIButton?
    private var closeButton: UIButton?
    private var previousViewportSize = CGSize.zero
    private let scrollView = UIScrollView()
    private let content = UIStackView()
    private let statusLabel = Theme.label("", style: .callout, color: .secondaryLabel)
    private let errorLabel = Theme.label("", style: .callout, color: .systemRed)

    // Keep uncertain/in-flight responses locked even if this sheet is closed and reopened.
    // The session owns transport; a sheet's lifetime must not decide whether a write is retried.
    private struct RequestKey: Hashable {
        let session: ObjectIdentifier
        let backend: String?
        let conversation: String
        let permissionId: String
        let turnId: String
        let payload: JSONValue
    }

    private enum SubmissionState {
        case sending
        case unknown(String)
        case completed
    }

    private final class Submission {
        weak var session: AppSession?
        var state: SubmissionState = .sending
        init(session: AppSession) { self.session = session }
    }

    private static var submissions: [RequestKey: Submission] = [:]

    init(session: AppSession, conversationId: String, permission: PendingPermission) {
        self.session = session
        self.conversationId = conversationId
        self.permission = permission
        requestKey = RequestKey(
            session: ObjectIdentifier(session), backend: session.selectedID,
            conversation: conversationId, permissionId: permission.id,
            turnId: permission.turnId, payload: permission.payload)
        form = PermissionForm(permission.payload)
        options = PermissionOption.advertised(in: permission.payload)
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "审批请求")
        modalPresentationStyle = .pageSheet
        Self.pruneSubmissions()
    }

    required init?(coder: NSCoder) { return nil }

    isolated deinit {
        if let observer { session.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        view.tintColor = Theme.accent
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "完成"), style: .prominent,
            target: self, action: #selector(done))
        sheetPresentationController?.detents = [.large()]
        sheetPresentationController?.prefersGrabberVisible = true
        configureLayout()
        buildContent()
        observeSession()
        updateAvailability()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        observeSession()
        updateAvailability()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent {
            stopObserving()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard previousViewportSize != scrollView.bounds.size else { return }
        previousViewportSize = scrollView.bounds.size
        if let editingView = inputs.lazy.compactMap(\.editingView).first {
            PermissionInputView.reveal(editingView)
        } else if let feedback, feedback.isFirstResponder {
            PermissionInputView.reveal(feedback)
        }
    }

    func textViewDidBeginEditing(_ textView: UITextView) { PermissionInputView.reveal(textView) }

    func textViewDidChange(_ textView: UITextView) {
        textView.invalidateIntrinsicContentSize()
        PermissionInputView.reveal(textView)
    }

    private func configureLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        scrollView.accessibilityIdentifier = "permission.form"
        view.addSubview(scrollView)
        content.axis = .vertical
        content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(content)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40),
        ])
    }

    private func buildContent() {
        let payload = permission.payload
        let heading = Theme.label(payload["title"].optionalString ?? String(localized: "需要你确认"), style: .title2)
        heading.accessibilityTraits.insert(.header)
        content.addArrangedSubview(heading)
        addDetails(payload["details"])

        statusLabel.accessibilityIdentifier = "permission.status"
        errorLabel.accessibilityIdentifier = "permission.error"
        errorLabel.isHidden = true
        content.addArrangedSubview(statusLabel)
        content.addArrangedSubview(errorLabel)

        if let reason = form.unsupportedReason {
            content.addArrangedSubview(Theme.label(reason, style: .callout, color: .systemOrange))
        }
        if case .url(let url) = form.mode {
            content.addArrangedSubview(Theme.label(url.absoluteString, style: .callout))
            let open = Theme.button(String(localized: "打开验证页面"), icon: "safari") { [weak self] in
                guard let self, self.ensureCurrent() else { return }
                self.view.endEditing(true)
                self.present(SFSafariViewController(url: url), animated: true)
            }
            open.accessibilityHint = String(localized: "打开显示的地址；完成操作后返回此处确认")
            openURLButton = open
            content.addArrangedSubview(open)
            content.addArrangedSubview(Theme.label(String(localized: "在页面完成操作后，返回并点击“已完成，继续”。"), style: .footnote, color: .secondaryLabel))
        }
        for field in form.fields {
            let input = PermissionInputView(field: field)
            inputs.append(input)
            content.addArrangedSubview(input)
        }
        if payload["kind"].stringValue == "plan", options.contains(where: { $0.kind == "reject_once" }) {
            let label = Theme.label(String(localized: "修改意见（拒绝计划时发送，可选）"), style: .headline)
            content.addArrangedSubview(label)
            let editor = PermissionInputView.makeEditor(label: label.text ?? String(localized: "修改意见"), initial: "")
            editor.accessibilityIdentifier = "permission.plan.feedback"
            editor.delegate = self
            feedback = editor
            content.addArrangedSubview(editor)
        }

        let actionHeading = Theme.label(String(localized: "请选择操作"), style: .headline)
        actionHeading.accessibilityTraits.insert(.header)
        content.addArrangedSubview(actionHeading)
        if options.isEmpty {
            content.addArrangedSubview(Theme.label(String(localized: "后端没有提供可用操作。请关闭此页并核对会话记录。"), style: .callout))
        }
        for option in options {
            let title = option.title(for: permission.payload["kind"].stringValue, isURL: form.isURL)
            let button = Theme.button(title) { [weak self] in self?.confirm(option) }
            button.configuration?.titleLineBreakMode = .byWordWrapping
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.configuration?.baseForegroundColor = option.isRejection ? .systemRed : Theme.accent
            button.accessibilityIdentifier = "permission.option.\(option.id)"
            button.accessibilityHint = String(localized: "确认后提交此操作")
            actionButtons.append((option, button))
            content.addArrangedSubview(button)
        }
        let close = Theme.button(String(localized: "关闭"), icon: "xmark") { [weak self] in self?.done() }
        close.accessibilityHint = String(localized: "关闭审批页，不提交回答")
        closeButton = close
        content.addArrangedSubview(close)
    }

    private func addDetails(_ details: JSONValue) {
        guard !details.isNull else { return }
        let summaries: [(String, String)] = [
            ("command", String(localized: "命令")), ("cwd", String(localized: "工作目录")), ("reason", String(localized: "原因")), ("message", String(localized: "说明")),
            ("path", String(localized: "路径")), ("filePath", String(localized: "文件")), ("files", String(localized: "文件")), ("changes", String(localized: "文件变更")),
            ("patch", String(localized: "补丁")), ("diff", String(localized: "差异")), ("permissions", String(localized: "请求的权限")),
            ("grantRoot", String(localized: "授权目录")), ("toolCall", String(localized: "工具调用")), ("rawInput", String(localized: "输入")),
            ("plan", String(localized: "计划")), ("content", String(localized: "内容")), ("summary", String(localized: "摘要")),
        ]
        var hasSummary = false
        for (key, label) in summaries {
            guard let value = details.objectValue[key], !value.isNull else { continue }
            hasSummary = true
            content.addArrangedSubview(Theme.label(label, style: .headline))
            content.addArrangedSubview(readOnlyText(value.optionalString ?? value.prettyPrinted))
        }
        if permission.payload["kind"].stringValue == "question" {
            let question = details["question"]
            if let text = question["question"].optionalString ?? question["prompt"].optionalString
                ?? question.optionalString
            {
                content.addArrangedSubview(Theme.label(text, style: .headline))
                hasSummary = true
            }
        }
        let raw = readOnlyText(details.optionalString ?? details.prettyPrinted)
        raw.isHidden = hasSummary || !form.fields.isEmpty
        let toggle = Theme.button(String(localized: "查看完整请求"), icon: "doc.text") { [weak raw] in
            raw?.isHidden.toggle()
        }
        toggle.accessibilityHint = String(localized: "展开或收起后端提供的完整请求内容")
        content.addArrangedSubview(toggle)
        content.addArrangedSubview(raw)
    }

    private func readOnlyText(_ text: String) -> UITextView {
        let textView = UITextView()
        textView.text = text
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = Theme.surface
        textView.font = UIFontMetrics(forTextStyle: .callout).scaledFont(
            for: .monospacedSystemFont(ofSize: 15, weight: .regular))
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        textView.layer.cornerRadius = 12
        return textView
    }

    private func observeSession() {
        guard observer == nil else { return }
        observer = session.observe { [weak self] in self?.updateAvailability() }
    }

    private func stopObserving() {
        if let observer { session.removeObserver(observer) }
        observer = nil
    }

    private var currentFailure: String? {
        guard session.selectedID == requestKey.backend else { return String(localized: "后端已切换，此审批已失效。") }
        guard session.isConnected else { return String(localized: "连接已断开。请重新连接并从当前记录打开审批。") }
        guard let runtime = session.runtimes[conversationId], runtime.readyForActions else {
            return String(localized: "会话正在回放或记录存在缺口。请同步完成后重新打开审批。")
        }
        guard
            runtime.pendingPermissions.contains(where: {
                $0.id == permission.id && $0.turnId == permission.turnId && $0.payload == permission.payload
            })
        else { return String(localized: "此审批已处理、已撤回或内容已更新。请从当前记录打开新的请求。") }
        return nil
    }

    private func updateAvailability() {
        if invalidation == nil { invalidation = currentFailure }
        let state = Self.submissions[requestKey]?.state
        let blocked = invalidation != nil || state != nil
        for (option, button) in actionButtons {
            button.isEnabled = !blocked && (option.kind != "answer" || form.canAnswer)
        }
        for input in inputs { input.setEnabled(!blocked) }
        feedback?.isEditable = !blocked
        openURLButton?.isEnabled = !blocked
        let sending: Bool
        switch state {
        case .sending:
            sending = true
            statusLabel.text = String(localized: "正在提交，请稍候…")
        case .unknown(let message):
            sending = false
            statusLabel.text = String(localized: "提交结果未知，已锁定此请求以避免重复发送。请关闭此页并核对会话记录。\n\(message)")
        case .completed:
            sending = false
            statusLabel.text = String(localized: "回答已提交，正在等待会话记录更新。")
        case nil:
            sending = false
            statusLabel.text = invalidation ?? String(localized: "请核对请求内容。只有明确确认操作后才会提交。")
        }
        isModalInPresentation = sending
        navigationController?.isModalInPresentation = sending
        navigationItem.rightBarButtonItem?.isEnabled = !sending
        closeButton?.isEnabled = !sending
    }

    @discardableResult
    private func ensureCurrent() -> Bool {
        updateAvailability()
        guard invalidation == nil, Self.submissions[requestKey] == nil else {
            UIAccessibility.post(notification: .announcement, argument: statusLabel.text)
            return false
        }
        return true
    }

    private func confirm(_ option: PermissionOption) {
        guard ensureCurrent(), options.contains(option) else { return }
        do {
            let decision = try makeDecision(option)
            errorLabel.isHidden = true
            view.endEditing(true)
            let title = option.title(for: permission.payload["kind"].stringValue, isURL: form.isURL)
            let message =
                form.isURL && option.kind == "answer"
                ? String(localized: "请确认你已在显示的验证页面完成操作。确认后将继续本轮任务。")
                : String(localized: "将提交“\(title)”。请确认这符合你的意愿。")
            let alert = UIAlertController(title: String(localized: "确认操作"), message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "返回修改"), style: .cancel))
            alert.addAction(
                UIAlertAction(title: String(localized: "确认"), style: option.isRejection ? .destructive : .default) { [weak self] _ in
                    self?.submit(option, decision: decision)
                })
            // No preferredAction: keyboard/assistive focus must not default to approval.
            present(alert, animated: true)
        } catch {
            displayError(error)
        }
    }

    private func makeDecision(_ option: PermissionOption) throws -> JSONValue {
        var decision: JSONValue = ["outcome": .string(option.kind), "optionId": .string(option.id)]
        if option.kind == "answer" {
            guard form.canAnswer else { throw TodexError.invalid(form.unsupportedReason ?? String(localized: "此请求不支持回答。")) }
            if case .choice = form.mode { return decision }
            if case .url = form.mode {
                decision["data"] = ["completed": true]
                return decision
            }
            var values: [String: JSONValue] = [:]
            for input in inputs {
                do {
                    if let value = try input.value() { values[input.field.id] = value }
                } catch {
                    scrollView.scrollRectToVisible(input.convert(input.bounds, to: scrollView), animated: true)
                    UIAccessibility.post(notification: .layoutChanged, argument: input.accessibilityTarget)
                    throw error
                }
            }
            switch form.mode {
            case .userInput:
                decision["data"] = ["answers": .object(values.mapValues { ["answers": $0] })]
            case .elicitation(let schema):
                let data = JSONValue.object(values)
                try PermissionSchema.validate(schema, value: data, label: String(localized: "回答"))
                decision["data"] = data
            case .extensionUI:
                decision["data"] = .object(values)
            case .none, .choice, .url:
                throw TodexError.invalid(String(localized: "此请求不支持表单回答。"))
            }
        } else if permission.payload["kind"].stringValue == "plan", option.kind == "reject_once",
            let text = feedback?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            decision["data"] = ["feedback": .string(text)]
        }
        return decision
    }

    private func submit(_ option: PermissionOption, decision: JSONValue) {
        // Revalidate after the confirmation alert as replay or another client may have resolved it.
        guard ensureCurrent(), PermissionOption.advertised(in: permission.payload).contains(option) else { return }
        let submission = Submission(session: session)
        Self.submissions[requestKey] = submission
        errorLabel.isHidden = true
        updateAvailability()
        let session = session
        let key = requestKey
        let permission = permission
        let conversationId = conversationId
        Task { @MainActor [weak self] in
            do {
                try await session.respond(permission, conversationId: conversationId, decision: decision)
                submission.state = .completed
                session.changed(immediate: true)
                self?.done()
            } catch {
                if case TodexError.unknownOutcome = error {
                    submission.state = .unknown(error.localizedDescription)
                } else {
                    Self.submissions.removeValue(forKey: key)
                }
                session.changed(immediate: true)
                self?.displayError(error)
            }
        }
    }

    private func displayError(_ error: any Error) {
        errorLabel.text = error.localizedDescription
        errorLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
        if view.window != nil { showError(error) }
    }

    @objc private func done() {
        if case .sending = Self.submissions[requestKey]?.state { return }
        view.endEditing(true)
        stopObserving()
        dismiss(animated: true)
    }

    private static func pruneSubmissions() {
        submissions = submissions.filter { key, submission in
            guard let session = submission.session else { return false }
            if case .sending = submission.state { return true }
            guard session.isConnected, session.selectedID == key.backend,
                let runtime = session.runtimes[key.conversation], runtime.readyForActions
            else { return true }
            return runtime.pendingPermissions.contains {
                $0.id == key.permissionId && $0.turnId == key.turnId && $0.payload == key.payload
            }
        }
    }
}

private struct PermissionOption: Equatable {
    let id: String
    let kind: String
    let name: String
    var isRejection: Bool { kind.hasPrefix("reject_") || kind == "abort_turn" }

    static func advertised(in payload: JSONValue) -> [Self] {
        var identifiers = Set<String>()
        let kinds: Set<String> = ["allow_once", "allow_always", "reject_once", "reject_always", "abort_turn", "answer"]
        var result: [Self] = []
        for raw in payload["options"].arrayValue {
            guard let id = raw["optionId"].optionalString, !id.isEmpty,
                let name = raw["name"].optionalString, !name.isEmpty,
                let kind = raw["kind"].optionalString, kinds.contains(kind),
                identifiers.insert(id).inserted
            else { return [] }
            result.append(Self(id: id, kind: kind, name: name))
        }
        return result
    }

    func title(for requestKind: String, isURL: Bool) -> String {
        if kind == "answer", requestKind == "question" { return name }
        if kind == "answer", isURL { return String(localized: "已完成，继续") }
        let translations = [
            "Allow once": String(localized: "仅本次允许"), "Allow for session": String(localized: "本会话内允许"),
            "Allow always": String(localized: "始终允许"), "Approve": String(localized: "批准计划"), "Request changes": String(localized: "拒绝并提出修改意见"),
            "Reject": String(localized: "拒绝"), "Decline": String(localized: "拒绝"), "Cancel": String(localized: "取消请求"),
            "Reject and stop turn": String(localized: "拒绝并停止本轮"), "Respond": String(localized: "提交回答"),
            "Submit": String(localized: "提交回答"), "Answer": String(localized: "提交回答"),
        ]
        if let title = translations[name] { return title }
        let action =
            switch kind {
            case "allow_once": String(localized: "本次允许")
            case "allow_always": String(localized: "持续允许")
            case "reject_once": String(localized: "拒绝")
            case "reject_always": String(localized: "持续拒绝")
            case "abort_turn": String(localized: "拒绝并停止本轮")
            default: String(localized: "提交回答")
            }
        return String(localized: "\(action)：\(name)")
    }
}

private struct PermissionField {
    enum Kind { case string, number, integer, boolean, json, answers }
    struct Choice {
        let label: String
        let value: JSONValue
        var description: String = ""
    }
    let id: String
    let label: String
    var kind: Kind = .string
    var description: String = ""
    var required = true
    var choices: [Choice]?
    var multiline = false
    var secret = false
    var initial = ""
    var placeholder = ""
    var allowsEmpty = false
    var schema: JSONValue?
}

private struct PermissionForm {
    enum Mode {
        case none, choice, userInput, extensionUI
        case elicitation(JSONValue)
        case url(URL)
    }
    var mode: Mode = .none
    var fields: [PermissionField] = []
    var unsupportedReason: String?
    var isURL: Bool { if case .url = mode { true } else { false } }
    var canAnswer: Bool {
        if case .none = mode { return false }
        return unsupportedReason == nil
    }

    init(_ payload: JSONValue) {
        let details = payload["details"]
        switch payload["kind"].stringValue {
        case "question": mode = .choice
        case "user_input":
            mode = .userInput
            let questions = details["questions"].arrayValue
            guard !questions.isEmpty else {
                unsupported()
                return
            }
            var ids = Set<String>()
            for question in questions {
                guard let id = question["id"].optionalString, !id.isEmpty, ids.insert(id).inserted else {
                    unsupported()
                    return
                }
                var field = PermissionField(
                    id: id, label: question["question"].optionalString ?? question["header"].optionalString ?? id)
                field.kind = .answers
                field.secret = question["isSecret"].boolValue
                field.multiline = !field.secret
                field.placeholder = String(localized: "输入回答，或补充已选选项")
                if !question["options"].isNull {
                    guard case .array(let choices) = question["options"] else {
                        unsupported()
                        return
                    }
                    field.choices = []
                    for choice in choices {
                        guard let label = choice["label"].optionalString ?? choice.optionalString, !label.isEmpty else {
                            unsupported()
                            return
                        }
                        field.choices?.append(
                            .init(label: label, value: .string(label), description: choice["description"].stringValue))
                    }
                }
                fields.append(field)
            }
        case "extension_ui":
            mode = .extensionUI
            let method = details["method"].stringValue
            var field = PermissionField(
                id: method == "confirm" ? "confirmed" : "value",
                label: details["message"].optionalString ?? details["title"].optionalString ?? String(localized: "你的回答"))
            switch method {
            case "confirm": field.kind = .boolean
            case "input", "editor":
                field.multiline = method == "editor"
                field.initial = method == "editor" ? details["prefill"].stringValue : ""
                field.placeholder = details["placeholder"].stringValue
                field.allowsEmpty = true
            case "select":
                guard case .array(let values) = details["options"], !values.isEmpty,
                    values.allSatisfy({ $0.optionalString != nil })
                else {
                    unsupported()
                    return
                }
                field.choices = values.map { .init(label: $0.stringValue, value: $0) }
            default:
                unsupported()
                return
            }
            fields = [field]
        case "elicitation":
            if details["mode"].stringValue == "url" {
                guard let raw = details["url"].optionalString, let url = URL(string: raw),
                    ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                    let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
                else {
                    unsupportedReason = String(localized: "验证地址无效，无法确认完成。你仍可选择后端提供的拒绝操作。")
                    return
                }
                mode = .url(url)
            } else {
                let schema = details.objectValue["requestedSchema"] ?? details["schema"]
                mode = .elicitation(schema)
                guard case .object(let root) = schema, !root.isEmpty,
                    root["type"] == nil || root["type"] == .string("object")
                else {
                    unsupported()
                    return
                }
                if let raw = root["properties"] {
                    guard case .object = raw else {
                        unsupported()
                        return
                    }
                }
                if let raw = root["required"] {
                    guard case .array = raw else {
                        unsupported()
                        return
                    }
                }
                let properties = schema["properties"].objectValue
                let required = schema["required"].arrayValue
                guard required.allSatisfy({ $0.optionalString.map { properties[$0] != nil } == true }) else {
                    unsupported()
                    return
                }
                for id in properties.keys.sorted() {
                    guard let property = properties[id], case .object = property else {
                        unsupported()
                        return
                    }
                    var field = PermissionField(id: id, label: property["title"].optionalString ?? id)
                    field.required = required.contains(.string(id))
                    field.description = property["description"].stringValue
                    field.schema = property
                    let constraints: [(String, String)] = [
                        ("minimum", String(localized: "最小值")), ("maximum", String(localized: "最大值")),
                        ("minLength", String(localized: "最少字符数")), ("maxLength", String(localized: "最多字符数")),
                        ("minItems", String(localized: "最少项目数")), ("maxItems", String(localized: "最多项目数")),
                    ]
                    for (key, label) in constraints where property[key].doubleValue != nil {
                        field.description +=
                            (field.description.isEmpty ? "" : "\n") + String(localized: "\(label)：\(property[key].prettyPrinted)")
                    }
                    if let raw = property.objectValue["type"], raw.optionalString == nil {
                        unsupported()
                        return
                    }
                    let enumValues: [JSONValue]?
                    if let raw = property.objectValue["enum"] {
                        guard case .array(let values) = raw, !values.isEmpty else {
                            unsupported()
                            return
                        }
                        enumValues = values
                    } else if let constant = property.objectValue["const"] {
                        enumValues = [constant]
                    } else {
                        enumValues = nil
                    }
                    let inferredType: String
                    switch enumValues?.first {
                    case .some(.bool): inferredType = "boolean"
                    case .some(.number): inferredType = "number"
                    case .some(.object): inferredType = "object"
                    case .some(.array): inferredType = "array"
                    case .some(.null): inferredType = "null"
                    default: inferredType = "string"
                    }
                    switch property["type"].optionalString ?? inferredType {
                    case "string": field.kind = .string
                    case "number": field.kind = .number
                    case "integer": field.kind = .integer
                    case "boolean": field.kind = .boolean
                    case "object", "array", "null":
                        field.kind = .json
                        field.multiline = true
                        field.placeholder = String(localized: "输入符合字段要求的 JSON 值")
                    default:
                        unsupported()
                        return
                    }
                    field.choices = enumValues?.map { .init(label: $0.optionalString ?? $0.prettyPrinted, value: $0) }
                    fields.append(field)
                }
            }
        default: break
        }
    }

    private mutating func unsupported() {
        unsupportedReason = String(localized: "这项请求包含无法安全填写的表单格式。请关闭此页，或选择后端提供的拒绝操作。")
    }
}

@MainActor
private final class PermissionInputView: UIStackView, UITextViewDelegate, UITextFieldDelegate {
    let field: PermissionField
    private var choices: [PermissionField.Choice]
    private var selected: Int?
    private var choiceButtons: [UIButton] = []
    private var textField: UITextField?
    private var editor: UITextView?

    var editingView: UIView? {
        if let textField, textField.isFirstResponder { return textField }
        if let editor, editor.isFirstResponder { return editor }
        return nil
    }

    var accessibilityTarget: UIView {
        if let first = choiceButtons.first { return first }
        if let textField { return textField }
        if let editor { return editor }
        return self
    }

    init(field: PermissionField) {
        self.field = field
        choices =
            field.choices
            ?? (field.kind == .boolean ? [.init(label: String(localized: "是"), value: true), .init(label: String(localized: "否"), value: false)] : [])
        super.init(frame: .zero)
        axis = .vertical
        spacing = 10
        accessibilityIdentifier = "permission.field.\(field.id)"
        let title = field.label + (field.required ? String(localized: "（必填）") : String(localized: "（可选）"))
        let label = Theme.label(title, style: .headline)
        label.accessibilityTraits.insert(.header)
        addArrangedSubview(label)
        if !field.description.isEmpty {
            addArrangedSubview(Theme.label(field.description, style: .footnote, color: .secondaryLabel))
        }
        for (index, choice) in choices.enumerated() {
            var config = UIButton.Configuration.tinted()
            config.title = choice.label
            config.subtitle = choice.description.isEmpty ? nil : choice.description
            config.titleLineBreakMode = .byWordWrapping
            config.subtitleLineBreakMode = .byWordWrapping
            config.image = UIImage(systemName: "circle")
            config.imagePadding = 10
            config.contentInsets = .init(top: 12, leading: 12, bottom: 12, trailing: 12)
            config.baseForegroundColor = Theme.accent
            let button = UIButton(
                configuration: config,
                primaryAction: UIAction { [weak self] _ in
                    guard let self else { return }
                    self.selected = self.selected == index ? nil : index
                    self.updateChoices()
                })
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.accessibilityLabel = String(localized: "\(field.label)：\(choice.label)")
            button.accessibilityHint = choice.description
            button.accessibilityIdentifier = "permission.field.\(field.id).choice.\(index)"
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            choiceButtons.append(button)
            addArrangedSubview(button)
        }
        if choices.isEmpty || field.kind == .answers {
            if field.kind == .answers, !choices.isEmpty {
                addArrangedSubview(Theme.label(String(localized: "补充或自定义回答"), style: .subheadline, color: .secondaryLabel))
            }
            if field.multiline && !field.secret {
                let editor = Self.makeEditor(label: title, initial: field.initial)
                editor.delegate = self
                editor.accessibilityHint = field.placeholder
                editor.accessibilityIdentifier = "permission.field.\(field.id).text"
                self.editor = editor
                addArrangedSubview(editor)
                if !field.placeholder.isEmpty {
                    addArrangedSubview(Theme.label(field.placeholder, style: .footnote, color: .secondaryLabel))
                }
            } else {
                let input = UITextField()
                input.borderStyle = .roundedRect
                input.backgroundColor = Theme.surface
                input.font = .preferredFont(forTextStyle: .body)
                input.adjustsFontForContentSizeCategory = true
                input.text = field.initial
                input.placeholder = field.placeholder
                input.isSecureTextEntry = field.secret
                input.autocorrectionType = .no
                input.autocapitalizationType = .none
                input.smartQuotesType = .no
                input.smartDashesType = .no
                input.delegate = self
                if field.kind == .number || field.kind == .integer { input.keyboardType = .numbersAndPunctuation }
                input.accessibilityLabel = title
                input.accessibilityIdentifier = "permission.field.\(field.id).text"
                input.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
                input.inputAccessoryView = keyboardToolbar()
                textField = input
                addArrangedSubview(input)
            }
        }
    }

    required init(coder: NSCoder) { fatalError("Use init(field:)") }

    static func makeEditor(label: String, initial: String) -> UITextView {
        let editor = UITextView()
        editor.text = initial
        editor.font = .preferredFont(forTextStyle: .body)
        editor.adjustsFontForContentSizeCategory = true
        editor.backgroundColor = Theme.surface
        editor.textColor = .label
        editor.layer.cornerRadius = 12
        editor.textContainerInset = .init(top: 12, left: 8, bottom: 12, right: 8)
        editor.isScrollEnabled = false
        editor.autocorrectionType = .no
        editor.autocapitalizationType = .none
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.accessibilityLabel = label
        editor.heightAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true
        let toolbar = UIToolbar()
        toolbar.items = [
            .flexibleSpace(),
            UIBarButtonItem(
                title: String(localized: "收起键盘"), image: nil, primaryAction: UIAction { [weak editor] _ in editor?.resignFirstResponder() }
            ),
        ]
        toolbar.sizeToFit()
        editor.inputAccessoryView = toolbar
        return editor
    }

    private func keyboardToolbar() -> UIToolbar {
        let toolbar = UIToolbar()
        toolbar.items = [
            .flexibleSpace(),
            UIBarButtonItem(
                title: String(localized: "收起键盘"), image: nil, primaryAction: UIAction { [weak self] _ in self?.endEditing(true) }),
        ]
        toolbar.sizeToFit()
        return toolbar
    }

    private func updateChoices() {
        for (index, button) in choiceButtons.enumerated() {
            let isSelected = selected == index
            button.configuration?.image = UIImage(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
            button.accessibilityValue = isSelected ? String(localized: "已选择") : String(localized: "未选择")
        }
    }

    func setEnabled(_ enabled: Bool) {
        for button in choiceButtons { button.isEnabled = enabled }
        textField?.isEnabled = enabled
        editor?.isEditable = enabled
    }

    func textViewDidChange(_ textView: UITextView) {
        textView.invalidateIntrinsicContentSize()
        Self.reveal(textView)
    }

    func textViewDidBeginEditing(_ textView: UITextView) { Self.reveal(textView) }
    func textFieldDidBeginEditing(_ textField: UITextField) { Self.reveal(textField) }

    static func reveal(_ input: UIView) {
        // Keep the insertion point visible when focus, keyboard size or multiline height changes.
        var ancestor = input.superview
        while let parent = ancestor {
            if let scroll = parent as? UIScrollView {
                scroll.layoutIfNeeded()
                let rect: CGRect
                if let textView = input as? UITextView, let range = textView.selectedTextRange {
                    rect = textView.caretRect(for: range.end)
                } else {
                    rect = input.bounds
                }
                scroll.scrollRectToVisible(input.convert(rect.insetBy(dx: 0, dy: -16), to: scroll), animated: false)
                break
            }
            ancestor = parent.superview
        }
    }

    func value() throws -> JSONValue? {
        let text = textField?.text ?? editor?.text ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let choice = selected.map { choices[$0].value }
        if field.kind == .answers {
            var answers: [JSONValue] = choice.map { [$0] } ?? []
            if !trimmed.isEmpty, !answers.contains(.string(text)) { answers.append(.string(text)) }
            guard !answers.isEmpty else { throw missing() }
            return .array(answers)
        }
        let value: JSONValue
        if let choice {
            value = choice
        } else if !choices.isEmpty || field.kind == .boolean {
            guard !field.required else { throw missing() }
            return nil
        } else {
            if trimmed.isEmpty && !field.allowsEmpty {
                guard !field.required else { throw missing() }
                return nil
            }
            switch field.kind {
            case .number, .integer:
                let separator = Locale.current.decimalSeparator ?? "."
                let normalized = separator == "." ? trimmed : trimmed.replacingOccurrences(of: separator, with: ".")
                guard let number = Double(normalized), number.isFinite else {
                    throw TodexError.invalid(String(localized: "「\(field.label)」需要有效数字。"))
                }
                if field.kind == .integer,
                    number.rounded(.towardZero) != number || abs(number) > 9_007_199_254_740_991
                {
                    throw TodexError.invalid(String(localized: "「\(field.label)」需要可精确表示的整数（绝对值不超过 9007199254740991）。"))
                }
                value = .number(number)
            case .json:
                do { value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) } catch {
                    throw TodexError.invalid(String(localized: "「\(field.label)」需要有效的 JSON 值。"))
                }
            default: value = .string(text)
            }
        }
        if let schema = field.schema { try PermissionSchema.validate(schema, value: value, label: field.label) }
        return value
    }

    private func missing() -> TodexError { .invalid(String(localized: "请填写或选择「\(field.label)」。")) }
}

private enum PermissionSchema {
    // Validate backend constraints, including Unicode scalar length and the depth limit.
    // Integers additionally stay within JSONValue's exact Double representation.
    static func validate(_ schema: JSONValue, value: JSONValue, label: String, depth: Int = 0) throws {
        let invalid = TodexError.invalid(String(localized: "「\(label)」不符合请求的字段类型、范围或必填要求。"))
        guard depth <= 16 else { throw invalid }
        if case .array(let choices) = schema["enum"], !choices.contains(value) { throw invalid }
        if let constant = schema.objectValue["const"], constant != value { throw invalid }
        switch schema["type"].optionalString {
        case "object":
            guard case .object(let object) = value else { throw invalid }
            for key in schema["required"].arrayValue {
                guard let name = key.optionalString, object[name] != nil else { throw invalid }
            }
            for (key, child) in object {
                if let property = schema["properties"].objectValue[key] {
                    try validate(property, value: child, label: "\(label).\(key)", depth: depth + 1)
                } else if schema["additionalProperties"] == .bool(false) {
                    throw invalid
                }
            }
        case "array":
            guard case .array(let items) = value else { throw invalid }
            if let itemSchema = schema.objectValue["items"] {
                for (index, item) in items.enumerated() {
                    try validate(itemSchema, value: item, label: "\(label)[\(index + 1)]", depth: depth + 1)
                }
            }
            try checkBounds(Double(items.count), min: schema["minItems"], max: schema["maxItems"], error: invalid)
        case "string":
            guard case .string(let text) = value else { throw invalid }
            try checkBounds(
                Double(text.unicodeScalars.count), min: schema["minLength"], max: schema["maxLength"], error: invalid)
        case "boolean":
            guard case .bool = value else { throw invalid }
        case "integer":
            guard case .number(let number) = value, number.isFinite,
                number.rounded(.towardZero) == number, abs(number) <= 9_007_199_254_740_991
            else { throw invalid }
        case "number":
            guard case .number(let number) = value, number.isFinite else { throw invalid }
        case "null":
            guard value.isNull else { throw invalid }
        default: break
        }
        if let number = value.doubleValue {
            try checkBounds(number, min: schema["minimum"], max: schema["maximum"], error: invalid)
        }
    }

    private static func checkBounds(_ number: Double, min: JSONValue, max: JSONValue, error: TodexError) throws {
        if let minimum = min.doubleValue, number < minimum { throw error }
        if let maximum = max.doubleValue, number > maximum { throw error }
    }
}
