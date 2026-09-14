import SwiftTerm
import TodexCore
import UIKit

@MainActor
final class WorkbenchTerminalViewController: UIViewController, @preconcurrency TerminalViewDelegate,
    UITextFieldDelegate
{
    private enum State { case idle, checking, starting, running, stopping, exited, unknown }
    private var descriptor: WorkbenchTab
    private let connection: BackendConnection
    private let workspace: WorkspaceRecord
    private let command: WorkbenchCommand
    private let update: @MainActor (WorkbenchTab) -> Void
    private let terminal = TerminalView(frame: .zero)
    private let statusLabel = UILabel()
    private let gapLabel = UILabel()
    private let directory = UITextField()
    private let shell = UITextField()
    private var state: State = .idle
    private var cols = 80
    private var rows = 24
    private var inputQueue: [String] = []
    private var inputGeneration = UUID()
    private var inputTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var actionButton: UIButton!
    private var autoStarted = false
    private var manualStop = false
    private var seenEvents = Set<String>()
    private var eventOrder: [String] = []
    private var hasCheckedStatus = false
    private var terminalId: String { descriptor.terminalId ?? "" }

    init(
        tab descriptor: WorkbenchTab, connection: BackendConnection, workspace: WorkspaceRecord,
        command: @escaping WorkbenchCommand,
        update: @escaping @MainActor (WorkbenchTab) -> Void
    ) {
        self.descriptor = descriptor
        self.connection = connection
        self.workspace = workspace
        self.command = command
        self.update = update
        super.init(nibName: nil, bundle: nil)
        if self.descriptor.terminalId == nil { self.descriptor.terminalId = "terminal_\(UUID().uuidString)" }
        terminal.terminalDelegate = self
        terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeBackgroundColor = Theme.secondary
        terminal.nativeForegroundColor = .label
        terminal.caretColor = Theme.accent
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        inputTask?.cancel()
        resizeTask?.cancel()
        statusTask?.cancel()
        operationTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        directory.text = descriptor.path
        directory.placeholder = "后端工作目录"
        directory.borderStyle = .roundedRect
        directory.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        directory.autocorrectionType = .no
        directory.autocapitalizationType = .none
        directory.spellCheckingType = .no
        directory.returnKeyType = .go
        directory.delegate = self
        directory.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        shell.placeholder = "Shell（默认）"
        shell.borderStyle = .roundedRect
        shell.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        shell.autocorrectionType = .no
        shell.autocapitalizationType = .none
        shell.spellCheckingType = .no
        shell.delegate = self
        shell.widthAnchor.constraint(equalToConstant: 108).isActive = true
        shell.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (self: WorkbenchTerminalViewController, _: UITraitCollection) in
            self.terminal.superview?.layer.borderColor = UIColor.separator.cgColor
        }
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textAlignment = .right
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.accessibilityIdentifier = "workbench.terminal.status"
        terminal.accessibilityIdentifier = "workbench.terminal.screen"
        gapLabel.font = .preferredFont(forTextStyle: .caption1)
        gapLabel.numberOfLines = 0
        gapLabel.textColor = .systemOrange
        gapLabel.isHidden = true
        actionButton = Theme.iconButton("play.fill")
        actionButton.accessibilityLabel = "启动"
        actionButton.addAction(
            UIAction { [weak self] _ in self?.primaryAction() }, for: .primaryActionTriggered)
        let options = Theme.iconButton("ellipsis", pointSize: 11)
        options.accessibilityLabel = "终端选项"
        options.showsMenuAsPrimaryAction = true
        options.menu = UIMenu(children: [
            UIAction(title: "刷新状态", image: Theme.icon("arrow.clockwise", pointSize: 13)) {
                [weak self] _ in self?.refreshStatus()
            },
            UIAction(title: "连接已有 PTY", image: Theme.icon("link", pointSize: 13)) {
                [weak self] _ in self?.chooseExistingTerminal()
            },
            UIAction(title: "清屏", image: Theme.icon("xmark.circle", pointSize: 13)) {
                [weak self] _ in self?.clearOutput()
            },
        ])
        let top = UIStackView(arrangedSubviews: [directory, shell, statusLabel, actionButton, options])
        top.axis = .horizontal
        top.spacing = 6
        top.alignment = .center
        let surface = UIView()
        surface.backgroundColor = Theme.secondary
        surface.layer.cornerRadius = 12
        surface.layer.cornerCurve = .continuous
        surface.layer.borderWidth = 0.5
        surface.layer.borderColor = UIColor.separator.cgColor
        surface.clipsToBounds = true
        surface.addSubview(terminal)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 6),
            terminal.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -6),
            terminal.topAnchor.constraint(equalTo: surface.topAnchor, constant: 6),
            terminal.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -6),
        ])
        WBUI.installStack(in: view, views: [top, gapLabel, surface], keyboard: true)
        renderState("尚未核对后端 PTY")
        // A restored ID must be queried before starting; it can already name a live process.
        markGap("仅恢复 PTY 标识；离开操作台期间的输出和历史滚屏无法重放。")
        refreshStatus()
    }
    private func primaryAction() {
        if [.running, .unknown, .starting].contains(state) {
            WBUI.confirm(on: self, title: "停止此终端？", message: "将结束后端 PTY 中的进程。", action: "停止") {
                [weak self] in
                guard let self else { return }
                self.manualStop = true
                self.operationTask = Task { [weak self] in
                    do { try await self?.stop() } catch { if let self { WBUI.error(error, on: self) } }
                }
            }
        } else {
            start()
        }
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        guard textField === directory else { return true }
        let cwd = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cwd.isEmpty else { return true }
        descriptor.path = cwd
        update(descriptor)
        if state == .running {
            enqueue("cd \"\(cwd.replacingOccurrences(of: "\"", with: "\\\""))\"\r")
        }
        return true
    }

    private var identity: [String: JSONValue] {
        ["terminalId": .string(terminalId), "tenantId": .string(tenantId)]
    }
    /// Backend-assigned workspace tenant wins; an empty one falls back to the
    /// connection's configured tenant, matching the desktop client.
    private var tenantId: String {
        workspace.tenantId.isEmpty ? connection.tenantId : workspace.tenantId
    }
    private func renderState(_ text: String) {
        statusLabel.text = text
        guard isViewLoaded else { return }
        let startable = hasCheckedStatus && [.idle, .exited].contains(state)
        let stoppable = [.running, .unknown, .starting].contains(state)
        actionButton.isEnabled = startable || stoppable
        actionButton.configuration?.image = Theme.icon(stoppable ? "stop.fill" : "play.fill", pointSize: 13)
        actionButton.configuration?.baseForegroundColor = stoppable ? .systemRed : Theme.accent
        actionButton.accessibilityLabel = stoppable ? "停止" : "启动"
        if state != .running { _ = terminal.resignFirstResponder() }
    }
    func markGap(_ message: String) {
        gapLabel.text = message
        gapLabel.isHidden = false
        if [.running, .starting, .stopping].contains(state) {
            state = .unknown
            renderState("状态待核对 · 输入已暂停")
        }
        inputGeneration = UUID()
        inputQueue.removeAll()
        inputTask?.cancel()
        inputTask = nil
    }
    func refreshStatus() {
        guard statusTask == nil else { return }
        statusTask = Task { [weak self] in
            guard let self else { return }
            defer { self.statusTask = nil }
            do {
                var payload = self.identity
                payload["workspaceId"] = .string(self.workspace.id)
                let result = try await self.command("terminal.status", .object(payload), 15)
                if let error = WBEvent.failure(result) { throw TodexError.invalid(error) }
                let data = WBEvent.data(result)
                if !data["terminals"].isNull {
                    self.applyStatus(data)
                } else if !self.hasCheckedStatus {
                    self.renderState("已请求状态，等待终端事件…")
                }
            } catch {
                self.state = .unknown
                self.renderState("状态查询失败：\(error.localizedDescription)")
            }
        }
    }
    private func chooseExistingTerminal() {
        guard [.idle, .exited].contains(state), hasCheckedStatus else {
            WBUI.message(on: self, title: "请新建终端标签", text: "当前标签的 PTY 仍可能在运行。新建一个空终端标签后，可通过「已有」重新连接保留的 PTY。")
            return
        }
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.operationTask = nil }
            do {
                let result = try await self.command(
                    "terminal.status",
                    ["tenantId": .string(self.tenantId), "workspaceId": .string(self.workspace.id)], 15)
                let data = WBEvent.data(result)
                guard case .array(let records) = data["terminals"] else {
                    throw TodexError.invalid("未收到终端列表；请确认宿主返回 terminal.status 实际结果")
                }
                let candidates = records.filter {
                    $0["tenantId"].stringValue == self.tenantId
                        && $0["workspaceId"].stringValue == self.workspace.id
                }
                guard !candidates.isEmpty else {
                    WBUI.message(on: self, title: "没有运行中的终端", text: "此工作区没有可以重新连接的 PTY。")
                    return
                }
                let sheet = UIAlertController(
                    title: "连接已有 PTY", message: "此前输出无法重放；只会接收连接后的输出。", preferredStyle: .actionSheet)
                for record in candidates {
                    guard let id = record["terminalId"].optionalString else { continue }
                    sheet.addAction(
                        UIAlertAction(title: "PID \(record["pid"].intValue) · \(id)", style: .default) {
                            [weak self] _ in
                            guard let self else { return }
                            self.terminal.getTerminal().resetToInitialState()
                            self.seenEvents.removeAll()
                            self.eventOrder.removeAll()
                            self.descriptor.terminalId = id
                            self.update(self.descriptor)
                            self.markGap("已连接现有 PTY；此前输出不可恢复。")
                            self.refreshStatus()
                        })
                }
                WBUI.presentSheet(sheet, on: self)
            } catch { WBUI.error(error, on: self) }
        }
    }
    /// Local view reset only; the remote PTY keeps running and nothing is sent.
    private func clearOutput() {
        terminal.getTerminal().resetToInitialState()
    }
    private func start() {
        guard hasCheckedStatus, [.idle, .exited].contains(state), operationTask == nil else { return }
        let cwd = (directory.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard cwd.hasPrefix("/") else {
            WBUI.message(on: self, title: "目录无效", text: "请输入后端绝对路径。")
            return
        }
        let shellPath = (shell.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard shellPath.isEmpty || shellPath.hasPrefix("/") else {
            WBUI.message(on: self, title: "Shell 无效", text: "请填写 Shell 的绝对路径，或留空使用后端默认。")
            return
        }
        state = .starting
        renderState("启动 PTY 中…")
        terminal.getTerminal().resetToInitialState()
        gapLabel.isHidden = true
        descriptor.path = cwd
        update(descriptor)
        var payload = identity
        payload["workspaceId"] = .string(workspace.id)
        payload["cwd"] = .string(cwd)
        if !shellPath.isEmpty { payload["shell"] = .string(shellPath) }
        payload["cols"] = .number(Double(cols))
        payload["rows"] = .number(Double(rows))
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.operationTask = nil }
            do {
                let result = try await self.command("terminal.start", .object(payload), 20)
                if let error = WBEvent.failure(result) { throw TodexError.invalid(error) }
                let data = WBEvent.data(result)
                if self.state == .starting && data["terminalId"].stringValue == self.terminalId
                    && data["lifecycleState"].stringValue == "running"
                {
                    self.state = .running
                    self.renderState("运行中 · PTY \(self.terminalId)")
                    self.scheduleResize()
                }
                for _ in 0..<150 where self.state == .starting { try await Task.sleep(for: .milliseconds(100)) }
                if self.state == .starting { throw TodexError.unknownOutcome("未收到 terminal.started，请查询状态") }
            } catch {
                self.state = .unknown
                self.renderState(error.localizedDescription)
                self.markGap("启动结果需核对；不会自动重试创建 PTY。")
            }
        }
    }
    func stop() async throws {
        if [.idle, .exited].contains(state), hasCheckedStatus { return }
        state = .stopping
        renderState("正在停止 PTY…")
        inputGeneration = UUID()
        inputQueue.removeAll()
        inputTask?.cancel()
        inputTask = nil
        do {
            var payload = identity
            payload["force"] = false
            let result = try await command("terminal.stop", .object(payload), 20)
            if let error = WBEvent.failure(result) { throw TodexError.invalid(error) }
            // Stop acknowledgement means a signal was sent, not that the process has exited.
            for _ in 0..<150 {
                if [.exited, .idle].contains(state) { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw TodexError.unknownOutcome("已请求停止但尚未确认退出，请查询状态")
        } catch {
            state = .unknown
            renderState(error.localizedDescription)
            throw error
        }
    }
    private func applyStatus(_ data: JSONValue) {
        if let tenant = data["tenantId"].optionalString, tenant != tenantId { return }
        guard case .array = data["terminals"] else {
            state = .unknown
            renderState("终端状态响应缺少列表，无法确认 PTY 状态。")
            return
        }
        guard
            data["terminalId"].optionalString == terminalId
                || data["terminals"].arrayValue.contains(where: { $0["terminalId"].stringValue == terminalId })
        else { return }
        hasCheckedStatus = true
        if let running = data["terminals"].arrayValue.first(where: { $0["terminalId"].stringValue == terminalId }) {
            guard running["tenantId"].optionalString == nil || running["tenantId"].stringValue == tenantId
            else { return }
            guard running["workspaceId"].optionalString == nil || running["workspaceId"].stringValue == workspace.id
            else {
                state = .unknown
                renderState("该 PTY 属于另一个工作区，未连接。")
                return
            }
            state = .running
            renderState("运行中 · PID \(running["pid"].intValue)")
            if let cwd = running["cwd"].optionalString {
                directory.text = cwd
                descriptor.path = cwd
                update(descriptor)
            }
            if let value = running["shell"].optionalString, !value.isEmpty { shell.text = value }
            scheduleResize()
        } else {
            state = .idle
            let siblings = data["terminals"].arrayValue.filter {
                $0["tenantId"].stringValue == self.tenantId
                    && $0["workspaceId"].stringValue == self.workspace.id
            }
            if siblings.isEmpty {
                renderState("后端不存在运行中的此 PTY · 可启动新进程")
                // Mirror the desktop: a terminal tab starts its PTY automatically once the
                // backend confirms nothing is running under this id.
                if !autoStarted && !manualStop {
                    autoStarted = true
                    start()
                }
            } else {
                renderState("此 PTY 未在运行 · \(siblings.count) 个已有 PTY 可通过「终端选项」连接")
            }
        }
    }
    func receive(_ event: JSONValue) {
        let type = event["type"].stringValue
        guard type.hasPrefix("terminal."), type != "terminal.audit" else { return }
        let data = WBEvent.data(event)
        if let tenant = data["tenantId"].optionalString, tenant != tenantId { return }
        if let workspaceId = data["workspaceId"].optionalString ?? event["workspace_id"].optionalString,
            workspaceId != workspace.id
        {
            return
        }
        if type == "terminal.status" {
            applyStatus(data)
            return
        }
        guard (data["terminalId"].optionalString ?? event["pane_id"].optionalString) == terminalId else { return }
        if let id = event["event_id"].optionalString {
            guard seenEvents.insert(id).inserted else { return }
            eventOrder.append(id)
            if eventOrder.count > 512 { seenEvents.remove(eventOrder.removeFirst()) }
        }
        switch type {
        case "terminal.output":
            if let text = data["data"].optionalString { terminal.feed(byteArray: Array(text.utf8)[...]) }
        case "terminal.started":
            state = .running
            hasCheckedStatus = true
            renderState("运行中 · PID \(data["pid"].intValue)")
            if let value = data["shell"].optionalString, !value.isEmpty { shell.text = value }
            scheduleResize()
        case "terminal.stopping":
            state = .stopping
            renderState("停止信号已发送，等待退出…")
        case "terminal.exited":
            state = .exited
            hasCheckedStatus = true
            renderState(
                data["error"].optionalString
                    ?? "已退出 · exit \(data["exitCode"].optionalString ?? data["exitCode"].prettyPrinted)")
        case "terminal.error":
            state = .unknown
            renderState(WBEvent.failure(event) ?? "终端错误，请查询状态")
        default: break
        }
    }
    private func enqueue(_ text: String) {
        guard state == .running, !text.isEmpty else { return }
        guard inputQueue.reduce(0, { $0 + $1.utf8.count }) + text.utf8.count <= 256 * 1024 else {
            markGap("输入队列已满，未发送本次输入；请核对终端后继续。")
            return
        }
        inputQueue.append(text)
        guard inputTask == nil else { return }
        let generation = inputGeneration
        inputTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.inputGeneration == generation { self.inputTask = nil } }
            do {
                while !self.inputQueue.isEmpty, self.state == .running, self.inputGeneration == generation {
                    try Task.checkCancellation()
                    let text = self.inputQueue.removeFirst()
                    var payload = self.identity
                    payload["data"] = .string(text)
                    let result = try await self.command("terminal.input", .object(payload), 15)
                    if let error = WBEvent.failure(result) { throw TodexError.invalid(error) }
                }
            } catch {
                guard self.inputGeneration == generation else { return }
                self.inputQueue.removeAll()
                self.markGap("输入确认失败，可能已被执行；不会重发。\(error.localizedDescription)")
            }
        }
    }
    private func scheduleResize() {
        resizeTask?.cancel()
        guard state == .running else { return }
        resizeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                guard let self, self.state == .running else { return }
                var payload = self.identity
                payload["cols"] = .number(Double(self.cols))
                payload["rows"] = .number(Double(self.rows))
                let result = try await self.command("terminal.resize", .object(payload), 15)
                if let error = WBEvent.failure(result) { throw TodexError.invalid(error) }
            } catch {
                if !Task.isCancelled { self?.renderState("尺寸同步失败：\(error.localizedDescription)") }
            }
        }
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let text = String(bytes: data, encoding: .utf8) else {
            renderState("后端 terminal.input 仅支持 UTF-8 文本；此输入未发送。")
            return
        }
        enqueue(text)
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        cols = max(20, min(newCols, 400))
        rows = max(8, min(newRows, 200))
        scheduleResize()
    }
    func setTerminalTitle(source: TerminalView, title: String) {
        // Delegate callbacks can run under SwiftTerm's lock; avoid re-entering its view/layout here.
        Task { [weak self] in
            guard let self, !title.isEmpty else { return }
            self.descriptor.title = String(title.prefix(32))
            self.update(self.descriptor)
        }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        Task { [weak self] in
            guard let self, let text = String(data: content, encoding: .utf8), self.viewIfLoaded?.window != nil else {
                return
            }
            WBUI.confirm(on: self, title: "复制终端内容？", message: String(text.prefix(300)), action: "复制") {
                UIPasteboard.general.string = text
            }
        }
    }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        Task { [weak self] in
            guard let self, let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { return }
            WBUI.confirm(on: self, title: "打开终端链接？", message: link, action: "打开") { UIApplication.shared.open(url) }
        }
    }
}
