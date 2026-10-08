// Run with scripts/run_session_tests.sh on macOS 26+ using Swift 6.2+.
// Compiles the real AppSession and LocalStore with TodexCore. HTTP, sockets,
// and credential writes are fixtures; no backend or real provider is invoked.
import Foundation
import Synchronization
import TodexCore

nonisolated struct Failure: Error, CustomStringConvertible { let description: String }

@MainActor enum TestEnvironment {
    private static var suites: [String] = []

    static func store() throws -> LocalStore {
        guard let directory = ProcessInfo.processInfo.environment["TODEX_SESSION_TEST_DATA"] else {
            throw Failure(description: "Run this executable through scripts/run_session_tests.sh")
        }
        return LocalStore(root: URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    static func defaults() -> UserDefaults {
        let name = "todex-session-race-" + UUID().uuidString
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    static func cleanup() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        suites.removeAll()
    }
}

nonisolated func report(_ text: String) {
    // Keep the last completed scenario visible even if the watchdog exits.
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

@MainActor func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(description: message) }
}
@MainActor func eventually(_ message: String, _ predicate: () async throws -> Bool) async throws {
    let limit = ContinuousClock.now + .seconds(8)
    while !(try await predicate()) {
        if ContinuousClock.now > limit { throw Failure(description: "timeout: " + message) }
        try await Task.sleep(for: .milliseconds(2))
    }
}
nonisolated func event(_ n: Int, _ type: String = "provider.event", _ payload: JSONValue = [:]) -> ConversationEvent {
    ConversationEvent(sequence: n, eventId: "event-\(n)", conversationId: "c", time: "2026-09-10T00:00:00Z", type: type, payload: payload)
}
actor Gate {
    var open = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; for waiter in waiters { waiter.resume() }; waiters = [] }
}
actor Backend {
    var journal: [ConversationEvent]
    var workspace = WorkspaceRecord(id: "w", name: "W", path: "/workspace", tenantId: "tenant-a")
    var manifest = ConversationManifest(id: "c", provider: "codex", workspace: "/workspace", workspaceId: "w")
    var providers: [ProviderDescriptor] = []
    var eventCalls = 0
    var manifestCalls = 0
    var pageSize = 200
    var reversePages = true
    var beforeCursors: [Int] = []
    var firstPageGate: Gate?
    var nextPageGate: Gate?
    /// Extra empty conversations listed beside "c" (subscription budget tests).
    var extraIDs: [String] = []
    /// Stored workspaces the backend reports as unusable (`rejected`).
    var rejected: [RejectedWorkspace] = []
    init(_ events: [ConversationEvent] = []) { journal = events }
    func setRejected(_ values: [RejectedWorkspace]) { rejected = values }
    func setExtraConversations(_ ids: [String]) { extraIDs = ids }
    func configure(gate: Gate? = nil, pageSize: Int = 200) { firstPageGate = gate; self.pageSize = pageSize }
    func setProviders(_ values: [ProviderDescriptor]) { providers = values }
    func changeTenant() { workspace.tenantId = "tenant-b" }
    func setStatus(_ value: String) { manifest.status = value }
    func setLegacyPlaintext(_ value: Bool) { manifest.legacyPlaintext = value ? true : nil }
    /// Simulate a backend that predates `beforeSequence`: it answers every page
    /// from the journal head regardless of the parameter.
    func setReversePages(_ value: Bool) { reversePages = value }
    /// Gate the next `/events` call regardless of its position in the sequence.
    func gateNextPage(_ gate: Gate) { nextPageGate = gate }
    func append(_ events: [ConversationEvent]) { journal.append(contentsOf: events) }
    func handle(_ url: URL) async throws -> JSONValue {
        switch url.path {
        case "/v2/workspaces":
            var body: JSONValue = ["workspaces": try JSONValue(encoding: [workspace])]
            if !rejected.isEmpty { body["rejected"] = try JSONValue(encoding: rejected) }
            return body
        case "/v2/conversations":
            var current = manifest; current.lastSequence = journal.last?.sequence ?? 0
            let extras = extraIDs.map { ConversationManifest(id: $0, provider: "codex", workspace: "/workspace", workspaceId: "w") }
            return ["conversations": try JSONValue(encoding: [current] + extras)]
        case let path where extraIDs.contains(where: { path == "/v2/conversations/" + $0 }):
            return try JSONValue(encoding: ConversationManifest(id: String(path.dropFirst("/v2/conversations/".count)), provider: "codex", workspace: "/workspace", workspaceId: "w"))
        case let path where extraIDs.contains(where: { path == "/v2/conversations/\($0)/events" }):
            return ["events": .array([]), "nextSequence": 0, "hasMore": false]
        case "/v2/providers": return ["providers": try JSONValue(encoding: providers)]
        case "/v2/conversations/c":
            manifestCalls += 1
            var current = manifest; current.lastSequence = journal.last?.sequence ?? 0
            return try JSONValue(encoding: current)
        case "/v2/conversations/c/events":
            eventCalls += 1
            if eventCalls == 1 { await firstPageGate?.wait() }
            if let gate = nextPageGate { nextPageGate = nil; await gate.wait() }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let before = Int(items.first(where: { $0.name == "beforeSequence" })?.value ?? "") {
                beforeCursors.append(before)
            }
            if reversePages, let before = Int(items.first(where: { $0.name == "beforeSequence" })?.value ?? "") {
                let eligible = journal.filter { $0.sequence <= before }, page = Array(eligible.suffix(pageSize))
                return ["events": try JSONValue(encoding: page), "nextSequence": .number(Double(page.last?.sequence ?? before)), "hasMore": .bool(eligible.count > page.count)]
            }
            let after = Int(items.first(where: { $0.name == "afterSequence" })?.value ?? "0") ?? 0
            let remaining = journal.filter { $0.sequence > after }, page = Array(remaining.prefix(pageSize))
            return ["events": try JSONValue(encoding: page), "nextSequence": .number(Double(page.last?.sequence ?? after)), "hasMore": .bool(remaining.count > page.count)]
        case "/v2/providers/models": return ["models": .array([])]
        default: throw Failure(description: "unexpected HTTP: \(url)")
        }
    }
}
nonisolated final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let backends = Mutex<[String: Backend]>([:])
    static func register(_ backend: Backend, host: String) { backends.withLock { $0[host] = backend } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let backend = Self.backends.withLock({ $0[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: Failure(description: "missing fixture")); return
        }
        Task {
            do {
                let body = try JSONEncoder().encode(await backend.handle(url))
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}
nonisolated struct Subscription: Sendable { var events: [ConversationEvent]; var more: Bool; var gate: Gate? = nil }
actor FakeSocket: SessionSocket {
    nonisolated let events: AsyncStream<JSONValue>
    let continuation: AsyncStream<JSONValue>.Continuation
    let backend: Backend
    var connects = 0
    var disconnects = 0
    var subscribeCursors: [Int] = []
    var watches: [String] = []
    var unsubscribes: [String] = []
    var controls: [JSONValue] = []
    var retries: [JSONValue] = []
    var prompts: [(String, JSONValue)] = []
    var forks: [JSONValue] = []
    /// `conversation.queue.*` commands in send order, with their payloads.
    var queueCommands: [(String, JSONValue)] = []
    var queueSnapshot: JSONValue = ["items": [], "paused": false]
    /// Failures `conversation.queue.add` throws, consumed one per call.
    var queueAddErrors: [TodexError] = []
    /// The item `conversation.queue.take` hands back.
    var takeItem: JSONValue = [:]
    var connectGate: Gate?
    var promptGate: Gate?
    var promptError: TodexError?
    var subscriptions: [Subscription] = []
    var ledgerStore: LocalStore?
    var ledgerKey: String?
    var ledgerChecks: [Bool] = []
    /// `agentBrowser.watch:<id>` / `agentBrowser.unwatch:<id>` in send order.
    var browserWatches: [String] = []
    /// Each connection iterates a fresh frame stream, like a new RealtimeClient.
    nonisolated let frameSink = Mutex<AsyncStream<JSONValue>.Continuation?>(nil)
    nonisolated var browserFrames: AsyncStream<JSONValue> {
        let (stream, sink) = AsyncStream<JSONValue>.makeStream()
        frameSink.withLock { $0 = sink }
        return stream
    }
    nonisolated func emitBrowserFrame(_ payload: JSONValue) { frameSink.withLock { _ = $0?.yield(payload) } }
    init(backend: Backend) {
        self.backend = backend
        (events, continuation) = AsyncStream<JSONValue>.makeStream()
    }
    func configure(connect: Gate? = nil, prompt: Gate? = nil, error: TodexError? = nil, subscriptions: [Subscription] = []) {
        connectGate = connect; promptGate = prompt; promptError = error; self.subscriptions = subscriptions
    }
    func inspectLedger(store: LocalStore, key: String) { ledgerStore = store; ledgerKey = key }
    func connect() async throws { connects += 1; await connectGate?.wait() }
    func disconnect() async { disconnects += 1 }
    func overflow() { for _ in 0..<2_060 { continuation.yield(["type": "workbench.fixture"]) } }
    func emit(_ event: ConversationEvent) throws { continuation.yield(["type": "conversation.event", "payload": try JSONValue(encoding: event)]) }
    func emitFrame(_ frame: JSONValue) { continuation.yield(frame) }
    func setQueueSnapshot(_ value: JSONValue) { queueSnapshot = value }
    func failQueueAdds(_ errors: [TodexError]) { queueAddErrors = errors }
    func setTakeItem(_ value: JSONValue) { takeItem = value }
    /// The fake's `conversation.queue.*` commands that reached the wire.
    func queueTypes() -> [String] { queueCommands.map(\.0) }
    /// `history.keys.wraps` answers: kid text → WrappedKey JSON.
    var historyWraps: [String: JSONValue] = [:]
    func setHistoryWrap(kid: String, wrapped: JSONValue) { historyWraps[kid] = wrapped }
    /// Answers `history.*` key management (not wraps) once enabled; before
    /// that the empty reply reads as a backend without history encryption.
    var historyBackend = false
    var historyAccess = "active"
    var historyRid: String?
    var revokedHistoryKeys: Set<String> = []
    var revokedDevices: [JSONValue] = []
    /// Every `history.*` command type except wraps, in send order.
    var historyLog: [String] = []
    var registeredKeys: [String] = []
    /// The backend lost every recipient (writes then fail with HISTORY_KEY_REQUIRED).
    func forgetHistoryRecipient() { historyRid = nil }
    func configureHistory(access: String, revokedKeys: Set<String> = [], revokedDevices: [JSONValue] = []) {
        historyBackend = true; historyAccess = access; revokedHistoryKeys = revokedKeys; self.revokedDevices = revokedDevices
    }
    var historyState: JSONValue {
        var state: JSONValue = ["mode": "e2e", "epoch": 1, "recipients": [], "grants": [], "myAccess": .string(historyAccess), "revokedDevices": .array(revokedDevices)]
        if let historyRid { state["myRid"] = .string(historyRid) }
        return state
    }
    func historyCommand(_ type: String, _ payload: JSONValue) throws -> JSONValue {
        historyLog.append(type)
        if historyAccess == "revoked" && type != "history.encryption.get" {
            throw TodexError.server(code: "HISTORY_ACCESS_REVOKED", message: "revoked")
        }
        if type == "history.recipient.register" {
            let key = payload["publicKey"].stringValue
            registeredKeys.append(key)
            if revokedHistoryKeys.contains(key) { throw TodexError.server(code: "CONFLICT", message: "revoked key") }
            historyRid = HistoryEncryption.encodeID(try HistoryCrypto.recipientID(publicKey: base64URLDecoded(key)))
            historyAccess = "active"
            return ["rid": .string(historyRid!)]
        }
        if type == "history.grant.request" { return ["grantId": "grt_1"] }
        return historyState
    }
    func command(type: String, payload: JSONValue, timeout: TimeInterval, id: String) async throws -> JSONValue {
        if historyBackend, type.hasPrefix("history."), type != "history.keys.wraps" { return try historyCommand(type, payload) }
        if historyBackend, type == "history.keys.wraps", historyAccess == "revoked" {
            throw TodexError.server(code: "HISTORY_ACCESS_REVOKED", message: "revoked")
        }
        if type == "conversation.control" { controls.append(payload); return ["accepted": true] }
        if type == "conversation.retry" {
            retries.append(payload)
            return ["conversationId": payload["conversationId"], "turnId": "retried", "retried": true]
        }
        if type.hasPrefix("conversation.queue.") {
            queueCommands.append((type, payload))
            if type == "conversation.queue.add" {
                if !queueAddErrors.isEmpty { throw queueAddErrors.removeFirst() }
                return ["conversationId": payload["conversationId"], "itemId": payload["itemId"], "status": "queued"]
            }
            if type == "conversation.queue.pause" {
                queueSnapshot["paused"] = true
                queueSnapshot["pauseReason"] = "user"
            }
            if type == "conversation.queue.take" {
                return [
                    "conversationId": payload["conversationId"], "itemId": payload["itemId"], "item": takeItem,
                    "queue": ["items": [], "paused": false],
                ]
            }
            return ["conversationId": payload["conversationId"], "queue": queueSnapshot]
        }
        if type.hasPrefix("agentBrowser.") {
            browserWatches.append("\(type):\(payload["conversationId"].stringValue)")
            return ["watching": .bool(type == "agentBrowser.watch")]
        }
        if type == "conversation.unsubscribe" {
            unsubscribes.append(payload["conversationId"].stringValue)
            return ["conversationId": payload["conversationId"], "unsubscribed": true]
        }
        // Background list watches are recorded apart from recovery subscribes
        // so the recovery scenarios keep asserting exact cursors.
        if type == "conversation.subscribe", payload["backfillLimit"].intValue == AppSession.watchBackfillLimit {
            watches.append(payload["conversationId"].stringValue)
            return ["conversationId": payload["conversationId"], "subscribed": true, "hasMore": false]
        }
        if type == "conversation.subscribe" {
            subscribeCursors.append(payload["afterSequence"].intValue)
            let conversation = payload["conversationId"]
            if !subscriptions.isEmpty {
                let page = subscriptions.removeFirst(); await page.gate?.wait(); await backend.append(page.events)
                return ["conversationId": conversation, "subscribed": true, "nextSequence": .number(Double(page.events.last?.sequence ?? payload["afterSequence"].intValue)), "hasMore": .bool(page.more)]
            }
            let last = conversation == "c" ? await backend.journal.last?.sequence ?? 0 : 0
            return ["conversationId": conversation, "subscribed": true, "nextSequence": .number(Double(last)), "hasMore": false]
        }
        if type == "history.keys.wraps" {
            let kids = payload["kids"].arrayValue.map(\.stringValue)
            return ["wraps": .object(historyWraps.filter { kids.contains($0.key) })]
        }
        if type == "conversation.fork" {
            forks.append(payload)
            return ["conversationId": "c-fork", "forkedFrom": payload["conversationId"]]
        }
        if type == "conversation.prompt" {
            prompts.append((id, payload))
            if let ledgerStore, let ledgerKey {
                let snapshot = try ledgerStore.read(ledgerKey, as: SessionSnapshot.self)
                ledgerChecks.append(snapshot?.pendingSends["c"]?.requestId == id)
            }
            await promptGate?.wait()
            if let promptError { throw promptError }
            return ["accepted": true]
        }
        return [:]
    }
}
nonisolated let loopbackHostCounter = Mutex<UInt32>(0)
/// A distinct canonical 127.x.y.z host per call (never 127.0.0.1, which a
/// real local backend may own; FixtureProtocol keeps requests in-process).
nonisolated func uniqueLoopbackHost() -> String {
    let next = loopbackHostCounter.withLock { value -> UInt32 in
        value += 1
        return value
    }
    return "127.\((next >> 16) % 254 + 1).\((next >> 8) & 0xff).\(next & 0xff)"
}
nonisolated func base64URLDecoded(_ text: String) throws -> Data {
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64) else { throw Failure(description: "bad base64url") }
    return data
}
@MainActor final class SeedBox {
    var value: Data?
    init(_ value: Data?) { self.value = value }
}
@MainActor struct Harness {
    let backend: Backend
    let socket: FakeSocket
    let store: LocalStore
    let connection: BackendConnection
    let session: AppSession
    let manifest = ConversationManifest(id: "c", provider: "codex", workspace: "/workspace", workspaceId: "w")
    /// The device history seed as the Keychain would hold it; a re-key replaces it.
    let seeds: SeedBox
    init(_ journal: [ConversationEvent] = [], snapshot: SessionSnapshot? = nil, historySeed: Data? = nil, deviceSecret: String = "") throws {
        backend = Backend(journal); socket = FakeSocket(backend: backend)
        // Transport v2 refuses a remote backend without a pinned key; an
        // unpinned loopback host stays plaintext, so the fixture uses a
        // distinct 127.0.0.0/8 host (FixtureProtocol intercepts by host).
        let host = uniqueLoopbackHost()
        connection = BackendConnection(id: "test-" + UUID().uuidString, name: "Fixture", serverURL: "http://" + host, deviceSecret: deviceSecret)
        let seeds = SeedBox(historySeed); self.seeds = seeds
        store = try TestEnvironment.store()
        if let snapshot { try store.save(snapshot, key: LocalStore.namespace(connection) + "-state") }
        FixtureProtocol.register(backend, host: host)
        let socket = self.socket
        let defaults = TestEnvironment.defaults()
        session = AppSession(store: store, connections: [connection], defaults: defaults, apiFactory: { value in
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
            return APIClient(connection: value, session: URLSession(configuration: config))
        }, socketFactory: { _ in socket }, credentialWriter: { _, _ in },
        historySeeds: HistorySeedStore(load: { _ in seeds.value }, save: { value, _ in seeds.value = value }))
    }
    func ready() async throws {
        await session.connect()
        try check(session.isConnected, "connect: \(session.status) / \(session.lastError ?? "none")")
        try await session.recover("c")
        try check(session.runtimes["c"]?.readyForActions == true, "ready")
    }
    var stateKey: String { LocalStore.namespace(connection) + "-state" }
    var eventKey: String { "events-v2-" + LocalStore.identity([LocalStore.namespace(connection), "tenant-a", "w", "/workspace", "c"]) }
}

@MainActor func connectionSingleFlight() async throws {
    let h = try Harness(), gate = Gate()
    await h.socket.configure(connect: gate)
    let first = Task { await h.session.connect() }
    try await eventually("connect entered") { await h.socket.connects == 1 }
    let second = Task { await h.session.connect() }
    h.session.setForeground(true)
    await Task.yield(); await gate.release(); await first.value; await second.value
    try check(await h.socket.connects == 1, "overlapping connect duplicated socket")
    try check(h.session.isConnected, "foreground interrupted initial connect")
    h.session.disconnect()
}
@MainActor func recoveryInterleaving() async throws {
    let records = [event(1, "turn.started", ["turnId": "t"]), event(2, "message.delta", ["turnId": "t", "text": "Hello"]), event(3, "message.delta", ["turnId": "t", "text": " world"]), event(4, "turn.completed", ["turnId": "t"])]
    let h = try Harness(records), gate = Gate()
    await h.backend.configure(gate: gate, pageSize: 2); await h.session.connect()
    let first = Task { try await h.session.recover("c") }
    try await eventually("HTTP replay entered") { await h.backend.eventCalls == 1 }
    let second = Task { try await h.session.recover("c") }
    try await h.socket.emit(records[0]); try await h.socket.emit(records[2])
    try await eventually("live gap buffered") { h.session.runtimes["c"]?.highWaterSequence == 3 }
    try check(h.session.runtimes["c"]?.readyForActions == false, "actions enabled before replay")
    await gate.release(); try await first.value; try await second.value
    try check(await h.backend.manifestCalls == 1, "duplicate recovery")
    try check(await h.socket.subscribeCursors.count == 1, "duplicate subscribe")
    try check(h.session.runtimes["c"]?.messages.map(\.text) == ["Hello world"], "HTTP overwrote live state")
    try check(h.session.runtimes["c"]?.appliedSequence == 4, "contiguous cursor")
    h.session.disconnect(); try check(h.session.runtimes["c"]?.readyForActions == false, "disconnect did not gate actions")
}
@MainActor func subscriptionPagination() async throws {
    let h = try Harness(), gate = Gate()
    await h.socket.configure(subscriptions: [Subscription(events: [event(1), event(2)], more: true), Subscription(events: [event(3)], more: false, gate: gate)])
    await h.session.connect()
    let recovery = Task { try await h.session.recover("c") }
    try await eventually("second subscription page") { await h.socket.subscribeCursors.count == 2 }
    try check(h.session.runtimes["c"]?.appliedSequence == 2, "ACK cursor was not recovered over REST")
    try check(h.session.runtimes["c"]?.readyForActions == false, "hasMore enabled actions")
    await gate.release(); try await recovery.value
    try check(await h.socket.subscribeCursors == [0, 2], "wrong subscription cursors")
    try check(h.session.runtimes["c"]?.readyForActions == true && h.session.runtimes["c"]?.appliedSequence == 3, "final page failed")
    h.session.disconnect()
}
@MainActor func ledgerBeforeWireAndRejectionKeepsTypedText() async throws {
    let h = try Harness(), gate = Gate(); try await h.ready()
    await h.socket.configure(prompt: gate, error: .server(code: "INVALID", message: "rejected"))
    await h.socket.inspectLedger(store: h.store, key: h.stateKey)
    let original = ComposerDraft(text: "original"), typed = ComposerDraft(text: "typed during ACK")
    h.session.drafts["c"] = original
    let send = Task { try await h.session.send(original, in: h.manifest) }
    try await eventually("prompt on the wire") { await h.socket.prompts.count == 1 }
    try check(await h.socket.ledgerChecks == [true], "pending ledger not durable before the wire")
    try check(h.session.drafts["c"]?.isEmpty == true, "composer kept the message while it was sent")
    h.session.drafts["c"] = typed
    await gate.release(); _ = await send.result
    try check(h.session.pendingSends["c"] == nil, "known rejection left a pending send")
    try check(h.session.drafts["c"]?.text == "original\n\ntyped during ACK", "rejection lost or overwrote text: \(h.session.drafts["c"]?.text ?? "nil")")
    h.session.disconnect()
}
@MainActor func manualFailureAndUnknown() async throws {
    for ambiguous in [false, true] {
        let h = try Harness(), gate = Gate(); try await h.ready()
        await h.socket.configure(prompt: gate, error: ambiguous ? .unknownOutcome("ACK lost") : .server(code: "INVALID", message: "no"))
        let old = ComposerDraft(text: "original"), newer = ComposerDraft(text: "typed during ACK")
        h.session.drafts["c"] = old
        let send = Task { try await h.session.send(old, in: h.manifest) }
        try await eventually("manual prompt") { await h.socket.prompts.count == 1 }
        h.session.drafts["c"] = newer; await gate.release(); _ = await send.result
        try check(ambiguous ? h.session.drafts["c"] == newer : h.session.drafts["c"]?.text == "original\n\ntyped during ACK", "manual failure overwrote new draft")
        if ambiguous {
            try check(h.session.pendingSends["c"]?.draft == old, "ambiguous outcome lost pending")
            h.session.restoreUnknownAsDraft("c")
            try check(h.session.drafts["c"] == newer && h.session.pendingSends["c"] != nil, "unknown restore overwrote draft")
            try await h.session.recover("c")
            try check(await h.socket.prompts.count == 1, "ambiguous mutation auto-retried")
        } else { try check(h.session.drafts["c"]?.text.hasPrefix(old.text) == true && h.session.pendingSends["c"] == nil, "known rejection lost original") }
        h.session.disconnect()
    }
}
@MainActor func staleBackendResponse() async throws {
    let h = try Harness(), gate = Gate(); try await h.ready()
    await h.socket.configure(prompt: gate, error: .server(code: "CONFLICT", message: "old backend rejection"))
    let draft = ComposerDraft(text: "A original"); h.session.drafts["c"] = draft
    let send = Task { try await h.session.send(draft, in: h.manifest) }
    try await eventually("old prompt") { await h.socket.prompts.count == 1 }
    var other = h.connection; other.serverURL = "https://other.invalid"; other.name = "B"
    try h.session.saveConnections([other], selected: other.id)
    try check(!h.session.isConnected && h.session.api == nil, "settings kept old transport")
    h.session.drafts["c"] = ComposerDraft(text: "B current")
    await gate.release(); _ = await send.result
    try check(h.session.drafts["c"]?.text == "B current" && h.session.pendingSends["c"] == nil, "late rejection mutated B")
    try h.session.saveConnections([h.connection], selected: h.connection.id)
    try await eventually("A pending restored") { h.session.pendingSends["c"]?.draft == draft }
    var blank = h.connection; blank.serverURL = ""
    try h.session.saveConnections([blank], selected: blank.id)
    await h.session.connect(); try check(!h.session.isConnected, "empty placeholder connected")
    h.session.disconnect()
}
@MainActor func diskFailurePreservesDraft() async throws {
    let h = try Harness(); try await h.ready()
    try await eventually("initial snapshot") { try h.store.read(h.stateKey, as: SessionSnapshot.self) != nil }
    // Fail disk writes after a successful load, so send reaches the durable-ledger path.
    try FileManager.default.moveItem(at: h.store.root, to: h.store.root.appendingPathExtension("backup"))
    try Data("blocked".utf8).write(to: h.store.root)
    let s = h.session
    s.drafts["c"] = ComposerDraft(text: "must survive")
    var failure = false
    do { try await s.send(s.drafts["c"]!, in: h.manifest) } catch { failure = true }
    try check(failure && s.storageError != nil, "disk failure hidden")
    try check(s.drafts["c"]?.text == "must survive" && s.pendingSends["c"] == nil, "disk failure lost composer or left pending")
    try check(await h.socket.prompts.isEmpty, "sent without durable ledger")
    var notifications = 0
    let observer = s.observe { notifications += 1; s.persist() }
    s.persist(); try await Task.sleep(for: .milliseconds(80))
    try check(notifications < 10, "save failure recursively notified")
    s.removeObserver(observer)
    var other = h.connection; other.serverURL = "https://retained-test.invalid"
    FixtureProtocol.register(h.backend, host: "retained-test.invalid")
    await s.connect(other); s.drafts["c"] = ComposerDraft(text: "other namespace")
    await s.connect(h.connection)
    try check(s.drafts["c"]?.text == "must survive", "switch back lost retained checkpoint when disk unreadable")
    s.disconnect()
}
/// Providers whose daemon holds the follow-up queue; `control` adds
/// pause/take and the paused add.
nonisolated func queueProviders(control: Bool = true) -> [ProviderDescriptor] {
    [ProviderDescriptor(id: "codex", displayName: "Codex", available: true,
        capabilities: ["backendQueue": true, "backendQueueControl": .bool(control)])]
}
@MainActor func backgroundAndDisconnectLeaveTheBackendQueueAlone() async throws {
    let h = try Harness([event(1, "turn.started", ["turnId": "t"])])
    await h.backend.setProviders(queueProviders())
    await h.socket.setQueueSnapshot(["items": [["id": "q1", "text": "waiting", "status": "queued"]], "paused": false])
    try await h.ready()
    try check(h.session.runtimes["c"]?.followUps.map { $0["id"] } == ["q1"], "queue snapshot not adopted")
    let before = await h.socket.queueTypes()
    h.session.activeConversationID = "c"
    h.session.setForeground(false)
    try await Task.sleep(for: .milliseconds(30))
    h.session.setForeground(true)
    try await eventually("foreground recovery") { h.session.runtimes["c"]?.readyForActions == true }
    h.session.disconnect()
    let commands = await h.socket.queueTypes().filter { !before.contains($0) || $0 == "conversation.queue.list" }
    try check(!commands.contains { ["pause", "remove", "clear", "resume", "take", "add"].contains(String($0.split(separator: ".").last ?? "")) },
        "background/disconnect changed the backend queue: \(commands)")
    try check(await h.socket.prompts.isEmpty, "background/disconnect prompted")
}
@MainActor func scopedReadsAndCachePrefix() async throws {
    let h = try Harness((1...10_005).map { event($0) })
    // The bounded-prefix cache is exercised through the forward path; a lazy
    // tail window would only stage never-drained pending entries.
    await h.backend.setReversePages(false)
    try await h.ready()
    h.session.readSequences["c"] = 10_005; h.session.persist()
    try await eventually("cache persisted") { try h.store.read(h.eventKey, as: CachedHistory.self)?.events.count == 10_000 }
    let cached = try h.store.read(h.eventKey, as: CachedHistory.self)!.events
    try check(cached.enumerated().allSatisfy { $0.element.sequence == $0.offset + 1 }, "cache is a tail or contains gaps")
    try check(try Data(contentsOf: h.store.url(h.eventKey)).count < 8 * 1_024 * 1_024, "cache byte bound")
    await h.backend.changeTenant(); try await h.session.refresh()
    try check(h.session.readSequences["c"] == nil && h.session.runtimes["c"] == nil, "tenant switch reused read/runtime")
    var other = h.connection; other.serverURL = "https://different.invalid"
    try check(LocalStore.namespace(h.connection) != LocalStore.namespace(other), "URL missing from namespace")
    other = h.connection; other.deviceSecret = "changed"
    try check(LocalStore.namespace(h.connection) != LocalStore.namespace(other), "credential missing from namespace")
    try check(LocalStore.identity(["ab", "c"]) != LocalStore.identity(["a", "bc"]), "namespace collision")
    h.session.disconnect()
}
@MainActor func encryptedHistoryStaysCiphertextOnDisk() async throws {
    let device = try HistoryCrypto.generateRecipientKey()
    let key = HistoryCrypto.SegmentKey.generate()
    func sealed(_ n: Int, turn: String, text: String, type: String = "message.delta", role: String? = nil) throws -> ConversationEvent {
        var payload: JSONValue = ["turnId": .string(turn), "text": .string(text)]
        var envelope: JSONValue = ["turnId": .string(turn)]
        if let role { payload["role"] = .string(role); envelope["role"] = .string(role) }
        let ciphertext = try HistoryCrypto.seal(
            JSONEncoder().encode(payload), key: key, conversationID: "c", stream: .eventFull, counter: UInt64(n))
        envelope["$enc"] = ["v": 1, "kid": .string(HistoryEncryption.encodeID(key.kid)), "c": "c", "n": .number(Double(n)),
                            "f": .string(HistoryEncryption.encodeID(ciphertext))]
        return event(n, type, envelope)
    }
    let secret = "replayed secret reply"
    let h = try Harness(
        [event(1, "turn.started", ["turnId": "t"]), try sealed(2, turn: "t", text: secret), event(3, "turn.completed", ["turnId": "t"])],
        historySeed: device.seedRepresentation)
    await h.socket.setHistoryWrap(
        kid: HistoryEncryption.encodeID(key.kid),
        wrapped: try JSONValue(encoding: HistoryCrypto.wrap(key, for: device.publicKey.rawRepresentation)))
    await h.backend.setReversePages(false)
    await h.backend.setProviders([
        ProviderDescriptor(id: "codex", displayName: "Codex", available: true, capabilities: ["controlActions": ["retry"]])
    ])
    try await h.ready()
    try check(h.session.runtimes["c"]?.messages.map(\.text) == [secret], "history page was not decrypted")
    try await h.socket.emit(event(4, "turn.started", ["turnId": "t2"]))
    try await h.socket.emit(try sealed(5, turn: "t2", text: "live secret"))
    try await eventually("live event decrypted") { h.session.runtimes["c"]?.appliedSequence == 5 }
    try check(h.session.runtimes["c"]?.messages.first?.text == "live secret", "live event was not decrypted")
    h.session.persist()
    try await eventually("cache persisted") { (try? h.store.read(h.eventKey, as: CachedHistory.self))?.events.count == 5 }
    let disk = String(decoding: try Data(contentsOf: h.store.url(h.eventKey)), as: UTF8.self)
    try check(!disk.contains(secret) && !disk.contains("live secret") && disk.contains("$enc"), "plaintext reached the event cache")
    // e2e retry (§7): the backend cannot read the prompt back, so the client
    // sends the newest decrypted user prompt.
    try await h.socket.emit(event(6, "turn.completed", ["turnId": "t2"]))
    for (n, turn, prompt) in [(7, "t3", "first secret prompt"), (10, "t4", "  latest secret prompt\n")] {
        try await h.socket.emit(event(n, "turn.started", ["turnId": .string(turn)]))
        try await h.socket.emit(try sealed(n + 1, turn: turn, text: prompt, type: "message.created", role: "user"))
        try await h.socket.emit(event(n + 2, "turn.completed", ["turnId": .string(turn)]))
    }
    try await eventually("prompts applied") { h.session.runtimes["c"]?.appliedSequence == 12 }
    _ = try await h.session.control("retry", conversation: h.manifest)
    let retry = await h.socket.retries.first ?? .null
    try check(retry == ["conversationId": "c", "prompt": "  latest secret prompt\n"], "e2e retry payload: \(retry)")
    // A newer user message this device cannot open: retry is refused here
    // instead of sending an older prompt the backend would reject.
    let unreadable = HistoryCrypto.SegmentKey.generate()
    var lockedPrompt = try sealed(14, turn: "t5", text: "unreadable prompt", type: "message.created", role: "user")
    lockedPrompt.payload["$enc"]["kid"] = .string(HistoryEncryption.encodeID(unreadable.kid))
    try await h.socket.emit(event(13, "turn.started", ["turnId": "t5"]))
    try await h.socket.emit(lockedPrompt)
    try await h.socket.emit(event(15, "turn.completed", ["turnId": "t5"]))
    try await eventually("locked prompt applied") { h.session.runtimes["c"]?.appliedSequence == 15 }
    do {
        _ = try await h.session.control("retry", conversation: h.manifest)
        try check(false, "retry sent an older prompt past a locked one")
    } catch let error as TodexError {
        try check("\(error)".contains("读不到上一轮"), "unexpected retry error: \(error)")
    }
    try check(await h.socket.retries.count == 1, "a refused retry reached the socket")
    h.session.disconnect()
}
@MainActor func corruptCacheIsOptional() async throws {
    let h = try Harness([event(1)])
    try FileManager.default.createDirectory(at: h.store.root, withIntermediateDirectories: true)
    try Data("broken cache".utf8).write(to: h.store.url(h.eventKey))
    try await h.ready()
    try check(h.session.runtimes["c"]?.appliedSequence == 1, "bad optional cache prevented HTTP replay")
    h.session.disconnect()
}
@MainActor func streamOverflowSignalsGap() async throws {
    let h = try Harness(); try await h.ready()
    let stream = h.session.wireEvents()
    await h.socket.overflow(); try await h.socket.emit(event(1))
    try await eventually("overflow frames processed") { h.session.runtimes["c"]?.appliedSequence == 1 }
    var sawGap = false, sawEnd = false
    for await frame in stream {
        if frame["type"].stringValue == "connection.gap" { sawGap = true }
        if frame["type"].stringValue == "conversation.event" { sawEnd = true; break }
    }
    try check(sawGap && sawEnd, "slow subscriber was not told frames were dropped")
    h.session.disconnect()
}
@MainActor func staleReplayResponse() async throws {
    let h = try Harness([event(1)]), gate = Gate()
    await h.backend.configure(gate: gate); await h.session.connect()
    let replay = Task { try await h.session.recover("c") }
    try await eventually("stale page gated") { await h.backend.eventCalls == 1 }
    var other = h.connection; other.serverURL = "https://replay-other.invalid"
    try h.session.saveConnections([other], selected: other.id)
    h.session.drafts["c"] = ComposerDraft(text: "new backend draft")
    await gate.release(); _ = await replay.result
    try check(h.session.runtimes.isEmpty && h.session.drafts["c"]?.text == "new backend draft", "old replay updated new backend")
    try check(await h.socket.subscribeCursors.isEmpty, "stale recovery issued subscription")
    h.session.disconnect()
}
@MainActor func debugPortFixture() async throws {
    #if DEBUG
    let store = try TestEnvironment.store()
    let session = AppSession(store: store, defaults: TestEnvironment.defaults())
    try check(session.connection?.serverURL == "http://127.0.0.1:18999", "port did not override malformed URL")
    try check(session.connection?.deviceSecret == "FRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRU", "fixture device secret changed")
    #endif
}
@MainActor func taskPlanPersistence() async throws {
    let h = try Harness()
    let task = h.session.addTask(workspaceId: "w", title: " 回归任务 ")
    try check(task?.title == "回归任务", "task title not trimmed")
    guard let task else { throw TodexError.invalid("addTask rejected a valid task") }
    h.session.setTaskStatus(task.id, .inProgress)
    h.session.attachTask(task.id, conversationId: "c")
    h.session.persist()
    try await eventually("tasks persisted") {
        try h.store.read(h.stateKey, as: SessionSnapshot.self)?.tasks.contains {
            $0.id == task.id && $0.status == .inProgress && $0.conversationId == "c"
        } == true
    }
    // Snapshots written before the tasks field existed must still decode.
    let legacy = try JSONDecoder().decode(
        SessionSnapshot.self, from: JSONEncoder().encode(["drafts": JSONValue.object([:])]))
    try check(legacy.tasks.isEmpty, "legacy snapshot failed to decode without tasks")
    h.session.disconnect()
}
@MainActor func composerMemory() async throws {
    let h = try Harness()
    await h.backend.setProviders([
        ProviderDescriptor(
            id: "codex", displayName: "Codex", available: true,
            capabilities: [
                "permissionConfig": [
                    "modes": ["ask", "auto", "full-access"], "defaultMode": "ask", "supportsPlan": true,
                ],
            ])
    ])
    try await h.ready()
    var pref = h.session.preferences(for: h.manifest)
    try check(pref.permissionMode == "ask" && pref.workMode == "implement", "unexpected preference defaults")
    pref.model = "swe-2-high"
    pref.reasoningEffort = "high"
    pref.permissionMode = "auto"
    pref.workMode = "plan"
    h.session.updatePreferences(pref, for: h.manifest)
    h.session.rememberAgent(provider: "codex", profile: nil)
    h.session.persist()
    try await eventually("composer memory persisted") {
        let disk = try h.store.read(h.stateKey, as: SessionSnapshot.self)
        return disk?.lastPreferencesByProvider["codex"]?.permissionMode == "auto"
            && disk?.lastAgent?.provider == "codex"
    }
    let remembered = h.session.rememberedPreferences(for: "codex")
    try check(
        remembered?.model == "swe-2-high" && remembered?.permissionMode == "auto"
            && remembered?.workMode == "plan",
        "provider memory lost supported values")
    try check(h.session.rememberedPreferences(for: "pi") == nil, "unknown provider invented memory")
    // A narrower capability descriptor restores its own defaults.
    await h.backend.setProviders([
        ProviderDescriptor(
            id: "codex", displayName: "Codex", available: true,
            capabilities: ["permissionConfig": ["modes": ["ask"], "defaultMode": "ask"]])
    ])
    try await h.session.refresh()
    let narrowed = h.session.rememberedPreferences(for: "codex")
    try check(
        narrowed?.permissionMode == "ask" && narrowed?.workMode == "implement",
        "unsupported memory was not normalized")
    // A restarted session restores the composer memory from the snapshot.
    var seeded = SessionSnapshot()
    var stored = ConversationPreferences()
    stored.model = "swe-2-high"; stored.permissionMode = "auto"; stored.workMode = "plan"
    seeded.lastPreferencesByProvider = ["codex": stored]
    seeded.lastAgent = AgentSelection(provider: "acp", profile: "claude")
    let revived = try Harness(snapshot: seeded)
    try await eventually("composer memory restored") {
        revived.session.lastAgent == AgentSelection(provider: "acp", profile: "claude")
            && revived.session.lastPreferencesByProvider["codex"]?.workMode == "plan"
    }
    // Without a live descriptor the plan fallback applies.
    try check(
        revived.session.rememberedPreferences(for: "codex")?.workMode == "implement",
        "undelcared plan capability kept")
    // Snapshots written before the memory fields existed must still decode.
    let legacy = try JSONDecoder().decode(
        SessionSnapshot.self, from: JSONEncoder().encode(["drafts": JSONValue.object([:])]))
    try check(
        legacy.lastPreferencesByProvider.isEmpty && legacy.lastAgent == nil,
        "legacy snapshot failed to decode without composer memory")
    h.session.disconnect()
    revived.session.disconnect()
}
@MainActor func lazyTailOpenAndEarlierPaging() async throws {
    // Distinct message ids keep every completed message a separate row.
    let records = (1...450).map { n in
        let message: JSONValue = ["role": "assistant", "text": .string("m\(n)"), "id": .string("msg-\(n)")]
        return event(n, "message.completed", ["message": message])
    }
    let h = try Harness(records)
    try await h.ready()
    // Fixture caps pages at 200: one reverse page seeds the tail, then the
    // forward cursor confirmation and the subscribe handshake run unchanged.
    try check(await h.backend.eventCalls == 3, "lazy open replayed forward pages")
    try check(await h.backend.beforeCursors == [450], "open did not anchor at the journal tail")
    try check(h.session.runtimes["c"]?.appliedSequence == 450, "tail window not applied")
    try check(h.session.runtimes["c"]?.readyForActions == true, "lazy open gated actions")
    try check(h.session.runtimes["c"]?.messages.count == 200, "tail window size")
    try check(h.session.runtimes["c"]?.messages.last?.sequence == 251, "window floor")
    try check(h.session.hasEarlierHistory("c"), "history exhausted too early")
    // A live frame landing while the earlier page is in flight must survive.
    let gate = Gate()
    await h.backend.gateNextPage(gate)
    let load = Task { try await h.session.loadEarlier("c") }
    try await eventually("earlier page gated") { await h.backend.eventCalls == 4 }
    try await h.socket.emit(
        event(451, "message.completed", ["message": ["role": "assistant", "text": "live", "id": "msg-451"]]))
    // A second request while one is in flight must not issue another fetch.
    try await h.session.loadEarlier("c")
    await gate.release()
    try await load.value
    try await eventually("live frame applied") { h.session.runtimes["c"]?.appliedSequence == 451 }
    try check(await h.backend.eventCalls == 4, "single-flight or live follow-up fetch broken")
    try check(h.session.runtimes["c"]?.messages.first?.text == "live", "live message not at head")
    try check(h.session.runtimes["c"]?.messages.count == 401, "earlier page not prepended")
    try check(h.session.runtimes["c"]?.messages.last?.sequence == 51, "page floor wrong")
    try check(h.session.hasEarlierHistory("c"), "floor should remain above the head")
    try await h.session.loadEarlier("c")
    try check(h.session.runtimes["c"]?.messages.count == 451, "final page missing")
    try check(!h.session.hasEarlierHistory("c"), "history floor did not reach the journal head")
    try check(await h.backend.beforeCursors == [450, 250, 50], "wrong reverse cursors")
    let calls = await h.backend.eventCalls
    try await h.session.loadEarlier("c")
    try check(await h.backend.eventCalls == calls, "exhausted history still fetched")
    h.session.disconnect()
}
@MainActor func lazyOpenFallsBackToForwardReplay() async throws {
    let records = (1...450).map { n in
        let message: JSONValue = ["role": "assistant", "text": .string("m\(n)"), "id": .string("msg-\(n)")]
        return event(n, "message.completed", ["message": message])
    }
    let h = try Harness(records)
    await h.backend.setReversePages(false)
    try await h.ready()
    try check(h.session.runtimes["c"]?.appliedSequence == 450, "fallback replay incomplete")
    try check(h.session.runtimes["c"]?.messages.count == 450, "fallback dropped messages")
    try check(!h.session.hasEarlierHistory("c"), "fallback left a history floor")
    try check(await h.backend.beforeCursors == [450], "fallback never tried a reverse page")
    h.session.disconnect()
}
@MainActor func lazyOpenScansBackForActiveTurn() async throws {
    var records = (1...450).map { event($0) }
    records[149] = event(150, "turn.started", ["turnId": "t-active"])
    let h = try Harness(records)
    await h.backend.setStatus("running")
    try await h.ready()
    // Page [251..450] holds no turn.started, so recovery pages back to 150.
    try check(await h.backend.beforeCursors == [450, 250], "active turn scan did not page back")
    try check(h.session.runtimes["c"]?.activeTurnId == "t-active", "active turn lost")
    try check(h.session.runtimes["c"]?.status == "running", "active turn status lost")
    try check(h.session.hasEarlierHistory("c"), "scan should stop above the journal head")
    h.session.disconnect()
}
@MainActor func watchedConversationUpdatesListRow() async throws {
    let h = try Harness(); await h.session.connect()
    try await eventually("watch subscribed") { await h.socket.watches == ["c"] }
    try await h.socket.emit(event(1, "turn.started", ["turnId": "t"]))
    try await eventually("row running") { h.session.conversations.first?.status == "running" }
    try check(h.session.runtimes["c"] == nil, "a watch-only row built a runtime")
    try await h.socket.emit(event(2, "permission.requested", ["turnId": "t", "permissionId": "p"]))
    try await eventually("row waiting") { h.session.conversations.first?.status == "waiting_permission" }
    try await h.socket.emit(event(3, "turn.completed", ["turnId": "t"]))
    try await eventually("row completed") {
        h.session.conversations.first?.status == "completed" && h.session.conversations.first?.lastSequence == 3
    }
    h.session.disconnect()
}
@MainActor func scopedStreamErrorResubscribesOpenConversation() async throws {
    let h = try Harness([event(1)]); try await h.ready()
    h.session.activeConversationID = "c"
    let before = await h.socket.subscribeCursors.count
    await h.socket.emitFrame(["type": "server.error", "payload": ["code": "EVENT_STREAM_LAGGED", "message": "lagged"]])
    await h.socket.emitFrame(["type": "server.error", "payload": ["code": "CONFLICT", "message": "gap", "conversationId": "c"]])
    try await eventually("resubscribed") {
        await h.socket.subscribeCursors.count == before + 1 && h.session.runtimes["c"]?.readyForActions == true
    }
    try check(h.session.isConnected, "a subscription-scoped error dropped the connection")
    try check(h.session.lastError == "gap", "lag notice surfaced as an error or scoped error was hidden: \(h.session.lastError ?? "none")")
    h.session.disconnect()
}
@MainActor func permanentCloseStopsReconnect() async throws {
    let permanent = try Harness(); await permanent.session.connect()
    await permanent.socket.emitFrame(["type": "connection.closed", "payload": ["message": "key", "retryable": false]])
    try await eventually("closed") { !permanent.session.isConnected }
    try check(permanent.session.status.contains("连接已停止"), "permanent failure kept retrying: \(permanent.session.status)")
    permanent.session.disconnect()
    let transient = try Harness(); await transient.session.connect()
    await transient.socket.emitFrame(["type": "connection.closed", "payload": ["message": "lost", "retryable": true]])
    try await eventually("closed") { !transient.session.isConnected }
    try check(transient.session.status.contains("第 1 次重试"), "transient failure did not retry: \(transient.session.status)")
    transient.session.disconnect()
}
@MainActor func subscriptionBudgetEvictsIdleWatch() async throws {
    let h = try Harness()
    let ids = (0..<140).map { "x\($0)" }
    await h.backend.setExtraConversations(ids)
    await h.session.connect()
    try await eventually("watch stops at its headroom") { await h.socket.watches.count == 104 }
    let watched = Set(await h.socket.watches)
    let unwatched = ids.filter { !watched.contains($0) }
    for id in unwatched.prefix(16) { try await h.session.recover(id) }
    try check(await h.socket.unsubscribes.isEmpty, "evicted below the budget")
    try await h.session.recover(unwatched[16])
    let evicted = await h.socket.unsubscribes
    try check(evicted.count == 1 && watched.contains(evicted[0]), "budget did not evict one idle watch: \(evicted)")
    try check(h.session.runtimes[unwatched[16]]?.readyForActions == true, "subscribe after eviction failed")
    h.session.disconnect()
}
@MainActor func busySendUsesTheBackendQueue() async throws {
    let h = try Harness([event(1, "turn.started", ["turnId": "t"])])
    await h.backend.setProviders(queueProviders())
    try await h.ready()
    let note = MessageAttachment(name: "a.txt", mimeType: "text/plain", data: Data("x".utf8))
    let draft = ComposerDraft(text: "see [文件:a.txt]", attachments: [note], skills: [SkillAttachment(id: "r1", name: "review")])
    h.session.drafts["c"] = draft
    try await h.session.send(draft, in: h.manifest)
    var commands = await h.socket.queueCommands
    let added = commands.last { $0.0 == "conversation.queue.add" }?.1 ?? .null
    try check(added["text"] == "see [文件:a.txt]" && added["itemId"].stringValue.count > 8, "busy send did not add to the backend queue")
    try check(added["content"].arrayValue.count == 1 && added["skills"].arrayValue.first?["resourceId"] == "r1", "attachment or skill lost")
    try check(added["paused"] == .null, "plain add must not pause")
    try check(h.session.drafts["c"]?.isEmpty == true, "composer kept an accepted message")
    let prompted = await h.socket.prompts.count, controlled = await h.socket.controls.count
    try check(prompted == 0 && controlled == 0, "busy send prompted or used native controls")

    // A rejected add (queue full) keeps the composer and reports the backend's message.
    await h.socket.failQueueAdds([.server(code: "RESOURCE_EXHAUSTED", message: "queue is full (32)")])
    let next = ComposerDraft(text: "one too many")
    h.session.drafts["c"] = next
    do {
        try await h.session.send(next, in: h.manifest)
        try check(false, "a full queue accepted the message")
    } catch TodexError.server(let code, let message) {
        try check(code == "RESOURCE_EXHAUSTED" && message.contains("32"), "unexpected error \(code) \(message)")
    }
    try check(h.session.drafts["c"] == next && h.session.pendingSends["c"] == nil, "failed add lost the draft")

    // The loaded window can miss a running turn: a CONFLICT moves the prompt
    // into the queue under its request id instead of failing the send.
    try await h.socket.emit(event(2, "turn.completed", ["turnId": "t"]))
    try await eventually("turn completed") { h.session.runtimes["c"]?.status == "completed" }
    await h.socket.configure(error: .server(code: "CONFLICT", message: "conversation c is already running turn x"))
    h.session.drafts["c"] = ComposerDraft()
    try await h.session.send(ComposerDraft(text: "after all"), in: h.manifest)
    let prompt = await h.socket.prompts.last
    commands = await h.socket.queueCommands
    try check(prompt != nil && commands.last?.0 == "conversation.queue.add" && commands.last?.1["itemId"] == .string(prompt?.0 ?? ""), "CONFLICT not queued under the request id")
    try check(h.session.pendingSends["c"] == nil && h.session.drafts["c"]?.isEmpty != false, "CONFLICT left a pending send or restored the draft")
    h.session.disconnect()
}
@MainActor func oldBackendRejectsBusySendsAndPermissionGuard() async throws {
    let h = try Harness([event(1, "turn.started", ["turnId": "t"])])
    await h.backend.setProviders([
        ProviderDescriptor(
            id: "codex", displayName: "Codex", available: true,
            capabilities: ["followUpQueue": true, "permissionConfig": ["modes": ["auto"]]])
    ])
    try await h.ready()
    try check(h.session.preferences(for: h.manifest).permissionMode == "", "assumed ask for an agent without it")
    let draft = ComposerDraft(text: "next")
    h.session.drafts["c"] = draft
    do {
        try await h.session.send(draft, in: h.manifest)
        try check(false, "a backend without the queue accepted a busy send")
    } catch TodexError.invalid(let message) {
        try check(message.contains("后端"), "unclear upgrade error: \(message)")
    }
    try check(h.session.drafts["c"] == draft, "rejected busy send cleared the composer")
    let wire = await (h.socket.controls.count, h.socket.queueCommands.count, h.socket.prompts.count)
    try check(wire == (0, 0, 0), "busy send reached the wire: \(wire)")
    try await h.socket.emit(event(2, "turn.completed", ["turnId": "t"]))
    try await eventually("turn completed") { h.session.runtimes["c"]?.status == "completed" }
    do {
        try await h.session.send(ComposerDraft(text: "go"), in: h.manifest)
        throw Failure(description: "sent with a permission mode the agent does not support")
    } catch TodexError.invalid {}
    try check(await h.socket.prompts.isEmpty, "prompt reached the socket")
    h.session.disconnect()
}
@MainActor func legacyQueueMigrates() async throws {
    // Ordered, under the original ids; the paused flag rides on the first add.
    let one = QueuedDraft(id: "legacy-1", draft: ComposerDraft(text: "first"))
    let two = QueuedDraft(id: "legacy-2", draft: ComposerDraft(text: "second"))
    var snapshot = SessionSnapshot()
    snapshot.queues = ["c": [one, two]]; snapshot.pausedQueues = ["c"]
    let h = try Harness([event(1, "turn.started", ["turnId": "t"])], snapshot: snapshot)
    await h.backend.setProviders(queueProviders())
    try await h.ready()
    try await eventually("legacy queue handed over") { await h.socket.queueCommands.filter { $0.0 == "conversation.queue.add" }.count == 2 }
    let adds = await h.socket.queueCommands.filter { $0.0 == "conversation.queue.add" }.map(\.1)
    try check(adds.map { $0["itemId"].stringValue } == ["legacy-1", "legacy-2"], "ids or order changed: \(adds.map { $0["itemId"] })")
    try check(adds[0]["paused"] == true && adds[1]["paused"] == .null, "pause must ride on the first add only")
    try check(h.session.legacyQueues.isEmpty && h.session.legacyPausedQueues.isEmpty, "legacy data kept after success")
    try check(await h.socket.prompts.isEmpty, "migration prompted")
    try await eventually("legacy keys gone from disk") {
        let stored = try h.store.read(h.stateKey, as: JSONValue.self)
        return stored != nil && stored?["queues"] == .null && stored?["pausedQueues"] == .null
    }
    h.session.disconnect()
}
@MainActor func legacyQueueRetriesAndDrops() async throws {
    let one = QueuedDraft(id: "legacy-1", draft: ComposerDraft(text: "first"))
    let two = QueuedDraft(id: "legacy-2", draft: ComposerDraft(text: "second"))
    var snapshot = SessionSnapshot()
    snapshot.queues = ["c": [one, two], "ghost": [QueuedDraft(id: "g1", draft: ComposerDraft(text: "orphan text"))]]
    let h = try Harness(snapshot: snapshot)
    await h.backend.setProviders(queueProviders())
    // First item succeeds, the second fails in transit: it stays for the next connect.
    await h.socket.failQueueAdds([]) 
    await h.session.connect()
    try await eventually("ghost conversation discarded with a notice") { h.session.discardedCandidates.count == 1 }
    try check(h.session.discardedCandidates.first?.texts == ["orphan text"] && h.session.legacyQueues["ghost"] == nil, "unknown conversation not surfaced")
    try await eventually("migrated") { h.session.legacyQueues["c"] == nil }
    h.session.disconnect()

    // Transient failure keeps the data and the next connect retries it in order.
    var again = SessionSnapshot()
    again.queues = ["c": [one, two]]
    let r = try Harness(snapshot: again)
    await r.backend.setProviders(queueProviders())
    await r.socket.failQueueAdds([.unknownOutcome("ACK lost")])
    await r.session.connect()
    try await eventually("first add failed") { await r.socket.queueCommands.filter { $0.0 == "conversation.queue.add" }.count == 1 }
    try await Task.sleep(for: .milliseconds(30))
    try check(r.session.legacyQueues["c"]?.map(\.id) == ["legacy-1", "legacy-2"] && r.session.discardedCandidates.isEmpty, "transient failure dropped data")
    r.session.disconnect()
    await r.session.connect()
    try await eventually("retry migrated both") { r.session.legacyQueues.isEmpty }
    let ids = await r.socket.queueCommands.filter { $0.0 == "conversation.queue.add" }.map { $0.1["itemId"].stringValue }
    try check(ids == ["legacy-1", "legacy-1", "legacy-2"], "retry order/ids: \(ids)")
    r.session.disconnect()

    // A paused local queue needs backendQueueControl; without it nothing moves.
    var paused = SessionSnapshot()
    paused.queues = ["c": [one]]; paused.pausedQueues = ["c"]
    let p = try Harness(snapshot: paused)
    await p.backend.setProviders(queueProviders(control: false))
    await p.session.connect()
    try await Task.sleep(for: .milliseconds(60))
    try check(await p.socket.queueCommands.isEmpty && p.session.legacyQueues["c"]?.count == 1 && p.session.legacyPausedQueues == ["c"], "paused queue moved without control")
    p.session.disconnect()

    // A permanent refusal (queue full) and a read-only conversation surface the text and drop it.
    var refused = SessionSnapshot()
    refused.queues = ["c": [one, two]]
    let f = try Harness(snapshot: refused)
    await f.backend.setProviders(queueProviders())
    await f.socket.failQueueAdds([.server(code: "RESOURCE_EXHAUSTED", message: "full")])
    await f.session.connect()
    try await eventually("refusal surfaced") { f.session.discardedCandidates.first?.texts == ["first", "second"] }
    try check(f.session.legacyQueues.isEmpty, "refused data kept")
    f.session.dismissDiscardedCandidates(f.session.discardedCandidates[0].id)
    try check(f.session.discardedCandidates.isEmpty, "notice not dismissable")
    f.session.disconnect()

    let r2 = try Harness(snapshot: refused)
    await r2.backend.setProviders(queueProviders())
    await r2.backend.setLegacyPlaintext(true)
    await r2.session.connect()
    try await eventually("read-only discarded") { r2.session.discardedCandidates.first?.texts == ["first", "second"] }
    try check(await r2.socket.queueCommands.filter { $0.0 == "conversation.queue.add" }.isEmpty && r2.session.legacyQueues.isEmpty, "read-only conversation received writes")
    r2.session.disconnect()
}
@MainActor func pauseAndEditThroughTake() async throws {
    let h = try Harness([event(1, "turn.started", ["turnId": "t"])])
    await h.backend.setProviders(queueProviders())
    await h.socket.setQueueSnapshot(["items": [["id": "q1", "text": "waiting [图片:p.jpg]", "status": "queued"]], "paused": false])
    try await h.ready()
    try await h.session.editFollowUps("pause", conversation: h.manifest)
    try check(h.session.runtimes["c"]?.followUpsPaused == true && h.session.runtimes["c"]?.followUpsPauseReason == "user", "pause not adopted from the backend")
    let png = Data([1, 2, 3])
    await h.socket.setTakeItem([
        "id": "q1", "text": "waiting [图片:p.jpg] and [文件:n.txt] [引用:ref]",
        "content": [
            ["type": "image", "data": .string(png.base64EncodedString()), "mimeType": "image/png"],
            ["type": "text", "text": "附件：n.txt\nline1\nline2"],
            ["type": "text", "text": "[引用: src/a.swift:3-5]\nContent:\nlet x = 1"],
            ["type": "localImage", "path": "/tmp/x.png"],
        ],
        "skills": [["resourceId": "r1", "name": "review"]],
    ])
    let taken = try await h.session.takeFollowUp("q1", conversation: h.manifest)
    let last = await h.socket.queueCommands.last
    try check(last?.0 == "conversation.queue.take" && last?.1["itemId"] == "q1", "take not sent")
    try check(h.session.runtimes["c"]?.followUps.isEmpty == true, "taken item still listed")
    try check(taken.skills == [SkillAttachment(id: "r1", name: "review")], "skills lost")
    try check(taken.attachments.count == 3, "attachments: \(taken.attachments.map(\.name))")
    let image = taken.attachments[0], file = taken.attachments[1], reference = taken.attachments[2]
    try check(image.isImage && image.name == "p.jpg" && image.mimeType == "image/png" && image.data == png, "image not rebuilt")
    try check(file.name == "n.txt" && String(decoding: file.data, as: UTF8.self) == "line1\nline2" && !file.isImage, "text attachment not rebuilt")
    try check(reference.name == "ref" && reference.reference?.path == "src/a.swift:3-5" && String(decoding: reference.data, as: UTF8.self) == "let x = 1", "reference not rebuilt")
    try check(taken.attachments.allSatisfy { taken.text.contains($0.token) }, "tokens no longer match the text: \(taken.text)")
    try check(taken.text.hasSuffix("/tmp/x.png"), "unrestorable part dropped: \(taken.text)")
    // Rebuilt attachments re-serialize to the content that was queued.
    try check(file.wireValue == ["type": "text", "text": "附件：n.txt\nline1\nline2"] && reference.wireValue == ["type": "text", "text": "[引用: src/a.swift:3-5]\nContent:\nlet x = 1"], "round trip changed the wire form")

    // Without backendQueueControl neither pause nor take is available.
    await h.backend.setProviders(queueProviders(control: false))
    try await h.session.refresh()
    let before = await h.socket.queueTypes().count
    for operation in ["pause", "take"] {
        do {
            if operation == "pause" { try await h.session.editFollowUps("pause", conversation: h.manifest) }
            else { _ = try await h.session.takeFollowUp("q1", conversation: h.manifest) }
            try check(false, "\(operation) ran without backendQueueControl")
        } catch TodexError.invalid {}
    }
    try check(await h.socket.queueTypes().count == before, "unsupported control reached the wire")
    h.session.disconnect()
}
@MainActor func fixtureNeverOverwritesCatalog() async throws {
    #if DEBUG
    let store = try TestEnvironment.store()
    let real = BackendConnection(id: "real-1", name: "真实后端", serverURL: "https://real.invalid")
    try store.save([real], key: "connections")
    let session = AppSession(
        store: store, defaults: TestEnvironment.defaults(), credentialWriter: { _, _ in })
    try check(
        session.connections.contains { $0.id == "real-1" }
            && session.connections.contains { $0.id == "simulator-fixture" },
        "fixture replaced the real catalog in memory")
    var edited = session.connections
    edited.append(BackendConnection(id: "added-1", name: "新增", serverURL: "https://added.invalid"))
    try session.saveConnections(edited, selected: "real-1")
    let onDisk = try store.read("connections", as: [BackendConnection].self) ?? []
    try check(
        onDisk.contains { $0.id == "real-1" } && onDisk.contains { $0.id == "added-1" }
            && !onDisk.contains { $0.id == "simulator-fixture" },
        "fixture reached the on-disk catalog or a real entry was dropped")
    session.disconnect()
    #endif
}
/// Home parity: list fork without a replayed runtime, busy refusal, rejected
/// workspaces, local conversation labels and another backend's cached catalog.
@MainActor func homeParity() async throws {
    let h = try Harness()
    await h.backend.setProviders([
        ProviderDescriptor(
            id: "codex", displayName: "Codex", available: true, capabilities: ["controlActions": ["fork"]])
    ])
    await h.backend.setExtraConversations(["c-fork"])
    await h.backend.setRejected([RejectedWorkspace(id: "gone", name: "旧", path: "/gone", message: "missing")])
    await h.session.connect()
    try check(h.session.isConnected, "connect failed")
    try check(h.session.rejectedWorkspaces.map(\.id) == ["gone"], "rejected workspaces not exposed")
    try check(h.session.runtimes["c"] == nil, "fork precondition: conversation never opened")
    var source = h.session.preferences(for: h.manifest)
    source.model = "fork-model"
    h.session.updatePreferences(source, for: h.manifest)
    let created = try await h.session.fork(h.manifest)
    let payload = await h.socket.forks.first ?? .null
    try check(created.id == "c-fork", "fork did not return the new conversation")
    try check(
        payload["conversationId"] == "c" && payload["title"] == "对话 · 分叉",
        "unexpected fork payload: \(payload)")
    try check(h.session.preferences(for: created).model == "fork-model", "fork did not inherit preferences")
    await h.backend.setStatus("running")
    try await h.session.refresh()
    do {
        _ = try await h.session.fork(h.manifest)
        throw TodexError.invalid("fork of a running conversation was not refused")
    } catch TodexError.invalid(let message) where message.contains("结束当前任务") {}
    try check(await h.socket.forks.count == 1, "a refused fork reached the backend")

    h.session.setConversationLabel("#EF4444", for: "c")
    h.session.setConversationLabel("teal", for: "c-fork")
    try check(h.session.conversationLabels == ["c": "#ef4444"], "labels not normalized")
    let task = h.session.addTask(workspaceId: "w", title: "细节", description: "  说明 ", dueDate: "2026-13")
    try check(task?.description == "说明" && task?.dueDate == nil, "task details not validated")
    h.session.updateTaskDetails(task?.id ?? "", description: nil, dueDate: "2026-10-01")
    try check(
        h.session.tasks.first { $0.id == task?.id }.map { $0.description == nil && $0.dueDate == "2026-10-01" } == true,
        "task details not updated")
    h.session.persist()
    try await eventually("labels persisted") {
        try h.store.read(h.stateKey, as: SessionSnapshot.self)?.conversationLabels == ["c": "#ef4444"]
    }
    // Another backend's cache is readable but never merged into this session.
    let other = BackendConnection(id: "other-" + UUID().uuidString, name: "Other", serverURL: "https://other.invalid")
    var cached = SessionSnapshot()
    cached.workspaces = [WorkspaceRecord(id: "ow", name: "Other W", path: "/other")]
    try h.store.save(cached, key: LocalStore.namespace(other) + "-state")
    let read = try await h.session.cachedSnapshot(for: other)
    try check(read?.workspaces.map(\.id) == ["ow"], "other backend cache not readable")
    try check(!h.session.workspaces.contains { $0.id == "ow" }, "other backend state leaked into the session")
    try check(try await h.session.cachedSnapshot(for: h.connection) == nil, "active namespace read as other backend")
    let legacy = try JSONDecoder().decode(
        SessionSnapshot.self, from: JSONEncoder().encode(["drafts": JSONValue.object([:])]))
    try check(legacy.conversationLabels.isEmpty, "legacy snapshot failed to decode without labels")
    h.session.disconnect()
}
@MainActor func usageLedgerPersistsAcrossRestart() async throws {
    // A record from an older, unloaded part of the journal must survive; a
    // runtime record with the same id replaces its stored copy.
    var snapshot = SessionSnapshot()
    snapshot.usageRecords = [
        ["id": "old", "conversationId": "c", "turnId": "t0", "provider": "codex", "updatedAt": 1, "totalTokens": 5],
        ["id": "other", "conversationId": "d", "turnId": "t9", "provider": "pi", "updatedAt": 2, "totalTokens": 7],
    ]
    let h = try Harness(
        [event(1, "turn.started", ["turnId": "t"]),
         event(2, "usage.updated", ["provider": "codex", "turnId": "t", "usage": ["last": ["input": 80, "output": 10, "total": 90]]])],
        snapshot: snapshot)
    try await h.ready()
    try await eventually("usage merged") { h.session.usageRecords.count == 3 }
    try check(h.session.usageRecords.contains { $0["id"] == "old" } && h.session.usageRecords.contains { $0["id"] == "other" },
              "merge dropped records outside the loaded window")
    try check(h.session.usageRecords.contains { $0["turnId"] == "t" && $0["totalTokens"] == 90 }, "runtime record missing")
    h.session.persist()
    try await eventually("usage persisted") {
        (try h.store.read(h.stateKey, as: SessionSnapshot.self)?.usageRecords.count) == 3
    }
    // A final turn snapshot supersedes that turn's partial records.
    let stored: [JSONValue] = [
        ["id": "r1", "conversationId": "c", "turnId": "t", "provider": "codex", "scope": "request", "updatedAt": 3],
        ["id": "keep", "conversationId": "c", "turnId": "u", "provider": "codex", "scope": "request", "updatedAt": 4],
    ]
    let merged = UsageLedger.merge(
        stored, runtime: [["id": "turn", "conversationId": "c", "turnId": "t", "provider": "codex", "scope": "turn", "updatedAt": 5]],
        provider: "codex", model: "gpt")
    try check(merged.map { $0["id"] } == ["turn", "keep"], "turn record did not supersede: \(merged.map { $0["id"] })")
    try check(merged.first?["model"] == "gpt", "unknown model not filled from conversation")
    let bounded = UsageLedger.union((0..<2_100).map { ["id": .string("n\($0)"), "updatedAt": .number(Double($0))] }, [])
    try check(bounded.count == UsageLedger.limit && bounded.first?["id"] == "n2099", "ledger not bounded newest-first")
    let legacy = try JSONDecoder().decode(
        SessionSnapshot.self, from: JSONEncoder().encode(["drafts": JSONValue.object([:])]))
    try check(legacy.usageRecords.isEmpty, "legacy snapshot failed to decode without usageRecords")
    h.session.disconnect()
}
@MainActor func connectFailureKeepsDiagnosticError() async throws {
    let h = try Harness()
    await h.session.connect()
    await h.socket.emitFrame(["type": "connection.closed", "payload": ["code": "401", "message": "后端拒绝认证", "retryable": false]])
    try await eventually("closed") { !h.session.isConnected && h.session.lastConnectionError != nil }
    try check(ConnectionDiagnostic.classify(h.session.lastConnectionError!).category == .authenticationFailed,
              "close code lost for diagnostics")
    await h.session.connect()
    try check(h.session.isConnected && h.session.lastConnectionError == nil, "diagnostic survived a successful connect")
    h.session.disconnect()
}
@MainActor func agentDesktopStateAndBrowserWatches() async throws {
    let h = try Harness([event(1, "desktop.computer.grant", ["status": "requested", "deviceName": "Mac"])])
    try await h.ready()
    try check(h.session.runtimes["c"]?.desktopComputer.awaitingHost == true, "replayed grant request not projected")
    try await h.socket.emit(event(2, "desktop.computer.session", ["status": "started", "deviceId": "d", "deviceName": "Mac"]))
    try await eventually("live session projected") { h.session.runtimes["c"]?.desktopComputer.active == true }
    try check(h.session.runtimes["c"]?.messages.isEmpty == true, "desktop events reached the timeline")
    final class Frames { var items: [AgentBrowserFrame] = [] }
    let first = Frames(), second = Frames()
    let a = h.session.watchAgentBrowser("c") { first.items.append($0) }
    let b = h.session.watchAgentBrowser("c") { second.items.append($0) }
    try await eventually("one socket watch for two views") { await h.socket.browserWatches == ["agentBrowser.watch:c"] }
    h.socket.emitBrowserFrame(["conversationId": "c", "seq": 1, "mimeType": "image/jpeg", "data": "AQID", "width": 1, "height": 1])
    h.socket.emitBrowserFrame(["conversationId": "other", "closed": true])
    h.socket.emitBrowserFrame(["conversationId": "c", "closed": true])
    try await eventually("frames delivered to both views") { first.items.count == 2 && second.items.count == 2 }
    try check(first.items.first?.content == .image(seq: 1, base64: "AQID", width: 1, height: 1), "frame decoded wrong")
    try check(first.items.last?.content == .closed, "closed frame lost")
    try check(h.session.runtimes["c"]?.appliedSequence == 2, "a frame entered the journal")
    h.session.disconnect()
    await h.session.connect()
    try await eventually("reconnect watches again") {
        await h.socket.browserWatches == ["agentBrowser.watch:c", "agentBrowser.watch:c"]
    }
    h.socket.emitBrowserFrame(["conversationId": "c", "closed": true])
    try await eventually("frames resume on the new socket") { first.items.count == 3 }
    h.session.unwatchAgentBrowser(a)
    try await Task.sleep(for: .milliseconds(50))
    try check(await h.socket.browserWatches.count == 2, "unwatched while another view remained")
    h.session.unwatchAgentBrowser(b)
    try await eventually("last view unwatches") { await h.socket.browserWatches.last == "agentBrowser.unwatch:c" }
    h.session.disconnect()
}

/// Content sealed under `key` for conversation "c" at sequence `n`.
@MainActor func sealedEvent(_ n: Int, key: HistoryCrypto.SegmentKey, turn: String, text: String) throws -> ConversationEvent {
    let payload: JSONValue = ["turnId": .string(turn), "text": .string(text)]
    let ciphertext = try HistoryCrypto.seal(
        JSONEncoder().encode(payload), key: key, conversationID: "c", stream: .eventFull, counter: UInt64(n))
    return event(n, "message.delta", ["turnId": .string(turn), "$enc": ["v": 1, "kid": .string(HistoryEncryption.encodeID(key.kid)), "c": "c",
        "n": .number(Double(n)), "f": .string(HistoryEncryption.encodeID(ciphertext))]])
}
nonisolated func historyPush(_ reason: String, rid: String? = nil, deviceId: String? = nil, conversations: [String]? = nil) -> JSONValue {
    var payload: JSONValue = ["epoch": 2, "mode": "e2e", "reason": .string(reason)]
    if let rid { payload["rid"] = .string(rid) }
    if let deviceId { payload["deviceId"] = .string(deviceId) }
    if let conversations { payload["conversationIds"] = .array(conversations.map { .string($0) }) }
    return ["eventId": .string(UUID().uuidString), "type": "history.encryption.updated", "payload": payload]
}
/// Device B's open conversation shows locked rows; another device fulfills
/// its grant and the push alone (no reload, no reopen) unlocks them.
@MainActor func grantPushUnlocksLoadedConversation() async throws {
    let device = try HistoryCrypto.generateRecipientKey()
    let key = HistoryCrypto.SegmentKey.generate()
    let secret = "granted secret reply"
    let h = try Harness(
        [event(1, "turn.started", ["turnId": "t"]), try sealedEvent(2, key: key, turn: "t", text: secret), event(3, "turn.completed", ["turnId": "t"])],
        historySeed: device.seedRepresentation)
    await h.socket.configureHistory(access: "active")
    await h.backend.setReversePages(false)
    h.session.activeConversationID = "c"
    try await h.ready()
    let isLocked = { h.session.runtimes["c"]?.messages.contains { $0.category == ConversationRuntime.lockedCategory } == true }
    try check(isLocked(), "no wrap yet: the reply should be locked")
    let mine = try required(h.session.historyDeviceRecipientID)
    // The grant lands on the backend.
    await h.socket.setHistoryWrap(
        kid: HistoryEncryption.encodeID(key.kid),
        wrapped: try JSONValue(encoding: HistoryCrypto.wrap(key, for: device.publicKey.rawRepresentation)))
    // Pushes for another device leave this one alone (the miss stays cached).
    let calls = await h.backend.eventCalls
    await h.socket.emitFrame(historyPush("grant.progress", rid: "someone-else", conversations: ["c"]))
    await h.socket.emitFrame(historyPush("grant.requested", rid: "someone-else"))
    try await eventually("state re-read after pushes") { await h.socket.historyLog.filter { $0 == "history.encryption.get" }.count >= 2 }
    try await Task.sleep(for: .milliseconds(100))
    try check(isLocked() && h.session.runtimes["c"]?.readyForActions == true, "a push for another device reloaded this one")
    try check(await h.backend.eventCalls == calls, "a push for another device refetched history")
    // A burst of progress pushes for this device: one rebuild, rows unlock in place.
    for _ in 0..<3 { await h.socket.emitFrame(historyPush("grant.progress", rid: mine, conversations: ["c", "other"])) }
    await h.socket.emitFrame(historyPush("grant.fulfilled", rid: mine))
    try await eventually("locked rows unlock without reload") {
        !isLocked() && h.session.runtimes["c"]?.readyForActions == true
            && h.session.runtimes["c"]?.messages.map(\.text) == [secret]
    }
    try check(h.session.activeConversationID == "c", "the open conversation changed")
    h.session.disconnect()
}
/// A revoked device never registers or re-keys; another device's restore
/// lifts the block, after which it registers a fresh key (its old one is
/// permanently revoked and refused with CONFLICT).
@MainActor func revokedDeviceStaysUnregisteredUntilRestored() async throws {
    let device = try HistoryCrypto.generateRecipientKey()
    let oldKey = HistoryEncryption.encodeID(device.publicKey.rawRepresentation)
    let secret = "FRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRU"
    let me = try required(DeviceIdentity(secretKeyBase64URL: secret)?.deviceID)
    let h = try Harness([event(1)], historySeed: device.seedRepresentation, deviceSecret: secret)
    await h.socket.configureHistory(
        access: "revoked", revokedKeys: [oldKey], revokedDevices: [["deviceId": .string(me), "revokedAt": "2026-10-06T00:00:00Z"]])
    try await h.ready()
    try await eventually("revoked state read") { h.session.historyEncryption?.isAccessRevoked == true }
    try check(h.session.historyAccessRevoked, "revoked state not exposed")
    try check(h.session.historyEncryption?.revokedDevices.first?.deviceId == me, "revoked devices missing")
    // Pushes and Settings refreshes re-read the state but never register.
    await h.socket.emitFrame(historyPush("recipient.registered", rid: "other"))
    _ = try await h.session.refreshHistoryEncryption()
    try await eventually("push re-read the state") { await h.socket.historyLog.filter { $0 == "history.encryption.get" }.count >= 3 }
    try check(await h.socket.registeredKeys.isEmpty, "a revoked device registered")
    do {
        try await h.session.requestHistoryGrant()
        try check(false, "a revoked device requested a grant")
    } catch TodexError.server(let code, _) {
        try check(code == HistoryEncryption.accessRevoked, "unexpected error \(code)")
        try check(!TodexError.server(code: code, message: "").localizedDescription.isEmpty, "no notice")
    }
    try check(!(await h.socket.historyLog.contains("history.grant.request")), "grant request reached the backend")
    // Another device restores it: the push re-reads, the old key is refused
    // (CONFLICT) and a fresh one is registered and stored.
    await h.socket.configureHistory(access: "unregistered", revokedKeys: [oldKey], revokedDevices: [])
    await h.socket.emitFrame(historyPush("device.restored", deviceId: me))
    try await eventually("restored device registers a fresh key") {
        h.session.historyEncryption?.myAccess == "active" && !h.session.historyAccessRevoked
    }
    let keys = await h.socket.registeredKeys
    try check(keys.count == 2 && keys[0] == oldKey && keys[1] != oldKey, "re-key sequence: \(keys.count)")
    try check(h.seeds.value != nil && h.seeds.value != device.seedRepresentation, "fresh seed not stored")
    try check(h.session.historyDeviceRecipientID == h.session.historyEncryption?.myRid, "decryptor not switched to the fresh key")
    // A device revoked while connected learns it from the refused command.
    await h.socket.configureHistory(access: "revoked")
    await h.socket.emitFrame(historyPush("device.revoked", deviceId: me))
    try await eventually("revocation observed") { h.session.historyAccessRevoked }
    let registrations = await h.socket.registeredKeys.count
    try await Task.sleep(for: .milliseconds(400))
    try check(await h.socket.registeredKeys.count == registrations, "re-registered after revocation")
    h.session.disconnect()
}
/// History is always end-to-end encrypted: a missing recovery key shows a
/// notice the user can close for this backend; HISTORY_KEY_REQUIRED registers
/// this device's key again; `legacyPlaintext` conversations refuse every write
/// locally, and a HISTORY_READ_ONLY refusal marks the conversation read-only.
@MainActor func legacyPlaintextIsReadOnlyAndKeyRequiredRegisters() async throws {
    let device = try HistoryCrypto.generateRecipientKey()
    let h = try Harness(
        [event(1)], historySeed: device.seedRepresentation, deviceSecret: "FRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRU")
    await h.backend.setProviders([
        ProviderDescriptor(id: "codex", displayName: "Codex", available: true, capabilities: ["controlActions": ["fork", "compact"]])
    ])
    await h.socket.configureHistory(access: "unregistered")
    try await h.ready()
    try await eventually("device key registered") {
        h.session.historyDeviceRecipientID != nil && h.session.historyEncryption?.myRid == h.session.historyDeviceRecipientID
    }
    try check(h.session.historyRecoveryMissing && h.session.showsRecoveryKeyNotice, "missing recovery key not announced")
    h.session.dismissRecoveryKeyNotice()
    try check(h.session.historyRecoveryMissing && !h.session.showsRecoveryKeyNotice, "closed notice came back")

    // The backend has no recipient any more: the refused write re-registers.
    let registered = await h.socket.registeredKeys.count
    await h.socket.forgetHistoryRecipient()
    await h.socket.configure(error: TodexError.server(code: HistoryEncryption.keyRequired, message: "no recipient"))
    do {
        try await h.session.send(ComposerDraft(text: "needs a key"), in: h.manifest)
        try check(false, "a write without a recipient succeeded")
    } catch TodexError.server(let code, _) {
        try check(code == HistoryEncryption.keyRequired, "unexpected error \(code)")
    }
    try await eventually("HISTORY_KEY_REQUIRED registered the key again") {
        await h.socket.registeredKeys.count == registered + 1 && h.session.historyEncryption?.myRid != nil
    }

    // Legacy plaintext: nothing reaches the backend, the error reads clearly.
    await h.socket.configure()
    await h.backend.setLegacyPlaintext(true)
    try await h.session.refresh()
    try check(h.session.isReadOnly("c"), "legacyPlaintext not adopted from the list")
    let prompts = await h.socket.prompts.count
    let writes: [(String, () async throws -> Void)] = [
        ("send", { try await h.session.send(ComposerDraft(text: "must not be sent"), in: h.manifest) }),
        ("compact", { _ = try await h.session.control("compact", conversation: h.manifest) }),
        ("fork", { _ = try await h.session.fork(h.manifest) }),
        ("queue", { try await h.session.editFollowUps("clear", conversation: h.manifest) }),
        ("steer", { _ = try await h.session.liveControl(["action": "steer", "text": "x"], conversation: h.manifest) }),
    ]
    for (name, write) in writes {
        do {
            try await write()
            try check(false, "\(name) wrote to a read-only conversation")
        } catch TodexError.server(let code, _) {
            try check(code == HistoryEncryption.readOnly, "\(name): unexpected error \(code)")
        }
    }
    try check(await h.socket.prompts.count == prompts, "a prompt reached the backend")
    let forks = await h.socket.forks.count, queueCommands = await h.socket.queueCommands.count
    try check(forks == 0 && queueCommands == 0, "a write reached the backend")
    try check(
        TodexError.server(code: HistoryEncryption.readOnly, message: "raw").localizedDescription != "raw", "no notice")

    // A backend refusal marks the conversation read-only before the list does.
    await h.backend.setLegacyPlaintext(false)
    try await h.session.refresh()
    try check(!h.session.isReadOnly("c"), "legacy flag stuck after the list cleared it")
    await h.socket.configure(error: TodexError.server(code: HistoryEncryption.readOnly, message: "read-only"))
    do {
        try await h.session.send(ComposerDraft(text: "refused"), in: h.manifest)
        try check(false, "a refused write succeeded")
    } catch TodexError.server(let code, _) {
        try check(code == HistoryEncryption.readOnly, "unexpected error \(code)")
    }
    try check(h.session.isReadOnly("c"), "HISTORY_READ_ONLY did not mark the conversation")
    h.session.disconnect()
}
@MainActor func required<T>(_ value: T?) throws -> T {
    guard let value else { throw Failure(description: "missing value") }
    return value
}
@main struct SessionRaceRunner {
    @MainActor static func main() async {
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("connect + foreground single flight", connectionSingleFlight),
            ("recover single flight + HTTP/live interleaving", recoveryInterleaving),
            ("subscribe pagination + ACK before frames", subscriptionPagination),
            ("durable ledger before wire + rejection keeps typed text", ledgerBeforeWireAndRejectionKeepsTypedText),
            ("manual rejection + ambiguous mutation", manualFailureAndUnknown),
            ("settings backend switch + stale response", staleBackendResponse),
            ("disk failure + no recursive notification", diskFailurePreservesDraft),
            ("background/disconnect leave the backend queue alone", backgroundAndDisconnectLeaveTheBackendQueueAlone),
            ("tenant scope + bounded cache prefix", scopedReadsAndCachePrefix),
            ("encrypted history: decrypt in memory, ciphertext on disk, retry prompt", encryptedHistoryStaysCiphertextOnDisk),
            ("history push: grant for this device unlocks the open conversation", grantPushUnlocksLoadedConversation),
            ("history revoked: no registration until restored, then a fresh key", revokedDeviceStaysUnregisteredUntilRestored),
            ("history e2e: recovery notice, key-required re-register, legacy read-only", legacyPlaintextIsReadOnlyAndKeyRequiredRegisters),
            ("corrupt optional cache recovery", corruptCacheIsOptional),
            ("wire subscriber overflow gap", streamOverflowSignalsGap),
            ("backend switch during HTTP replay", staleReplayResponse),
            ("DEBUG port environment fixture", debugPortFixture),
            ("fixture launch never overwrites catalog", fixtureNeverOverwritesCatalog),
            ("task plan persistence + legacy snapshot decode", taskPlanPersistence),
            ("composer memory persistence + capability fallback", composerMemory),
            ("lazy tail open + earlier paging", lazyTailOpenAndEarlierPaging),
            ("old backend falls back to forward replay", lazyOpenFallsBackToForwardReplay),
            ("lazy open scans back for active turn", lazyOpenScansBackForActiveTurn),
            ("background watch updates list row", watchedConversationUpdatesListRow),
            ("scoped stream error resubscribes", scopedStreamErrorResubscribesOpenConversation),
            ("permanent close stops reconnect", permanentCloseStopsReconnect),
            ("subscription budget evicts idle watch", subscriptionBudgetEvictsIdleWatch),
            ("busy send queues in the backend: add, full queue, CONFLICT", busySendUsesTheBackendQueue),
            ("old backend rejects busy sends + permission guard", oldBackendRejectsBusySendsAndPermissionGuard),
            ("legacy local candidates migrate to the backend", legacyQueueMigrates),
            ("legacy migration: retry, pause needs control, notices", legacyQueueRetriesAndDrops),
            ("backend pause + edit through take", pauseAndEditThroughTake),
            ("home parity: fork, labels, task details, other backend cache", homeParity),
            ("usage ledger persists across conversations", usageLedgerPersistsAcrossRestart),
            ("connection diagnostic error lifecycle", connectFailureKeepsDiagnosticError),
            ("agent desktop state + browser watches", agentDesktopStateAndBrowserWatches)
        ]
        var failures = 0
        for (name, run) in tests {
            // A detached watchdog also catches a blocked main actor or an
            // unresumed fixture continuation. CI receives a nonzero exit code.
            let watchdog = Task.detached {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                report("FAIL \(name): exceeded 30-second scenario deadline")
                exit(124)
            }
            do { try await run(); report("PASS \(name)") }
            catch { failures += 1; report("FAIL \(name): \(error)") }
            watchdog.cancel()
        }
        report("\(tests.count - failures)/\(tests.count) session regression scenarios passed")
        TestEnvironment.cleanup()
        if failures != 0 { exit(1) }
    }
}
