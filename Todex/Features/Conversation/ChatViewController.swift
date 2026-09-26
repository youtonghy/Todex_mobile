import ImageIO
import PhotosUI
import TodexCore
import UIKit
import UniformTypeIdentifiers

final class ChatViewController: UIViewController, UITextViewDelegate, UIGestureRecognizerDelegate,
    UIDocumentPickerDelegate, PHPickerViewControllerDelegate
{
    private let session: AppSession
    private let conversation: ConversationManifest
    private let timeline = TimelineViewController()
    private let composer = ComposerTextView()
    /// Container-provided panels for `/diff` and `/skills` / `/mcp`.
    var openGit: (() -> Void)?
    var openCatalog: (() -> Void)?
    private let contextButton = UIButton(type: .system)
    /// Desktop ConversationRunStatus: a running turn quiet for 2 minutes on
    /// this client (not by replayed timestamps) gets a possibly-stuck notice.
    private var quietKey = ""
    private var quietSince = Date()
    private var stallTicker: Task<Void, Never>?
    private static let stallInterval: TimeInterval = 120
    /// One-shot notices (compaction finished) shown in the alert area.
    private var transientNotice: (text: String, color: UIColor, until: Date)?
    private var noticedCompaction: String?
    private let placeholder = Theme.label(String(localized: "描述你的任务"), color: .placeholderText)
    private let status = Theme.label(String(localized: "正在同步…"), style: .caption1, color: .secondaryLabel)
    private let chips = UIStackView()
    private let alerts = UIStackView()
    private let modelChip = Theme.chip(String(localized: "模型"), icon: "cpu")
    private let permissionChip = UIButton(configuration: Theme.iconChipConfiguration(icon: "hand.raised.fill", tint: .systemOrange))
    private let workModeChip = UIButton(configuration: Theme.iconChipConfiguration(icon: "bolt.fill", tint: Theme.accent))
    private let moreChip = Theme.iconButton("ellipsis", pointSize: 11)
    private var sendButton: UIButton!
    private var stopButton: UIButton!
    private var observer: UUID?
    private var contentSizeObserver: NSObjectProtocol?
    private var capsuleCache: [String: MessageAttachment] = [:]
    private var wasConnected = false
    private let suggestionBox = UIView()
    private let suggestionList = UIStackView()
    private var mentionTask: Task<Void, Never>?
    private var skillCatalog: [JSONValue]?
    private var mcpCatalog: [JSONValue]?
    private var skillCatalogTask: Task<Void, Never>?
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
    isolated deinit {
        if let observer { session.removeObserver(observer) }
        if let contentSizeObserver { NotificationCenter.default.removeObserver(contentSizeObserver) }
        stallTicker?.cancel()
    }
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
        timeline.addReference = { [weak self] in self?.addReference($0) }
        timeline.loadActivity = { [weak self] key, from, to in
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.session.hydrateActivity(
                        conversationId: self.conversation.id, from: from, to: to)
                } catch {
                    self.timeline.activityLoadFailed(key)
                }
            }
        }
        timeline.previewSentAttachment = { [weak self] in self?.previewSent($0) }
        timeline.loadEarlier = { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.session.loadEarlier(self.conversation.id)
                } catch {
                    self.timeline.historyLoadFailed()
                }
            }
        }
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
        contentSizeObserver = NotificationCenter.default.addObserver(
            forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.contentSizeCategoryChanged() }
        }
        composer.accessibilityLabel = String(localized: "消息输入框")
        composer.accessibilityIdentifier = "chat.composer"
        composer.textContainerInset = .init(top: 5, left: 6, bottom: 5, right: 6)
        composer.heightAnchor.constraint(equalToConstant: 75).isActive = true
        composer.onPaste = { [weak self] in self?.handlePaste($0) ?? false }
        // Only claim taps that land on a reference token. If this recognizer
        // were allowed to recognize ordinary taps it would pre-empt the text
        // view's own tap handling and the keyboard would never appear.
        let locateTap = UITapGestureRecognizer(target: self, action: #selector(composerTapped(_:)))
        locateTap.cancelsTouchesInView = false
        locateTap.delegate = self
        composer.addGestureRecognizer(locateTap)
        let dismiss = UIToolbar()
        dismiss.items = [
            .flexibleSpace(),
            UIBarButtonItem(
                title: String(localized: "收起键盘"), image: nil,
                primaryAction: UIAction { [weak composer] _ in composer?.resignFirstResponder() }),
        ]
        dismiss.sizeToFit()
        composer.inputAccessoryView = dismiss
        placeholder.isUserInteractionEnabled = false
        composer.addSubview(placeholder)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(
                equalTo: composer.leadingAnchor,
                constant: composer.textContainerInset.left + composer.textContainer.lineFragmentPadding),
            placeholder.topAnchor.constraint(
                equalTo: composer.topAnchor, constant: composer.textContainerInset.top),
        ])
        inputStack.addArrangedSubview(composer)
        let expand = Theme.iconButton("arrow.up.left.and.arrow.down.right", pointSize: 12)
        expand.accessibilityLabel = String(localized: "全屏编辑")
        expand.accessibilityIdentifier = "chat.composer.expand"
        expand.addAction(
            UIAction { [weak self] _ in self?.presentFullscreenComposer() }, for: .touchUpInside)
        glass.contentView.addSubview(expand)
        expand.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            expand.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -5),
            expand.topAnchor.constraint(equalTo: composer.topAnchor, constant: 2),
        ])
        let attach = Theme.iconButton("plus")
        attach.accessibilityLabel = String(localized: "附件")
        attach.showsMenuAsPrimaryAction = true
        attach.menu = UIMenu(children: [
            UIAction(title: String(localized: "照片"), image: Theme.icon("photo")) { [weak self] _ in self?.pickPhotos() },
            UIAction(title: String(localized: "文件"), image: Theme.icon("doc")) { [weak self] _ in self?.pickFiles() },
        ])
        for chip in [modelChip, permissionChip, workModeChip, moreChip] {
            chip.showsMenuAsPrimaryAction = true
            chip.setContentHuggingPriority(.required, for: .horizontal)
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        moreChip.accessibilityLabel = String(localized: "更多控制")
        stopButton = Theme.button(String(localized: "停止"), icon: "stop.fill") { [weak self] in self?.performControl("cancel") }
        sendButton = Theme.button(String(localized: "发送"), icon: "arrow.up", prominent: true) { [weak self] in self?.submit() }
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
        contextButton.accessibilityIdentifier = "chat.context"
        contextButton.addAction(UIAction { [weak self] _ in self?.showContextUsage() }, for: .touchUpInside)
        for button in [contextButton, attach, stopButton!, sendButton!] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let toolbar = UIStackView(arrangedSubviews: [selectorScroll, contextButton, attach, stopButton, sendButton])
        toolbar.axis = .horizontal
        toolbar.spacing = 6
        toolbar.alignment = .center
        inputStack.addArrangedSubview(toolbar)
        stack.addArrangedSubview(footer)
        timeline.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        observer = session.observe { [weak self] in self?.reload() }
        reload()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Keep the first lines clear of the floating expand button.
        let width = composer.textContainer.size.width
        composer.textContainer.exclusionPaths =
            width > 96
            ? [
                UIBezierPath(
                    rect: CGRect(
                        x: width - 30, y: -composer.textContainerInset.top, width: 38,
                        height: 36))
            ]
            : []
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        session.viewingConversationID = conversation.id
        // Model catalogs are discovered live by the backend; refresh whenever the
        // conversation is shown again so CLI config edits are reflected.
        Task { [weak self] in
            guard let self, self.session.isConnected else { return }
            try? await self.session.loadModels(for: self.conversation)
            try? await self.session.loadCommands(for: self.conversation)
        }
        // Re-evaluates time-based notices (stall, one-shot) without new events.
        stallTicker?.cancel()
        stallTicker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self else { return }
                // Only time-based notices need a tick; an idle reload would also
                // steal VoiceOver focus from the rebuilt alert buttons.
                let running = self.session.runtimes[self.conversation.id]?.status == "running"
                if running || self.transientNotice != nil { self.reload() }
            }
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if session.viewingConversationID == conversation.id { session.viewingConversationID = nil }
        stallTicker?.cancel()
        stallTicker = nil
        session.persist()
    }
    override var keyCommands: [UIKeyCommand]? {
        // iPad hardware keyboards: ⌘↩ sends, ⌘. stops the running turn.
        [
            UIKeyCommand(title: String(localized: "发送"), action: #selector(sendShortcut), input: "\r", modifierFlags: .command),
            UIKeyCommand(title: String(localized: "停止"), action: #selector(stopShortcut), input: ".", modifierFlags: .command),
        ]
    }
    @objc private func sendShortcut() { submit() }
    @objc private func stopShortcut() {
        guard !stopButton.isHidden, stopButton.isEnabled else { return }
        performControl("cancel")
    }
    func insert(_ text: String) {
        var value = draft
        value.text += (value.text.isEmpty ? "" : "\n") + text
        setDraft(value)
    }
    func addReference(_ attachment: MessageAttachment) {
        var value = draft
        guard value.attachments.count < 6 else {
            status.text = String(localized: "附件最多 6 个，请先移除部分附件后再添加引用")
            return
        }
        let preview = Self.referencePreview(of: String(decoding: attachment.data, as: UTF8.self))
        let base = preview.isEmpty ? attachment.name : preview
        var reference = attachment
        reference.name = uniqueName(base, isImage: false, isReference: true, in: value)
        insert(reference, into: &value)
        setDraft(value)
        focusCaret(after: reference.id)
    }
    /// Toggles the chip like the desktop `#` picker: choosing an attached
    /// skill detaches it again.
    func insertSkill(_ id: String, name: String) {
        var value = draft
        if value.skills.contains(where: { $0.id == id }) {
            value.skills.removeAll { $0.id == id }
        } else {
            value.skills.append(.init(id: id, name: name))
        }
        setDraft(value)
    }
    private func setDraft(_ value: ComposerDraft) {
        session.drafts[conversation.id] = value
        session.saveSoon()
        reload()
    }
    /// Insert a token at the caret so every glyph shares one plain-text source
    /// of truth. Names stay unique because the token is the only lookup key.
    /// A capsule never touches adjacent glyphs, matching the desktop composer.
    private func insert(_ attachment: MessageAttachment, into value: inout ComposerDraft) {
        var text = value.text
        let offset = min(max(insertionOffset(in: value), 0), text.utf16.count)
        let at = String.Index(
            text.utf16.index(text.utf16.startIndex, offsetBy: offset), within: text
        ) ?? text.endIndex
        let lead = at > text.startIndex && text[..<at].last?.isWhitespace == false ? " " : ""
        let tail = at < text.endIndex && text[at].isWhitespace == false ? " " : ""
        text.insert(contentsOf: "\(lead)\(attachment.token)\(tail)", at: at)
        value.text = text
        value.attachments.append(attachment)
    }
    /// UTF-16 offset in `value.text` matching the composer's current selection.
    private func insertionOffset(in value: ComposerDraft) -> Int {
        guard let attributed = composer.attributedText, attributed.length > 0,
            composer.selectedRange.location != NSNotFound
        else { return value.text.utf16.count }
        let location = min(max(composer.selectedRange.location, 0), attributed.length)
        return ComposerText.plain(attributed, range: NSRange(location: 0, length: location)).utf16.count
    }
    private func focusCaret(after attachmentId: String) {
        guard let attributed = composer.attributedText else { return }
        var target: Int?
        attributed.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: attributed.length)
        ) { value, range, stop in
            if let capsule = value as? ComposerCapsuleAttachment, capsule.attachmentId == attachmentId {
                target = range.location + range.length
                stop.pointee = true
            }
        }
        guard let target else { return }
        composer.selectedRange = NSRange(location: target, length: 0)
        composer.becomeFirstResponder()
    }
    private func uniqueName(
        _ base: String, isImage: Bool, isReference: Bool, in value: ComposerDraft
    ) -> String {
        let taken = Set(value.attachments.map(\.name))
        var name = base
        var index = 2
        while taken.contains(name)
            || value.text.contains(
                MessageAttachment.token(name: name, isImage: isImage, isReference: isReference))
        {
            name = "\(base) \(index)"
            index += 1
        }
        return name
    }
    func textViewDidChange(_ textView: UITextView) {
        let attributed = textView.attributedText ?? NSAttributedString()
        let text = ComposerText.plain(attributed)
        var present = Set<String>()
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) {
            value, _, _ in
            if let capsule = value as? ComposerCapsuleAttachment { present.insert(capsule.attachmentId) }
        }
        var value = draft
        value.text = text
        // Tokens are the source of truth: drop records that no longer appear.
        var retained = draft.attachments.filter { text.contains($0.token) }
        for id in present where !retained.contains(where: { $0.id == id }) {
            if let cached = capsuleCache[id] { retained.append(cached) }
        }
        value.attachments = retained
        session.drafts[conversation.id] = value
        renderedDraft = value
        session.saveSoon()
        placeholder.isHidden = !text.isEmpty
        sendButton.isEnabled = canSend
        updateSuggestions()
    }
    private func contentSizeCategoryChanged() {
        composer.font = .preferredFont(forTextStyle: .body)
        resetTypingAttributes()
        render(normalizedDraft())
    }
    func textViewDidChangeSelection(_ textView: UITextView) {
        resetTypingAttributes()
        updateSuggestions()
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UITapGestureRecognizer else { return true }
        return capsuleHit(at: gestureRecognizer.location(in: composer)) != nil
    }
    @objc private func composerTapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let hit = capsuleHit(at: gesture.location(in: composer))
        else { return }
        if hit.isDelete {
            removeCapsule(id: hit.capsule.attachmentId)
            return
        }
        previewCapsule(hit.capsule)
    }
    /// Capsule under `point` (composer coordinates) plus whether the tap landed
    /// on its trailing delete zone.
    private func capsuleHit(at point: CGPoint)
        -> (capsule: ComposerCapsuleAttachment, isDelete: Bool)?
    {
        guard composer.textStorage.length > 0, let range = composer.characterRange(at: point)
        else { return nil }
        let location = composer.offset(from: composer.beginningOfDocument, to: range.start)
        guard location >= 0, location < composer.textStorage.length,
            let capsule = composer.textStorage.attribute(.attachment, at: location, effectiveRange: nil)
                as? ComposerCapsuleAttachment
        else { return nil }
        let glyphRange = composer.layoutManager.glyphRange(
            forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
        var rect = composer.layoutManager.boundingRect(
            forGlyphRange: glyphRange, in: composer.textContainer)
        rect.origin.x += composer.textContainerInset.left
        rect.origin.y += composer.textContainerInset.top
        guard rect.contains(point) else { return nil }
        return (capsule, point.x >= rect.maxX - capsule.deleteZoneWidth)
    }
    /// Remove one capsule as a single undoable edit, keeping the caret in place.
    private func removeCapsule(id: String) {
        guard let attributed = composer.attributedText else { return }
        var target: NSRange?
        attributed.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: attributed.length)
        ) { value, range, stop in
            if let capsule = value as? ComposerCapsuleAttachment, capsule.attachmentId == id {
                target = range
                stop.pointee = true
            }
        }
        guard let target,
            let start = composer.position(from: composer.beginningOfDocument, offset: target.location),
            let end = composer.position(from: start, offset: target.length),
            let textRange = composer.textRange(from: start, to: end)
        else { return }
        composer.replace(textRange, withText: "")
        composer.becomeFirstResponder()
    }
    /// Tapping a capsule body opens a modal preview; the trailing zone still deletes.
    private func previewCapsule(_ capsule: ComposerCapsuleAttachment) {
        guard let attachment = draft.attachments.first(where: { $0.id == capsule.attachmentId })
            ?? capsuleCache[capsule.attachmentId]
            ?? draft.attachments.first(where: { $0.name == capsule.name })
        else { return }
        if attachment.isImage, let image = UIImage(data: attachment.data) {
            presentImagePreview(image, named: attachment.name)
            return
        }
        var actions: [(String, @MainActor (String) -> Void)] = []
        if let reference = attachment.reference {
            if let path = reference.path, !path.isEmpty {
                actions.append((String(localized: "打开文件"), { [weak self] _ in self?.openFile?(path) }))
            } else if let messageId = reference.messageId {
                actions.append((String(localized: "跳到消息"), { [weak self] _ in self?.timeline.scrollToMessage(messageId) }))
            }
        }
        let excerpt = String(decoding: attachment.data, as: UTF8.self)
        // Desktop parity: a pasted or picked text file can be edited before
        // sending. References stay read-only; they quote a source.
        if attachment.isImage {
            showNotice(title: attachment.name, message: String(localized: "无法预览此图片。"))
            return
        }
        if attachment.reference == nil {
            WBUI.textSheet(
                on: self, title: attachment.name, text: excerpt, editable: true,
                actions: [(String(localized: "保存修改"), { @MainActor [weak self] text in self?.updateAttachmentText(attachment.id, text) })])
            return
        }
        let location = attachment.reference?.location ?? ""
        var parts = location.isEmpty ? [] : [location]
        parts.append(excerpt.isEmpty ? String(localized: "（没有可预览的内容）") : excerpt)
        WBUI.textSheet(on: self, title: attachment.name, text: parts.joined(separator: "\n\n"), actions: actions)
    }
    private func updateAttachmentText(_ id: String, _ text: String) {
        var value = draft
        guard let index = value.attachments.firstIndex(where: { $0.id == id }) else { return }
        let data = Data(text.utf8)
        let others = value.attachments.enumerated().filter { $0.offset != index }.reduce(0) { $0 + $1.element.data.count }
        guard data.count + others <= 2_500_000 else {
            showError(TodexError.invalid(String(localized: "附件总大小需小于 2.5 MB")))
            return
        }
        value.attachments[index].data = data
        setDraft(value)
    }
    private func presentImagePreview(_ image: UIImage, named name: String) {
        let page = UIViewController()
        page.title = name
        page.view.backgroundColor = .systemBackground
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        page.view.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.bottomAnchor),
        ])
        let nav = UINavigationController(rootViewController: page)
        page.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
        WBUI.presentModal(nav, on: self)
    }
    /// First non-empty line of the excerpt, whitespace-collapsed, truncated for the token label.
    static func referencePreview(of excerpt: String, max: Int = 10) -> String {
        let line = excerpt.split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces) } ?? ""
        return line.count > max ? String(line.prefix(max)) + "…" : line
    }
    private func resetTypingAttributes() {
        composer.typingAttributes = [
            .font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label,
        ]
    }
    private func styledComposerText(_ draft: ComposerDraft) -> NSAttributedString {
        let styled = NSMutableAttributedString(
            string: draft.text,
            attributes: [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label])
        for attachment in draft.attachments {
            // Replace every occurrence: a pasted token duplicate must also
            // render as a capsule, not editable raw text.
            var search = NSRange(location: 0, length: styled.length)
            while true {
                let found = (styled.string as NSString).range(of: attachment.token, range: search)
                guard found.location != NSNotFound else { break }
                let capsule = ComposerCapsuleAttachment(
                    attachment: attachment, font: .preferredFont(forTextStyle: .body))
                styled.replaceCharacters(in: found, with: NSAttributedString(attachment: capsule))
                search = NSRange(
                    location: found.location + 1, length: styled.length - found.location - 1)
            }
        }
        return styled
    }
    private var canSend: Bool {
        session.isConnected && session.runtimes[conversation.id]?.readyForActions == true && !draft.isEmpty
            && !submitting && !switchingAgent && session.pendingSends[conversation.id] == nil
    }
    /// Legacy drafts stored records without tokens in the text; materialize the
    /// missing tokens once so their capsules survive a round trip.
    private func normalizedDraft() -> ComposerDraft {
        var value = draft
        let missing = value.attachments.filter { !value.text.contains($0.token) }
        guard !missing.isEmpty else { return value }
        for attachment in missing {
            value.text += (value.text.isEmpty ? "" : "\n") + attachment.token
        }
        session.drafts[conversation.id] = value
        session.saveSoon()
        return value
    }
    private func render(_ value: ComposerDraft) {
        composer.attributedText = styledComposerText(value)
        renderedDraft = value
        capsuleCache = Dictionary(uniqueKeysWithValues: value.attachments.map { ($0.id, $0) })
        composer.accessibilityValue = value.text
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
            String(localized: "\(conversation.provider) · \(session.isConnected ? runtime?.readyForActions == true ? (running ? String(localized: "正在进行") : String(localized: "已同步")) : String(localized: "正在补齐记录") : session.status)")
        timeline.update(
            runtime?.messages ?? [], provider: session.provider(for: conversation)?.displayName ?? conversation.provider,
            sentAttachments: session.sentAttachments(for: conversation.id),
            usage: runtime?.usageRecords ?? [],
            hasEarlier: session.hasEarlierHistory(conversation.id),
            loadingEarlier: session.isLoadingEarlier(conversation.id)
        )
        let value = normalizedDraft()
        if renderedDraft != value {
            render(value)
        }
        placeholder.isHidden = !value.text.isEmpty
        composer.accessibilityHint = value.isEmpty ? String(localized: "描述你的任务") : nil
        sendButton.configuration?.title = running ? String(localized: "加入队列") : String(localized: "发送")
        sendButton.isEnabled = canSend
        stopButton.isHidden = !running
        stopButton.isEnabled = session.isConnected && runtime?.readyForActions == true
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for skill in draft.skills {
            chips.addArrangedSubview(
                Theme.button(String(localized: "$\(skill.name) · 移除"), icon: "sparkles") { [weak self] in
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
                Theme.button(String(localized: "消息等待核对 · 查看"), icon: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90") {
                    [weak self] in self?.showUnknown(pending)
                })
        }
        // Desktop lists every pending approval above the composer; show up to
        // three and summarize the rest so the timeline keeps its space.
        let permissions = runtime?.pendingPermissions ?? []
        for (index, permission) in permissions.prefix(3).enumerated() {
            let title = permission.payload["title"].optionalString ?? String(localized: "需要你的审批")
            let button = Theme.button(
                permission.isSessionScoped ? String(localized: "\(title) · 会话") : title, icon: "hand.raised.fill", prominent: index == 0
            ) { [weak self] in self?.presentPermission(permission) }
            button.isEnabled = session.isConnected && runtime?.readyForActions == true
            button.accessibilityIdentifier = index == 0 ? "chat.permission" : "chat.permission.\(index)"
            alerts.addArrangedSubview(button)
        }
        if permissions.count > 3 {
            alerts.addArrangedSubview(
                Theme.button(String(localized: "另有 \(permissions.count - 3) 项审批"), icon: "list.bullet") { [weak self] in
                    self?.showAllPermissions()
                })
        }
        let nativeItems = (runtime?.queueItems ?? []).filter {
            ["queued", "pending", "delivering", "unknown"].contains($0["status"].stringValue)
        }
        if !nativeItems.isEmpty {
            alerts.addArrangedSubview(
                Theme.button(
                    String(localized: "Agent 队列 \(nativeItems.count) 条\(runtime?.queuePaused == true ? String(localized: " · 已暂停，请核对") : "")"),
                    icon: "tray.full"
                ) { [weak self] in self?.nativeQueue() })
        }
        if let items = session.queues[conversation.id], !items.isEmpty {
            let paused = session.pausedQueues.contains(conversation.id)
            alerts.addArrangedSubview(
                Theme.button(
                    String(localized: "候选消息 \(items.count) 条\(paused ? String(localized: " · 已暂停") : "")"),
                    icon: "text.line.first.and.arrowtriangle.forward"
                ) { [weak self] in self?.showQueue() })
            // A paused queue's failure reason would otherwise only show offline.
            if paused, session.isConnected, let error = session.lastError {
                alerts.addArrangedSubview(Theme.label(String(localized: "候选消息未发送：\(error)"), style: .caption1, color: .systemOrange))
            }
        }
        addRuntimeNotices(runtime, running: running)
        if let error = session.storageError ?? (session.isConnected ? nil : session.lastError) {
            alerts.addArrangedSubview(Theme.label(error, style: .caption1, color: .systemOrange))
        }
        alerts.isHidden = alerts.arrangedSubviews.isEmpty
        let models = session.models[conversation.provider + ":" + conversation.workspace] ?? []
        let modelTitle =
            pref.model.isEmpty
            ? models.first { $0["isDefault"].boolValue }.map { String(localized: "默认 · ") + Self.modelName($0) } ?? String(localized: "默认模型")
            : models.first { $0["id"].stringValue == pref.model }.map(Self.modelName) ?? pref.model
        modelChip.configuration = Theme.chipConfiguration(
            title: modelTitle, icon: "cpu",
            detail: pref.reasoningEffort.isEmpty ? nil : "· \(pref.reasoningEffort)")
        modelChip.accessibilityLabel = String(localized: "模型：\(modelTitle)")
        modelChip.menu = modelMenu()
        let capability = session.provider(for: conversation)?.capabilities ?? .null
        let permissionStyle = Self.permissionStyle(pref.permissionMode)
        permissionChip.configuration = Theme.iconChipConfiguration(
            icon: permissionStyle.icon, tint: permissionStyle.color)
        permissionChip.accessibilityLabel = String(localized: "权限模式：\(permissionStyle.title)")
        permissionChip.isEnabled = !capability["permissionConfig"]["modes"].arrayValue.isEmpty
        permissionChip.menu = permissionMenu()
        let modes = capability["permissionConfig"]["modes"].arrayValue.compactMap(\.optionalString)
        if !modes.isEmpty, !modes.contains(pref.permissionMode) {
            // Desktop parity: an unsupported or unset mode is never sent silently.
            permissionChip.configuration = Theme.iconChipConfiguration(
                icon: "exclamationmark.triangle.fill", tint: .systemRed)
            permissionChip.accessibilityLabel = String(localized: "权限模式未选择，请重新选择")
        }
        updateContextButton(runtime)
        workModeChip.isHidden = !capability["permissionConfig"]["supportsPlan"].boolValue
        let workModeStyle = Self.workModeStyle(pref.workMode)
        workModeChip.configuration = Theme.iconChipConfiguration(
            icon: workModeStyle.icon, tint: workModeStyle.color)
        workModeChip.accessibilityLabel = String(localized: "工作模式：\(workModeStyle.title)")
        workModeChip.menu = workModeMenu()
        moreChip.menu = moreMenu()
        updateSuggestions()
    }
    /// Run-status notices (desktop ConversationRunStatus / ConversationControls):
    /// compaction progress and results, a context-size suggestion, a stalled
    /// turn, and a configuration the agent refused.
    private func addRuntimeNotices(_ runtime: ConversationRuntime?, running: Bool) {
        guard let runtime else { return }
        let compaction = runtime.compaction
        let supported = session.provider(for: conversation)?.capabilities["controlActions"].arrayValue
            .compactMap(\.optionalString) ?? []
        let compactionStatus = compaction["status"].stringValue
        let compactionKey = compaction["updatedAt"].stringValue
        // The first reload adopts the current state: reopening a conversation
        // must not announce a compaction that finished long ago.
        if noticedCompaction == nil { noticedCompaction = compactionKey }
        switch compactionStatus {
        case "running":
            alerts.addArrangedSubview(Theme.label(String(localized: "正在压缩上下文…"), style: .caption1, color: .secondaryLabel))
        case "failed" where compactionKey != noticedCompaction:
            let reason = compaction["error"].optionalString ?? String(localized: "上下文压缩失败")
            alerts.addArrangedSubview(Theme.label(String(localized: "上下文压缩失败：\(reason)"), style: .caption1, color: .systemRed))
        case "completed" where compactionKey != noticedCompaction:
            // Announce a finished compaction once, like the desktop toast.
            noticedCompaction = compactionKey
            transientNotice = (String(localized: "上下文压缩完成"), .systemGreen, Date().addingTimeInterval(6))
        default: break
        }
        // A later context build-up can recommend compacting again after any
        // earlier result, so this is independent of the last status.
        if compactionStatus != "running", compaction["recommended"].boolValue {
            let label = String(localized: "上下文已接近上限，建议压缩")
            alerts.addArrangedSubview(
                supported.contains("compact")
                    ? Theme.button("\(label) · \(String(localized: "压缩"))", icon: "arrow.down.right.and.arrow.up.left") {
                        [weak self] in self?.performControl("compact")
                    }
                    : Theme.label(label, style: .caption1, color: .secondaryLabel))
        }
        if let notice = transientNotice {
            if notice.until > Date() {
                alerts.addArrangedSubview(Theme.label(notice.text, style: .caption1, color: notice.color))
            } else {
                transientNotice = nil
            }
        }
        if runtime.configurationStatus == "rejected" {
            alerts.addArrangedSubview(
                Theme.label(String(localized: "配置未应用：\(runtime.configurationError)"), style: .caption1, color: .systemOrange))
        }
        // Quiet time is measured on this client so replayed timestamps and clock
        // skew cannot trigger it; known work (approvals, running tools,
        // compaction) is progress, not a stall.
        let key = [
            runtime.activeTurnId, runtime.lastProgressAt?.description ?? "", String(runtime.appliedSequence),
        ].joined(separator: "|")
        if key != quietKey {
            quietKey = key
            quietSince = Date()
        }
        let busy =
            !runtime.pendingPermissions.isEmpty || compaction["status"] == "running"
            || runtime.messages.contains { $0.turnId == runtime.activeTurnId && $0.category == "tool" && $0.status == "running" }
        if running, runtime.status == "running", runtime.readyForActions, session.isConnected, !busy,
            Date().timeIntervalSince(quietSince) >= Self.stallInterval
        {
            alerts.addArrangedSubview(
                Theme.button(String(localized: "超过 2 分钟没有新进展，可能仍在执行或已卡住 · 同步记录"), icon: "clock.badge.exclamationmark") {
                    [weak self] in
                    guard let self else { return }
                    Task { [weak self] in
                        guard let self else { return }
                        do { try await session.recover(conversation.id) } catch { showError(error) }
                    }
                })
        }
    }
    private func presentPermission(_ permission: PendingPermission) {
        let page = PermissionViewController(session: session, conversationId: conversation.id, permission: permission)
        present(UINavigationController(rootViewController: page), animated: true)
    }
    private func showAllPermissions() {
        let sheet = UIAlertController(title: String(localized: "待审批"), message: nil, preferredStyle: .actionSheet)
        for permission in session.runtimes[conversation.id]?.pendingPermissions ?? [] {
            sheet.addAction(
                UIAlertAction(title: permission.payload["title"].optionalString ?? String(localized: "需要你的审批"), style: .default) {
                    [weak self] _ in self?.presentPermission(permission)
                })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        WBUI.presentSheet(sheet, on: self)
    }
    /// Context window in use (desktop ContextUsageIndicator): runtime-reported
    /// usage over the provider's window, falling back to the model descriptor.
    private func contextUsage(_ runtime: ConversationRuntime?) -> (used: Double, window: Double?)? {
        guard let runtime, let used = runtime.compaction["usedTokens"].doubleValue else { return nil }
        let models = session.models[conversation.provider + ":" + conversation.workspace] ?? []
        let pref = session.preferences(for: conversation)
        let model =
            pref.model.isEmpty ? models.first { $0["isDefault"].boolValue } : models.first { $0["id"] == .string(pref.model) }
        let window = runtime.compaction["contextWindow"].doubleValue ?? model?["contextWindow"].doubleValue
        return (used, window.flatMap { $0 > 0 ? $0 : nil })
    }
    private func updateContextButton(_ runtime: ConversationRuntime?) {
        let usage = contextUsage(runtime)
        contextButton.isHidden = usage == nil
        guard let usage else { return }
        let fraction = usage.window.map { min(1, max(0, usage.used / $0)) }
        let size = CGSize(width: 20, height: 20)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2.5, dy: 2.5)
            let track = UIBezierPath(ovalIn: rect)
            track.lineWidth = 3
            UIColor.separator.setStroke()
            track.stroke()
            guard let fraction, fraction > 0 else { return }
            let arc = UIBezierPath(
                arcCenter: CGPoint(x: size.width / 2, y: size.height / 2), radius: rect.width / 2,
                startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * fraction, clockwise: true)
            arc.lineWidth = 3
            arc.lineCapStyle = .round
            (fraction >= 0.8 ? UIColor.systemOrange : Theme.accent).setStroke()
            arc.stroke()
        }
        contextButton.setImage(image.withRenderingMode(.alwaysOriginal), for: .normal)
        contextButton.accessibilityLabel =
            fraction.map { String(localized: "上下文已使用 \(Int(($0 * 100).rounded()))%") } ?? String(localized: "上下文用量等待模型窗口信息")
    }
    private func showContextUsage() {
        let runtime = session.runtimes[conversation.id]
        guard let usage = contextUsage(runtime) else { return }
        var lines = [
            usage.window.map {
                "\(UsageCalculation.format(usage.used)) / \(UsageCalculation.format($0)) tokens · "
                    + String(format: "%.1f%%", usage.used / $0 * 100)
            } ?? String(localized: "已用 \(UsageCalculation.format(usage.used)) tokens，模型窗口未知")
        ]
        if let latest = runtime?.usageRecords.first {
            let value = { (key: String) in UsageCalculation.number(latest, key).map(UsageCalculation.format) ?? String(localized: "未知") }
            lines.append(String(localized: "最近一次：输入 \(value("inputTokens")) · 输出 \(value("outputTokens"))"))
            lines.append(String(localized: "缓存读取 \(value("cachedInputTokens")) · 缓存写入 \(value("cacheWriteTokens"))"))
        }
        showNotice(title: String(localized: "上下文用量"), message: lines.joined(separator: "\n"))
    }
    /// Receipt preview for an already-sent attachment (desktop SentAttachmentPreview).
    private func previewSent(_ attachment: SentAttachment) {
        if attachment.kind == "image" {
            guard let preview = attachment.preview, let comma = preview.firstIndex(of: ","),
                let data = Data(base64Encoded: String(preview[preview.index(after: comma)...])),
                let image = UIImage(data: data)
            else {
                showNotice(title: attachment.name, message: String(localized: "缩略图已超出本地保存上限，无法预览。"))
                return
            }
            presentImagePreview(image, named: attachment.name)
            return
        }
        guard let text = attachment.textContent else {
            showNotice(title: attachment.name, message: String(localized: "内容已超出本地保存上限，无法预览。"))
            return
        }
        WBUI.textSheet(on: self, title: attachment.name, text: text.isEmpty ? String(localized: "（空文件）") : text, actions: [])
    }
    /// Desktop composer paste: images become attachments, and text longer
    /// than five lines becomes a text attachment capsule instead of a wall
    /// of composer text. Returns true when the paste was consumed.
    private func handlePaste(_ pasteboard: UIPasteboard) -> Bool {
        do {
            // Rich copies (spreadsheet cells, web selections) carry text and an
            // image rendition; the text is what the user meant.
            if let text = pasteboard.string, !text.isEmpty {
                let lines = text.replacingOccurrences(of: #"[\r\n]+$"#, with: "", options: .regularExpression)
                    .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                guard lines.count > 5 else { return false }
                try addAttachment(Data(text.utf8), name: String(localized: "粘贴的文本"), mime: "text/plain")
                return true
            }
            guard pasteboard.hasImages, let image = pasteboard.image else { return false }
            // Point-sized rendering at scale 1: the screen scale would triple the
            // pixels and push ordinary screenshots past the attachment limit.
            let scale = min(1, 1600 / max(image.size.width * image.scale, image.size.height * image.scale, 1))
            let size = CGSize(
                width: (image.size.width * image.scale * scale).rounded(),
                height: (image.size.height * image.scale * scale).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let jpeg = rendered.jpegData(compressionQuality: 0.8) else {
                throw TodexError.invalid(String(localized: "无法读取剪贴板图片"))
            }
            try addAttachment(jpeg, name: String(localized: "粘贴的图片.jpg"), mime: "image/jpeg")
            return true
        } catch {
            showError(error)
            return true
        }
    }
    private func submit(nativeQueue: Bool = true) {
        if runClientCommand() { return }
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
                        throw TodexError.invalid(capability["reason"].optionalString ?? String(localized: "当前模型不支持图片输入"))
                    }
                }
                try await session.send(value, in: conversation, nativeQueue: nativeQueue)
            } catch { showError(error) }
        }
    }
    /// Slash commands the client owns instead of forwarding to the agent,
    /// mirroring the desktop command table for unified conversations.
    /// Returns true when the draft named such a command and was consumed.
    private func runClientCommand() -> Bool {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft.attachments.isEmpty, draft.skills.isEmpty, text.hasPrefix("/"),
            let token = text.split(whereSeparator: \.isWhitespace).first
        else { return false }
        let rest = text.dropFirst(token.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let capability = session.provider(for: conversation)?.capabilities ?? .null
        switch token.lowercased() {
        case "/memory", "/memories", "/subagents":
            openAuxiliary()
        case "/plan":
            guard capability["permissionConfig"]["supportsPlan"].boolValue else {
                showNotice(title: String(localized: "计划模式"), message: String(localized: "当前 Agent 不支持计划模式。"))
                return true
            }
            configure { $0.workMode = "plan" }
            // `/plan <task>` switches to plan mode and sends the task at once;
            // while a turn runs it waits locally so it is sent as a plan prompt.
            if !rest.isEmpty {
                setDraft(ComposerDraft(text: rest))
                submit(nativeQueue: false)
                return true
            }
        case "/model":
            if rest.isEmpty {
                presentModelSearch()
            } else {
                configure { $0.model = rest; $0.reasoningEffort = "" }
            }
        case "/permissions", "/permission":
            let modes = capability["permissionConfig"]["modes"].arrayValue.compactMap(\.optionalString)
            if let mode = modes.first(where: { $0.lowercased() == rest.lowercased() }) {
                configure { $0.permissionMode = mode }
            } else {
                showPermissionPicker(modes)
            }
        case "/copy":
            guard
                let reply = session.runtimes[conversation.id]?.messages.first(where: {
                    $0.category == "assistant_final" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })
            else {
                showNotice(title: String(localized: "复制回复"), message: String(localized: "还没有可复制的 Agent 回复。"))
                return true
            }
            UIPasteboard.general.string = reply.text
            transientNotice = (String(localized: "已复制最近一条回复"), .secondaryLabel, Date().addingTimeInterval(4))
        case "/diff":
            openGit?()
        case "/skills", "/mcp":
            openCatalog?()
        case "/approve", "/approval":
            // Decisions differ per request schema, so open the request itself
            // rather than guessing an allow/deny payload.
            let pending = session.runtimes[conversation.id]?.pendingPermissions ?? []
            guard let target = pending.first(where: { $0.id == rest }) ?? pending.first else {
                showNotice(title: String(localized: "审批"), message: String(localized: "当前没有待处理的审批请求。"))
                return true
            }
            presentPermission(target)
        case "/resume":
            let supported =
                session.provider(for: conversation)?.capabilities["controlActions"].arrayValue
                .compactMap(\.optionalString) ?? []
            if supported.contains("resume") {
                performControl("resume")
            } else {
                showNotice(
                    title: String(localized: "恢复对话"), message: String(localized: "请发送明确的后续消息继续对话；当前 Agent 不支持独立恢复操作。"))
            }
        case "/compact", "/retry":
            performControl(String(token.dropFirst()))
        default:
            return false
        }
        setDraft(ComposerDraft())
        return true
    }
    private func openAuxiliary() {
        let page = AuxiliaryViewController(session: session, conversation: conversation)
        let nav = UINavigationController(rootViewController: page)
        page.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
        present(nav, animated: true)
    }
    /// Full-screen editor shares the same draft: text edits stream back through
    /// `onChange`, while attachments and skills stay untouched. `onFinish`
    /// re-renders the inline composer so reference tokens regain styling.
    private func presentFullscreenComposer() {
        hideSuggestions()
        let page = ComposerEditorViewController(
            text: draft.text,
            canSend: { [weak self] in self?.canSend ?? false },
            onChange: { [weak self] text in
                guard let self else { return }
                var value = self.draft
                value.text = text
                // Deleting a token here must stick, or `normalizedDraft`
                // would resurrect the capsule on the next render.
                value.attachments.removeAll { !text.contains($0.token) }
                self.session.drafts[self.conversation.id] = value
                self.session.saveSoon()
            },
            onFinish: { [weak self] in self?.reload() },
            onSend: { [weak self] in self?.submit() })
        let nav = UINavigationController(rootViewController: page)
        nav.modalPresentationStyle = .fullScreen
        WBUI.presentModal(nav, on: self)
    }
    // MARK: - Inline suggestions (/ commands, @ file mentions, # skills)
    private struct Suggestion {
        let title: String
        let detail: String
        let apply: () -> Void
    }
    /// Commands handled locally in `runClientCommand`; provider-advertised
    /// commands with the same name are shadowed, matching the desktop table.
    private static let clientCommands: Set<String> = [
        "/memory", "/memories", "/subagents", "/compact", "/retry", "/resume", "/plan", "/model", "/permissions",
        "/permission", "/copy", "/diff", "/skills", "/mcp", "/approve", "/approval",
    ]
    /// Local commands offered in the `/` popup: (command, detail, prefill).
    /// Commands taking an argument prefill the composer instead of running.
    private static let localCommandSuggestions: [(String, String, String?)] = [
        ("/plan", String(localized: "切换到计划模式；后接内容时直接发送"), "/plan "),
        ("/model", String(localized: "切换模型；不带参数时打开模型搜索"), nil),
        ("/permissions", String(localized: "切换权限模式"), nil),
        ("/copy", String(localized: "复制最近一条 Agent 回复"), nil),
        ("/diff", String(localized: "查看工作区 Git 改动"), nil),
        ("/skills", String(localized: "打开 Skill 目录"), nil),
        ("/mcp", String(localized: "打开 MCP 目录"), nil),
        ("/approve", String(localized: "处理待审批请求"), nil),
    ]
    private func updateSuggestions() {
        let text = composer.text ?? ""
        let trimmed = text.drop(while: \.isWhitespace)
        if trimmed.hasPrefix("/") {
            let token = String(trimmed.dropFirst().prefix(while: { !$0.isWhitespace }))
            if session.commands[conversation.provider + ":" + conversation.workspace] == nil {
                loadCommands()
            }
            let items = slashSuggestions(matching: "/" + token)
            if items.isEmpty {
                updateReferenceSuggestions()
            } else {
                mentionTask?.cancel()
                showSuggestions(items)
            }
            return
        }
        updateReferenceSuggestions()
    }
    /// `@` file mentions and `#` capability references share the popup; the
    /// trigger closest to the caret wins, matching the desktop composer.
    private func updateReferenceSuggestions() {
        let mention = mentionTrigger()
        let skill = skillTrigger()
        if let mention, mention.range.location >= (skill?.range.location ?? -1) {
            fetchMentionSuggestions(mention)
        } else if let skill {
            fetchSkillSuggestions(skill)
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
        for (command, action, detail) in [
            ("/compact", "compact", String(localized: "压缩上下文，保留关键进展")), ("/retry", "retry", String(localized: "重试上一轮")),
            ("/resume", "resume", String(localized: "恢复对话")),
        ]
        where supported.contains(action) && command.hasPrefix(lowered) {
            items.append(
                Suggestion(title: command, detail: detail) { [weak self] in
                    self?.applyControlCommand(action)
                })
        }
        for (command, detail) in [
            ("/memory", String(localized: "查看当前对话的 Agent 记忆")), ("/memories", String(localized: "查看当前对话的 Agent 记忆")),
            ("/subagents", String(localized: "查看当前对话的子代理运行")),
        ] where command.hasPrefix(lowered) {
            items.append(
                Suggestion(title: command, detail: detail) { [weak self] in
                    self?.applyTextSuggestion("")
                    self?.openAuxiliary()
                })
        }
        for (command, detail, prefill) in Self.localCommandSuggestions where command.hasPrefix(lowered) {
            items.append(
                Suggestion(title: command, detail: detail) { [weak self] in
                    guard let self else { return }
                    if let prefill {
                        applyTextSuggestion(prefill)
                    } else {
                        applyTextSuggestion(command)
                        submit()
                    }
                })
        }
        for item in session.commands[conversation.provider + ":" + conversation.workspace] ?? [] {
            let name = item["name"].stringValue
            let command = "/" + name
            guard !name.isEmpty, command.lowercased().hasPrefix(lowered),
                !Self.clientCommands.contains(command.lowercased())
            else { continue }
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
        value.attachments.removeAll { !replacement.contains($0.token) }
        session.drafts[conversation.id] = value
        session.saveSoon()
        render(value)
        composer.selectedRange = NSRange(location: (composer.text as NSString).length, length: 0)
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
        showSuggestions([Suggestion(title: String(localized: "正在搜索工作区文件…"), detail: "", apply: {})], interactive: false)
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
                        [Suggestion(title: String(localized: "没有匹配的文件"), detail: "", apply: {})], interactive: false)
                    : self.showSuggestions(Array(items))
            } catch {
                guard !Task.isCancelled, self.mentionTrigger()?.range.location == range.location else { return }
                self.hideSuggestions()
            }
        }
    }
    private func applyMention(range: NSRange, text insert: String) {
        guard let attributed = composer.attributedText else { return }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: attributed.length))
        let prefix = ComposerText.plain(
            attributed, range: NSRange(location: 0, length: clamped.location))
        // The trigger range is in composer coordinates; translate it through the
        // serialized tokens so a capsule before the caret cannot corrupt the draft.
        let removed = ComposerText.plain(attributed, range: clamped)
        let start = prefix.utf16.count
        let ns = NSMutableString(string: ComposerText.plain(attributed))
        guard start <= ns.length, start + removed.utf16.count <= ns.length else { return }
        ns.replaceCharacters(in: NSRange(location: start, length: removed.utf16.count), with: insert)
        var value = draft
        value.text = ns as String
        value.attachments.removeAll { !value.text.contains($0.token) }
        session.drafts[conversation.id] = value
        session.saveSoon()
        render(value)
        let caret = ComposerText.attributedLocation(
            forPlainOffset: start + insert.utf16.count,
            in: composer.attributedText ?? NSAttributedString())
        composer.selectedRange = NSRange(location: caret, length: 0)
        sendButton.isEnabled = canSend
        hideSuggestions()
    }
    /// `#` offers attachable skills plus MCP references from the backend
    /// catalogs; picking a skill drops the token and toggles the same chip the
    /// catalog attach flow produces, while an MCP inserts `#name` text.
    private func skillTrigger() -> (range: NSRange, query: String)? {
        let text = composer.text ?? ""
        let ns = text as NSString
        let end = max(0, min(composer.selectedRange.location, ns.length))
        let before = ns.substring(to: end)
        let found = (before as NSString).range(of: "#", options: .backwards)
        guard found.location != NSNotFound else { return nil }
        guard found.location == 0
            || CharacterSet.whitespacesAndNewlines.contains(
                UnicodeScalar((before as NSString).character(at: found.location - 1)) ?? " ")
        else { return nil }
        let query = (before as NSString).substring(from: found.location + 1)
        guard
            query.rangeOfCharacter(
                from: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "@#"))) == nil
        else { return nil }
        return (NSRange(location: found.location, length: end - found.location), query)
    }
    /// The desktop `#` popup merges every provider's catalog with the
    /// conversation's own provider first; load both lists lazily and keep
    /// partial results when one provider fails.
    private func loadCapabilityCatalog() {
        guard skillCatalogTask == nil else { return }
        skillCatalogTask = Task { [weak self] in
            defer { self?.skillCatalogTask = nil }
            guard let self, let api = session.api else { return }
            var skills: [JSONValue] = []
            var mcps: [JSONValue] = []
            var ordered = [conversation.provider]
            ordered += session.providers.map(\.id).filter { !ordered.contains($0) }
            for provider in ordered {
                if Task.isCancelled { return }
                if let value = try? await api.skills(
                    provider: provider, workspace: conversation.workspace) {
                    skills += value["skills"].arrayValue
                }
                if let value = try? await api.mcpCatalog(
                    provider: provider, workspace: conversation.workspace) {
                    mcps += value["servers"].arrayValue
                }
            }
            guard !Task.isCancelled else { return }
            skillCatalog = skills
            mcpCatalog = mcps
            updateSuggestions()
        }
    }
    private func fetchSkillSuggestions(_ trigger: (range: NSRange, query: String)) {
        mentionTask?.cancel()
        let range = trigger.range
        let query = trigger.query.lowercased()
        guard let skills = skillCatalog, let mcps = mcpCatalog else {
            showSuggestions(
                [Suggestion(title: String(localized: "正在读取 Skill 与 MCP 目录…"), detail: "", apply: {})], interactive: false)
            loadCapabilityCatalog()
            return
        }
        var seenSkills = Set<String>()
        let matchedSkills = skills.filter { item in
            guard item["valid"].boolValue, !(item["resourceId"].optionalString ?? "").isEmpty
            else { return false }
            let name = item["name"].optionalString ?? ""
            let detail = item["description"].optionalString ?? item["source"].stringValue
            return query.isEmpty || name.lowercased().contains(query) || detail.lowercased().contains(query)
        }.filter { item in
            seenSkills.insert("\(item["resourceId"].stringValue):\(item["name"].stringValue)").inserted
        }
        var seenMcps = Set<String>()
        let matchedMcps = mcps.filter { item in
            guard item["enabled"].boolValue else { return false }
            let name = item["name"].optionalString ?? ""
            return query.isEmpty || name.lowercased().contains(query)
                || item["source"].stringValue.lowercased().contains(query)
        }.filter { item in
            let key = item["resourceId"].optionalString
                ?? "\(item["name"].stringValue):\(item["source"].stringValue)"
            return seenMcps.insert(key).inserted
        }
        let attached = draft.skills
        var items = matchedSkills.map { item -> Suggestion in
            let id = item["resourceId"].stringValue
            let name = item["name"].optionalString ?? String(localized: "未命名")
            let detail = item["description"].optionalString ?? item["source"].stringValue
            let state = attached.contains(where: { $0.id == id }) ? String(localized: " · 已附加") : ""
            return Suggestion(
                title: "#\(name)",
                detail: "Skill\(state)\(detail.isEmpty ? "" : " · \(detail)")"
            ) { [weak self] in
                self?.applySkillMention(range: range, id: id, name: name)
            }
        }
        items += matchedMcps.map { item -> Suggestion in
            let name = item["name"].optionalString ?? String(localized: "未命名")
            return Suggestion(
                title: "#\(name)",
                detail: "MCP · \(item["transport"].stringValue) · \(item["source"].stringValue)"
            ) { [weak self] in
                self?.applyMention(range: range, text: "#\(name) ")
            }
        }
        items = Array(items.prefix(8))
        guard !items.isEmpty else {
            showSuggestions(
                [Suggestion(title: String(localized: "没有匹配的 Skill 或 MCP"), detail: "", apply: {})], interactive: false)
            return
        }
        showSuggestions(items)
    }
    private func applySkillMention(range: NSRange, id: String, name: String) {
        applyMention(range: range, text: "")
        insertSkill(id, name: name)
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
        // Desktop parity: "Provider 默认" still resolves to the provider's
        // isDefault model, so its reasoning efforts stay selectable.
        let defaultModel = models.first { $0["isDefault"].boolValue }
        let model = pref.model.isEmpty ? defaultModel : models.first { $0["id"] == .string(pref.model) }
        var modelActions: [UIMenuElement] = [
            UIAction(
                title: String(localized: "Provider 默认"),
                subtitle: defaultModel.map { Self.modelName($0) },
                state: pref.model.isEmpty ? .on : .off
            ) { [weak self] _ in
                self?.configure { $0.model = ""; $0.reasoningEffort = "" }
            }
        ]
        // A model change clears the effort: the old value may not be one the
        // new model supports, and an unset effort lets the provider choose.
        modelActions += models.map { model in
            let id = model["id"].stringValue
            return UIAction(title: Self.modelName(model), state: pref.model == id ? .on : .off) { [weak self] _ in
                self?.configure { $0.model = id; $0.reasoningEffort = "" }
            }
        }
        if models.count > 1 {
            modelActions.append(
                UIAction(title: String(localized: "搜索模型…"), image: Theme.icon("magnifyingglass")) { [weak self] _ in
                    self?.presentModelSearch()
                })
        }
        modelActions.append(
            UIAction(title: String(localized: "输入模型 ID…")) { [weak self] _ in
                self?.askText(title: String(localized: "模型 ID"), value: pref.model) { id in
                    self?.configure { $0.model = id; $0.reasoningEffort = "" }
                }
            })
        var values: [UIMenuElement] = [UIMenu(title: String(localized: "模型"), children: modelActions)]
        let efforts = (model?["supportedReasoningEfforts"].arrayValue ?? []).map {
            $0.optionalString ?? $0["reasoningEffort"].optionalString ?? $0["id"].stringValue
        }
        if !efforts.isEmpty {
            let fallback = model?["defaultReasoningEffort"].optionalString
                ?? (efforts.contains("medium") ? "medium" : efforts[0])
            var reasoning: [UIMenuElement] = [
                UIAction(
                    title: String(localized: "默认"), subtitle: fallback, state: pref.reasoningEffort.isEmpty ? .on : .off
                ) { [weak self] _ in self?.configure { $0.reasoningEffort = "" } }
            ]
            reasoning += efforts.map { id in
                UIAction(title: id, state: pref.reasoningEffort == id ? .on : .off) { [weak self] _ in
                    self?.configure { $0.reasoningEffort = id }
                }
            }
            values.append(
                UIMenu(title: String(localized: "思考深度"), subtitle: pref.reasoningEffort.isEmpty ? fallback : pref.reasoningEffort,
                    children: reasoning))
        }
        if conversation.provider == "codex" {
            values.append(UIAction(title: String(localized: "Fast · 后端暂不支持"), attributes: .disabled) { _ in })
        }
        return UIMenu(children: values)
    }
    private static func modelName(_ model: JSONValue) -> String {
        model["name"].optionalString ?? model["displayName"].optionalString ?? model["id"].stringValue
    }
    /// Desktop ModelReasoningCard: case-insensitive search over name and id.
    private func presentModelSearch() {
        let models = session.models[conversation.provider + ":" + conversation.workspace] ?? []
        guard !models.isEmpty else {
            showNotice(title: String(localized: "模型"), message: String(localized: "模型列表尚未加载，可稍后重试或直接输入模型 ID。"))
            return
        }
        let page = ModelSearchViewController(
            models: models.map { (id: $0["id"].stringValue, name: Self.modelName($0), isDefault: $0["isDefault"].boolValue) },
            selected: session.preferences(for: conversation).model
        ) { [weak self] id in
            self?.configure { $0.model = id; $0.reasoningEffort = "" }
        }
        let nav = UINavigationController(rootViewController: page)
        page.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close, primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
        WBUI.presentModal(nav, on: self)
    }
    private func showPermissionPicker(_ modes: [String]) {
        guard !modes.isEmpty else {
            showNotice(title: String(localized: "权限"), message: String(localized: "当前 Agent 未提供可切换的权限模式。"))
            return
        }
        let sheet = UIAlertController(title: String(localized: "权限模式"), message: nil, preferredStyle: .actionSheet)
        for mode in modes {
            sheet.addAction(
                UIAlertAction(title: Self.permissionStyle(mode).title, style: .default) { [weak self] _ in
                    self?.configure { $0.permissionMode = mode }
                })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        WBUI.presentSheet(sheet, on: self)
    }
    /// Desktop lets the agent change until the first message. The backend fixes
    /// a conversation's provider at creation, so an untouched conversation is
    /// replaced by a new one in the same workspace and the empty one deleted.
    private var switchingAgent = false
    private var canSwitchAgent: Bool {
        let runtime = session.runtimes[conversation.id]
        return session.isConnected && runtime?.readyForActions == true && runtime?.messages.isEmpty == true
            && (session.conversations.first { $0.id == conversation.id }?.lastSequence ?? 0) == 0
            && session.pendingSends[conversation.id] == nil && (session.queues[conversation.id] ?? []).isEmpty
    }
    private func switchAgent() {
        guard canSwitchAgent, let workspace = session.workspace(for: conversation) else { return }
        let sheet = UIAlertController(title: String(localized: "更换 Agent"), message: String(localized: "当前对话还没有消息，将改用新的 Agent 重新创建。"), preferredStyle: .actionSheet)
        for provider in session.providers where provider.available {
            let profiles: [String?] = provider.id == "acp" && !provider.profiles.isEmpty ? provider.profiles : [nil]
            for profile in profiles {
                let current = provider.id == conversation.provider && profile == conversation.providerProfile
                let action = UIAlertAction(
                    title: profile.map { "ACP · \($0)" } ?? provider.displayName, style: .default
                ) { [weak self] _ in self?.recreate(in: workspace, provider: provider.id, profile: profile) }
                action.isEnabled = !current
                sheet.addAction(action)
            }
        }
        sheet.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        WBUI.presentSheet(sheet, on: self)
    }
    private func recreate(in workspace: WorkspaceRecord, provider: String, profile: String?) {
        guard !switchingAgent else { return }
        // Sending stays off while the replacement is created, so nothing can
        // land in the conversation that is about to be deleted.
        switchingAgent = true
        reload()
        Task { [weak self] in
            guard let self else { return }
            defer {
                switchingAgent = false
                reload()
            }
            guard let api = session.api, canSwitchAgent else { return }
            do {
                let next = try await api.createConversation(
                    workspace: workspace, provider: provider, profile: profile, title: conversation.title)
                // Another client may have written to the old conversation meanwhile:
                // keep it and discard the replacement instead.
                guard canSwitchAgent else {
                    do { _ = try await api.deleteConversation(id: next.id) } catch { showError(error) }
                    showNotice(title: String(localized: "更换 Agent"), message: String(localized: "原对话已有新内容，已保留原对话。"))
                    try await session.refresh()
                    return
                }
                session.rememberAgent(provider: provider, profile: profile)
                // Carry over what the user already prepared for the first message.
                session.drafts[next.id] = session.drafts[conversation.id]
                if let remembered = session.rememberedPreferences(for: provider) {
                    session.updatePreferences(remembered, for: next)
                }
                do { _ = try await api.deleteConversation(id: conversation.id) } catch {
                    // The new conversation is usable; the empty one just stays listed.
                    showError(error)
                }
                session.drafts[conversation.id] = nil
                try await session.refresh()
                guard let manifest = session.conversations.first(where: { $0.id == next.id }) else { return }
                session.select(manifest)
                guard let navigation = navigationController, let container = parent else { return }
                var stack = navigation.viewControllers
                if let index = stack.firstIndex(where: { $0 === container }) {
                    stack[index] = ConversationContainerController(session: session, conversation: manifest)
                    navigation.setViewControllers(stack, animated: true)
                }
            } catch { showError(error) }
        }
    }
    // Icon + tint encode the active option so the icon-only chips stay legible.
    private static func permissionStyle(_ mode: String) -> (title: String, icon: String, color: UIColor) {
        switch mode {
        case "auto": return (String(localized: "自动审批"), "checkmark.shield.fill", Theme.accent)
        case "full-access": return (String(localized: "完全访问"), "lock.open.fill", .systemRed)
        case "ask": return (String(localized: "按需审批"), "hand.raised.fill", .systemOrange)
        default: return (mode.isEmpty ? String(localized: "权限") : mode, "hand.raised", .secondaryLabel)
        }
    }
    private static func workModeStyle(_ mode: String) -> (title: String, icon: String, color: UIColor) {
        mode == "plan" ? (String(localized: "计划"), "map.fill", .systemIndigo) : (String(localized: "执行"), "bolt.fill", Theme.accent)
    }
    private static func coloredIcon(_ icon: String, _ color: UIColor) -> UIImage? {
        Theme.icon(icon, pointSize: 13)?.withTintColor(color, renderingMode: .alwaysOriginal)
    }
    private func permissionMenu() -> UIMenu {
        let pref = session.preferences(for: conversation)
        let capability = session.provider(for: conversation)?.capabilities ?? .null
        let permissions = capability["permissionConfig"]["modes"].arrayValue.map { value -> UIMenuElement in
            let id = value.stringValue
            let style = Self.permissionStyle(id)
            return UIAction(
                title: style.title, image: Self.coloredIcon(style.icon, style.color),
                state: pref.permissionMode == id ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                if id == "full-access" {
                    confirm(
                        title: String(localized: "启用完全访问？"),
                        message:
                            String(localized: "后续任务可获得当前 Agent 支持的最高权限。\n\(capability["permissionConfig"]["description"].stringValue)")
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
        return UIMenu(children: ["implement", "plan"].map { mode -> UIMenuElement in
            let style = Self.workModeStyle(mode)
            return UIAction(
                title: style.title, image: Self.coloredIcon(style.icon, style.color),
                state: pref.workMode == mode ? .on : .off
            ) { [weak self] _ in
                self?.configure { $0.workMode = mode }
            }
        })
    }
    private func moreMenu() -> UIMenu {
        let capability = session.provider(for: conversation)?.capabilities ?? .null
        var values: [UIMenuElement] = [
            UIAction(title: String(localized: "查看实际配置")) { [weak self] _ in
                guard let self else { return }
                let runtime = session.runtimes[conversation.id]
                WBUI.textSheet(
                    on: self, title: String(localized: "当前配置"),
                    text:
                        String(localized: "状态：\(runtime?.configurationStatus ?? "unknown")\n\n请求权限\n\(runtime?.requestedConfig.prettyPrinted ?? String(localized: "未知"))\n\n实际配置\n\(runtime?.effectiveConfig.prettyPrinted ?? String(localized: "未知"))\n\n\(capability["permissionConfig"]["description"].stringValue)")
                )
            }
        ]
        let supported = capability["controlActions"].arrayValue.compactMap(\.optionalString)
        for (action, label) in [("retry", String(localized: "重试上一轮")), ("fork", String(localized: "从此处分叉")), ("compact", String(localized: "压缩上下文"))]
        where supported.contains(action) {
            values.append(UIAction(title: label) { [weak self] _ in self?.performControl(action) })
        }
        if supported.contains("steer") {
            values.append(
                UIAction(title: String(localized: "引导当前任务…")) { [weak self] _ in
                    self?.askText(title: String(localized: "引导当前任务"), placeholder: String(localized: "补充方向")) { self?.steer($0) }
                })
        }
        if supported.contains("queue") {
            values.append(UIAction(title: String(localized: "后端原生队列…")) { [weak self] _ in self?.nativeQueue() })
        }
        if canSwitchAgent {
            values.append(
                UIAction(title: String(localized: "更换 Agent…"), image: Theme.icon("arrow.triangle.2.circlepath")) { [weak self] _ in
                    self?.switchAgent()
                })
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
                    title: String(localized: "后端原生队列"), message: result.prettyPrinted, preferredStyle: .actionSheet)
                sheet.addAction(
                    UIAlertAction(title: String(localized: "添加消息"), style: .default) { [weak self] _ in
                        self?.askText(title: String(localized: "队列消息")) { text in
                            self?.queueControl([
                                "action": "queueAdd", "itemId": .string(UUID().uuidString), "text": .string(text),
                            ])
                        }
                    })
                for item in result["items"].arrayValue {
                    sheet.addAction(
                        UIAlertAction(title: String(localized: "移除：\(item["text"].stringValue.prefix(40))"), style: .destructive) {
                            [weak self] _ in self?.queueControl(["action": "queueRemove", "itemId": item["itemId"]])
                        })
                }
                sheet.addAction(
                    UIAlertAction(title: String(localized: "清空"), style: .destructive) { [weak self] _ in
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
        let sheet = UIAlertController(title: String(localized: "候选消息"), message: String(localized: "当前任务结束后按顺序发送；后台或断线后暂停。"), preferredStyle: .actionSheet)
        if session.pausedQueues.contains(conversation.id) {
            sheet.addAction(
                UIAlertAction(title: String(localized: "恢复发送"), style: .default) { [weak self] _ in
                    guard let self else { return }
                    session.resumeQueue(conversation)
                })
        } else {
            sheet.addAction(
                UIAlertAction(title: String(localized: "暂停"), style: .default) { [weak self] _ in
                    guard let self else { return }
                    session.pausedQueues.insert(conversation.id)
                    session.changed()
                })
        }
        for item in session.queues[conversation.id] ?? [] {
            sheet.addAction(
                UIAlertAction(title: String(localized: "编辑：\(item.draft.text.prefix(35))"), style: .default) { [weak self] _ in
                    guard let self else { return }
                    guard draft.isEmpty else {
                        showNotice(title: String(localized: "输入框已有草稿"), message: String(localized: "先发送或保存当前草稿，再编辑候选消息。"))
                        return
                    }
                    session.removeQueued(item.id, conversationId: conversation.id)
                    setDraft(item.draft)
                })
            sheet.addAction(
                UIAlertAction(title: String(localized: "删除：\(item.draft.text.prefix(35))"), style: .destructive) { [weak self] _ in
                    guard let self else { return }
                    session.removeQueued(item.id, conversationId: conversation.id)
                })
        }
        WBUI.presentSheet(sheet, on: self)
    }
    private func showUnknown(_ pending: PendingSend) {
        let sheet = UIAlertController(
            title: String(localized: "消息提交结果待核对"), message: String(localized: "\(pending.draft.text.prefix(300))\n\n网络中断可能发生在后端接收之后。核对历史不会再次发送消息。"),
            preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: String(localized: "同步并核对"), style: .default) { [weak self] _ in
                Task { [weak self] in
                    guard let self else { return }
                    do { try await session.reconcile(conversation.id) } catch { showError(error) }
                }
            })
        sheet.addAction(
            UIAlertAction(title: String(localized: "恢复为草稿"), style: .destructive) { [weak self] _ in
                guard let self else { return }
                guard draft.isEmpty else {
                    showNotice(title: String(localized: "输入框已有草稿"), message: String(localized: "先处理当前草稿，再恢复待核对消息。"))
                    return
                }
                confirm(title: String(localized: "恢复原消息？"), message: String(localized: "之后手动发送可能产生重复任务。请先核对后端记录。")) {
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
                            throw TodexError.invalid(String(localized: "无法读取图片，或图片超过 32 MB"))
                        }
                        try addAttachment(jpeg, name: String(localized: "图片.jpg"), mime: "image/jpeg")
                    } catch { showError(error) }
                }
            }
        }
    }
    private func addAttachment(_ data: Data, name: String, mime: String) throws {
        guard draft.attachments.count < 6, data.count + draft.attachments.reduce(0, { $0 + $1.data.count }) <= 2_500_000
        else { throw TodexError.invalid(String(localized: "附件总大小需小于 2.5 MB，最多 6 个")) }
        if mime.hasPrefix("image/") {
            guard session.provider(for: conversation)?.capabilities["imageInput"].boolValue == true else {
                throw TodexError.invalid(String(localized: "当前 Agent 未提供图片输入能力"))
            }
        } else {
            guard String(data: data, encoding: .utf8) != nil else { throw TodexError.invalid(String(localized: "文本附件须使用 UTF-8 编码")) }
        }
        var value = draft
        let isImage = mime.hasPrefix("image/")
        let resolved = uniqueName(name, isImage: isImage, isReference: false, in: value)
        let attachment = MessageAttachment(name: resolved, mimeType: mime, data: data)
        insert(attachment, into: &value)
        setDraft(value)
        focusCaret(after: attachment.id)
    }
}

/// Serializes composer attributed text: every capsule stands in for its full
/// token, so plain offsets and token offsets stay interchangeable.
enum ComposerText {
    static func plain(_ attributed: NSAttributedString) -> String {
        plain(attributed, range: NSRange(location: 0, length: attributed.length))
    }
    static func plain(_ attributed: NSAttributedString, range: NSRange) -> String {
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: attributed.length))
        guard clamped.length > 0 else { return "" }
        var result = ""
        attributed.enumerateAttributes(in: clamped) { attributes, subrange, _ in
            if let capsule = attributes[.attachment] as? ComposerCapsuleAttachment {
                result += capsule.token
            } else {
                result += (attributed.string as NSString).substring(with: subrange)
            }
        }
        return result
    }
    /// Composer character index for a plain-text offset, collapsing tokens back
    /// to their single attachment character.
    static func attributedLocation(forPlainOffset offset: Int, in attributed: NSAttributedString) -> Int {
        var plain = 0
        var result = attributed.length
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) {
            attributes, range, stop in
            if let capsule = attributes[.attachment] as? ComposerCapsuleAttachment {
                if offset <= plain + capsule.token.utf16.count {
                    result = range.location + range.length
                    stop.pointee = true
                    return
                }
                plain += capsule.token.utf16.count
            } else {
                if offset <= plain + range.length {
                    result = range.location + max(0, offset - plain)
                    stop.pointee = true
                    return
                }
                plain += range.length
            }
        }
        return result
    }
}

/// A non-editable, deletable inline capsule for one composer attachment token.
/// It is a single attachment character, so TextKit can never place the caret
/// inside it and backspace always removes the whole token.
nonisolated final class ComposerCapsuleAttachment: NSTextAttachment {
    enum Kind: String {
        case reference
        case file
        case image
        init(_ attachment: MessageAttachment) {
            self = attachment.isReference ? .reference : (attachment.isImage ? .image : .file)
        }
        var symbol: String {
            switch self {
            case .reference: "text.quote"
            case .image: "photo"
            case .file: "doc.text"
            }
        }
    }

    let attachmentId: String
    let name: String
    let kind: Kind
    let token: String
    let deleteZoneWidth: CGFloat

    init(attachment: MessageAttachment, font: UIFont) {
        let kind = Kind(attachment)
        // `NSTextAttachment`'s designated initializers are nonisolated, so the
        // subclass must be too; rendering still runs on the main actor.
        let rendered = MainActor.assumeIsolated { Self.render(name: attachment.name, kind: kind, font: font) }
        attachmentId = attachment.id
        name = attachment.name
        self.kind = kind
        token = attachment.token
        deleteZoneWidth = rendered.deleteZoneWidth
        super.init(data: nil, ofType: nil)
        image = rendered.image
        bounds = rendered.bounds
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private struct Rendering {
        let image: UIImage
        let bounds: CGRect
        let deleteZoneWidth: CGFloat
    }

    @MainActor private static func render(name: String, kind: Kind, font: UIFont) -> Rendering {
        let labelFont = UIFont.systemFont(ofSize: min(font.pointSize, 15), weight: .medium)
        let label = truncated(name)
        let labelWidth = ceil((label as NSString).size(withAttributes: [.font: labelFont]).width)
        let leading: CGFloat = 8
        let trailing: CGFloat = 7
        let gap: CGFloat = 4
        let symbol = Theme.icon(kind.symbol, pointSize: 12)
        let symbolWidth = ceil(symbol?.size.width ?? 13)
        let mark = Theme.icon("xmark", pointSize: 9)
        let markWidth = ceil(mark?.size.width ?? 9)
        let height = ceil(font.lineHeight) + 2
        let width = ceil(leading + symbolWidth + gap + labelWidth + gap + markWidth + trailing)
        let size = CGSize(width: width, height: height)
        let deleteZoneWidth = markWidth + trailing + 1
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            Theme.accent.withAlphaComponent(0.15).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: height / 2).fill()
            if let symbol = symbol?.withTintColor(Theme.accent, renderingMode: .alwaysOriginal) {
                symbol.draw(in: CGRect(
                    x: leading, y: (height - symbol.size.height) / 2,
                    width: symbol.size.width, height: symbol.size.height))
            }
            (label as NSString).draw(
                in: CGRect(
                    x: leading + symbolWidth + gap, y: (height - labelFont.lineHeight) / 2,
                    width: labelWidth, height: labelFont.lineHeight),
                withAttributes: [.font: labelFont, .foregroundColor: Theme.accent])
            if let mark = mark?.withTintColor(Theme.accent, renderingMode: .alwaysOriginal) {
                mark.draw(in: CGRect(
                    x: width - trailing - mark.size.width, y: (height - mark.size.height) / 2,
                    width: mark.size.width, height: mark.size.height))
            }
        }
        let bounds = CGRect(x: 0, y: (font.capHeight - height) / 2, width: width, height: height)
        return Rendering(image: image, bounds: bounds, deleteZoneWidth: deleteZoneWidth)
    }

    private static func truncated(_ name: String, max: Int = 18) -> String {
        guard name.count > max else { return name }
        let keep = max - 1
        let head = keep / 2
        let tail = keep - head
        return "\(name.prefix(head))…\(name.suffix(tail))"
    }
}

/// Full-screen text editor opened from the corner button on the inline
/// composer. Edits stream back through `onChange` so the shared draft stays in
/// sync; `onFinish` runs after dismissal and `onSend` after a successful send.
final class ComposerEditorViewController: UIViewController, UITextViewDelegate {
    private let editor = UITextView()
    private let placeholder = Theme.label(String(localized: "描述你的任务"), color: .placeholderText)
    private let canSend: () -> Bool
    private let onChange: (String) -> Void
    private let onFinish: () -> Void
    private let onSend: () -> Void
    private var sendItem: UIBarButtonItem?

    init(
        text: String, canSend: @escaping () -> Bool, onChange: @escaping (String) -> Void,
        onFinish: @escaping () -> Void, onSend: @escaping () -> Void
    ) {
        self.canSend = canSend
        self.onChange = onChange
        self.onFinish = onFinish
        self.onSend = onSend
        super.init(nibName: nil, bundle: nil)
        editor.text = text
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "编辑消息")
        view.backgroundColor = Theme.background
        editor.font = .preferredFont(forTextStyle: .body)
        editor.adjustsFontForContentSizeCategory = true
        editor.backgroundColor = .clear
        editor.delegate = self
        editor.alwaysBounceVertical = true
        editor.accessibilityLabel = String(localized: "消息输入框")
        editor.accessibilityIdentifier = "chat.composer.fullscreen"
        editor.textContainerInset = .init(top: 10, left: 6, bottom: 10, right: 6)
        let dismiss = UIToolbar()
        dismiss.items = [
            .flexibleSpace(),
            UIBarButtonItem(
                title: String(localized: "收起键盘"), image: nil,
                primaryAction: UIAction { [weak editor] _ in editor?.resignFirstResponder() }),
        ]
        dismiss.sizeToFit()
        editor.inputAccessoryView = dismiss
        placeholder.isUserInteractionEnabled = false
        editor.addSubview(placeholder)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(
                equalTo: editor.leadingAnchor,
                constant: editor.textContainerInset.left + editor.textContainer.lineFragmentPadding),
            placeholder.topAnchor.constraint(
                equalTo: editor.topAnchor, constant: editor.textContainerInset.top),
        ])
        placeholder.isHidden = !editor.text.isEmpty
        WBUI.installStack(in: view, views: [editor], keyboard: true)
        let send = UIBarButtonItem(
            image: Theme.icon("arrow.up", pointSize: 15), style: .prominent,
            target: self, action: #selector(sendTapped))
        send.accessibilityLabel = String(localized: "发送")
        send.isEnabled = canSend()
        sendItem = send
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.finish() }),
            send,
        ]
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        editor.becomeFirstResponder()
    }
    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        sendItem?.isEnabled = canSend()
        onChange(textView.text ?? "")
    }
    @objc private func sendTapped() {
        guard canSend() else { return }
        dismiss(animated: true) { [onFinish, onSend] in
            onFinish()
            onSend()
        }
    }
    private func finish() {
        dismiss(animated: true, completion: onFinish)
    }
}

/// Composer text view whose paste can be claimed by the chat (images and long
/// text become attachments). Anything unclaimed pastes normally.
final class ComposerTextView: UITextView {
    var onPaste: ((UIPasteboard) -> Bool)?
    override func paste(_ sender: Any?) {
        if onPaste?(UIPasteboard.general) == true { return }
        super.paste(sender)
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Plain text views refuse to paste image-only content; allow it here.
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }
}

/// Searchable model list (desktop ModelReasoningCard): matches name or id
/// case-insensitively; the provider default is labeled.
final class ModelSearchViewController: UITableViewController, UISearchResultsUpdating {
    typealias Model = (id: String, name: String, isDefault: Bool)
    private let models: [Model]
    private let selected: String
    private let onSelect: (String) -> Void
    private var filtered: [Model]
    init(models: [Model], selected: String, onSelect: @escaping (String) -> Void) {
        self.models = models
        self.selected = selected
        self.onSelect = onSelect
        filtered = models
        super.init(style: .insetGrouped)
        title = String(localized: "选择模型")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "搜索模型名称或 ID")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
    }
    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        filtered =
            query.isEmpty
            ? models : models.filter { $0.name.lowercased().contains(query) || $0.id.lowercased().contains(query) }
        tableView.reloadData()
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { filtered.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let model = filtered[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = model.name + (model.isDefault ? String(localized: " · 默认") : "")
        content.secondaryText = model.id == model.name ? nil : model.id
        cell.contentConfiguration = content
        cell.accessoryType = model.id == selected ? .checkmark : .none
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        onSelect(filtered[indexPath.row].id)
        // An active search controller is itself presented; close the whole sheet.
        navigationItem.searchController?.isActive = false
        navigationController?.dismiss(animated: true)
    }
}
