import ImageIO
import PhotosUI
import TodexCore
import UIKit
import UniformTypeIdentifiers

final class ChatViewController: UIViewController, UITextViewDelegate, UIDocumentPickerDelegate,
    PHPickerViewControllerDelegate
{
    private let session: AppSession
    private let conversation: ConversationManifest
    private let timeline = TimelineViewController()
    private let composer = UITextView()
    private let status = Theme.label("正在同步…", style: .caption1, color: .secondaryLabel)
    private let chips = UIStackView()
    private let alerts = UIStackView()
    private let modelChip = Theme.chip("模型", icon: "cpu")
    private let permissionChip = Theme.chip("权限", icon: "hand.raised")
    private let workModeChip = Theme.chip("执行", icon: "checklist")
    private let moreChip = Theme.iconButton("ellipsis", pointSize: 11)
    private var sendButton: UIButton!
    private var stopButton: UIButton!
    private var observer: UUID?
    private var wasConnected = false
    private let suggestionBox = UIView()
    private let suggestionList = UIStackView()
    private var mentionTask: Task<Void, Never>?
    private var draft: ComposerDraft { session.drafts[conversation.id] ?? ComposerDraft() }
    private var submitting = false
    var openFile: ((String) -> Void)?
    private var renderedDraft = ComposerDraft()
    init(session: AppSession, conversation: ConversationManifest) {
        self.session = session
        self.conversation = conversation
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { if let observer { session.removeObserver(observer) } }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 0
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        let header = UIStackView(arrangedSubviews: [status])
        header.axis = .horizontal
        header.spacing = 6
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = .init(top: 9, leading: 18, bottom: 8, trailing: 12)
        stack.addArrangedSubview(header)
        alerts.axis = .vertical
        alerts.spacing = 6
        alerts.isLayoutMarginsRelativeArrangement = true
        alerts.directionalLayoutMargins = .init(top: 0, leading: 14, bottom: 6, trailing: 14)
        stack.addArrangedSubview(alerts)
        addChild(timeline)
        stack.addArrangedSubview(timeline.view)
        timeline.didMove(toParent: self)
        timeline.insertText = { [weak self] in self?.insert($0) }
        timeline.openFile = { [weak self] in self?.openFile?($0) }
        let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        glass.layer.cornerRadius = 26
        glass.clipsToBounds = true
        let footer = UIView()
        footer.addSubview(glass)
        glass.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 10),
            glass.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -10),
            glass.topAnchor.constraint(equalTo: footer.topAnchor, constant: 3),
            glass.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -8),
        ])
        let inputStack = UIStackView()
        inputStack.axis = .vertical
        inputStack.spacing = 5
        glass.contentView.addSubview(inputStack)
        inputStack.pinEdges(to: glass.contentView, inset: 10)
        chips.axis = .vertical
        chips.spacing = 3
        inputStack.addArrangedSubview(chips)
        suggestionBox.backgroundColor = Theme.surface
        suggestionBox.layer.cornerRadius = 12
        suggestionBox.clipsToBounds = true
        suggestionBox.isHidden = true
        suggestionBox.accessibilityIdentifier = "chat.suggestions"
        suggestionList.axis = .vertical
        suggestionList.spacing = 0
        suggestionBox.addSubview(suggestionList)
        suggestionList.pinEdges(to: suggestionBox)
        inputStack.addArrangedSubview(suggestionBox)
        composer.font = .preferredFont(forTextStyle: .body)
        composer.adjustsFontForContentSizeCategory = true
        composer.backgroundColor = .clear
        composer.delegate = self
        composer.accessibilityLabel = "消息输入框"
        composer.accessibilityIdentifier = "chat.composer"
        composer.textContainerInset = .init(top: 5, left: 6, bottom: 5, right: 6)
        composer.heightAnchor.constraint(equalToConstant: 75).isActive = true
        inputStack.addArrangedSubview(composer)
        let attach = Theme.iconButton("plus")
        attach.accessibilityLabel = "附件"
        attach.showsMenuAsPrimaryAction = true
        attach.menu = UIMenu(children: [
            UIAction(title: "照片", image: Theme.icon("photo")) { [weak self] _ in self?.pickPhotos() },
            UIAction(title: "文件", image: Theme.icon("doc")) { [weak self] _ in self?.pickFiles() },
        ])
        for chip in [modelChip, permissionChip, workModeChip, moreChip] {
            chip.showsMenuAsPrimaryAction = true
            chip.setContentHuggingPriority(.required, for: .horizontal)
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        moreChip.accessibilityLabel = "更多控制"
        stopButton = Theme.button("停止", icon: "stop.fill") { [weak self] in self?.performControl("cancel") }
        sendButton = Theme.button("发送", icon: "arrow.up", prominent: true) { [weak self] in self?.submit() }
        sendButton.accessibilityIdentifier = "chat.send"
        let selectorScroll = UIScrollView()
        selectorScroll.showsHorizontalScrollIndicator = false
        let selectors = UIStackView(arrangedSubviews: [modelChip, permissionChip, workModeChip, moreChip])
        selectors.axis = .horizontal
        selectors.spacing = 6
        selectorScroll.addSubview(selectors)
        selectors.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            selectors.leadingAnchor.constraint(equalTo: selectorScroll.contentLayoutGuide.leadingAnchor),
            selectors.trailingAnchor.constraint(equalTo: selectorScroll.contentLayoutGuide.trailingAnchor),
            selectors.topAnchor.constraint(equalTo: selectorScroll.contentLayoutGuide.topAnchor),
            selectors.bottomAnchor.constraint(equalTo: selectorScroll.contentLayoutGuide.bottomAnchor),
            selectors.heightAnchor.constraint(equalTo: selectorScroll.frameLayoutGuide.heightAnchor),
        ])
        selectorScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        selectorScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [attach, stopButton!, sendButton!] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let toolbar = UIStackView(arrangedSubviews: [selectorScroll, attach, stopButton, sendButton])
        toolbar.axis = .horizontal
        toolbar.spacing = 6
        toolbar.alignment = .center
        inputStack.addArrangedSubview(toolbar)
        stack.addArrangedSubview(footer)
        timeline.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        observer = session.observe { [weak self] in self?.reload() }
        reload()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Model catalogs are discovered live by the backend; refresh whenever the
        // conversation is shown again so CLI config edits are reflected.
        Task { [weak self] in
            guard let self, self.session.isConnected else { return }
            try? await self.session.loadModels(for: self.conversation)
            try? await self.session.loadCommands(for: self.conversation)
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session.persist()
    }
    func insert(_ text: String) {
        var value = draft
        value.text += (value.text.isEmpty ? "" : "\n") + text
        setDraft(value)
    }
    func insertSkill(_ id: String, name: String) {
        var value = draft
        guard !value.skills.contains(where: { $0.id == id }) else { return }
        value.skills.append(.init(id: id, name: name))
        setDraft(value)
    }
    private func setDraft(_ value: ComposerDraft) {
        session.drafts[conversation.id] = value
        session.saveSoon()
        reload()
    }
    func textViewDidChange(_ textView: UITextView) {
        var value = draft
        value.text = textView.text
        session.drafts[conversation.id] = value
        renderedDraft = value
        session.saveSoon()
        sendButton.isEnabled = canSend
        updateSuggestions()
    }
    func textViewDidChangeSelection(_ textView: UITextView) {
        updateSuggestions()
    }
    private var canSend: Bool {
        session.isConnected && session.runtimes[conversation.id]?.readyForActions == true && !draft.isEmpty
            && !submitting && session.pendingSends[conversation.id] == nil
    }
    private func reload() {
        guard isViewLoaded else { return }
        if session.isConnected && !wasConnected {
            Task { [weak self] in
                guard let self else { return }
                try? await self.session.loadModels(for: self.conversation)
            }
        }
        wasConnected = session.isConnected
        let runtime = session.runtimes[conversation.id]
        let running = ["running", "waitingPermission"].contains(runtime?.status ?? "")
        let pref = session.preferences(for: conversation)
        status.text =
            "\(conversation.provider) · \(session.isConnected ? runtime?.readyForActions == true ? (running ? "正在进行" : "已同步") : "正在补齐记录" : session.status)"
        timeline.update(
            runtime?.messages ?? [], provider: session.provider(for: conversation)?.displayName ?? conversation.provider
        )
        if renderedDraft != draft {
            composer.text = draft.text
            renderedDraft = draft
        }
        composer.accessibilityHint = draft.isEmpty ? "描述你的任务" : nil
        sendButton.configuration?.title = running ? "加入队列" : "发送"
        sendButton.isEnabled = canSend
        stopButton.isHidden = !running
        stopButton.isEnabled = session.isConnected && runtime?.readyForActions == true
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for attachment in draft.attachments {
            chips.addArrangedSubview(
                Theme.button("\(attachment.name) · 移除", icon: attachment.isImage ? "photo" : "doc") { [weak self] in
                    guard let self else { return }
                    var value = draft
                    value.attachments.removeAll { $0.id == attachment.id }
                    setDraft(value)
                })
        }
        for skill in draft.skills {
            chips.addArrangedSubview(
                Theme.button("$\(skill.name) · 移除", icon: "sparkles") { [weak self] in
                    guard let self else { return }
                    var value = draft
                    value.skills.removeAll { $0.id == skill.id }
                    setDraft(value)
                })
        }
        chips.isHidden = chips.arrangedSubviews.isEmpty
        alerts.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let pending = session.pendingSends[conversation.id] {
            alerts.addArrangedSubview(
                Theme.button("消息等待核对 · 查看", icon: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90") {
                    [weak self] in self?.showUnknown(pending)
                })
        }
        if let permission = runtime?.pendingPermissions.first {
            let button = Theme.button(
                permission.payload["title"].optionalString ?? "需要你的审批", icon: "hand.raised.fill", prominent: true
            ) { [weak self] in
                guard let self else { return }
                let page = PermissionViewController(
                    session: session, conversationId: conversation.id, permission: permission)
                present(UINavigationController(rootViewController: page), animated: true)
            }
            button.isEnabled = session.isConnected && runtime?.readyForActions == true
            button.accessibilityIdentifier = "chat.permission"
            alerts.addArrangedSubview(button)
        }
        if let items = session.queues[conversation.id], !items.isEmpty {
            alerts.addArrangedSubview(
                Theme.button(
                    "候选消息 \(items.count) 条\(session.pausedQueues.contains(conversation.id) ? " · 已暂停" : "")",
                    icon: "text.line.first.and.arrowtriangle.forward"
                ) { [weak self] in self?.showQueue() })
        }
        if runtime?.compaction["status"] == "running" {
            alerts.addArrangedSubview(Theme.label("正在压缩上下文…", style: .caption1, color: .secondaryLabel))
        }
        if let error = session.storageError ?? (session.isConnected ? nil : session.lastError) {
            alerts.addArrangedSubview(Theme.label(error, style: .caption1, color: .systemOrange))
        }
        alerts.isHidden = alerts.arrangedSubviews.isEmpty
        let models = session.models[conversation.provider + ":" + conversation.workspace] ?? []
        let descriptor = models.first { $0["id"].stringValue == pref.model }
        let modelTitle =
            pref.model.isEmpty
            ? "默认模型"
            : (descriptor?["name"].optionalString ?? descriptor?["displayName"].optionalString ?? pref.model)
        modelChip.configuration = Theme.chipConfiguration(
            title: modelTitle, icon: "cpu",
            detail: pref.reasoningEffort.isEmpty ? nil : "· \(pref.reasoningEffort)")
        modelChip.accessibilityLabel = "模型：\(modelTitle)"
        modelChip.menu = modelMenu()
        let capability = session.provider(for: conversation)?.capabilities ?? .null
        let permissionTitle =
            ["ask": "按需审批", "auto": "自动审批", "full-access": "完全访问"][pref.permissionMode]
            ?? pref.permissionMode
        permissionChip.configuration = Theme.chipConfiguration(
            title: permissionTitle.isEmpty ? "权限" : permissionTitle, icon: "hand.raised")
        permissionChip.accessibilityLabel = "权限模式：\(permissionTitle)"
        permissionChip.isEnabled = !capability["permissionConfig"]["modes"].arrayValue.isEmpty
        permissionChip.menu = permissionMenu()
        workModeChip.isHidden = !capability["permissionConfig"]["supportsPlan"].boolValue
        workModeChip.configuration = Theme.chipConfiguration(
            title: pref.workMode == "plan" ? "计划" : "执行", icon: "checklist")
        workModeChip.menu = workModeMenu()
        moreChip.menu = moreMenu()
        updateSuggestions()
    }
    private func submit() {
        guard canSend else { return }
        let value = draft
        submitting = true
        reload()
        Task { [weak self] in
            guard let self else { return }
            defer {
                submitting = false
                reload()
            }
            do {
                if value.attachments.contains(where: \.isImage) {
                    guard let api = session.api else { throw TodexError.disconnected }
                    let pref = session.preferences(for: conversation)
                    let capability = try await api.providerImageInput(
                        provider: conversation.provider, workspace: conversation.workspace,
                        profile: conversation.providerProfile, model: pref.model.isEmpty ? nil : pref.model)
                    guard capability["imageInput"].boolValue else {
                        throw TodexError.invalid(capability["reason"].optionalString ?? "当前模型不支持图片输入")
                    }
                }
                try await session.send(value, in: conversation)
            } catch { showError(error) }
        }
    }
    // MARK: - Inline suggestions (/ commands, @ file mentions)
    private struct Suggestion {
        let title: String
        let detail: String
        let apply: () -> Void
    }
    private func updateSuggestions() {
        let text = composer.text ?? ""
        let trimmed = text.drop(while: \.isWhitespace)
        if trimmed.hasPrefix("/") {
            let token = String(trimmed.dropFirst().prefix(while: { !$0.isWhitespace }))
            let items = slashSuggestions(matching: "/" + token)
            if items.isEmpty {
                if session.commands[conversation.provider + ":" + conversation.workspace] == nil {
                    loadCommands()
                }
                if let trigger = mentionTrigger() {
                    fetchMentionSuggestions(trigger)
                } else {
                    mentionTask?.cancel()
                    hideSuggestions()
                }
            } else {
                mentionTask?.cancel()
                showSuggestions(items)
            }
            return
        }
        if let trigger = mentionTrigger() {
            fetchMentionSuggestions(trigger)
        } else {
            mentionTask?.cancel()
            hideSuggestions()
        }
    }
    private func loadCommands() {
        Task { [weak self] in
            guard let self, self.session.isConnected else { return }
            try? await self.session.loadCommands(for: self.conversation)
        }
    }
    private func slashSuggestions(matching token: String) -> [Suggestion] {
        let lowered = token.lowercased()
        var items: [Suggestion] = []
        let supported =
            session.provider(for: conversation)?.capabilities["controlActions"].arrayValue
            .compactMap(\.optionalString) ?? []
        for (command, action, detail) in [("/compact", "compact", "压缩上下文，保留关键进展"), ("/retry", "retry", "重试上一轮")]
        where supported.contains(action) && command.hasPrefix(lowered) {
            items.append(
                Suggestion(title: command, detail: detail) { [weak self] in
                    self?.applyControlCommand(action)
                })
        }
        for item in session.commands[conversation.provider + ":" + conversation.workspace] ?? [] {
            let name = item["name"].stringValue
            let command = "/" + name
            guard !name.isEmpty, command.lowercased().hasPrefix(lowered), command != "/compact" else { continue }
            let invocation = item["invocation"].optionalString ?? command
            let hint = item["argumentHint"].optionalString.map { " \($0)" } ?? ""
            items.append(
                Suggestion(
                    title: command + hint,
                    detail: item["description"].optionalString ?? item["source"].stringValue
                ) { [weak self] in
                    self?.applyTextSuggestion("\(invocation) ")
                })
        }
        return Array(items.prefix(8))
    }
    private func applyControlCommand(_ action: String) {
        applyTextSuggestion("")
        performControl(action)
    }
    private func applyTextSuggestion(_ replacement: String) {
        var value = draft
        value.text = replacement
        composer.text = replacement
        composer.selectedRange = NSRange(location: replacement.utf16.count, length: 0)
        session.drafts[conversation.id] = value
        renderedDraft = value
        session.saveSoon()
        sendButton.isEnabled = canSend
        hideSuggestions()
    }
    private func mentionTrigger() -> (range: NSRange, query: String)? {
        let text = composer.text ?? ""
        let ns = text as NSString
        let end = max(0, min(composer.selectedRange.location, ns.length))
        let before = ns.substring(to: end)
        let found = (before as NSString).range(of: "@", options: .backwards)
        guard found.location != NSNotFound else { return nil }
        guard found.location == 0
            || CharacterSet.whitespacesAndNewlines.contains(
                UnicodeScalar((before as NSString).character(at: found.location - 1)) ?? " ")
        else { return nil }
        let query = (before as NSString).substring(from: found.location + 1)
        guard
            query.rangeOfCharacter(
                from: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "@"))) == nil
        else { return nil }
        return (NSRange(location: found.location, length: end - found.location), query)
    }
    private func fetchMentionSuggestions(_ trigger: (range: NSRange, query: String)) {
        mentionTask?.cancel()
        let range = trigger.range
        let query = trigger.query
        showSuggestions([Suggestion(title: "正在搜索工作区文件…", detail: "", apply: {})], interactive: false)
        mentionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            guard let api = self.session.api else { self.hideSuggestions(); return }
            do {
                let result = try await api.workspaceEntries(
                    cwd: self.conversation.workspace, query: query, limit: 40)
                guard !Task.isCancelled, self.mentionTrigger()?.range.location == range.location else { return }
                let items = result["entries"].arrayValue.prefix(8).map { entry in
                    let isDirectory = entry["kind"].stringValue == "directory"
                    let path = entry["path"].stringValue
                    return Suggestion(
                        title: entry["name"].stringValue + (isDirectory ? "/" : ""),
                        detail: path
                    ) { [weak self] in
                        self?.applyMention(range: range, text: "@\(path)" + (isDirectory ? "" : " "))
                    }
                }
                items.isEmpty
                    ? self.showSuggestions(
                        [Suggestion(title: "没有匹配的文件", detail: "", apply: {})], interactive: false)
                    : self.showSuggestions(Array(items))
            } catch {
                guard !Task.isCancelled, self.mentionTrigger()?.range.location == range.location else { return }
                self.hideSuggestions()
            }
        }
    }
    private func applyMention(range: NSRange, text insert: String) {
        let ns = NSMutableString(string: composer.text ?? "")
        ns.replaceCharacters(in: range, with: insert)
        composer.text = ns as String
        composer.selectedRange = NSRange(location: range.location + insert.utf16.count, length: 0)
        var value = draft
        value.text = composer.text
        session.drafts[conversation.id] = value
        renderedDraft = value
        session.saveSoon()
        sendButton.isEnabled = canSend
        hideSuggestions()
    }
    private func showSuggestions(_ items: [Suggestion], interactive: Bool = true) {
        suggestionList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, item) in items.enumerated() {
            var config = UIButton.Configuration.plain()
            config.title = item.title
            config.subtitle = item.detail.isEmpty ? nil : item.detail
            config.titleTextAttributesTransformer = .init { incoming in
                var outgoing = incoming
                outgoing.font = .preferredFont(forTextStyle: .callout)
                outgoing.foregroundColor = .label
                return outgoing
            }
            config.subtitleTextAttributesTransformer = .init { incoming in
                var outgoing = incoming
                outgoing.font = .preferredFont(forTextStyle: .caption1)
                outgoing.foregroundColor = .secondaryLabel
                return outgoing
            }
            config.titleAlignment = .leading
            config.contentInsets = .init(top: 5, leading: 14, bottom: 5, trailing: 14)
            let button = UIButton(configuration: config)
            button.contentHorizontalAlignment = .leading
            button.accessibilityIdentifier = "chat.suggestion.\(index)"
            button.isEnabled = interactive
            if interactive {
                button.addAction(UIAction { _ in item.apply() }, for: .touchUpInside)
            }
            suggestionList.addArrangedSubview(button)
        }
        suggestionBox.isHidden = items.isEmpty
    }
    private func hideSuggestions() {
        if !suggestionBox.isHidden { suggestionBox.isHidden = true }
    }
    private func modelMenu() -> UIMenu {
        let pref = session.preferences(for: conversation)
        let models = session.models[conversation.provider + ":" + conversation.workspace] ?? []
        var modelActions: [UIMenuElement] = [
            UIAction(title: "Provider 默认", state: pref.model.isEmpty ? .on : .off) { [weak self] _ in
                self?.configure { $0.model = "" }
            }
        ]
        modelActions += models.map { model in
            let id = model["id"].stringValue
            return UIAction(
                title: model["name"].optionalString ?? model["displayName"].optionalString ?? id,
                state: pref.model == id ? .on : .off
            ) { [weak self] _ in self?.configure { $0.model = id } }
        }
        modelActions.append(
            UIAction(title: "输入模型 ID…") { [weak self] _ in
                self?.askText(title: "模型 ID", value: pref.model) { id in self?.configure { $0.model = id } }
            })
        var values: [UIMenuElement] = [UIMenu(title: "模型", children: modelActions)]
        let model = models.first { $0["id"] == .string(pref.model) }
        let efforts = model?["supportedReasoningEfforts"].arrayValue ?? []
        let reasoning = efforts.map { value -> UIMenuElement in
            let id = value.optionalString ?? value["reasoningEffort"].optionalString ?? value["id"].stringValue
            return UIAction(title: id, state: pref.reasoningEffort == id ? .on : .off) { [weak self] _ in
                self?.configure { $0.reasoningEffort = id }
            }
        }
        if !reasoning.isEmpty { values.append(UIMenu(title: "思考深度", children: reasoning)) }
        if conversation.provider == "codex" {
            values.append(UIAction(title: "Fast · 后端暂不支持", attributes: .disabled) { _ in })
        }
        return UIMenu(children: values)
    }
    private func permissionMenu() -> UIMenu {
        let pref = session.preferences(for: conversation)
        let capability = session.provider(for: conversation)?.capabilities ?? .null
        let permissions = capability["permissionConfig"]["modes"].arrayValue.map { value -> UIMenuElement in
            let id = value.stringValue
            let title = ["ask": "按需审批", "auto": "自动审批", "full-access": "完全访问"][id] ?? id
            return UIAction(title: title, state: pref.permissionMode == id ? .on : .off) { [weak self] _ in
                guard let self else { return }
                if id == "full-access" {
                    confirm(
                        title: "启用完全访问？",
                        message:
                            "后续任务可获得当前 Agent 支持的最高权限。\n\(capability["permissionConfig"]["description"].stringValue)"
                    ) { self.configure { $0.permissionMode = id } }
                } else {
                    configure { $0.permissionMode = id }
                }
            }
        }
        return UIMenu(children: permissions)
    }
    private func workModeMenu() -> UIMenu {
        let pref = session.preferences(for: conversation)
        return UIMenu(children: [
            UIAction(title: "执行", state: pref.workMode == "implement" ? .on : .off) { [weak self] _ in
                self?.configure { $0.workMode = "implement" }
            },
            UIAction(title: "计划", state: pref.workMode == "plan" ? .on : .off) { [weak self] _ in
                self?.configure { $0.workMode = "plan" }
            },
        ])
    }
    private func moreMenu() -> UIMenu {
        let capability = session.provider(for: conversation)?.capabilities ?? .null
        var values: [UIMenuElement] = [
            UIAction(title: "查看实际配置") { [weak self] _ in
                guard let self else { return }
                let runtime = session.runtimes[conversation.id]
                WBUI.textSheet(
                    on: self, title: "当前配置",
                    text:
                        "状态：\(runtime?.configurationStatus ?? "unknown")\n\n请求权限\n\(runtime?.requestedConfig.prettyPrinted ?? "未知")\n\n实际配置\n\(runtime?.effectiveConfig.prettyPrinted ?? "未知")\n\n\(capability["permissionConfig"]["description"].stringValue)"
                )
            }
        ]
        let supported = capability["controlActions"].arrayValue.compactMap(\.optionalString)
        for (action, label) in [("retry", "重试上一轮"), ("fork", "从此处分叉"), ("compact", "压缩上下文")]
        where supported.contains(action) {
            values.append(UIAction(title: label) { [weak self] _ in self?.performControl(action) })
        }
        if supported.contains("steer") {
            values.append(
                UIAction(title: "引导当前任务…") { [weak self] _ in
                    self?.askText(title: "引导当前任务", placeholder: "补充方向") { self?.steer($0) }
                })
        }
        if supported.contains("queue") {
            values.append(UIAction(title: "后端原生队列…") { [weak self] _ in self?.nativeQueue() })
        }
        return UIMenu(children: values)
    }
    private func configure(_ update: (inout ConversationPreferences) -> Void) {
        var value = session.preferences(for: conversation)
        update(&value)
        session.updatePreferences(value, for: conversation)
        if session.runtimes[conversation.id]?.status == "running",
            session.provider(for: conversation)?.capabilities["liveConfiguration"].boolValue == true
        {
            let control: JSONValue = [
                "action": "configure", "model": value.model.isEmpty ? .null : .string(value.model),
                "reasoningEffort": value.reasoningEffort.isEmpty ? .null : .string(value.reasoningEffort),
            ]
            Task { [weak self] in
                guard let self else { return }
                do { _ = try await session.liveControl(control, conversation: conversation) } catch { showError(error) }
            }
        }
        reload()
    }
    private func performControl(_ action: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await session.control(action, conversation: conversation)
                try await session.refresh()
                if action == "fork", let id = result["conversationId"].optionalString,
                    let next = session.conversations.first(where: { $0.id == id })
                {
                    session.select(next)
                    navigationController?.pushViewController(
                        ConversationContainerController(session: session, conversation: next), animated: true)
                }
            } catch { showError(error) }
        }
    }
    private func steer(_ text: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await session.liveControl(
                    ["action": "steer", "text": .string(text)], conversation: conversation)
            } catch { showError(error) }
        }
    }
    private func nativeQueue() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await session.liveControl(["action": "queueList"], conversation: conversation)
                let sheet = UIAlertController(
                    title: "后端原生队列", message: result.prettyPrinted, preferredStyle: .actionSheet)
                sheet.addAction(
                    UIAlertAction(title: "添加消息", style: .default) { [weak self] _ in
                        self?.askText(title: "队列消息") { text in
                            self?.queueControl([
                                "action": "queueAdd", "itemId": .string(UUID().uuidString), "text": .string(text),
                            ])
                        }
                    })
                for item in result["items"].arrayValue {
                    sheet.addAction(
                        UIAlertAction(title: "移除：\(item["text"].stringValue.prefix(40))", style: .destructive) {
                            [weak self] _ in self?.queueControl(["action": "queueRemove", "itemId": item["itemId"]])
                        })
                }
                sheet.addAction(
                    UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
                        self?.queueControl(["action": "queueClear"])
                    })
                WBUI.presentSheet(sheet, on: self)
            } catch { showError(error) }
        }
    }
    private func queueControl(_ value: JSONValue) {
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await session.liveControl(value, conversation: conversation) } catch { showError(error) }
        }
    }
    private func showQueue() {
        let sheet = UIAlertController(title: "候选消息", message: "当前任务结束后按顺序发送；后台或断线后暂停。", preferredStyle: .actionSheet)
        if session.pausedQueues.contains(conversation.id) {
            sheet.addAction(
                UIAlertAction(title: "恢复发送", style: .default) { [weak self] _ in
                    guard let self else { return }
                    session.resumeQueue(conversation)
                })
        } else {
            sheet.addAction(
                UIAlertAction(title: "暂停", style: .default) { [weak self] _ in
                    guard let self else { return }
                    session.pausedQueues.insert(conversation.id)
                    session.changed()
                })
        }
        for item in session.queues[conversation.id] ?? [] {
            sheet.addAction(
                UIAlertAction(title: "编辑：\(item.draft.text.prefix(35))", style: .default) { [weak self] _ in
                    guard let self else { return }
                    guard draft.isEmpty else {
                        showNotice(title: "输入框已有草稿", message: "先发送或保存当前草稿，再编辑候选消息。")
                        return
                    }
                    session.removeQueued(item.id, conversationId: conversation.id)
                    setDraft(item.draft)
                })
            sheet.addAction(
                UIAlertAction(title: "删除：\(item.draft.text.prefix(35))", style: .destructive) { [weak self] _ in
                    guard let self else { return }
                    session.removeQueued(item.id, conversationId: conversation.id)
                })
        }
        WBUI.presentSheet(sheet, on: self)
    }
    private func showUnknown(_ pending: PendingSend) {
        let sheet = UIAlertController(
            title: "消息提交结果待核对", message: "\(pending.draft.text.prefix(300))\n\n网络中断可能发生在后端接收之后。核对历史不会再次发送消息。",
            preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: "同步并核对", style: .default) { [weak self] _ in
                Task { [weak self] in
                    guard let self else { return }
                    do { try await session.reconcile(conversation.id) } catch { showError(error) }
                }
            })
        sheet.addAction(
            UIAlertAction(title: "恢复为草稿", style: .destructive) { [weak self] _ in
                guard let self else { return }
                guard draft.isEmpty else {
                    showNotice(title: "输入框已有草稿", message: "先处理当前草稿，再恢复待核对消息。")
                    return
                }
                confirm(title: "恢复原消息？", message: "之后手动发送可能产生重复任务。请先核对后端记录。") {
                    self.session.restoreUnknownAsDraft(self.conversation.id)
                }
            })
        WBUI.presentSheet(sheet, on: self)
    }
    private func pickFiles() {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.text, .json, .sourceCode, .image], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for url in urls {
            do {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let type = UTType(filenameExtension: url.pathExtension)
                try addAttachment(data, name: url.lastPathComponent, mime: type?.preferredMIMEType ?? "text/plain")
            } catch { showError(error) }
        }
    }
    private func pickPhotos() {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 4
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        for result in results {
            result.itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) {
                [weak self] data, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        if let error { throw error }
                        guard let data, data.count <= 32 * 1024 * 1024,
                            let source = CGImageSourceCreateWithData(
                                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                                source, 0,
                                [
                                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                    kCGImageSourceThumbnailMaxPixelSize: 1600,
                                ] as CFDictionary),
                            let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.8)
                        else {
                            throw TodexError.invalid("无法读取图片，或图片超过 32 MB")
                        }
                        try addAttachment(jpeg, name: "图片.jpg", mime: "image/jpeg")
                    } catch { showError(error) }
                }
            }
        }
    }
    private func addAttachment(_ data: Data, name: String, mime: String) throws {
        guard draft.attachments.count < 6, data.count + draft.attachments.reduce(0, { $0 + $1.data.count }) <= 2_500_000
        else { throw TodexError.invalid("附件总大小需小于 2.5 MB，最多 6 个") }
        if mime.hasPrefix("image/") {
            guard session.provider(for: conversation)?.capabilities["imageInput"].boolValue == true else {
                throw TodexError.invalid("当前 Agent 未提供图片输入能力")
            }
        } else {
            guard String(data: data, encoding: .utf8) != nil else { throw TodexError.invalid("文本附件须使用 UTF-8 编码") }
        }
        var value = draft
        value.attachments.append(.init(name: name, mimeType: mime, data: data))
        setDraft(value)
    }
}
