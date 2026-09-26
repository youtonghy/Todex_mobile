import Foundation
import Synchronization

/// One connection owns one ordered encryption stream and one request ledger.
public actor RealtimeClient {
    /// Consume with one iterator. On overflow the retained prefix is followed by
    /// connection.closed and end-of-stream; create a fresh client to reconnect.
    public nonisolated let events: AsyncStream<JSONValue>
    private let eventQueue: RealtimeEventQueue
    private let connection: BackendConnection
    private let http: HTTPClient
    private let makeSocket: @Sendable (URLRequest) -> any RealtimeSocket
    private var socket: (any RealtimeSocket)?
    private var crypto: TransportCryptoSession?
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var generation = UUID()
    private var connected = false
    private var usedRequestIDs: Set<String> = []
    private struct Pending {
        let command: RealtimeCommand
        let token: UUID
        let continuation: CheckedContinuation<JSONValue, any Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [String: Pending] = [:]

    public init(connection: BackendConnection) {
        self.init(
            connection: connection, http: HTTPClient(connection: connection),
            makeSocket: { FoundationRealtimeSocket(request: $0) })
    }

    init(
        connection: BackendConnection, http: HTTPClient, eventCapacity: Int = 4096,
        makeSocket: @escaping @Sendable (URLRequest) -> any RealtimeSocket
    ) {
        self.connection = connection
        self.http = http
        self.makeSocket = makeSocket
        let queue = RealtimeEventQueue(capacity: eventCapacity)
        eventQueue = queue
        events = AsyncStream(unfolding: { await queue.next() }, onCancel: { queue.finish() })
    }

    public func connect() async throws {
        guard !eventQueue.isFinished else { throw TodexError.invalid(String(localized: "事件流已结束，请创建新的连接", bundle: .module)) }
        resetConnection()
        let revision = generation
        do {
            try Task.checkCancellation()
            let policy = try await http.response(
                path: "/v2/transport-policy", authenticated: false, timeout: 10, maximumBytes: 2048)
            try Self.validatePolicy(policy, connection: connection)
            try Task.checkCancellation()
            guard revision == generation else { throw CancellationError() }
            if connection.encryption != .none {
                do { crypto = try TransportCryptoSession(connection: connection) } catch {
                    throw TodexError.configuration(String(localized: "加密公钥无法使用：\(error.localizedDescription)", bundle: .module))
                }
            }
            var components = URLComponents(url: try connection.normalizedURL(), resolvingAgainstBaseURL: false)!
            components.scheme = components.scheme == "https" ? "wss" : "ws"
            components.path = "/v2/ws"
            // Transport-crypto material travels as query parameters so the
            // device signature binds the handshake to this enrolled device.
            var query = crypto?.handshakeQuery ?? ""
            if let device = DeviceIdentity(secretKeyBase64URL: connection.deviceSecret) {
                let auth = try device.authQuery(pathAndQuery: "/v2/ws\(query.isEmpty ? "" : "?\(query)")")
                query = query.isEmpty ? auth : "\(query)&\(auth)"
            }
            components.percentEncodedQuery = query.isEmpty ? nil : query
            guard let url = components.url else { throw TodexError.invalid(String(localized: "WebSocket 地址无效", bundle: .module)) }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpShouldHandleCookies = false
            let socket = makeSocket(request)
            self.socket = socket
            receiver = Task { [weak self] in await self?.receive(revision: revision, socket: socket) }
            let pong = try await sendCommand(
                type: "server.ping", payload: [:], timeout: 15, id: UUID().uuidString, verifying: true)
            guard pong["pong"] == .bool(true), revision == generation else { throw TodexError.invalid(CoreMessage.handshakeFailed) }
            try Task.checkCancellation()
            connected = true
            guard emit(["type": "connection.ready", "payload": [:]]) else { throw TodexError.disconnected }
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(25))
                        guard let self else { return }
                        _ = try await self.command(type: "server.ping", payload: [:], timeout: 12)
                    } catch {
                        if !Task.isCancelled { await self?.failed(error, revision: revision) }
                        return
                    }
                }
            }
        } catch {
            failed(error, revision: revision)
            throw error
        }
    }

    public func disconnect() { resetConnection() }

    private func resetConnection(reason: (any Error)? = nil) {
        generation = UUID()
        connected = false
        receiver?.cancel()
        receiver = nil
        heartbeat?.cancel()
        heartbeat = nil
        socket?.cancel()
        socket = nil
        crypto = nil
        usedRequestIDs.removeAll()
        let requests = pending
        pending.removeAll()
        for request in requests.values {
            request.timeout.cancel()
            request.continuation.resume(
                throwing: request.command.isReadOnly
                    ? (reason ?? TodexError.disconnected) : TodexError.unknownOutcome(String(localized: "连接中断，未收到操作确认", bundle: .module)))
        }
    }

    public func command(type: String, payload: JSONValue, timeout: TimeInterval = 30, id: String = UUID().uuidString)
        async throws -> JSONValue
    {
        try await sendCommand(type: type, payload: payload, timeout: timeout, id: id, verifying: false)
    }

    private func sendCommand(type: String, payload: JSONValue, timeout: TimeInterval, id: String, verifying: Bool)
        async throws -> JSONValue
    {
        try Task.checkCancellation()
        guard let socket, connected || (verifying && type == "server.ping") else { throw TodexError.disconnected }
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.utf8.count <= 256, !type.isEmpty,
            timeout.isFinite, timeout > 0, timeout <= 3600
        else { throw TodexError.invalid(String(localized: "请求 ID 或超时无效", bundle: .module)) }
        guard !usedRequestIDs.contains(id) else { throw TodexError.invalid(String(localized: "此连接已使用该请求 ID，请勿重复提交", bundle: .module)) }
        guard usedRequestIDs.count < 65_536 else { throw TodexError.invalid(String(localized: "连接请求计数已耗尽，请重新连接", bundle: .module)) }
        let command = RealtimeCommand(id: id, type: type, payload: payload)
        let data = try JSONEncoder().encode(
            JSONValue.object(["id": .string(id), "type": .string(type), "payload": payload]))
        guard data.count <= 4 * 1024 * 1024 else { throw TodexError.invalid(String(localized: "消息和附件编码后不能超过 4 MiB", bundle: .module)) }
        let plaintext = String(decoding: data, as: UTF8.self)
        let revision = generation
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Cancellation before submission must not consume a crypto nonce.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    // No await between encrypting, registering and enqueueing the
                    // frame. The actor owns crypto and the socket preserves sends.
                    let encoded = try crypto?.encrypt(plaintext) ?? plaintext
                    let timeoutTask = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                        await self?.expire(id, token: token, revision: revision)
                    }
                    usedRequestIDs.insert(id)
                    pending[id] = Pending(
                        command: command, token: token, continuation: continuation, timeout: timeoutTask)
                    socket.send(encoded) { [weak self] error in
                        if let error { Task { await self?.sendFailed(revision: revision, error: error) } }
                    }
                } catch {
                    continuation.resume(throwing: error)
                    failed(error, revision: revision)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id, token: token, revision: revision) }
        }
    }

    private func receive(revision: UUID, socket: any RealtimeSocket) async {
        do {
            while !Task.isCancelled && revision == generation {
                let raw = try await socket.receive()
                guard revision == generation, !Task.isCancelled else { return }
                let text = try crypto?.decrypt(raw) ?? raw
                let frame = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
                guard let response = RealtimeResponse(frame) else { throw TodexError.invalid(String(localized: "后端事件格式无效", bundle: .module)) }
                if let id = response.requestID, let request = pending[id],
                    let resolution = response.resolution(for: request.command)
                {
                    pending.removeValue(forKey: id)
                    request.timeout.cancel()
                    switch resolution {
                    case .success(let value): request.continuation.resume(returning: value)
                    case .failure(let error): request.continuation.resume(throwing: error)
                    }
                }
                guard emit(frame) else { return }
                if response.requestID == nil && ["server.error", "error"].contains(response.type)
                    && !Self.isScopedStreamError(response.payload)
                {
                    // Legacy dispatch errors omit the request id. Do not guess
                    // which mutation failed; close and mark all unresolved ones unknown.
                    failed(response.error, revision: revision)
                    return
                }
            }
        } catch {
            if !Task.isCancelled { failed(error, revision: revision) }
        }
    }

    @discardableResult
    private func emit(_ frame: JSONValue) -> Bool {
        switch eventQueue.offer(frame) {
        case .enqueued: return true
        case .overflow:
            resetConnection()
            // The original FIFO prefix is preserved. A reserved control slot
            // guarantees delivery without advancing cursors past the lost frame.
            eventQueue.finish(with: [
                "type": "connection.closed", "payload": ["code": "EVENT_BUFFER_OVERFLOW", "message": .string(String(localized: "接收队列已满，需要补齐事件", bundle: .module))],
            ])
            return false
        case .terminated:
            resetConnection()
            return false
        }
    }

    private func failed(_ error: any Error, revision: UUID) {
        guard revision == generation else { return }
        resetConnection(reason: error)
        var payload: JSONValue = [
            "message": .string(error.localizedDescription), "retryable": .bool(!TodexError.stopsReconnect(error)),
        ]
        if case TodexError.server(let code, _) = error { payload["code"] = .string(code) }
        emit(["type": "connection.closed", "payload": payload])
    }

    private func take(_ id: String, token: UUID, revision: UUID) -> Pending? {
        guard revision == generation, pending[id]?.token == token else { return nil }
        let request = pending.removeValue(forKey: id)
        request?.timeout.cancel()
        return request
    }
    private func expire(_ id: String, token: UUID, revision: UUID) {
        guard let request = take(id, token: token, revision: revision) else { return }
        request.continuation.resume(
            throwing: request.command.isReadOnly
                ? TodexError.invalid(String(localized: "等待后端响应超时", bundle: .module)) : TodexError.unknownOutcome(String(localized: "等待操作确认超时", bundle: .module)))
    }
    private func cancelRequest(_ id: String, token: UUID, revision: UUID) {
        guard let request = take(id, token: token, revision: revision) else { return }
        request.continuation.resume(
            throwing: request.command.isReadOnly ? CancellationError() : TodexError.unknownOutcome(String(localized: "已停止等待，操作可能已提交", bundle: .module)))
    }
    private func sendFailed(revision: UUID, error: any Error) {
        guard revision == generation else { return }
        // A failed encrypted send breaks the nonce sequence for the entire socket.
        // Its request may already have timed out or stopped waiting.
        failed(error, revision: revision)
    }

    /// Unidentified errors the backend attributes to one subscription stream
    /// rather than to a command: a forwarding task that died (it names the
    /// conversation) or a lag notice the backend recovers from by replaying.
    /// The socket and every other request stay healthy.
    static func isScopedStreamError(_ payload: JSONValue) -> Bool {
        !payload["conversationId"].stringValue.isEmpty || payload["code"] == "EVENT_STREAM_LAGGED"
    }

    static func validatePolicy(_ response: HTTPResult, connection: BackendConnection) throws {
        if response.statusCode != 404 {
            let value = try response.json()
            guard case .object = value, let name = value["requiredProtocol"].optionalString,
                let required = EncryptionProtocol(rawValue: name)
            else { throw TodexError.invalid(CoreMessage.invalidPolicy) }
            guard required == .none || required == connection.encryption else {
                throw TodexError.configuration(String(localized: "后端要求 \(name) 加密，请导入对应公钥", bundle: .module))
            }
        }
        if connection.encryption != .none
            && connection.publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw TodexError.configuration(String(localized: "尚未导入加密公钥，请先完成密钥传输验证", bundle: .module))
        }
    }

    static func socketError(_ error: any Error, response: URLResponse?) -> any Error {
        guard let response = response as? HTTPURLResponse, response.statusCode != 101 else { return error }
        let message =
            [401, 403].contains(response.statusCode)
            ? String(localized: "后端拒绝认证，请检查令牌与配对状态", bundle: .module) : String(localized: "WebSocket 握手失败（HTTP \(response.statusCode)）", bundle: .module)
        return TodexError.server(code: String(response.statusCode), message: message)
    }
}

struct RealtimeCommand: Sendable {
    let id: String
    let type: String
    let payload: JSONValue
    var isReadOnly: Bool {
        [
            "server.ping", "session.resume", "conversation.subscribe", "conversation.unsubscribe", "terminal.status", "codex.local.status",
            "codex.local.replay", "codex.local.snapshot", "codex.local.attach", "mcp.list",
        ].contains(type)
    }
}

/// Extract only envelope-level correlation, never ids buried in provider results
/// or notifications. Direct gateway replay and live bus wrappers are both valid.
struct RealtimeResponse: Sendable {
    let type: String
    let payload: JSONValue
    let requestID: String?
    let sessionID: String?

    init?(_ frame: JSONValue) {
        guard case .object = frame, let type = frame["type"].optionalString, !type.isEmpty,
            frame.objectValue["payload"] != nil
        else { return nil }
        self.type = type
        let outer = frame["payload"]
        let wrapped =
            type.hasPrefix("codex.") && outer.objectValue["data"] != nil
            && (outer.objectValue["cursor"] != nil || outer.objectValue["codex_session_id"] != nil)
        payload = wrapped ? outer["data"] : outer
        sessionID =
            payload["codexSessionId"].optionalString ?? payload["codex_session_id"].optionalString ?? outer[
                "codex_session_id"
            ].optionalString ?? frame["codex_session_id"].optionalString
        if type == "server.result" || type == "server.error" {
            requestID = frame["id"].optionalString.flatMap { $0.isEmpty ? nil : $0 }
        } else {
            var ids = [
                frame["id"].optionalString, payload["requestId"].optionalString, payload["request_id"].optionalString,
            ]
            if Self.errorTypes.contains(type) {
                ids += [payload["error"]["requestId"].optionalString, payload["error"]["request_id"].optionalString]
            }
            let unique = Set(ids.compactMap { $0 }.filter { !$0.isEmpty })
            requestID = unique.count == 1 ? unique.first : nil
        }
    }

    func resolution(for command: RealtimeCommand) -> Result<JSONValue, TodexError>? {
        guard requestID == command.id else { return nil }
        if let expected = command.payload["codexSessionId"].optionalString
            ?? command.payload["codex_session_id"].optionalString, let sessionID, expected != sessionID
        {
            return nil
        }
        if let expected = command.payload["terminalId"].optionalString,
            let actual = payload["terminalId"].optionalString, expected != actual
        {
            return nil
        }
        if Self.errorTypes.contains(type) { return .failure(error) }
        if ["terminal.audit", "codex.audit"].contains(type) {
            guard payload["decision"] == "deny", payload["action"] == .string(command.type) else { return nil }
            return .failure(.server(code: payload["reason_code"].optionalString ?? "UNAUTHORIZED", message: String(localized: "后端拒绝此操作", bundle: .module)))
        }
        switch command.type {
        case "codex.local.start":
            guard
                type == "codex.control.ready"
                    || (type == "codex.local.lifecycle" && payload["lifecycleState"] == "ready")
            else { return nil }
            if let state = payload["lifecycleState"].optionalString, state != "ready" { return nil }
        case "codex.local.stop":
            guard
                type == "codex.control.stopped"
                    || (type == "codex.local.lifecycle" && payload["lifecycleState"] == "stopped")
            else { return nil }
            if let state = payload["lifecycleState"].optionalString, state != "stopped" { return nil }
        case "codex.local.status": guard type == "codex.control.status" else { return nil }
        case "codex.local.snapshot": guard type == "codex.local.snapshot" else { return nil }
        case "codex.local.request", "codex.local.turn", "codex.local.input", "codex.local.steer",
            "codex.local.interrupt":
            guard type == "codex.control.response" else { return nil }
            guard let result = payload.objectValue["result"] else {
                return .failure(.unknownOutcome(String(localized: "Codex 响应缺少 result", bundle: .module)))
            }
            return .success(result)
        case "codex.local.approval.respond":
            // This acknowledgement is emitted after writing the JSON-RPC server
            // response; no second JSON-RPC response exists for an approval reply.
            guard type == "codex.control.request.accepted", payload["operation"] == .string(command.type) else {
                return nil
            }
        case "codex.gateway.control": guard type == "codex.gateway.control.accepted" else { return nil }
        case "terminal.start": guard type == "terminal.started" else { return nil }
        case "terminal.input": guard type == "terminal.input.accepted" else { return nil }
        case "terminal.stop": guard type == "terminal.stopping" else { return nil }
        case "terminal.resize": guard type == "terminal.resized" else { return nil }
        case "terminal.status": guard type == "terminal.status" else { return nil }
        case "codex.local.replay", "codex.local.attach":
            // The backend only republishes old events with their original ids.
            // There is no correlated completion; session.resume has an explicit ack.
            return nil
        default:
            guard type == "server.result", !command.type.hasPrefix("codex."), !command.type.hasPrefix("terminal.")
            else { return nil }
        }
        return .success(payload)
    }

    var error: TodexError {
        let nested = payload["error"]
        let code =
            nested["code"].optionalString ?? payload["code"].optionalString ?? Self.numericCode(nested["code"])
            ?? Self.numericCode(payload["code"]) ?? "ERROR"
        let message =
            nested["message"].optionalString ?? payload["message"].optionalString ?? nested.optionalString ?? String(localized: "后端操作失败", bundle: .module)
        return .server(code: code, message: message)
    }
    private static let errorTypes: Set<String> = [
        "server.error", "error", "codex.control.error", "codex.control.request.rejected", "terminal.error",
    ]
    private static func numericCode(_ value: JSONValue) -> String? {
        guard let number = value.doubleValue, number.isFinite, number.rounded() == number,
            abs(number) <= 9_007_199_254_740_991
        else { return nil }
        return String(Int64(number))
    }
}

/// Synchronous, bounded FIFO shared with AsyncStream's consumer. Overflow never
/// evicts a sequence-bearing event; one extra slot is reserved for terminal notice.
final class RealtimeEventQueue: Sendable {
    enum Offer { case enqueued, overflow, terminated }
    private struct State {
        var frames: [JSONValue] = []
        var head = 0
        var waiters: [CheckedContinuation<JSONValue?, Never>] = []
        var finished = false
    }
    private let capacity: Int
    private let state = Mutex(State())
    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }
    var isFinished: Bool { state.withLock { $0.finished } }
    func offer(_ frame: JSONValue) -> Offer {
        var waiter: CheckedContinuation<JSONValue?, Never>?
        let result: Offer = state.withLock {
            if $0.finished { return .terminated }
            if !$0.waiters.isEmpty {
                waiter = $0.waiters.removeFirst()
                return .enqueued
            }
            guard $0.frames.count - $0.head < capacity else { return .overflow }
            $0.frames.append(frame)
            return .enqueued
        }
        waiter?.resume(returning: frame)
        return result
    }
    func next() async -> JSONValue? {
        await withCheckedContinuation { continuation in
            let result: (Bool, JSONValue?) = state.withLock {
                if $0.head < $0.frames.count {
                    let frame = $0.frames[$0.head]
                    $0.head += 1
                    if $0.head >= 256 {
                        $0.frames.removeFirst($0.head)
                        $0.head = 0
                    }
                    return (true, frame)
                }
                if $0.finished { return (true, nil) }
                $0.waiters.append(continuation)
                return (false, nil)
            }
            if result.0 { continuation.resume(returning: result.1) }
        }
    }
    func finish(with finalFrame: JSONValue? = nil) {
        let waiters: [CheckedContinuation<JSONValue?, Never>] = state.withLock {
            guard !$0.finished else { return [] }
            $0.finished = true
            let waiters = $0.waiters
            $0.waiters.removeAll()
            if let finalFrame, waiters.isEmpty { $0.frames.append(finalFrame) }
            return waiters
        }
        for (index, waiter) in waiters.enumerated() { waiter.resume(returning: index == 0 ? finalFrame : nil) }
    }
}

protocol RealtimeSocket: Sendable {
    func send(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void)
    func receive() async throws -> String
    func cancel()
}

private final class SocketRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

private final class FoundationRealtimeSocket: RealtimeSocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    init(request: URLRequest) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: SocketRedirectDelegate(), delegateQueue: nil)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 8 * 1024 * 1024
        task.resume()
    }
    func send(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void) {
        task.send(.string(text)) { [task] error in
            completion(error.map { RealtimeClient.socketError($0, response: task.response) })
        }
    }
    func receive() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let value): return value
            case .data(let value):
                guard let text = String(data: value, encoding: .utf8) else { throw TodexError.invalid(String(localized: "收到非 UTF-8 消息", bundle: .module)) }
                return text
            @unknown default: throw TodexError.invalid(String(localized: "收到未知消息格式", bundle: .module))
            }
        } catch { throw RealtimeClient.socketError(error, response: task.response) }
    }
    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}
