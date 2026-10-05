import TodexCore
import UIKit

/// Pinned between the timeline and the composer while the conversation's
/// agent works on the backend's computer (web `ComputerLiveView` /
/// `AgentBrowserLiveView`): Computer Use shows the host's screen, polled while
/// visible; the agent browser shows its tab, streamed over the session socket.
/// Without a live image the latest screenshot the agent took stands in. Only
/// watches while `isActive` (chat on screen, app in the foreground) and the
/// panel is expanded.
final class AgentLiveView: UIView {
    /// Polling cadence of the Computer Use frame while it is visible.
    private static let frameInterval: Duration = .milliseconds(350)
    /// After a failed frame (session ending, older backend): wait longer.
    private static let frameRetry: Duration = .seconds(2)
    /// Collapsed panels per conversation, for this app run.
    private static var collapsedPanels: [String: Set<Kind>] = [:]

    enum Kind: Hashable { case computer, browser }

    private let session: AppSession
    private let conversationID: String
    /// Presents a failed Stop.
    var reportError: ((String, String) -> Void)?

    private let stack = UIStackView()
    private let awaitingBanner = UIStackView()
    private let awaitingLabel = Theme.label("", style: .caption1)
    private let computerPanel: Panel
    private let browserPanel: Panel

    private var computer = DesktopComputerState()
    private var browser = DesktopBrowserState()
    private var isActive = false

    // Computer Use: a live frame, else the latest shot.
    private var framePoll: Task<Void, Never>?
    private var computerLive = false
    private var computerShot: (id: String, image: UIImage)?
    private var computerShotTask: Task<Void, Never>?
    // Agent browser: streamed frames, else the latest shot.
    private var browserWatch: UUID?
    private var browserLive = false
    private var browserClosed = false
    private var decoding = false
    private var pendingFrame: AgentBrowserFrame?
    private var browserShot: (id: String, image: UIImage)?
    private var browserShotTask: Task<Void, Never>?
    private var stopping: Set<Kind> = []
    /// Shots that failed to load (expired); not retried on every reload.
    private var failedShots: Set<String> = []

    init(session: AppSession, conversationID: String) {
        self.session = session
        self.conversationID = conversationID
        computerPanel = Panel(kind: .computer)
        browserPanel = Panel(kind: .browser)
        super.init(frame: .zero)
        stack.axis = .vertical
        stack.spacing = 6
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: 4, leading: 14, bottom: 4, trailing: 14)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let icon = UIImageView(image: Theme.icon("desktopcomputer", pointSize: 13))
        icon.tintColor = .systemOrange
        icon.setContentHuggingPriority(.required, for: .horizontal)
        awaitingBanner.addArrangedSubview(icon)
        awaitingBanner.addArrangedSubview(awaitingLabel)
        awaitingBanner.axis = .horizontal
        awaitingBanner.spacing = 8
        awaitingBanner.alignment = .center
        awaitingBanner.isLayoutMarginsRelativeArrangement = true
        awaitingBanner.directionalLayoutMargins = .init(top: 8, leading: 12, bottom: 8, trailing: 12)
        awaitingBanner.layer.cornerRadius = 12
        awaitingBanner.layer.borderWidth = 1
        awaitingBanner.layer.borderColor = UIColor.systemOrange.cgColor
        awaitingBanner.isAccessibilityElement = true
        awaitingBanner.accessibilityIdentifier = "agentLive.awaitingHost"
        awaitingLabel.numberOfLines = 1
        awaitingLabel.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(awaitingBanner)
        for panel in [computerPanel, browserPanel] {
            stack.addArrangedSubview(panel)
            panel.collapse.addAction(UIAction { [weak self] _ in self?.toggle(panel.kind) }, for: .primaryActionTriggered)
            panel.stop.addAction(UIAction { [weak self] _ in self?.stop(panel.kind) }, for: .primaryActionTriggered)
        }
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        framePoll?.cancel()
        computerShotTask?.cancel()
        browserShotTask?.cancel()
        if let browserWatch { session.unwatchAgentBrowser(browserWatch) }
    }

    /// The conversation's projected desktop state; cheap when unchanged.
    func update(computer: DesktopComputerState, browser: DesktopBrowserState) {
        guard computer != self.computer || browser != self.browser else { return }
        if browser.tabOpen == true, self.browser.actions.last?.actionId != browser.actions.last?.actionId {
            // A new action after `closed`: the tab may be back.
            browserClosed = false
        }
        self.computer = computer
        self.browser = browser
        render()
    }

    /// Chat on screen and the app in the foreground.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        render()
    }

    private func collapsed(_ kind: Kind) -> Bool {
        Self.collapsedPanels[conversationID]?.contains(kind) ?? false
    }

    private func toggle(_ kind: Kind) {
        var set = Self.collapsedPanels[conversationID] ?? []
        if set.contains(kind) { set.remove(kind) } else { set.insert(kind) }
        Self.collapsedPanels[conversationID] = set
        render()
    }

    private var computerShown: Bool { computer.active }
    private var browserShown: Bool { browser.tabOpen == true }

    private func render() {
        let device = computer.deviceName.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "后端所在的电脑")
        awaitingBanner.isHidden = !(computer.awaitingHost && !computer.active)
        awaitingLabel.text = String(localized: "正在等待 \(device) 前的人允许 Computer Use…")
        awaitingBanner.accessibilityLabel = awaitingLabel.text

        // Both at once share the space: smaller images.
        let compact = computerShown && browserShown
        computerPanel.isHidden = !computerShown
        if computerShown {
            let latest = computer.actions.last
            computerPanel.configure(
                title: String(localized: "Agent 正在操作 \(device)"),
                subtitle: latest.map { action in action.app.map { "\(action.summary) · \($0)" } ?? action.summary },
                live: computerLive, collapsed: collapsed(.computer), stopping: stopping.contains(.computer),
                stopEnabled: true, compact: compact)
            computerPanel.show(
                image: computerLive ? computerPanel.imageView.image : computerShot?.image,
                placeholder: String(localized: "等待第一帧画面…"),
                description: computerLive ? String(localized: "被控制电脑的实时画面") : String(localized: "Agent 最新截图"))
        }
        browserPanel.isHidden = !browserShown
        if browserShown {
            let page = browser.actions.last { $0.ok && ($0.url?.isEmpty == false || $0.title?.isEmpty == false) }
            let latest = browser.actions.last
            let host = browser.deviceName.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "后端所在的电脑")
            let url = page?.url.flatMap { $0.isEmpty ? nil : $0 }
            browserPanel.configure(
                title: page?.title.flatMap { $0.isEmpty ? nil : $0 } ?? url ?? String(localized: "Agent 浏览器"),
                subtitle: latest.map { action in url.map { "\(action.summary) · \($0)" } ?? action.summary }
                    ?? String(localized: "运行在 \(host)"),
                live: browserLive, collapsed: collapsed(.browser), stopping: stopping.contains(.browser),
                stopEnabled: !browserClosed, compact: compact)
            browserPanel.show(
                image: browserLive ? browserPanel.imageView.image : browserShot?.image,
                placeholder: browserClosed
                    ? String(localized: "Agent 尚未打开页面，或标签已关闭。") : String(localized: "等待第一帧画面…"),
                description: browserLive ? String(localized: "Agent 浏览器的实时画面") : String(localized: "Agent 最新截图"))
        }
        isHidden = awaitingBanner.isHidden && !computerShown && !browserShown
        syncComputer()
        syncBrowser()
    }

    // MARK: Computer Use

    private func syncComputer() {
        let watching = isActive && computerShown && !collapsed(.computer)
        if watching, framePoll == nil {
            framePoll = Task { [weak self] in await self?.pollFrames() }
        } else if !watching, let poll = framePoll {
            poll.cancel()
            framePoll = nil
            if computerLive {
                computerLive = false
                render()
                return
            }
        }
        if watching, !computerLive {
            loadShot(
                computer.actions.last { $0.shotId != nil }?.shotId, current: computerShot?.id, task: \.computerShotTask
            ) { [weak self] id, image in self?.computerShot = (id, image) }
        }
    }

    private func pollFrames() async {
        while !Task.isCancelled {
            var delay = Self.frameInterval
            // A chat hidden behind the compact workbench pane keeps the view
            // in the window; skip fetching until it shows again.
            if isVisibleOnScreen {
                do {
                    guard let api = session.api else { throw TodexError.disconnected }
                    let frame = try await api.agentDesktopFrame(conversationId: conversationID)
                    let image = try await Self.decode(frame.data)
                    guard !Task.isCancelled else { return }
                    computerPanel.imageView.image = image
                    if !computerLive {
                        computerLive = true
                        render()
                    }
                } catch {
                    if Task.isCancelled { return }
                    if computerLive {
                        computerLive = false
                        render()
                    }
                    delay = Self.frameRetry
                }
            }
            do { try await Task.sleep(for: delay) } catch { return }
        }
    }

    // MARK: Agent browser

    private func syncBrowser() {
        let watching = isActive && browserShown && !collapsed(.browser)
        if watching, browserWatch == nil {
            browserWatch = session.watchAgentBrowser(conversationID) { [weak self] in self?.receive($0) }
        } else if !watching, let token = browserWatch {
            session.unwatchAgentBrowser(token)
            browserWatch = nil
            pendingFrame = nil
            if browserLive {
                browserLive = false
                render()
                return
            }
        }
        if watching, !browserLive {
            loadShot(
                browser.actions.last { $0.shotId != nil }?.shotId, current: browserShot?.id, task: \.browserShotTask
            ) { [weak self] id, image in self?.browserShot = (id, image) }
        }
    }

    /// Only the newest frame waits while one decodes.
    private func receive(_ frame: AgentBrowserFrame) {
        guard browserWatch != nil else { return }
        if decoding {
            pendingFrame = frame
            return
        }
        switch frame.content {
        case .closed:
            browserClosed = true
            if browserLive { browserLive = false }
            render()
        case .image(_, let base64, _, _):
            decoding = true
            Task { [weak self] in
                let image = try? await Self.decode(Data(base64Encoded: base64))
                guard let self else { return }
                decoding = false
                // A corrupt frame is skipped; the next one replaces it.
                if let image, browserWatch != nil {
                    browserPanel.imageView.image = image
                    if !browserLive || browserClosed {
                        browserLive = true
                        browserClosed = false
                        render()
                    }
                }
                if let next = pendingFrame {
                    pendingFrame = nil
                    receive(next)
                }
            }
        }
    }

    // MARK: Shared

    private func loadShot(
        _ shotID: String?, current: String?, task: ReferenceWritableKeyPath<AgentLiveView, Task<Void, Never>?>,
        store: @escaping (String, UIImage) -> Void
    ) {
        guard let shotID, shotID != current, !failedShots.contains(shotID), self[keyPath: task] == nil,
            let api = session.api
        else { return }
        let conversationID = conversationID
        self[keyPath: task] = Task { [weak self] in
            defer { self?[keyPath: task] = nil }
            do {
                let shot = try await api.agentShot(conversationId: conversationID, shotId: shotID)
                let image = try await Self.decode(shot.data)
                guard let self, !Task.isCancelled else { return }
                store(shotID, image)
                render()
            } catch {
                // Shots expire with the conversation's journal; the placeholder stays.
                if !(error is CancellationError) { self?.failedShots.insert(shotID) }
            }
        }
    }

    private func stop(_ kind: Kind) {
        guard !stopping.contains(kind) else { return }
        stopping.insert(kind)
        render()
        let conversationID = conversationID
        Task { [weak self] in
            guard let self else { return }
            defer {
                stopping.remove(kind)
                render()
            }
            do {
                guard let api = session.api else { throw TodexError.disconnected }
                _ = try await api.revokeAgentDesktop(
                    conversationId: conversationID, capability: kind == .computer ? .screen : .browser)
            } catch {
                reportError?(
                    kind == .computer ? String(localized: "无法停止 Computer Use") : String(localized: "无法停止 Agent 浏览器"),
                    error.localizedDescription)
            }
        }
    }

    private var isVisibleOnScreen: Bool {
        guard window != nil else { return false }
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha == 0 { return false }
            view = current.superview
        }
        return true
    }

    /// JPEG decoding and display preparation off the main thread.
    private static func decode(_ data: Data?) async throws -> UIImage {
        guard let data else { throw TodexError.invalid(String(localized: "画面数据无效")) }
        let image = await Task.detached(priority: .userInitiated) {
            UIImage(data: data)?.preparingForDisplay()
        }.value
        guard let image else { throw TodexError.invalid(String(localized: "画面数据无效")) }
        return image
    }
}

/// One live panel: header (title, latest action, live badge, collapse, stop)
/// over an outlined image area.
private final class Panel: UIStackView {
    let kind: AgentLiveView.Kind
    let imageView = UIImageView()
    let collapse = UIButton(type: .system)
    let stop = UIButton(type: .system)
    private let title = Theme.label("", style: .footnote)
    private let subtitle = Theme.label("", style: .caption1, color: .secondaryLabel)
    private let badge = UILabel()
    private let imageArea = UIView()
    private let placeholder = Theme.label("", style: .caption1, color: UIColor.white.withAlphaComponent(0.7))
    private var imageHeight: NSLayoutConstraint!

    init(kind: AgentLiveView.Kind) {
        self.kind = kind
        super.init(frame: .zero)
        axis = .vertical
        spacing = 0
        layer.cornerRadius = 12
        layer.borderWidth = 1
        layer.borderColor = UIColor.systemOrange.cgColor
        clipsToBounds = true
        backgroundColor = Theme.surface
        let prefix = kind == .computer ? "agentLive.computer" : "agentLive.browser"
        accessibilityIdentifier = prefix

        let icon = UIImageView(image: Theme.icon(kind == .computer ? "desktopcomputer" : "globe", pointSize: 13))
        icon.tintColor = kind == .computer ? .systemOrange : .secondaryLabel
        icon.setContentHuggingPriority(.required, for: .horizontal)
        title.font = .preferredFont(forTextStyle: .footnote).withTraits(.traitBold)
        for label in [title, subtitle] {
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle
        }
        title.accessibilityIdentifier = "\(prefix).title"
        subtitle.accessibilityIdentifier = "\(prefix).subtitle"
        let texts = UIStackView(arrangedSubviews: [title, subtitle])
        texts.axis = .vertical
        texts.spacing = 1
        badge.text = String(localized: "实时")
        badge.font = .preferredFont(forTextStyle: .caption2)
        badge.adjustsFontForContentSizeCategory = true
        badge.textColor = .systemOrange
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        var collapseConfig = UIButton.Configuration.plain()
        collapseConfig.contentInsets = .init(top: 4, leading: 4, bottom: 4, trailing: 4)
        collapse.configuration = collapseConfig
        collapse.setContentHuggingPriority(.required, for: .horizontal)
        collapse.accessibilityIdentifier = "\(prefix).collapse"
        var stopConfig = UIButton.Configuration.tinted()
        stopConfig.title = String(localized: "停止")
        stopConfig.image = Theme.icon("stop.circle", pointSize: 12)
        stopConfig.imagePadding = 4
        stopConfig.cornerStyle = .capsule
        stopConfig.baseForegroundColor = .systemRed
        stopConfig.baseBackgroundColor = .systemRed
        stopConfig.buttonSize = .small
        stop.configuration = stopConfig
        stop.setContentHuggingPriority(.required, for: .horizontal)
        stop.setContentCompressionResistancePriority(.required, for: .horizontal)
        stop.accessibilityIdentifier = "\(prefix).stop"
        let header = UIStackView(arrangedSubviews: [icon, texts, badge, collapse, stop])
        header.axis = .horizontal
        header.spacing = 8
        header.alignment = .center
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = .init(top: 6, leading: 10, bottom: 6, trailing: 8)
        addArrangedSubview(header)

        imageArea.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        imageView.accessibilityIdentifier = "\(prefix).image"
        placeholder.textAlignment = .center
        for view in [imageView, placeholder] {
            imageArea.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        imageHeight = imageArea.heightAnchor.constraint(equalToConstant: 200)
        NSLayoutConstraint.activate([
            imageHeight,
            imageView.leadingAnchor.constraint(equalTo: imageArea.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: imageArea.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: imageArea.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: imageArea.bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: imageArea.leadingAnchor, constant: 16),
            placeholder.trailingAnchor.constraint(equalTo: imageArea.trailingAnchor, constant: -16),
            placeholder.centerYAnchor.constraint(equalTo: imageArea.centerYAnchor),
        ])
        addArrangedSubview(imageArea)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        title text: String, subtitle detail: String?, live: Bool, collapsed: Bool, stopping: Bool, stopEnabled: Bool,
        compact: Bool
    ) {
        title.text = text
        subtitle.text = detail
        subtitle.isHidden = detail?.isEmpty ?? true
        badge.isHidden = !live
        collapse.configuration?.image = Theme.icon(collapsed ? "chevron.up" : "chevron.down", pointSize: 12)
        collapse.accessibilityLabel = collapsed ? String(localized: "展开") : String(localized: "收起")
        stop.isEnabled = stopEnabled && !stopping
        stop.configuration?.showsActivityIndicator = stopping
        imageArea.isHidden = collapsed
        // Short screens (landscape iPhone) keep room for the timeline.
        imageHeight.constant = compact ? 130 : 200
    }

    func show(image: UIImage?, placeholder text: String, description: String) {
        imageView.image = image
        imageView.isHidden = image == nil
        imageView.accessibilityLabel = description
        placeholder.text = text
        placeholder.isHidden = image != nil
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: 0) } ?? self
    }
}
