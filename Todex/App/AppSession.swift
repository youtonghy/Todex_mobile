import Foundation
import TodexCore

/// The sole transport seam needed for deterministic recovery/send race tests.
nonisolated protocol SessionSocket: Sendable {
    var events: AsyncStream<JSONValue> { get }
    func connect() async throws
    func disconnect() async
    func command(type: String, payload: JSONValue, timeout: TimeInterval, id: String) async throws -> JSONValue
}
extension RealtimeClient: SessionSocket {}

@MainActor final class AppSession {
    private(set) var connections: [BackendConnection] = []
    private(set) var selectedID: String?
    // The environment-injected test fixture is merged into the catalog but must
    // never reach connections.json, or a Settings save under a fixture launch
    // would overwrite the real backend list.
    private var fixtureConnectionID: String?
    private var connectionStatus = "尚未连接"
    var status: String { storageError.map { "本地保存失败：\($0)" } ?? connectionStatus }
    private(set) var isConnected = false
    private(set) var isConnecting = false
    private var operationError: String?
    var lastError: String? { storageError ?? operationError }
    var storageError: String? { storageFailures[stateNamespace]?.message }
    private(set) var workspaces: [WorkspaceRecord] = []
    private(set) var conversations: [ConversationManifest] = []
    private(set) var providers: [ProviderDescriptor] = []
    private(set) var runtimes: [String: ConversationRuntime] = [:]
    private(set) var models: [String: [JSONValue]] = [:]
    private(set) var commands: [String: [JSONValue]] = [:]
    private(set) var pendingSends: [String: PendingSend] = [:]
    var activeConversationID: String?
    var drafts: [String: ComposerDraft] = [:]
    var preferences: [String: ConversationPreferences] = [:]
    var queues: [String: [QueuedDraft]] = [:]
    var pausedQueues: Set<String> = []
    var pinnedWorkspaces: [String] = []
    var pinnedConversations: [String] = []
    var readSequences: [String: Int] = [:]
    private(set) var api: APIClient?
    private var socket: (any SessionSocket)?
    private let store: LocalStore
    private let persistence: SessionPersistence
    private let defaults: UserDefaults
    private let makeAPI: (BackendConnection) -> APIClient
    private let makeSocket: (BackendConnection) -> any SessionSocket
    private let saveCredential: (String, String) throws -> Void
    private var frameTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var connectingConfiguration: BackendConnection?
    private var reconnectTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var stateLoadTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private struct Recovery {
        let token: UUID
        let task: Task<Void, any Error>
    }
    private var recoveryTasks: [String: Recovery] = [:]
    private struct SendOperation {
        let requestID: String
        let afterSequence: Int
    }
    private var sending: [String: SendOperation] = [:]
    private var queueDispatches: [String: UUID] = [:]
    private var completedDuringSend: [String: String] = [:]
    private var observers: [UUID: () -> Void] = [:]
    private var wireSubscribers: [UUID: AsyncStream<JSONValue>.Continuation] = [:]
    private var legacyCursors: [String: Int] = [:]
    private var revision = UUID()
    private var refreshRevision = UUID()
    private var modelRevisions: [String: UUID] = [:]
    private var commandRevisions: [String: UUID] = [:]
    private var reconnectAttempt = 0
    private var foreground = true
    private var wantsConnection = false
    // This identity is frozen until old state has been captured for persistence.
    private var stateNamespace = "unconnected-v2"
    private var stateGeneration = UUID()
    private var stateLoaded = false
    private var saveAfterLoad = false
    private var saveVersion: UInt64 = 0
    private struct Checkpoint {
        let version: UInt64
        let snapshot: SessionSnapshot
    }
    private var unsavedSnapshots: [String: Checkpoint] = [:]
    private var storageFailures: [String: (version: UInt64, message: String)] = [:]
    private struct CachedJournal {
        var events: [ConversationEvent] = []
        var pending: [Int: ConversationEvent] = [:]
        var bytes = 0
        var saturated = false
    }
    private var rawEvents: [String: CachedJournal] = [:]
    private var cachedBytes = 0
    private var cacheLoaded: Set<String> = []
    private var dirtyCaches: Set<String> = []
    private struct CacheWrite {
        let namespace: String
        let version: UInt64
        let events: [ConversationEvent]
    }
    private var cacheWrites: [String: CacheWrite] = [:]
    private static let cacheByteLimit = 32 * 1_024 * 1_024
    private static let journalByteLimit = 8 * 1_024 * 1_024
    var connection: BackendConnection? { connections.first { $0.id == selectedID } }
    var activeConversation: ConversationManifest? { conversations.first { $0.id == activeConversationID } }

    init(
        store: LocalStore = LocalStore(), connections initial: [BackendConnection]? = nil,
        defaults: UserDefaults = .standard,
        apiFactory: @escaping (BackendConnection) -> APIClient = { APIClient(connection: $0) },
        socketFactory: @escaping (BackendConnection) -> any SessionSocket = { RealtimeClient(connection: $0) },
        credentialWriter: @escaping (String, String) throws -> Void = { try CredentialStore.save($0, for: $1) }
    ) {
        self.store = store
        persistence = SessionPersistence(store: store)
        self.defaults = defaults
        makeAPI = apiFactory
        makeSocket = socketFactory
        saveCredential = credentialWriter
        var startupError: Error?
        if let initial {
            connections = initial
        } else {
            do { connections = try store.read("connections", as: [BackendConnection].self) ?? [] } catch {
                startupError = error
            }
            for index in connections.indices {
                connections[index].token = CredentialStore.token(for: connections[index].id)
            }
        }
        selectedID = defaults.string(forKey: "selectedBackend")
        if !connections.contains(where: { $0.id == selectedID }) { selectedID = connections.first?.id }
        #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            let fixtureURL =
                environment["TODEX_TEST_PORT"].flatMap { port in
                    UInt16(port).map { "http://127.0.0.1:\($0)" }
                } ?? environment["TODEX_TEST_URL"]
            if initial == nil, let url = fixtureURL {
                let fixture = BackendConnection(
                    id: "simulator-fixture", name: "测试后端", serverURL: url,
                    token: environment["TODEX_TEST_TOKEN"] ?? "")
                connections.removeAll { $0.id == fixture.id }
                connections.append(fixture)
                selectedID = fixture.id
                fixtureConnectionID = fixture.id
            }
        #endif
        stateNamespace = LocalStore.namespace(connections.first { $0.id == selectedID })
        if let startupError { reportStorageError(startupError, namespace: stateNamespace, version: 0) }
        loadState()
    }

    func observe(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        return id
    }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    func changed(immediate: Bool = false) {
        if immediate {
            changeTask?.cancel()
            changeTask = nil
            for callback in Array(observers.values) { callback() }
            return
        }
        guard changeTask == nil else { return }
        changeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard let self else { return }
            changeTask = nil
            for callback in Array(observers.values) { callback() }
        }
    }
    func wireEvents() -> AsyncStream<JSONValue> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<JSONValue>.makeStream(bufferingPolicy: .bufferingNewest(2048))
        wireSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.wireSubscribers.removeValue(forKey: id) }
        }
        return stream
    }

    func saveConnections(_ values: [BackendConnection], selected: String?) throws {
        guard Set(values.map(\.id)).count == values.count else { throw TodexError.invalid("后端标识重复") }
        // Settings persists an unfinished row while the user enters its address.
        for value in values where !value.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try value.normalizedURL()
        }
        let nextID = values.contains(where: { $0.id == selected }) ? selected : values.first?.id
        let next = values.first { $0.id == nextID }
        let changedTransport = !Self.sameTransport(connection, next)
        let removed = connections.filter { old in !values.contains { $0.id == old.id } }
        do {
            // The catalog is saved before credentials so a Keychain failure cannot
            // discard the whole connection list. The environment fixture is a
            // launch-time convenience and never enters the on-disk catalog.
            try store.save(values.filter { $0.id != fixtureConnectionID }, key: "connections")
            for value in values { try saveCredential(value.token, value.id) }
            for old in removed { try saveCredential("", old.id) }
        } catch {
            reportStorageError(error, namespace: stateNamespace, version: saveVersion)
            throw error
        }
        persist()  // Capture the old namespace before changing editable Settings values.
        if changedTransport {
            wantsConnection = false
            invalidateTransport()
            connectionStatus = "尚未连接"
        }
        connections = values
        selectedID = nextID
        defaults.set(selectedID, forKey: "selectedBackend")
        if stateNamespace != LocalStore.namespace(next) { switchState(to: LocalStore.namespace(next)) }
        changed(immediate: true)
    }

    func connect(_ requested: BackendConnection? = nil) async {
        guard let next = requested ?? connection else { return }
        if let task = connectTask, Self.sameTransport(connectingConfiguration, next) {
            await task.value
            return
        }
        do { _ = try next.normalizedURL() } catch {
            operationError = error.localizedDescription
            connectionStatus = "连接配置未完成"
            changed(immediate: true)
            return
        }
        persist()
        invalidateTransport()
        if let index = connections.firstIndex(where: { $0.id == next.id }) {
            connections[index] = next
        } else {
            connections.append(next)
            // A connection introduced through connect() must reach the catalog even
            // when no Settings save preceded it, or it would vanish on relaunch.
            do {
                try store.save(connections.filter { $0.id != fixtureConnectionID }, key: "connections")
                try saveCredential(next.token, next.id)
            } catch {
                reportStorageError(error, namespace: stateNamespace, version: saveVersion)
            }
        }
        selectedID = next.id
        defaults.set(next.id, forKey: "selectedBackend")
        if stateNamespace != LocalStore.namespace(next) { switchState(to: LocalStore.namespace(next)) }
        let current = revision
        wantsConnection = true
        isConnecting = true
        connectionStatus = "正在连接…"
        operationError = nil
        connectingConfiguration = next
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await performConnect(next, revision: current)
        }
        // Store the flight before the first suspension, including SceneDelegate's
        // simultaneous foreground and initial-connect requests.
        connectTask = task
        changed(immediate: true)
        await task.value
    }

    private func performConnect(_ next: BackendConnection, revision current: UUID) async {
        defer {
            if current == revision {
                connectTask = nil
                connectingConfiguration = nil
            }
        }
        await stateLoadTask?.value
        guard current == revision, !Task.isCancelled else { return }
        let api = makeAPI(next)
        let socket = makeSocket(next)
        self.api = api
        self.socket = socket
        frameTask = Task { [weak self] in
            for await frame in socket.events {
                guard let self, self.revision == current, !Task.isCancelled else { return }
                receive(frame)
            }
        }
        do {
            try await socket.connect()
            try checkRevision(current)
            isConnecting = false
            isConnected = true
            connectionStatus = "已连接"
            try await refresh()
            try checkRevision(current)
            if !legacyCursors.isEmpty {
                _ = try await socket.command(
                    type: "session.resume",
                    payload: ["sessionCursors": .object(legacyCursors.mapValues { .number(Double($0)) })], timeout: 30,
                    id: UUID().uuidString)
                try checkRevision(current)
            }
            if let id = activeConversationID, conversations.contains(where: { $0.id == id }) { try await recover(id) }
            try checkRevision(current)
            reconnectAttempt = 0
            changed(immediate: true)
        } catch {
            guard current == revision else { return }
            invalidateTransport()
            operationError = error.localizedDescription
            connectionStatus = "连接失败"
            if case TodexError.server(let code, _) = error,
                ["401", "403", "UNAUTHENTICATED", "UNAUTHORIZED"].contains(code)
            {
                wantsConnection = false
            }
            persist()
            scheduleReconnect()
            changed(immediate: true)
        }
    }

    /// Invalidate synchronously, before awaiting the old actor's disconnect.
    private func invalidateTransport() {
        revision = UUID()
        refreshRevision = UUID()
        connectTask?.cancel()
        connectTask = nil
        connectingConfiguration = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        frameTask?.cancel()
        frameTask = nil
        for flight in recoveryTasks.values { flight.task.cancel() }
        recoveryTasks.removeAll()
        queueDispatches.removeAll()
        sending.removeAll()
        completedDuringSend.removeAll()
        for id in Array(runtimes.keys) { runtimes[id]?.beginReplay() }
        pausedQueues.formUnion(queues.keys)
        isConnected = false
        isConnecting = false
        api = nil
        let old = socket
        socket = nil
        Task { await old?.disconnect() }
    }
    func disconnect() {
        wantsConnection = false
        invalidateTransport()
        connectionStatus = "已断开"
        persist()
        changed(immediate: true)
    }
    func setForeground(_ value: Bool) {
        foreground = value
        if !value {
            for id in Array(runtimes.keys) { runtimes[id]?.beginReplay() }
            pausedQueues.formUnion(queues.keys)
            persist()
            reconnectTask?.cancel()
            reconnectTask = nil
        } else if wantsConnection || connectTask != nil {
            let current = revision
            Task { [weak self] in
                guard let self, current == revision else { return }
                if connectTask != nil || !isConnected {
                    await connect()
                    return
                }
                do {
                    try await refresh()
                    try checkRevision(current)
                    if let id = activeConversationID { try await recover(id) }
                } catch {
                    if current == revision, !(error is CancellationError) {
                        operationError = error.localizedDescription
                        changed()
                    }
                }
            }
        }
    }
    private func scheduleReconnect() {
        guard wantsConnection, foreground, reconnectTask == nil, reconnectAttempt < 5 else { return }
        reconnectAttempt += 1
        let current = revision
        let delay = min(30, pow(2, Double(reconnectAttempt)))
        connectionStatus = "连接中断，\(Int(delay)) 秒后重试"
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, current == revision else { return }
            reconnectTask = nil
            await connect()
        }
    }
    private func checkRevision(_ current: UUID) throws {
        guard current == revision, !Task.isCancelled else { throw CancellationError() }
    }
    private static func sameTransport(_ lhs: BackendConnection?, _ rhs: BackendConnection?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        let lhsURL =
            (try? lhs.normalizedURL().absoluteString) ?? lhs.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsURL =
            (try? rhs.normalizedURL().absoluteString) ?? rhs.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return lhs.id == rhs.id && lhsURL == rhsURL
            && lhs.token == rhs.token && lhs.encryption == rhs.encryption && lhs.publicKey == rhs.publicKey
    }

    func refresh() async throws {
        guard let api, isConnected else { throw TodexError.disconnected }
        let current = revision
        let request = UUID()
        refreshRevision = request
        async let workspaceResult = api.workspaces()
        async let conversationResult = api.conversations()
        async let providerResult = api.providers()
        let (workspaces, conversations, providers) = try await (workspaceResult, conversationResult, providerResult)
        try checkRevision(current)
        guard refreshRevision == request else { return }
        let oldScopes = Dictionary(
            self.conversations.map { ($0.id, conversationScope($0)) }, uniquingKeysWith: { _, latest in latest })
        self.workspaces = workspaces
        self.conversations = conversations
        self.providers = providers
        for conversation in conversations
        where oldScopes[conversation.id] != nil && oldScopes[conversation.id] != conversationScope(conversation) {
            readSequences.removeValue(forKey: conversation.id)
            runtimes.removeValue(forKey: conversation.id)
            removeCache(conversation.id)
            cacheLoaded.remove(conversation.id)
        }
        persist()
        changed(immediate: true)
    }
    func select(_ conversation: ConversationManifest) {
        guard conversations.contains(where: { $0.id == conversation.id && $0.workspace == conversation.workspace })
        else { return }
        activeConversationID = conversation.id
        if runtimes[conversation.id] == nil {
            runtimes[conversation.id] = ConversationRuntime(conversationId: conversation.id)
        }
        changed(immediate: true)
        saveSoon()
        let current = revision
        Task { [weak self] in
            guard let self, current == revision else { return }
            do {
                if isConnected {
                    try await recover(conversation.id)
                    try checkRevision(current)
                    try await loadModels(for: conversation)
                }
            } catch {
                if current == revision, !(error is CancellationError) {
                    operationError = error.localizedDescription
                    changed()
                }
            }
        }
    }
    func workspace(for conversation: ConversationManifest) -> WorkspaceRecord? {
        workspaces.first { $0.id == conversation.workspaceId || $0.path == conversation.workspace }
    }
    func provider(for conversation: ConversationManifest) -> ProviderDescriptor? {
        providers.first { $0.id == conversation.provider }
    }
    func preferences(for conversation: ConversationManifest) -> ConversationPreferences {
        if let value = preferences[conversation.id] { return value }
        var value = ConversationPreferences()
        value.model = workspace(for: conversation)?.model ?? ""
        let config = provider(for: conversation)?.capabilities["permissionConfig"] ?? .null
        value.permissionMode = config["defaultMode"].optionalString ?? "ask"
        value.reasoningEffort = workspace(for: conversation)?.reasoningEffort ?? ""
        return value
    }
    func updatePreferences(_ value: ConversationPreferences, for conversation: ConversationManifest) {
        preferences[conversation.id] = value
        saveSoon()
        changed()
    }
    func loadModels(for conversation: ConversationManifest) async throws {
        guard let api, isConnected else { throw TodexError.disconnected }
        let current = revision
        let request = UUID()
        let key = conversation.provider + ":" + conversation.workspace
        modelRevisions[key] = request
        let result = try await api.http.request(
            path: "/v2/providers/models",
            query: ["provider": conversation.provider, "workspace": conversation.workspace])
        try checkRevision(current)
        guard modelRevisions[key] == request else { throw CancellationError() }
        models[key] = result["models"].arrayValue
        changed()
    }

    func loadCommands(for conversation: ConversationManifest) async throws {
        guard let api, isConnected else { throw TodexError.disconnected }
        let current = revision
        let request = UUID()
        let key = conversation.provider + ":" + conversation.workspace
        commandRevisions[key] = request
        let result = try await api.providerCommands(
            provider: conversation.provider, workspace: conversation.workspace)
        try checkRevision(current)
        guard commandRevisions[key] == request else { throw CancellationError() }
        commands[key] = result["commands"].arrayValue
        changed()
    }

    func recover(_ id: String) async throws {
        guard let api, let socket, isConnected else { throw TodexError.disconnected }
        if let flight = recoveryTasks[id] {
            try await flight.task.value
            return
        }
        let current = revision
        let token = UUID()
        if runtimes[id] == nil { runtimes[id] = ConversationRuntime(conversationId: id) }
        runtimes[id]?.beginReplay()
        changed(immediate: true)
        let task = Task<Void, any Error> { [weak self] in
            guard let self else { throw CancellationError() }
            defer {
                if current == revision, recoveryTasks[id]?.token == token { recoveryTasks.removeValue(forKey: id) }
            }
            do { try await replay(id, api: api, socket: socket, revision: current) } catch {
                if current == revision {
                    runtimes[id]?.beginReplay()
                    if !(error is CancellationError) { operationError = error.localizedDescription }
                    changed(immediate: true)
                }
                throw error
            }
        }
        recoveryTasks[id] = Recovery(token: token, task: task)
        try await task.value
    }
    private func replay(_ id: String, api: APIClient, socket: any SessionSocket, revision current: UUID) async throws {
        let manifest = try await api.conversation(id: id)
        try checkRevision(current)
        guard manifest.id == id else { throw TodexError.invalid("对话恢复响应不匹配") }
        if !cacheLoaded.contains(id) {
            let cached: [ConversationEvent]
            do { cached = try await persistence.events(eventKey(manifest)) } catch {
                try checkRevision(current)
                reportStorageError(error, namespace: stateNamespace, version: saveVersion)
                cached = []
            }
            try checkRevision(current)
            cacheLoaded.insert(id)
            // Cache files contain a prefix only. Never seed a cursor from a tail.
            for (offset, event) in cached.prefix(10_000).enumerated() {
                guard event.sequence == offset + 1, event.conversationId == id else { break }
                ingest(event)
            }
        }
        var highWater = manifest.lastSequence
        try await replayPages(id, target: highWater, api: api, revision: current)
        for _ in 0..<10_000 {
            try checkRevision(current)
            let before = runtimes[id]?.appliedSequence ?? 0
            let result = try await socket.command(
                type: "conversation.subscribe",
                payload: ["conversationId": .string(id), "afterSequence": .number(Double(before)), "limit": 200],
                timeout: 45, id: UUID().uuidString)
            try checkRevision(current)
            guard result["conversationId"].isNull || result["conversationId"] == .string(id) else {
                throw TodexError.invalid("订阅响应不匹配")
            }
            guard result["subscribed"].boolValue else { throw TodexError.invalid("后端未确认订阅") }
            highWater = max(
                highWater, Self.sequence(result["nextSequence"]) ?? 0, Self.sequence(result["lastSequence"]) ?? 0)
            for raw in result["events"].arrayValue { try ingestReplay(raw, conversationId: id) }
            // The socket ACK can resume this task before the frame-consumer Task
            // has applied its earlier replay frames. Fill through the ACK cursor.
            try await replayPages(id, target: highWater, api: api, revision: current)
            try checkRevision(current)
            if !result["hasMore"].boolValue {
                runtimes[id]?.markReplayComplete(highWater: highWater)
                guard runtimes[id]?.readyForActions == true else { throw TodexError.invalid("历史记录存在缺口，请重新核对") }
                var updated = manifest
                updated.lastSequence = max(manifest.lastSequence, runtimes[id]?.appliedSequence ?? 0)
                updated.status = runtimes[id]?.status ?? manifest.status
                if let index = conversations.firstIndex(where: { $0.id == id }) {
                    conversations[index] = updated
                } else {
                    conversations.append(updated)
                }
                if activeConversationID == id { readSequences[id] = runtimes[id]?.appliedSequence ?? 0 }
                saveSoon()
                changed(immediate: true)
                return
            }
            guard (runtimes[id]?.appliedSequence ?? 0) > before else { throw TodexError.invalid("订阅分页没有前进，恢复未完成") }
        }
        throw TodexError.invalid("订阅分页过多，恢复未完成")
    }
    private func replayPages(_ id: String, target: Int, api: APIClient, revision current: UUID) async throws {
        var highWater = target
        for _ in 0..<10_000 {
            try checkRevision(current)
            let before = runtimes[id]?.appliedSequence ?? 0
            let page = try await api.events(conversationId: id, after: before, limit: 200)
            try checkRevision(current)
            guard case .array(let events) = page["events"] else { throw TodexError.invalid("历史分页响应无效") }
            for raw in events { try ingestReplay(raw, conversationId: id) }
            let runtime = runtimes[id] ?? ConversationRuntime(conversationId: id)
            highWater = max(
                highWater, runtime.highWaterSequence, Self.sequence(page["nextSequence"]) ?? 0,
                Self.sequence(page["lastSequence"]) ?? 0)
            if !page["hasMore"].boolValue, runtime.appliedSequence >= highWater { return }
            guard runtime.appliedSequence > before else { throw TodexError.invalid("历史记录存在缺口，请重新核对") }
        }
        throw TodexError.invalid("历史分页过多，恢复未完成")
    }
    private func ingestReplay(_ raw: JSONValue, conversationId: String) throws {
        let event = try raw.decoded(ConversationEvent.self)
        guard event.conversationId == conversationId else { throw TodexError.invalid("历史事件属于其他对话") }
        ingest(event)
    }
    private static func sequence(_ value: JSONValue) -> Int? {
        guard let number = value.doubleValue, number.isFinite, number >= 0, number < Double(Int.max),
            number.rounded(.down) == number
        else { return nil }
        return Int(number)
    }

    func command(_ type: String, _ payload: JSONValue, timeout: TimeInterval = 30) async throws -> JSONValue {
        guard let socket, isConnected else { throw TodexError.disconnected }
        let current = revision
        let result = try await socket.command(type: type, payload: payload, timeout: timeout, id: UUID().uuidString)
        try checkRevision(current)
        return result
    }
    func send(_ draft: ComposerDraft, in conversation: ConversationManifest, enqueueWhenBusy: Bool = true) async throws
    {
        try await send(draft, in: conversation, enqueueWhenBusy: enqueueWhenBusy, queued: nil)
    }
    private func send(
        _ draft: ComposerDraft, in conversation: ConversationManifest, enqueueWhenBusy: Bool, queued: QueuedDraft?
    ) async throws {
        let id = conversation.id
        let current = revision
        guard !draft.isEmpty else { return }
        guard stateLoaded else { throw TodexError.invalid(storageError ?? "本地草稿仍在加载") }
        guard let socket, isConnected else { throw TodexError.disconnected }
        guard conversations.contains(where: { $0.id == id && $0.workspace == conversation.workspace }) else {
            throw TodexError.invalid("对话已切换，请重新打开")
        }
        guard pendingSends[id] == nil, sending[id] == nil else { throw TodexError.unknownOutcome("已有消息等待核对") }
        guard let runtime = runtimes[id], runtime.readyForActions else { throw TodexError.invalid("请等待历史记录同步完成") }
        if ["running", "waitingPermission", "waiting_permission"].contains(runtime.status) {
            guard enqueueWhenBusy else { throw TodexError.server(code: "CONFLICT", message: "当前任务尚未结束") }
            guard (queues[id]?.count ?? 0) < 32 else { throw TodexError.invalid("候选消息最多 32 条") }
            queues[id, default: []].append(QueuedDraft(draft: draft))
            pausedQueues.remove(id)
            if drafts[id] == draft { drafts[id] = ComposerDraft() }
            changed(immediate: true)
            try await persistDurably()
            try checkRevision(current)
            return
        }
        if let queued {
            guard foreground, !pausedQueues.contains(id), queues[id]?.first?.id == queued.id else {
                throw CancellationError()
            }
        }
        let pref = preferences(for: conversation)
        var payload: JSONValue = [
            "conversationId": .string(id), "text": .string(draft.text),
            "content": .array(draft.attachments.map(\.wireValue)),
            "skills": .array(draft.skills.map { ["resourceId": .string($0.id), "name": .string($0.name)] }),
            "permissionMode": .string(pref.permissionMode), "workMode": .string(pref.workMode),
        ]
        if !pref.model.isEmpty { payload["model"] = .string(pref.model) }
        if !pref.reasoningEffort.isEmpty { payload["reasoningEffort"] = .string(pref.reasoningEffort) }
        let requestID = UUID().uuidString
        pendingSends[id] = PendingSend(requestId: requestID, draft: draft, afterSequence: runtime.appliedSequence)
        sending[id] = SendOperation(requestID: requestID, afterSequence: runtime.appliedSequence)
        if let queued { queues[id]?.removeAll { $0.id == queued.id } }
        changed(immediate: true)
        var submitted = false
        defer {
            if current == revision, sending[id]?.requestID == requestID {
                sending.removeValue(forKey: id)
                if completedDuringSend.removeValue(forKey: id) == requestID {
                    Task { [weak self] in
                        guard let self, current == revision else { return }
                        dispatchQueue(id)
                    }
                }
                changed()
            }
        }
        do {
            // Durable pending + queue removal BEFORE the only network mutation.
            try await persistDurably()
            try checkRevision(current)
            guard pendingSends[id]?.requestId == requestID else { throw CancellationError() }
            if queued != nil { guard foreground, !pausedQueues.contains(id) else { throw CancellationError() } }
            guard runtimes[id]?.readyForActions == true, isConnected else { throw TodexError.disconnected }
            if queued == nil, drafts[id] == draft { drafts[id] = ComposerDraft() }
            persist()
            submitted = true
            _ = try await socket.command(type: "conversation.prompt", payload: payload, timeout: 45, id: requestID)
            try checkRevision(current)
            if pendingSends[id]?.requestId == requestID { pendingSends.removeValue(forKey: id) }
            persist()
        } catch {
            guard current == revision else { throw CancellationError() }
            if pendingSends[id]?.requestId == requestID {
                if !submitted || Self.knownRejection(error) {
                    pendingSends.removeValue(forKey: id)
                    if let queued {
                        if queues[id]?.contains(where: { $0.id == queued.id }) != true {
                            queues[id, default: []].insert(queued, at: 0)
                        }
                    } else if drafts[id]?.isEmpty != false {
                        drafts[id] = draft
                    } else if drafts[id] != draft {
                        // Do not overwrite text entered while the ACK was pending.
                        queues[id, default: []].insert(QueuedDraft(draft: draft), at: 0)
                    }
                }
                pausedQueues.insert(id)
            }
            persist()
            throw error
        }
    }
    private static func knownRejection(_ error: Error) -> Bool {
        switch error {
        case TodexError.server, TodexError.invalid, TodexError.disconnected: true
        default: false
        }
    }
    func reconcile(_ id: String) async throws {
        let current = revision
        try await recover(id)
        try checkRevision(current)
        if pendingSends[id] != nil { throw TodexError.unknownOutcome("完整记录中仍未找到这次请求，原消息保留在待核对区") }
    }
    func restoreUnknownAsDraft(_ id: String) {
        guard sending[id] == nil, let pending = pendingSends[id] else { return }
        guard drafts[id]?.isEmpty != false else {
            operationError = "输入框已有草稿，请先保留它再恢复待核对消息"
            changed(immediate: true)
            return
        }
        pendingSends.removeValue(forKey: id)
        drafts[id] = pending.draft
        pausedQueues.insert(id)
        persist()
        changed(immediate: true)
    }
    func resumeQueue(_ conversation: ConversationManifest) {
        pausedQueues.remove(conversation.id)
        dispatchQueue(conversation.id)
        persist()
        changed()
    }
    func removeQueued(_ item: String, conversationId: String) {
        queues[conversationId]?.removeAll { $0.id == item }
        persist()
        changed()
    }
    private func dispatchQueue(_ id: String) {
        guard foreground, isConnected, !pausedQueues.contains(id), sending[id] == nil, queueDispatches[id] == nil,
            pendingSends[id] == nil,
            let runtime = runtimes[id], ["idle", "completed"].contains(runtime.status), runtime.readyForActions,
            let first = queues[id]?.first, let conversation = conversations.first(where: { $0.id == id })
        else { return }
        let current = revision
        let token = UUID()
        queueDispatches[id] = token
        Task { [weak self] in
            guard let self, current == revision, queueDispatches[id] == token else { return }
            defer { if current == revision, queueDispatches[id] == token { queueDispatches.removeValue(forKey: id) } }
            do { try await send(first.draft, in: conversation, enqueueWhenBusy: false, queued: first) } catch {
                guard current == revision else { return }
                pausedQueues.insert(id)
                if !(error is CancellationError) { operationError = error.localizedDescription }
                persist()
                changed()
            }
        }
    }
    func respond(_ permission: PendingPermission, conversationId: String, decision: JSONValue) async throws {
        guard let runtime = runtimes[conversationId], runtime.readyForActions,
            runtime.pendingPermissions.contains(where: { $0.id == permission.id && $0.turnId == permission.turnId })
        else { throw TodexError.invalid("审批已失效，请同步当前记录") }
        _ = try await command(
            "conversation.permission.respond",
            ["conversationId": .string(conversationId), "permissionId": .string(permission.id), "decision": decision])
    }
    func control(_ action: String, conversation: ConversationManifest) async throws -> JSONValue {
        guard runtimes[conversation.id]?.readyForActions == true else { throw TodexError.invalid("请等待历史记录同步完成") }
        guard provider(for: conversation)?.capabilities["controlActions"].arrayValue.contains(.string(action)) == true
        else { throw TodexError.invalid("当前 Agent 不支持此操作") }
        return try await command(
            "conversation.\(action)", ["conversationId": .string(conversation.id)],
            timeout: action == "compact" ? 310 : 45)
    }
    func liveControl(_ control: JSONValue, conversation: ConversationManifest) async throws -> JSONValue {
        guard let runtime = runtimes[conversation.id], runtime.readyForActions, !runtime.activeTurnId.isEmpty else {
            throw TodexError.invalid("没有已同步的运行任务")
        }
        return try await command(
            "conversation.control",
            [
                "conversationId": .string(conversation.id), "expectedTurnId": .string(runtime.activeTurnId),
                "control": control,
            ])
    }

    private func receive(_ frame: JSONValue) {
        for continuation in wireSubscribers.values {
            if case .dropped = continuation.yield(frame) {
                // Consumers must refresh any projection that missed a wire frame.
                continuation.yield([
                    "type": "connection.gap",
                    "payload": ["message": "实时事件缓冲区已满，请重新同步", "reason": "subscriberOverflow"],
                ])
            }
        }
        let type = frame["type"].stringValue
        if type == "connection.closed" {
            invalidateTransport()
            operationError = frame["payload"]["message"].stringValue
            connectionStatus = "连接已中断"
            persist()
            scheduleReconnect()
            changed(immediate: true)
            return
        }
        if type == "conversation.event", let event = try? frame["payload"].decoded(ConversationEvent.self) {
            ingest(event)
            if runtimes[event.conversationId]?.needsRecovery == true, recoveryTasks[event.conversationId] == nil,
                isConnected
            {
                let current = revision
                Task { [weak self] in
                    guard let self, current == revision else { return }
                    do { try await recover(event.conversationId) } catch { /* recover reports once for all waiters. */
                    }
                }
            }
        } else if type.hasPrefix("codex.") {
            let payload = frame["payload"]
            let id = frame["payload"]["codex_session_id"].stringValue
            if !id.isEmpty {
                legacyCursors[id] = max(legacyCursors[id] ?? 0, payload["cursor"].intValue)
                saveSoon()
            }
        } else if type == "server.error", frame["id"].isNull {
            operationError = frame["payload"]["message"].stringValue
            changed()
        }
    }
    private func ingest(_ event: ConversationEvent) {
        let id = event.conversationId
        var runtime = runtimes[id] ?? ConversationRuntime(conversationId: id)
        let before = runtime.appliedSequence
        let oldStatus = runtime.status
        let oldTurn = runtime.activeTurnId
        runtime.ingest(event)
        runtimes[id] = runtime
        cache(event)
        if let pending = pendingSends[id], event.sequence > pending.afterSequence,
            event.payload["clientRequestId"].stringValue == pending.requestId
        {
            pendingSends.removeValue(forKey: id)
            saveSoon()
        }
        if runtime.appliedSequence > before {
            if activeConversationID == id { readSequences[id] = runtime.appliedSequence }
            if let index = conversations.firstIndex(where: { $0.id == id }) {
                conversations[index].lastSequence = max(conversations[index].lastSequence, runtime.appliedSequence)
                conversations[index].status = runtime.status
            }
            if ["failed", "cancelled", "interrupted"].contains(runtime.status) { pausedQueues.insert(id) }
            if runtime.status == "completed", oldStatus != "completed", !oldTurn.isEmpty {
                if let send = sending[id], runtime.appliedSequence > send.afterSequence {
                    completedDuringSend[id] = send.requestID
                } else {
                    dispatchQueue(id)
                }
            }
            saveSoon()
        }
        changed()
    }

    /// Cache only a bounded contiguous prefix. Neither arrival order nor the
    /// 10,000-event cap may turn a tail into a seemingly complete offline journal.
    private func cache(_ event: ConversationEvent) {
        let id = event.conversationId
        guard event.sequence > 0, event.sequence <= 10_000,
            rawEvents[id] != nil || rawEvents.count < 32
        else { return }
        var journal = rawEvents[id] ?? CachedJournal()
        guard !journal.saturated, event.sequence > journal.events.count,
            journal.pending[event.sequence] == nil
        else { return }
        guard event.sequence == journal.events.count + 1 || journal.pending.count < 256 else { return }
        let bytes = Self.eventCost(event)
        guard bytes <= Self.journalByteLimit - journal.bytes, bytes <= Self.cacheByteLimit - cachedBytes else {
            journal.saturated = true
            for pending in journal.pending.values {
                let cost = Self.eventCost(pending)
                journal.bytes -= cost
                cachedBytes -= cost
            }
            journal.pending.removeAll()
            rawEvents[id] = journal
            return
        }
        journal.pending[event.sequence] = event
        journal.bytes += bytes
        cachedBytes += bytes
        while let next = journal.pending.removeValue(forKey: journal.events.count + 1) {
            journal.events.append(next)
            dirtyCaches.insert(id)
        }
        rawEvents[id] = journal
    }
    private static func eventCost(_ event: ConversationEvent) -> Int {
        func cost(_ value: JSONValue, remaining: Int) -> Int {
            guard remaining > 0 else { return Self.journalByteLimit + 1 }
            switch value {
            case .string(let string): return min(Self.journalByteLimit + 1, string.utf8.count * 6 + 2)
            case .array(let values):
                var total = 2
                for value in values {
                    total += cost(value, remaining: remaining - total) + 1
                    if total > remaining { break }
                }
                return total
            case .object(let values):
                var total = 2
                for (key, value) in values {
                    total += key.utf8.count * 6 + 4 + cost(value, remaining: remaining - total)
                    if total > remaining { break }
                }
                return total
            default: return 32
            }
        }
        return 256
            + [
                event.eventId, event.conversationId, event.type, event.time, event.provider ?? "",
                event.normalizedType ?? "", event.rawType ?? "",
            ].reduce(0) { $0 + $1.utf8.count * 6 }
            + cost(event.payload, remaining: Self.journalByteLimit)
    }
    private func removeCache(_ id: String) {
        if let old = rawEvents.removeValue(forKey: id) { cachedBytes -= old.bytes }
        dirtyCaches.remove(id)
    }
    private func conversationScope(_ conversation: ConversationManifest) -> String {
        let workspace = workspace(for: conversation)
        return LocalStore.identity([
            stateNamespace, workspace?.tenantId ?? "", conversation.workspaceId ?? workspace?.id ?? "",
            conversation.workspace, conversation.id,
        ])
    }
    private func eventKey(_ conversation: ConversationManifest) -> String {
        "events-v2-" + conversationScope(conversation)
    }
    private func key(_ suffix: String) -> String { "\(stateNamespace)-\(suffix)" }

    func saveSoon() {
        guard saveTask == nil else { return }
        let generation = stateGeneration
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, generation == stateGeneration else { return }
            saveTask = nil
            persist()
        }
    }
    func persist() {
        saveTask?.cancel()
        saveTask = nil
        guard stateLoaded else {
            saveAfterLoad = true
            return
        }
        _ = stageCheckpoint()
        for id in dirtyCaches {
            guard let conversation = conversations.first(where: { $0.id == id }), let events = rawEvents[id]?.events
            else { continue }
            saveVersion += 1
            cacheWrites[eventKey(conversation)] = CacheWrite(
                namespace: stateNamespace, version: saveVersion, events: events)
        }
        dirtyCaches.removeAll()
        startPersistenceWorker()
    }
    private func stageCheckpoint() -> Checkpoint {
        saveVersion += 1
        // Read marks are scoped by tenant/workspace/conversation in the file.
        let reads = Dictionary(
            conversations.compactMap { conversation in
                readSequences[conversation.id].map { (conversationScope(conversation), $0) }
            }, uniquingKeysWith: max)
        let snapshot = SessionSnapshot(
            workspaces: workspaces, conversations: conversations, drafts: drafts, preferences: preferences,
            queues: queues, pendingSends: pendingSends, legacyCursors: legacyCursors, readSequences: reads,
            pinnedWorkspaces: pinnedWorkspaces, pinnedConversations: pinnedConversations,
            pausedQueues: pausedQueues, activeConversationID: activeConversationID)
        let checkpoint = Checkpoint(version: saveVersion, snapshot: snapshot)
        unsavedSnapshots[stateNamespace] = checkpoint
        return checkpoint
    }
    private func persistDurably() async throws {
        guard stateLoaded else { throw TodexError.invalid(storageError ?? "本地状态未完成加载") }
        let namespace = stateNamespace
        let checkpoint = stageCheckpoint()
        try await commit(checkpoint, namespace: namespace)
    }
    private func commit(_ checkpoint: Checkpoint, namespace: String) async throws {
        do {
            try await persistence.save(checkpoint.snapshot, key: "\(namespace)-state", version: checkpoint.version)
            if unsavedSnapshots[namespace]?.version == checkpoint.version {
                unsavedSnapshots.removeValue(forKey: namespace)
            }
            if let failure = storageFailures[namespace], checkpoint.version >= failure.version {
                storageFailures.removeValue(forKey: namespace)
                if namespace == stateNamespace { changed(immediate: true) }
            }
        } catch {
            reportStorageError(error, namespace: namespace, version: checkpoint.version)
            throw error
        }
    }
    private func startPersistenceWorker() {
        guard persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            guard let self else { return }
            defer { persistenceTask = nil }
            var attempted: [String: UInt64] = [:]
            while true {
                if let (namespace, checkpoint) = unsavedSnapshots.first(where: { attempted[$0.key] != $0.value.version }
                ) {
                    attempted[namespace] = checkpoint.version
                    do { try await commit(checkpoint, namespace: namespace) } catch { /* Retain the checkpoint. */  }
                } else if let (key, write) = cacheWrites.first {
                    cacheWrites.removeValue(forKey: key)
                    do { try await persistence.saveEvents(write.events, key: key, version: write.version) } catch {
                        reportStorageError(error, namespace: write.namespace, version: write.version)
                    }
                } else {
                    break
                }
            }
        }
    }
    private func reportStorageError(_ error: Error, namespace: String, version: UInt64) {
        guard version >= (storageFailures[namespace]?.version ?? 0) else { return }
        let message = "草稿和待确认消息仍保留在内存中。\(error.localizedDescription)"
        let different = storageFailures[namespace]?.message != message
        storageFailures[namespace] = (version, message)
        if namespace == stateNamespace {
            pausedQueues.formUnion(queues.keys)
            if different { changed(immediate: true) }
        }
        // Deliberately do not persist here: a full/protected disk must not create
        // a save-error-observer-save recursion or retry a network mutation.
    }
    private func switchState(to namespace: String) {
        stateLoadTask?.cancel()
        saveTask?.cancel()
        saveTask = nil
        stateGeneration = UUID()
        stateNamespace = namespace
        stateLoaded = false
        saveAfterLoad = false
        workspaces = []
        conversations = []
        providers = []
        runtimes = [:]
        models = [:]
        commands = [:]
        drafts = [:]
        preferences = [:]
        queues = [:]
        pendingSends = [:]
        pausedQueues = []
        pinnedWorkspaces = []
        pinnedConversations = []
        readSequences = [:]
        legacyCursors = [:]
        rawEvents = [:]
        cachedBytes = 0
        cacheLoaded = []
        dirtyCaches = []
        activeConversationID = nil
        modelRevisions = [:]
        commandRevisions = [:]
        operationError = nil
        loadState()
    }
    private func loadState() {
        let generation = stateGeneration
        let namespace = stateNamespace
        let retained = unsavedSnapshots[namespace]?.snapshot
        stateLoadTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == stateGeneration { stateLoadTask = nil } }
            do {
                let disk: SessionSnapshot?
                if unsavedSnapshots[namespace] != nil || retained != nil {
                    disk = nil
                } else {
                    disk = try await persistence.load("\(namespace)-state")
                }
                guard generation == stateGeneration, !Task.isCancelled else { return }
                let snapshot = unsavedSnapshots[namespace]?.snapshot ?? retained ?? disk ?? SessionSnapshot()
                workspaces = snapshot.workspaces
                conversations = snapshot.conversations
                // Preserve edits made while the asynchronous load was in flight.
                drafts = snapshot.drafts.merging(drafts) { _, edited in edited }
                preferences = snapshot.preferences.merging(preferences) { _, edited in edited }
                queues = snapshot.queues.merging(queues) { _, edited in edited }
                pendingSends = snapshot.pendingSends
                legacyCursors = snapshot.legacyCursors
                pinnedWorkspaces = Array(Set(snapshot.pinnedWorkspaces + pinnedWorkspaces)).sorted {
                    (snapshot.pinnedWorkspaces.firstIndex(of: $0) ?? Int.max)
                        < (snapshot.pinnedWorkspaces.firstIndex(of: $1) ?? Int.max)
                }
                pinnedConversations = Array(Set(snapshot.pinnedConversations + pinnedConversations)).sorted {
                    (snapshot.pinnedConversations.firstIndex(of: $0) ?? Int.max)
                        < (snapshot.pinnedConversations.firstIndex(of: $1) ?? Int.max)
                }
                readSequences = Dictionary(
                    conversations.compactMap { conversation in
                        snapshot.readSequences[conversationScope(conversation)].map { (conversation.id, $0) }
                    }, uniquingKeysWith: max)
                pausedQueues = Set(queues.keys)  // Restarts never automatically drain a persisted queue.
                activeConversationID = activeConversationID ?? snapshot.activeConversationID
                stateLoaded = true
                if saveAfterLoad {
                    saveAfterLoad = false
                    persist()
                }
                changed(immediate: true)
            } catch {
                guard generation == stateGeneration else { return }
                reportStorageError(error, namespace: namespace, version: saveVersion)
            }
        }
    }
}
