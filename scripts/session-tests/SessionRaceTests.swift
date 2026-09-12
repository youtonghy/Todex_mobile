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
    var firstPageGate: Gate?
    init(_ events: [ConversationEvent] = []) { journal = events }
    func configure(gate: Gate? = nil, pageSize: Int = 200) { firstPageGate = gate; self.pageSize = pageSize }
    func setProviders(_ values: [ProviderDescriptor]) { providers = values }
    func changeTenant() { workspace.tenantId = "tenant-b" }
    func append(_ events: [ConversationEvent]) { journal.append(contentsOf: events) }
    func handle(_ url: URL) async throws -> JSONValue {
        switch url.path {
        case "/v2/workspaces": return ["workspaces": try JSONValue(encoding: [workspace])]
        case "/v2/conversations":
            var current = manifest; current.lastSequence = journal.last?.sequence ?? 0
            return ["conversations": try JSONValue(encoding: [current])]
        case "/v2/providers": return ["providers": try JSONValue(encoding: providers)]
        case "/v2/conversations/c":
            manifestCalls += 1
            var current = manifest; current.lastSequence = journal.last?.sequence ?? 0
            return try JSONValue(encoding: current)
        case "/v2/conversations/c/events":
            eventCalls += 1
            let after = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "afterSequence" })?.value ?? "0") ?? 0
            let remaining = journal.filter { $0.sequence > after }, page = Array(remaining.prefix(pageSize))
            let response: JSONValue = ["events": try JSONValue(encoding: page), "nextSequence": .number(Double(page.last?.sequence ?? after)), "hasMore": .bool(remaining.count > page.count)]
            if eventCalls == 1 { await firstPageGate?.wait() }
            return response
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
    var prompts: [(String, JSONValue)] = []
    var connectGate: Gate?
    var promptGate: Gate?
    var promptError: TodexError?
    var subscriptions: [Subscription] = []
    var ledgerStore: LocalStore?
    var ledgerKey: String?
    var ledgerChecks: [Bool] = []
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
    func command(type: String, payload: JSONValue, timeout: TimeInterval, id: String) async throws -> JSONValue {
        if type == "conversation.subscribe" {
            subscribeCursors.append(payload["afterSequence"].intValue)
            if !subscriptions.isEmpty {
                let page = subscriptions.removeFirst(); await page.gate?.wait(); await backend.append(page.events)
                return ["conversationId": "c", "subscribed": true, "nextSequence": .number(Double(page.events.last?.sequence ?? payload["afterSequence"].intValue)), "hasMore": .bool(page.more)]
            }
            return ["conversationId": "c", "subscribed": true, "nextSequence": .number(Double(await backend.journal.last?.sequence ?? 0)), "hasMore": false]
        }
        if type == "conversation.prompt" {
            prompts.append((id, payload))
            if let ledgerStore, let ledgerKey {
                let snapshot = try ledgerStore.read(ledgerKey, as: SessionSnapshot.self)
                ledgerChecks.append(snapshot?.pendingSends["c"]?.requestId == id && snapshot?.queues["c"]?.contains(where: { $0.draft.text == payload["text"].stringValue }) != true)
            }
            await promptGate?.wait()
            if let promptError { throw promptError }
            return ["accepted": true]
        }
        return [:]
    }
}
@MainActor struct Harness {
    let backend: Backend
    let socket: FakeSocket
    let store: LocalStore
    let connection: BackendConnection
    let session: AppSession
    let manifest = ConversationManifest(id: "c", provider: "codex", workspace: "/workspace", workspaceId: "w")
    init(_ journal: [ConversationEvent] = [], snapshot: SessionSnapshot? = nil) throws {
        backend = Backend(journal); socket = FakeSocket(backend: backend)
        let host = UUID().uuidString.lowercased() + ".invalid"
        connection = BackendConnection(id: "test-" + UUID().uuidString, name: "Fixture", serverURL: "https://" + host, token: "")
        store = try TestEnvironment.store()
        if let snapshot { try store.save(snapshot, key: LocalStore.namespace(connection) + "-state") }
        FixtureProtocol.register(backend, host: host)
        let socket = self.socket
        let defaults = TestEnvironment.defaults()
        session = AppSession(store: store, connections: [connection], defaults: defaults, apiFactory: { value in
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
            return APIClient(connection: value, session: URLSession(configuration: config))
        }, socketFactory: { _ in socket }, credentialWriter: { _, _ in })
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
@MainActor func queuedDraftAndAtomicLedger() async throws {
    let h = try Harness(), gate = Gate(); try await h.ready()
    await h.socket.configure(prompt: gate, error: .server(code: "CONFLICT", message: "rejected"))
    await h.socket.inspectLedger(store: h.store, key: h.stateKey)
    let old = ComposerDraft(text: "queued original"), newer = ComposerDraft(text: "new composer")
    h.session.queues["c"] = [QueuedDraft(draft: old)]; h.session.drafts["c"] = newer
    h.session.resumeQueue(h.manifest)
    try await eventually("queued prompt") { await h.socket.prompts.count == 1 }
    try check(h.session.drafts["c"] == newer, "queue cleared current composer")
    try check(await h.socket.ledgerChecks == [true], "pending+queue removal not atomic before wire")
    await gate.release()
    try await eventually("known rejection restored queue") { h.session.pendingSends["c"] == nil && h.session.queues["c"]?.count == 1 }
    try check(h.session.drafts["c"] == newer && h.session.queues["c"]?.first?.draft == old, "failed queue overwrote new composer")
    h.session.disconnect()
}
@MainActor func manualFailureAndUnknown() async throws {
    for ambiguous in [false, true] {
        let h = try Harness(), gate = Gate(); try await h.ready()
        await h.socket.configure(prompt: gate, error: ambiguous ? .unknownOutcome("ACK lost") : .server(code: "CONFLICT", message: "no"))
        let old = ComposerDraft(text: "original"), newer = ComposerDraft(text: "typed during ACK")
        h.session.drafts["c"] = old
        let send = Task { try await h.session.send(old, in: h.manifest) }
        try await eventually("manual prompt") { await h.socket.prompts.count == 1 }
        h.session.drafts["c"] = newer; await gate.release(); _ = await send.result
        try check(h.session.drafts["c"] == newer, "manual rejection overwrote new draft")
        if ambiguous {
            try check(h.session.pendingSends["c"]?.draft == old, "ambiguous outcome lost pending")
            h.session.restoreUnknownAsDraft("c")
            try check(h.session.drafts["c"] == newer && h.session.pendingSends["c"] != nil, "unknown restore overwrote draft")
            try await h.session.recover("c"); h.session.resumeQueue(h.manifest)
            try check(await h.socket.prompts.count == 1, "ambiguous mutation auto-retried")
        } else { try check(h.session.queues["c"]?.first?.draft == old && h.session.pendingSends["c"] == nil, "known rejection lost original") }
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
    try check(h.session.drafts["c"]?.text == "B current" && h.session.pendingSends["c"] == nil && h.session.queues["c"] == nil, "late rejection mutated B")
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
@MainActor func restartBackgroundAndFastCompletion() async throws {
    let queued = QueuedDraft(draft: ComposerDraft(text: "restored queued"))
    var snapshot = SessionSnapshot(); snapshot.queues = ["c": [queued]]
    let h = try Harness(snapshot: snapshot); try await h.ready()
    try check(h.session.pausedQueues.contains("c"), "restart unpaused queue")
    try check(await h.socket.prompts.isEmpty, "restart dispatched")
    h.session.activeConversationID = "c"
    h.session.setForeground(false); h.session.resumeQueue(h.manifest)
    try check(await h.socket.prompts.isEmpty, "background dispatched")
    h.session.setForeground(true)
    try await eventually("foreground recovery") { h.session.runtimes["c"]?.readyForActions == true }
    let gate = Gate(); await h.socket.configure(prompt: gate)
    h.session.queues["c"] = [queued, QueuedDraft(draft: ComposerDraft(text: "second queued"))]
    h.session.resumeQueue(h.manifest)
    try await eventually("first queue send") { await h.socket.prompts.count == 1 }
    let sent = await h.socket.prompts
    let request = sent[0].0
    try await h.socket.emit(event(1, "turn.started", ["turnId": "t", "clientRequestId": .string(request)]))
    try await h.socket.emit(event(2, "turn.completed", ["turnId": "t"]))
    try await eventually("terminal before ACK") { h.session.runtimes["c"]?.status == "completed" }
    await gate.release()
    try await eventually("second queue after early terminal") { await h.socket.prompts.count == 2 }
    try check(h.session.queues["c"]?.isEmpty == true, "queue stalled")
    h.session.disconnect()
}
@MainActor func scopedReadsAndCachePrefix() async throws {
    let h = try Harness((1...10_005).map { event($0) }); try await h.ready()
    h.session.readSequences["c"] = 10_005; h.session.persist()
    try await eventually("cache persisted") { try h.store.read(h.eventKey, as: [ConversationEvent].self)?.count == 10_000 }
    let cached = try h.store.read(h.eventKey, as: [ConversationEvent].self)!
    try check(cached.enumerated().allSatisfy { $0.element.sequence == $0.offset + 1 }, "cache is a tail or contains gaps")
    try check(try Data(contentsOf: h.store.url(h.eventKey)).count < 8 * 1_024 * 1_024, "cache byte bound")
    await h.backend.changeTenant(); try await h.session.refresh()
    try check(h.session.readSequences["c"] == nil && h.session.runtimes["c"] == nil, "tenant switch reused read/runtime")
    var other = h.connection; other.serverURL = "https://different.invalid"
    try check(LocalStore.namespace(h.connection) != LocalStore.namespace(other), "URL missing from namespace")
    other = h.connection; other.token = "changed"
    try check(LocalStore.namespace(h.connection) != LocalStore.namespace(other), "credential missing from namespace")
    try check(LocalStore.identity(["ab", "c"]) != LocalStore.identity(["a", "bc"]), "namespace collision")
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
    try check(session.connection?.token == "fixture-token", "fixture token changed")
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
@main struct SessionRaceRunner {
    @MainActor static func main() async {
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("connect + foreground single flight", connectionSingleFlight),
            ("recover single flight + HTTP/live interleaving", recoveryInterleaving),
            ("subscribe pagination + ACK before frames", subscriptionPagination),
            ("queue new-draft preservation + atomic ledger", queuedDraftAndAtomicLedger),
            ("manual rejection + ambiguous mutation", manualFailureAndUnknown),
            ("settings backend switch + stale response", staleBackendResponse),
            ("disk failure + no recursive notification", diskFailurePreservesDraft),
            ("restart/background pause + early completion", restartBackgroundAndFastCompletion),
            ("tenant scope + bounded cache prefix", scopedReadsAndCachePrefix),
            ("corrupt optional cache recovery", corruptCacheIsOptional),
            ("wire subscriber overflow gap", streamOverflowSignalsGap),
            ("backend switch during HTTP replay", staleReplayResponse),
            ("DEBUG port environment fixture", debugPortFixture),
            ("fixture launch never overwrites catalog", fixtureNeverOverwritesCatalog),
            ("task plan persistence + legacy snapshot decode", taskPlanPersistence),
            ("composer memory persistence + capability fallback", composerMemory)
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
