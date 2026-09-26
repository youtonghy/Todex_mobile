import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import TodexCore

struct RealtimeClientTests {
    @Test func legacyStartRequiresReadyAndRequestRequiresInnerResult() throws {
        let start = RealtimeCommand(id: "r1", type: "codex.local.start", payload: ["codexSessionId": "session"])
        for type in [
            "codex.control.starting", "codex.control.request.accepted", "codex.control.response", "codex.item.started",
            "codex.audit",
        ] {
            #expect(
                try response(type, ["requestId": "r1", "lifecycleState": "starting", "codexSessionId": "session"])
                    .resolution(for: start) == nil)
        }
        let ready: JSONValue = [
            "requestId": "r1", "operation": "codex.local.start", "lifecycleState": "ready", "codexSessionId": "session",
        ]
        #expect(try success(response("codex.control.ready", ready).resolution(for: start)) == ready)
        #expect(
            try response("codex.control.ready", ["requestId": "r1", "lifecycleState": "starting"]).resolution(
                for: start) == nil)
        #expect(
            try response("codex.local.lifecycle", ["requestId": "r1", "lifecycleState": "starting"]).resolution(
                for: start) == nil)
        #expect(try success(response("codex.local.lifecycle", ready).resolution(for: start)) == ready)
        let request = RealtimeCommand(id: "r1", type: "codex.local.request", payload: ["codexSessionId": "session"])
        let inner: JSONValue = ["data": ["requestId": "foreign"], "value": 42]
        #expect(
            try success(
                response("codex.control.response", ["requestId": "r1", "result": inner], wrapped: true).resolution(
                    for: request)) == inner)
        #expect(
            try success(
                response("codex.control.response", ["requestId": "r1", "result": nil]).resolution(for: request))
                == .null)
        #expect(try response("codex.control.request.accepted", ["requestId": "r1"]).resolution(for: request) == nil)
        let malformed = try response("codex.control.response", ["requestId": "r1"])
        if case .failure(.unknownOutcome) = malformed.resolution(for: request) {
        } else {
            Issue.record("Missing result must not look successful")
        }
    }

    @Test(arguments: [
        ("terminal.start", "terminal.started"), ("terminal.input", "terminal.input.accepted"),
        ("terminal.stop", "terminal.stopping"), ("terminal.resize", "terminal.resized"),
        ("terminal.status", "terminal.status"), ("codex.local.status", "codex.control.status"),
        ("codex.local.stop", "codex.control.stopped"), ("codex.local.snapshot", "codex.local.snapshot"),
    ])
    func onlyTheSpecificDefinitiveLegacyResponseSettles(_ pair: (String, String)) throws {
        let command = RealtimeCommand(id: "request", type: pair.0, payload: [:])
        let payload: JSONValue = ["requestId": "request", "data": "terminal data remains data"]
        #expect(try success(response(pair.1, payload).resolution(for: command)) == payload)
        for unrelated in [
            "terminal.audit", "terminal.output", "terminal.exited", "codex.control.starting",
            "codex.control.request.accepted",
        ] {
            #expect(try response(unrelated, payload).resolution(for: command) == nil)
        }
    }

    @Test func correlationNeverUsesProviderIDsAndRejectsConflictsOrOtherScopes() throws {
        let command = RealtimeCommand(id: "r", type: "codex.local.request", payload: ["codexSessionId": "session"])
        #expect(
            try response("codex.control.response", ["requestId": "other", "result": ["requestId": "r"]]).resolution(
                for: command) == nil)
        #expect(
            try response("codex.control.response", ["requestId": "r", "request_id": "other", "result": true])
                .resolution(for: command) == nil)
        #expect(
            try response("codex.control.response", ["requestId": "r", "codexSessionId": "other", "result": true])
                .resolution(for: command) == nil)
        let nested = try response(
            "codex.control.error", ["error": ["requestId": "r", "code": -32601, "message": "unknown method"]],
            wrapped: true)
        if case .failure(.server(let code, let message)) = nested.resolution(for: command) {
            #expect(code == "-32601" && message == "unknown method")
        } else {
            Issue.record("Expected correlated JSON-RPC error")
        }
        let rejected = try response(
            "codex.control.request.rejected", ["requestId": "r", "error": ["code": "BUSY", "message": "busy"]])
        if case .failure(.server("BUSY", _)) = rejected.resolution(for: command) {
        } else {
            Issue.record("Rejected is a failure, not an acknowledgement")
        }
        let native = try #require(
            RealtimeResponse([
                "id": "native", "type": "server.result", "payload": ["data": ["requestId": "r"], "value": 1],
            ]))
        #expect(
            try success(native.resolution(for: .init(id: "native", type: "conversation.create", payload: [:]))) == [
                "data": ["requestId": "r"], "value": 1,
            ])
        #expect(native.resolution(for: command) == nil)
        #expect(
            try response("terminal.started", ["requestId": "t", "terminalId": "different"]).resolution(
                for: .init(id: "t", type: "terminal.start", payload: ["terminalId": "expected"])) == nil)
    }

    @Test func auditAllowsAndUnacknowledgedReplayNeverManufactureSuccess() throws {
        let command = RealtimeCommand(id: "r", type: "terminal.start", payload: [:])
        #expect(
            try response("terminal.audit", ["request_id": "r", "decision": "allow", "action": "terminal.start"])
                .resolution(for: command) == nil)
        if case .failure(.server("TENANT_MISMATCH", _)) = try response(
            "terminal.audit",
            ["request_id": "r", "decision": "deny", "action": "terminal.start", "reason_code": "TENANT_MISMATCH"]
        ).resolution(for: command) {
        } else {
            Issue.record("Denied audit must fail")
        }
        for type in ["codex.local.replay", "codex.local.attach"] {
            #expect(
                try response("codex.control.ready", ["requestId": "r"]).resolution(
                    for: .init(id: "r", type: type, payload: [:])) == nil)
        }
        let approval = RealtimeCommand(id: "r", type: "codex.local.approval.respond", payload: [:])
        let accepted: JSONValue = ["requestId": "r", "operation": "codex.local.approval.respond"]
        #expect(try success(response("codex.control.request.accepted", accepted).resolution(for: approval)) == accepted)
        #expect(
            try response("codex.control.request.accepted", ["requestId": "r", "operation": "codex.local.turn"])
                .resolution(for: approval) == nil)
    }

    @Test func full4096EventBufferPreservesPrefixAndAlwaysDeliversClosed() async throws {
        let queue = RealtimeEventQueue(capacity: 4096)
        for index in 0..<4096 { #expect(queue.offer(.number(Double(index))) == .enqueued) }
        #expect(queue.offer("lost") == .overflow)
        let closed: JSONValue = ["type": "connection.closed", "payload": ["code": "EVENT_BUFFER_OVERFLOW"]]
        queue.finish(with: closed)
        #expect(queue.offer("after close") == .terminated)
        for index in 0..<4096 { #expect(await queue.next() == .number(Double(index))) }
        #expect(await queue.next() == closed)
        #expect(await queue.next() == nil)
    }

    @Test func actorPendingStartSurvivesStartingAndAcceptedFrames() async throws {
        let fixture = NetworkHTTPFixture { _ in .json(["requiredProtocol": "none"]) }
        defer { fixture.close() }
        let socket = ScriptedRealtimeSocket()
        let client = RealtimeClient(
            connection: fixture.client().connection, http: fixture.client(), makeSocket: { _ in socket })
        try await client.connect()
        let resultFlag = RealtimeFlag()
        let work = Task {
            let result = try await client.command(type: "codex.local.start", payload: [:], id: "start")
            resultFlag.set()
            return result
        }
        await socket.waitForSent(2)
        try socket.push(["type": "codex.control.starting", "payload": ["requestId": "start"]])
        try socket.push(["type": "codex.control.request.accepted", "payload": ["requestId": "start"]])
        // A subsequent ping response is a receive-loop barrier for the two events.
        _ = try await client.command(type: "server.ping", payload: [:])
        #expect(!resultFlag.value)
        try socket.push(["type": "codex.control.ready", "payload": ["requestId": "start", "lifecycleState": "ready"]])
        #expect(try await work.value == ["requestId": "start", "lifecycleState": "ready"])
        await client.disconnect()
    }

    @Test func actorOverflowClosesSocketAndDoesNotYieldPastTheGap() async throws {
        let fixture = NetworkHTTPFixture { _ in .json(["requiredProtocol": "none"]) }
        defer { fixture.close() }
        let socket = ScriptedRealtimeSocket()
        let client = RealtimeClient(
            connection: fixture.client().connection, http: fixture.client(), eventCapacity: 4,
            makeSocket: { _ in socket })
        try await client.connect()
        // connect emits its ping response and connection.ready; two slots remain.
        for index in 1...3 {
            try socket.push(["type": "conversation.event", "payload": ["sequence": .number(Double(index))]])
        }
        await socket.waitForCancel()
        var received: [JSONValue] = []
        for await event in client.events { received.append(event) }
        #expect(received.last?["type"] == "connection.closed")
        #expect(received.last?["payload"]["code"] == "EVENT_BUFFER_OVERFLOW")
        #expect(received.filter { $0["type"] == "conversation.event" }.map { $0["payload"]["sequence"] } == [1, 2])
        await #expect(throws: (any Error).self) { try await client.connect() }
    }

    @Test func mutationTimeoutCancellationAndUncorrelatedErrorNeverRetry() async throws {
        let fixture = NetworkHTTPFixture { _ in .json(["requiredProtocol": "none"]) }
        defer { fixture.close() }
        let socket = ScriptedRealtimeSocket()
        let client = RealtimeClient(
            connection: fixture.client().connection, http: fixture.client(), makeSocket: { _ in socket })
        try await client.connect()
        do {
            _ = try await client.command(type: "conversation.create", payload: [:], timeout: 0.02, id: "once")
            Issue.record("Expected timeout")
        } catch TodexError.unknownOutcome {}
        await #expect(throws: (any Error).self) {
            try await client.command(type: "conversation.create", payload: [:], id: "once")
        }
        let cancelled = Task { try await client.command(type: "conversation.prompt", payload: [:], id: "cancelled") }
        await socket.waitForSent(3)
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("Expected unknown cancellation outcome")
        } catch TodexError.unknownOutcome {}
        let work = Task { try await client.command(type: "terminal.start", payload: [:], id: "terminal") }
        await socket.waitForSent(4)
        try socket.push([
            "type": "error", "payload": ["code": "WORKSPACE_TRUST_REQUIRED", "message": "trust required"],
        ])
        do {
            _ = try await work.value
            Issue.record("Cannot assign an uncorrelated error to one mutation")
        } catch TodexError.unknownOutcome {}
        #expect(socket.sent.count == 4)
        await socket.waitForCancel()
    }

    @Test func subscriptionScopedStreamErrorsKeepTheSocketAndPendingMutations() async throws {
        let fixture = NetworkHTTPFixture { _ in .json(["requiredProtocol": "none"]) }
        defer { fixture.close() }
        let socket = ScriptedRealtimeSocket()
        let client = RealtimeClient(
            connection: fixture.client().connection, http: fixture.client(), makeSocket: { _ in socket })
        try await client.connect()
        let work = Task { try await client.command(type: "conversation.prompt", payload: [:], id: "prompt") }
        await socket.waitForSent(2)
        // v2.rs: lag notices carry no conversation; dead forwarders name one.
        try socket.push(["type": "server.error", "payload": ["code": "EVENT_STREAM_LAGGED", "message": "lagged"]])
        try socket.push([
            "type": "server.error", "payload": ["code": "CONFLICT", "message": "gap", "conversationId": "c"],
        ])
        // A ping round trip is a receive-loop barrier for both frames.
        _ = try await client.command(type: "server.ping", payload: [:])
        #expect(!socket.isCancelled)
        try socket.push(["type": "server.result", "id": "prompt", "payload": ["accepted": true]])
        #expect(try await work.value == ["accepted": true])
        var iterator = client.events.makeAsyncIterator()
        var types: [String] = []
        while types.count < 5, let frame = await iterator.next() { types.append(frame["type"].stringValue) }
        #expect(!types.contains("connection.closed"))
        #expect(types.filter { $0 == "server.error" }.count == 2)
        await client.disconnect()
    }

    @Test func permanentConnectionFailuresAreMarkedNotRetryable() {
        #expect(TodexError.stopsReconnect(TodexError.configuration("key")))
        #expect(TodexError.stopsReconnect(TodexError.server(code: "401", message: "")))
        #expect(!TodexError.stopsReconnect(TodexError.server(code: "500", message: "")))
        #expect(!TodexError.stopsReconnect(TodexError.invalid("timeout")))
        #expect(!TodexError.stopsReconnect(URLError(.networkConnectionLost)))
    }

    @Test func staleSendCallbackCannotCloseANewConnectionWithTheSameRequestID() async throws {
        let fixture = NetworkHTTPFixture { _ in .json(["requiredProtocol": "none"]) }
        defer { fixture.close() }
        let first = ScriptedRealtimeSocket()
        let second = ScriptedRealtimeSocket()
        let sockets = RealtimeSocketList([first, second])
        let client = RealtimeClient(
            connection: fixture.client().connection, http: fixture.client(), makeSocket: { _ in sockets.take() })
        try await client.connect()
        let old = Task { try await client.command(type: "conversation.create", payload: [:], id: "reused") }
        await first.waitForSent(2)
        await client.disconnect()
        do {
            _ = try await old.value
            Issue.record("Expected unknown old outcome")
        } catch TodexError.unknownOutcome {}
        try await client.connect()
        let fresh = Task { try await client.command(type: "conversation.create", payload: [:], id: "reused") }
        await second.waitForSent(2)
        first.completeSend(1, error: URLError(.networkConnectionLost))
        _ = try await client.command(type: "server.ping", payload: [:])
        #expect(!second.isCancelled)
        try second.push(["id": "reused", "type": "server.result", "payload": ["created": true]])
        #expect(try await fresh.value == ["created": true])
        await client.disconnect()
    }

    @Test func sendFailureAfterRequestTimeoutStillClosesCurrentSocket() async throws {
        let fixture = NetworkHTTPFixture { _ in .json(["requiredProtocol": "none"]) }
        defer { fixture.close() }
        let socket = ScriptedRealtimeSocket()
        let client = RealtimeClient(
            connection: fixture.client().connection, http: fixture.client(), makeSocket: { _ in socket })
        try await client.connect()
        do {
            _ = try await client.command(type: "conversation.create", payload: [:], timeout: 0.02)
            Issue.record("Expected unknown timeout outcome")
        } catch TodexError.unknownOutcome {}
        socket.completeSend(1, error: URLError(.networkConnectionLost))
        await socket.waitForCancel()
        await #expect(throws: (any Error).self) { try await client.command(type: "conversation.create", payload: [:]) }
        #expect(socket.sent.count == 2)
    }

    @Test func encryptedConcurrentCommandsStayInNonceOrderAndVerifyBeforeUse() async throws {
        let fixture = NetworkHTTPFixture { _ in .json(["requiredProtocol": "x25519"]) }
        defer { fixture.close() }
        let server = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32))
        var connection = fixture.client().connection
        connection.encryption = .x25519
        connection.publicKey = CryptoEncoding.encode(server.publicKey.rawRepresentation)
        let box = RealtimeSocketList([])
        let client = RealtimeClient(
            connection: connection, http: fixture.client(),
            makeSocket: { request in
                do {
                    guard let url = request.url,
                        let clientKey = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?.first(where: { $0.name == "client_key" })?.value
                    else { throw TodexError.invalid("握手缺少 client_key") }
                    #expect(request.value(forHTTPHeaderField: "x-todex-client-key") == nil)
                    let clientPublic = try CryptoEncoding.decode(clientKey, count: 32)
                    let secret = try server.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: clientPublic))
                    let key = secret.hkdfDerivedSymmetricKey(
                        using: SHA256.self, salt: server.publicKey.rawRepresentation + clientPublic,
                        sharedInfo: Data("x25519".utf8), outputByteCount: 32)
                    let socket = ScriptedRealtimeSocket(key: key, echo: true)
                    box.append(socket)
                    return socket
                } catch {
                    Issue.record(error)
                    return ScriptedRealtimeSocket()
                }
            })
        await #expect(throws: (any Error).self) { try await client.command(type: "conversation.create", payload: [:]) }
        try await client.connect()
        try await withThrowingTaskGroup(of: JSONValue.self) { group in
            for index in 0..<30 {
                group.addTask {
                    try await client.command(type: "conversation.create", payload: ["index": .number(Double(index))])
                }
            }
            var results: Set<JSONValue> = []
            for try await result in group { results.insert(result["index"]) }
            #expect(results.count == 30)
        }
        let socket = box.snapshot[0]
        #expect(socket.sent.count == 31)
        #expect(socket.clientCounters == Array(0..<31).map(UInt64.init))
        await client.disconnect()
    }

    @Test func policyFailuresStopBeforeSocketCreationAndReportClosed() async throws {
        let fixture = NetworkHTTPFixture { _ in .json(["code": "NOT_FOUND", "message": "unauthorized"], status: 401) }
        defer { fixture.close() }
        let socket = ScriptedRealtimeSocket()
        let client = RealtimeClient(
            connection: fixture.client().connection, http: fixture.client(),
            makeSocket: { _ in
                Issue.record("Should not create a socket")
                return socket
            })
        do {
            try await client.connect()
            Issue.record("Expected policy error")
        } catch TodexError.server(let code, _) { #expect(code == "NOT_FOUND") }
        var iterator = client.events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event?["type"] == "connection.closed")
        #expect(fixture.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(socket.sent.isEmpty)
    }

    @Test func socketHandshakeFailureKeepsHTTPStatusButUpgradeErrorsKeepTransportCause() throws {
        let underlying = URLError(.badServerResponse)
        let url = try #require(URL(string: "http://fixture.invalid/v2/ws"))
        for status in [200, 307, 401, 403, 404, 500] {
            let response = try #require(
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            if case TodexError.server(let code, _) = RealtimeClient.socketError(underlying, response: response) {
                #expect(code == String(status))
            } else {
                Issue.record("Missing HTTP status from WebSocket handshake rejection")
            }
        }
        let upgrade = try #require(HTTPURLResponse(url: url, statusCode: 101, httpVersion: nil, headerFields: nil))
        #expect((RealtimeClient.socketError(underlying, response: upgrade) as? URLError)?.code == underlying.code)
        #expect((RealtimeClient.socketError(underlying, response: nil) as? URLError)?.code == underlying.code)
    }

    private func response(_ type: String, _ payload: JSONValue, wrapped: Bool = false) throws -> RealtimeResponse {
        try #require(
            RealtimeResponse([
                "type": .string(type),
                "payload": wrapped ? ["cursor": 7, "codex_session_id": "session", "data": payload] : payload,
            ]))
    }
    private func success(_ result: Result<JSONValue, TodexError>?) throws -> JSONValue { try #require(result).get() }
}

private final class RealtimeFlag: Sendable {
    private let storage = Mutex(false)
    var value: Bool { storage.withLock { $0 } }
    func set() { storage.withLock { $0 = true } }
}
private final class RealtimeSocketList: Sendable {
    private let sockets: Mutex<[ScriptedRealtimeSocket]>
    init(_ sockets: [ScriptedRealtimeSocket]) { self.sockets = Mutex(sockets) }
    func append(_ socket: ScriptedRealtimeSocket) { sockets.withLock { $0.append(socket) } }
    func take() -> ScriptedRealtimeSocket { sockets.withLock { $0.removeFirst() } }
    var snapshot: [ScriptedRealtimeSocket] { sockets.withLock { $0 } }
}

private final class ScriptedRealtimeSocket: RealtimeSocket {
    private struct State {
        var inbound: [String] = []
        var reader: CheckedContinuation<String, any Error>?
        var sent: [JSONValue] = []
        var callbacks: [@Sendable ((any Error)?) -> Void] = []
        var sentWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        var cancelWaiters: [CheckedContinuation<Void, Never>] = []
        var cancelled = false
        var serverCounter: UInt64 = 0
        var clientCounters: [UInt64] = []
    }
    private let state = Mutex(State())
    private let key: SymmetricKey?
    private let echo: Bool
    init(key: SymmetricKey? = nil, echo: Bool = false) {
        self.key = key
        self.echo = echo
    }
    var sent: [JSONValue] { state.withLock { $0.sent } }
    var clientCounters: [UInt64] { state.withLock { $0.clientCounters } }
    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func send(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void) {
        do {
            var bytes = Data(text.utf8)
            if let key {
                let frame = try JSONDecoder().decode(JSONValue.self, from: bytes)
                let nonce = try CryptoEncoding.decode(frame["nonce"].stringValue, count: 24)
                let counter = nonce[8..<16].enumerated().reduce(UInt64(0)) {
                    $0 | UInt64($1.element) << ($1.offset * 8)
                }
                let expected = state.withLock { state in
                    let n = state.clientCounters.count
                    state.clientCounters.append(counter)
                    return n
                }
                #expect(counter == UInt64(expected) && nonce[0] == 2)
                bytes = try XChaChaAEAD.open(
                    CryptoEncoding.decode(frame["ciphertext"].stringValue), key: key, nonce: nonce,
                    aad: TransportCryptoSession.aad)
            }
            let frame = try JSONDecoder().decode(JSONValue.self, from: bytes)
            let waiters = state.withLock {
                $0.sent.append(frame)
                $0.callbacks.append(completion)
                let count = $0.sent.count
                let ready = $0.sentWaiters.filter { $0.0 <= count }.map(\.1)
                $0.sentWaiters.removeAll { $0.0 <= count }
                return ready
            }
            for waiter in waiters { waiter.resume() }
            if frame["type"] == "server.ping" || echo {
                try push([
                    "id": frame["id"], "type": "server.result",
                    "payload": frame["type"] == "server.ping" ? ["pong": true] : frame["payload"],
                ])
            }
        } catch { completion(error) }
    }
    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<String, any Error>? = state.withLock {
                if !$0.inbound.isEmpty { return .success($0.inbound.removeFirst()) }
                if $0.cancelled { return .failure(CancellationError()) }
                $0.reader = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }
    func push(_ frame: JSONValue) throws {
        var raw = frame.prettyPrinted
        if let key {
            let counter = state.withLock {
                let n = $0.serverCounter
                $0.serverCounter += 1
                return n
            }
            let nonce = TransportCryptoSession.nonce(direction: 1, counter: counter)
            let ciphertext = try XChaChaAEAD.seal(
                Data(raw.utf8), key: key, nonce: nonce, aad: TransportCryptoSession.aad)
            let encrypted: JSONValue = [
                "type": "todex.crypto.v1", "protocol": "x25519", "nonce": .string(CryptoEncoding.encode(nonce)),
                "ciphertext": .string(CryptoEncoding.encode(ciphertext)),
            ]
            raw = encrypted.prettyPrinted
        }
        let reader: CheckedContinuation<String, any Error>? = state.withLock {
            let reader = $0.reader
            $0.reader = nil
            if reader == nil && !$0.cancelled { $0.inbound.append(raw) }
            return reader
        }
        reader?.resume(returning: raw)
    }
    func cancel() {
        let pending = state.withLock {
            $0.cancelled = true
            let value = ($0.reader, $0.cancelWaiters)
            $0.reader = nil
            $0.cancelWaiters.removeAll()
            return value
        }
        pending.0?.resume(throwing: CancellationError())
        for waiter in pending.1 { waiter.resume() }
    }
    func waitForSent(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let done = state.withLock {
                if $0.sent.count >= count { return true }
                $0.sentWaiters.append((count, continuation))
                return false
            }
            if done { continuation.resume() }
        }
    }
    func waitForCancel() async {
        await withCheckedContinuation { continuation in
            let done = state.withLock {
                if $0.cancelled { return true }
                $0.cancelWaiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }
    func completeSend(_ index: Int, error: any Error) { state.withLock { $0.callbacks[index] }(error) }
}
