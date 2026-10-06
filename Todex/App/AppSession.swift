import Foundation
import TodexCore
#if canImport(UIKit)
    import UIKit
#endif

/// The sole transport seam needed for deterministic recovery/send race tests.
nonisolated protocol SessionSocket: Sendable {
    var events: AsyncStream<JSONValue> { get }
    /// `agentBrowser.frame` payloads, delivered apart from `events`.
    var browserFrames: AsyncStream<JSONValue> { get }
    func connect() async throws
    func disconnect() async
    func command(type: String, payload: JSONValue, timeout: TimeInterval, id: String) async throws -> JSONValue
}
extension RealtimeClient: SessionSocket {}
extension SessionSocket {
    /// Sockets without live browser views (test doubles) never yield frames.
    var browserFrames: AsyncStream<JSONValue> { AsyncStream { $0.finish() } }
}

@MainActor final class AppSession {
    private(set) var connections: [BackendConnection] = []
    private(set) var selectedID: String?
    // The environment-injected test fixture is merged into the catalog but must
    // never reach connections.json, or a Settings save under a fixture launch
    // would overwrite the real backend list.
    private var fixtureConnectionID: String?
    private var connectionStatus = String(localized: "尚未连接")
    var status: String { storageError.map { String(localized: "本地保存失败：\($0)") } ?? connectionStatus }
    private(set) var isConnected = false
    private(set) var isConnecting = false
    private var operationError: String?
    var lastError: String? { storageError ?? operationError }
    var storageError: String? { storageFailures[stateNamespace]?.message }
    private(set) var workspaces: [WorkspaceRecord] = []
    /// Stored workspaces whose path the backend rejects (directory removed or
    /// outside its roots); Home lists them dimmed and unselectable.
    private(set) var rejectedWorkspaces: [RejectedWorkspace] = []
    private(set) var tasks: [KanbanTask] = []
    private(set) var conversations: [ConversationManifest] = []
    private(set) var providers: [ProviderDescriptor] = []
    private(set) var runtimes: [String: ConversationRuntime] = [:]
    private(set) var models: [String: [JSONValue]] = [:]
    private(set) var commands: [String: [JSONValue]] = [:]
    private(set) var pendingSends: [String: PendingSend] = [:]
    var activeConversationID: String?
    /// The conversation whose chat is on screen right now (nil on Home or
    /// Settings); completion alerts skip it.
    var viewingConversationID: String?
    var drafts: [String: ComposerDraft] = [:]
    var preferences: [String: ConversationPreferences] = [:]
    // Composer memory: the last chip configuration used with each provider, and
    // the agent picked for the most recently created conversation.
    private(set) var lastPreferencesByProvider: [String: ConversationPreferences] = [:]
    private(set) var lastAgent: AgentSelection?
    var queues: [String: [QueuedDraft]] = [:]
    var pausedQueues: Set<String> = []
    var pinnedWorkspaces: [String] = []
    var pinnedConversations: [String] = []
    var readSequences: [String: Int] = [:]
    /// Local-only conversation label colors (`#rrggbb`) in this backend's namespace.
    private(set) var conversationLabels: [String: String] = [:]
    private(set) var sentAttachments: [SentAttachmentRecord] = []
    /// Usage records across every conversation of this backend, newest first
    /// and bounded like desktop; Settings aggregates them.
    private(set) var usageRecords: [JSONValue] = [] { didSet { usageRevision &+= 1 } }
    /// Bumps on every ledger change; merges can replace a mid-list record
    /// without changing the count or head, so observers compare this instead.
    private(set) var usageRevision = 0
    /// The error behind the last failed connect/close, kept only so Settings can
    /// present a categorized diagnostic. Reconnect policy never reads it.
    private(set) var lastConnectionError: (any Error)?
    private(set) var api: APIClient?
    private var socket: (any SessionSocket)?
    private let store: LocalStore
    private let persistence: SessionPersistence
    private let defaults: UserDefaults
    private let makeAPI: (BackendConnection) -> APIClient
    private let makeSocket: (BackendConnection) -> any SessionSocket
    private let saveCredential: (String, String) throws -> Void
    private var frameTask: Task<Void, Never>?
    private var browserFrameTask: Task<Void, Never>?
    /// Conversation id → live agent-browser views (token → frame handler).
    /// A conversation is watched on the socket while it has any; reconnects
    /// watch them again. Frames are only handed over, never stored.
    private var browserWatchers: [String: [UUID: (AgentBrowserFrame) -> Void]] = [:]
    private var connectTask: Task<Void, Never>?
    private var connectingConfiguration: BackendConnection?
    private var reconnectTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var stateLoadTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var kanbanPushTask: Task<Void, Never>?
    // A 404 marks a backend older than the kanban endpoints; stay local-only
    // until the next refresh re-probes instead of failing every mutation.
    private var kanbanSyncSupported = true
    private struct Recovery {
        let token: UUID
        let task: Task<Void, any Error>
    }
    private var recoveryTasks: [String: Recovery] = [:]
    /// Conversations subscribed on the current socket, least recently used
    /// first. The backend rejects subscribes past 128 per socket; the local
    /// budget evicts (unsubscribes) before that so opening one never fails.
    private var liveSubscriptions: [String] = []
    private static let subscriptionBudget = 120
    /// Slots background watching leaves free for conversations the user opens.
    private static let watchHeadroom = 16
    /// Watch-only subscribes backfill only this many events past the listed
    /// cursor: enough to catch up the row's status, never a whole journal.
    nonisolated static let watchBackfillLimit = 50
    private var watchTask: Task<Void, Never>?
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
    /// Conversation id → Codex adapter sidecar state. Desktop keeps this on
    /// the manifest as `localAdapterState` plus a per-conversation `turnIds`
    /// map; mobile scopes both by conversation id inside the session.
    private var sidecars: [String: CodexLocalSidecar] = [:]
    /// Concurrent `codex.local.start`/`thread/start` callers join these tasks
    /// (desktop `pendingLocalStarts`/`pendingThreadStarts` dedup).
    private var sidecarStarts: [String: Task<Void, Error>] = [:]
    private var localThreadStarts: [String: Task<String, Error>] = [:]
    /// conversationId → adapter thread id. Persisted: the adapter process may
    /// outlive an app restart, and resuming needs the same thread id.
    private var localThreads: [String: String] = [:]
    private var revision = UUID()
    private var refreshRevision = UUID()
    private var modelRevisions: [String: UUID] = [:]
    private var commandRevisions: [String: UUID] = [:]
    private var reconnectAttempt = 0
    private var foreground = true
    private var wantsConnection = false
    // Periodic /health probe (desktop parity): latency for the status line and a
    // reachability hint that never overrides the authoritative socket state.
    private(set) var healthLatencyMs: Int?
    private(set) var healthFailed = false
    private var healthTask: Task<Void, Never>?
    private var healthProbeSeq = 0
    // Release versions ship in lockstep across backend and clients; a non-dev
    // mismatch surfaces as an upgrade warning. Dev builds (DEV0.0.0) skip it.
    private(set) var versionMismatch: (app: String, backend: String)?
    private var versionProbeSeq = 0
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
    /// Contiguous journal prefixes as received: ciphertext under history
    /// encryption, decrypted again in memory whenever they are loaded.
    private var eventCache = ConversationEventCache()
    private var cacheLoaded: Set<String> = []
    private var dirtyCaches: Set<String> = []
    /// Lazily-opened histories: `historyFloors[id]` is the highest sequence not
    /// yet loaded (the next `beforeSequence` cursor). Absent or 0 means the
    /// loaded window already reaches the journal head.
    private var historyFloors: [String: Int] = [:]
    private var earlierLoading: [String: UUID] = [:]
    private static let historyPageSize = 300
    private static let activeTurnScanPages = 10
    /// Events a subscription backfills over the socket; the rest pages over HTTP.
    private static let subscribeBackfillLimit = 500
    private struct CacheWrite {
        let namespace: String
        let version: UInt64
        let history: CachedHistory
    }
    private var cacheWrites: [String: CacheWrite] = [:]
    /// One journal event as the backend sent it (`raw`, the only form that
    /// reaches the disk cache) and as projected (`plain`, decrypted).
    private struct ReceivedEvent {
        let raw: ConversationEvent
        let plain: ConversationEvent
    }
    // MARK: History encryption (history v3)
    /// This backend's history-encryption settings; nil while unknown or when
    /// the backend predates history encryption.
    private(set) var historyEncryption: HistoryEncryptionState?
    private var historyDecryptor: HistoryDecryptor?
    private let historySeeds: HistorySeedStore
    /// Conversations whose journal carried ciphertext; retry must then send
    /// the prompt text itself (§7).
    private var encryptedConversations: Set<String> = []
    /// `titleEnc.ct` → decrypted title, memory only: titles stay ciphertext on disk.
    private var decryptedTitles: [String: String] = [:]
    private var historyProbe: Task<Void, Never>?
    var connection: BackendConnection? { connections.first { $0.id == selectedID } }
    var activeConversation: ConversationManifest? { conversations.first { $0.id == activeConversationID } }

    init(
        store: LocalStore = LocalStore(), connections initial: [BackendConnection]? = nil,
        defaults: UserDefaults = .standard,
        apiFactory: @escaping (BackendConnection) -> APIClient = { APIClient(connection: $0) },
        socketFactory: @escaping (BackendConnection) -> any SessionSocket = { RealtimeClient(connection: $0) },
        credentialWriter: @escaping (String, String) throws -> Void = { try CredentialStore.save($0, for: $1) },
        historySeeds: HistorySeedStore = .keychain
    ) {
        self.store = store
        self.historySeeds = historySeeds
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
                connections[index].deviceSecret = CredentialStore.deviceSecret(for: connections[index].id)
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
                    id: "simulator-fixture", name: String(localized: "测试后端"), serverURL: url,
                    deviceSecret: environment["TODEX_TEST_DEVICE_SECRET"] ?? "")
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

    /// Streams the conversation's agent browser tab to `onFrame` until
    /// `unwatchAgentBrowser(_:)`. The socket watch is shared by every view of
    /// the conversation and restored after reconnects.
    func watchAgentBrowser(_ conversationID: String, onFrame: @escaping (AgentBrowserFrame) -> Void) -> UUID {
        let token = UUID()
        let first = browserWatchers[conversationID]?.isEmpty ?? true
        browserWatchers[conversationID, default: [:]][token] = onFrame
        if first, isConnected { sendBrowserWatch(conversationID, watching: true) }
        return token
    }

    func unwatchAgentBrowser(_ token: UUID) {
        guard let id = browserWatchers.first(where: { $0.value[token] != nil })?.key else { return }
        browserWatchers[id]?.removeValue(forKey: token)
        guard browserWatchers[id]?.isEmpty == true else { return }
        browserWatchers.removeValue(forKey: id)
        if isConnected { sendBrowserWatch(id, watching: false) }
    }

    private func sendBrowserWatch(_ conversationID: String, watching: Bool) {
        guard let socket else { return }
        let current = revision
        Task { [weak self] in
            do {
                _ = try await socket.command(
                    type: watching ? "agentBrowser.watch" : "agentBrowser.unwatch",
                    payload: ["conversationId": .string(conversationID)], timeout: 15, id: UUID().uuidString)
            } catch {
                // The view falls back to screenshots; a reconnect watches again.
                guard let self, current == self.revision, !(error is CancellationError) else { return }
                DebugLog.record(
                    "agentBrowser.watch.failed",
                    ["watching": "\(watching)", "error": String(describing: error)], level: .warn)
            }
        }
    }

    func saveConnections(_ values: [BackendConnection], selected: String?) throws {
        guard Set(values.map(\.id)).count == values.count else { throw TodexError.invalid(String(localized: "后端标识重复")) }
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
            for value in values { try saveCredential(value.deviceSecret, value.id) }
            for old in removed {
                try saveCredential("", old.id)
                try historySeeds.save(nil, old.id)
            }
        } catch {
            reportStorageError(error, namespace: stateNamespace, version: saveVersion)
            throw error
        }
        persist()  // Capture the old namespace before changing editable Settings values.
        if changedTransport {
            wantsConnection = false
            invalidateTransport()
            connectionStatus = String(localized: "尚未连接")
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
            connectionStatus = String(localized: "连接配置未完成")
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
                try saveCredential(next.deviceSecret, next.id)
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
        connectionStatus = String(localized: "正在连接…")
        operationError = nil
        lastConnectionError = nil
        DebugLog.record(
            "connection.connect", ["url": next.serverURL, "encryption": next.encryption.rawValue], level: .info)
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
                // Encrypted live events decrypt here, in arrival order; the
                // loop waits so later frames cannot overtake them.
                let decrypted = await decryptLive(frame)
                guard self.revision == current, !Task.isCancelled else { return }
                receive(frame, decrypted: decrypted)
            }
        }
        browserFrameTask = Task { [weak self] in
            for await payload in socket.browserFrames {
                guard let self, self.revision == current, !Task.isCancelled else { return }
                guard let frame = AgentBrowserFrame(payload: payload) else { continue }
                for handler in Array((browserWatchers[frame.conversationId] ?? [:]).values) { handler(frame) }
            }
        }
        do {
            try await socket.connect()
            try checkRevision(current)
            isConnecting = false
            isConnected = true
            connectionStatus = String(localized: "已连接")
            // A new socket has no watches; restore the views still open.
            for id in browserWatchers.keys { sendBrowserWatch(id, watching: true) }
            DebugLog.record("connection.open", level: .info)
            startHealthChecks()
            checkBackendVersion(api)
            try await refresh()
            try checkRevision(current)
            probeHistoryEncryption()
            if !legacyCursors.isEmpty {
                _ = try await socket.command(
                    type: "session.resume",
                    payload: ["sessionCursors": .object(legacyCursors.mapValues { .number(Double($0)) })], timeout: 30,
                    id: UUID().uuidString)
                try checkRevision(current)
            }
            // Adapters kept running on the backend while the socket was down:
            // re-attach to replay the missed sidecar events (desktop
            // attachWorkspaceConversation on reconnect).
            for (id, sidecar) in sidecars where [.running, .starting].contains(sidecar.phase) || !sidecar.turnId.isEmpty {
                guard let conversation = conversations.first(where: { $0.id == id }) else { continue }
                try? await attachLocal(conversation)
            }
            if let id = activeConversationID, conversations.contains(where: { $0.id == id }) { try await recover(id) }
            try checkRevision(current)
            reconnectAttempt = 0
            changed(immediate: true)
        } catch {
            guard current == revision else { return }
            invalidateTransport()
            operationError = error.localizedDescription
            lastConnectionError = error
            DebugLog.record(
                "connection.failed",
                ["error": String(describing: error), "permanent": "\(TodexError.stopsReconnect(error))"], level: .error)
            connectionStatus = String(localized: "连接失败")
            stopReconnectingIfPermanent(TodexError.stopsReconnect(error))
            persist()
            scheduleReconnect()
            changed(immediate: true)
        }
    }
    /// Auth rejections and transport-setup mismatches fail identically on
    /// every retry; stop until the user edits the backend or reconnects.
    private func stopReconnectingIfPermanent(_ permanent: Bool) {
        guard permanent else { return }
        wantsConnection = false
        connectionStatus = String(localized: "连接已停止，请检查后端配置")
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
        browserFrameTask?.cancel()
        browserFrameTask = nil
        healthTask?.cancel()
        healthTask = nil
        historyProbe?.cancel()
        historyProbe = nil
        healthLatencyMs = nil
        healthFailed = false
        versionMismatch = nil
        versionProbeSeq += 1
        for flight in recoveryTasks.values { flight.task.cancel() }
        recoveryTasks.removeAll()
        // Subscriptions belong to the socket; a new one starts with none.
        liveSubscriptions.removeAll()
        watchTask?.cancel()
        watchTask = nil
        queueDispatches.removeAll()
        sending.removeAll()
        completedDuringSend.removeAll()
        for task in sidecarStarts.values { task.cancel() }
        sidecarStarts.removeAll()
        for task in localThreadStarts.values { task.cancel() }
        localThreadStarts.removeAll()
        // Adapter processes live on the backend host — their phase survives a
        // socket drop; only the not-yet-started marker must reset.
        for id in Array(sidecars.keys) where sidecars[id]?.phase == .starting {
            sidecars[id]?.phase = .idle
        }
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
        DebugLog.record("connection.disconnect", level: .info)
        wantsConnection = false
        invalidateTransport()
        connectionStatus = String(localized: "已断开")
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
            healthTask?.cancel()
            healthTask = nil
        } else {
            if isConnected { startHealthChecks() }
            guard wantsConnection || connectTask != nil else { return }
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
    /// Desktop parity: retry for as long as the app is foregrounded, backing off
    /// to 30 s. Backgrounding cancels the loop; returning restarts it at once.
    private func scheduleReconnect() {
        guard wantsConnection, foreground, reconnectTask == nil else { return }
        reconnectAttempt += 1
        let current = revision
        let delay = min(30, pow(2, Double(min(reconnectAttempt, 5))))
        DebugLog.record("connection.retryScheduled", ["attempt": "\(reconnectAttempt)", "delay": "\(Int(delay))"])
        connectionStatus = String(localized: "连接中断，\(Int(delay)) 秒后第 \(reconnectAttempt) 次重试")
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, current == revision else { return }
            reconnectTask = nil
            await connect()
        }
    }
    /// Foreground-only probe loop; iOS suspends the socket in the background so
    /// polling stops instead of draining battery on a dead connection.
    private func startHealthChecks() {
        guard healthTask == nil else { return }
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.probeHealth()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
    private func probeHealth() async {
        guard foreground, isConnected, let api else { return }
        healthProbeSeq += 1
        let probe = healthProbeSeq
        let started = Date()
        do {
            _ = try await api.health()
            guard probe == healthProbeSeq, isConnected else { return }
            healthLatencyMs = max(0, Int(Date().timeIntervalSince(started) * 1000))
            healthFailed = false
        } catch {
            guard probe == healthProbeSeq, isConnected, !Task.isCancelled else { return }
            healthLatencyMs = nil
            healthFailed = true
        }
        changed()
    }
    /// Best-effort /v2/version probe after connect; failures stay silent and a
    /// stale probe cannot overwrite a newer transport's result.
    private func checkBackendVersion(_ api: APIClient) {
        versionProbeSeq += 1
        let probe = versionProbeSeq
        Task { [weak self] in
            guard let info = try? await api.version(),
                let backend = info["version"].optionalString
            else { return }
            guard let self, self.versionProbeSeq == probe, self.isConnected else { return }
            let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            self.versionMismatch = VersionCheck.mismatch(app: app, backend: backend) ? (app ?? String(localized: "未知"), backend) : nil
            self.changed()
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
            && lhs.deviceSecret == rhs.deviceSecret && lhs.encryption == rhs.encryption && lhs.publicKey == rhs.publicKey
    }

    func refresh() async throws {
        guard let api, isConnected else { throw TodexError.disconnected }
        let current = revision
        let request = UUID()
        refreshRevision = request
        kanbanSyncSupported = true
        async let workspaceResult = api.workspaceCatalog()
        async let conversationResult = api.conversations()
        async let providerResult = api.providers()
        async let taskResult = remoteKanbanTasks()
        let (catalog, conversations, providers) = try await (workspaceResult, conversationResult, providerResult)
        try checkRevision(current)
        guard refreshRevision == request else { return }
        let oldScopes = Dictionary(
            self.conversations.map { ($0.id, conversationScope($0)) }, uniquingKeysWith: { _, latest in latest })
        self.workspaces = catalog.workspaces
        rejectedWorkspaces = catalog.rejected
        self.conversations = conversations.map(presentable)
        self.providers = providers
        decryptTitles()
        // A deleted conversation leaves its adapter running on the backend;
        // stop it rather than leaking the process.
        for removed in Set(oldScopes.keys).subtracting(conversations.map(\.id)) {
            discardSidecar(removed)
        }
        if let remoteTasks = await taskResult {
            mergeRemoteKanbanTasks(remoteTasks)
            // Local additions and tombstones the backend lacks still go up.
            scheduleKanbanPush()
        }
        for conversation in conversations
        where oldScopes[conversation.id] != nil && oldScopes[conversation.id] != conversationScope(conversation) {
            readSequences.removeValue(forKey: conversation.id)
            runtimes.removeValue(forKey: conversation.id)
            historyFloors.removeValue(forKey: conversation.id)
            earlierLoading.removeValue(forKey: conversation.id)
            removeCache(conversation.id)
            cacheLoaded.remove(conversation.id)
        }
        persist()
        watchConversations()
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
        let modes = config["modes"].arrayValue.compactMap(\.optionalString)
        // Never assume "ask" for an agent that cannot enforce it: leave the mode
        // unset so the composer asks the user to choose (desktop parity).
        value.permissionMode = config["defaultMode"].optionalString ?? (modes.isEmpty || modes.contains("ask") ? "ask" : "")
        value.reasoningEffort = workspace(for: conversation)?.reasoningEffort ?? ""
        return value
    }
    func updatePreferences(_ value: ConversationPreferences, for conversation: ConversationManifest) {
        preferences[conversation.id] = value
        lastPreferencesByProvider[conversation.provider] = value
        saveSoon()
        changed()
    }
    /// Composer memory for a provider's next conversation. Values the current
    /// capability descriptor no longer supports fall back to its defaults.
    func rememberedPreferences(for provider: String) -> ConversationPreferences? {
        guard var value = lastPreferencesByProvider[provider] else { return nil }
        let config = providers.first { $0.id == provider }?.capabilities["permissionConfig"] ?? .null
        let modes = config["modes"].arrayValue.compactMap(\.optionalString)
        if !modes.isEmpty, !modes.contains(value.permissionMode) {
            // Same fallback as preferences(for:): never assume an unsupported "ask".
            value.permissionMode = config["defaultMode"].optionalString ?? (modes.contains("ask") ? "ask" : "")
        }
        if value.workMode == "plan", config["supportsPlan"].boolValue != true {
            value.workMode = "implement"
        }
        return value
    }
    func rememberAgent(provider: String, profile: String?) {
        lastAgent = AgentSelection(provider: provider, profile: profile)
        saveSoon()
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

    /// Exports another conversation's user and assistant messages as Markdown
    /// for an `@chat:` reference. Replays the whole journal because the
    /// conversation may never have been opened on this device.
    func exportConversationMarkdown(_ target: ConversationManifest, maxBytes: Int) async throws -> String {
        guard let api, isConnected else { throw TodexError.disconnected }
        let current = revision
        let id = target.id
        let messages = try await ConversationExport.transcript(conversationId: id) { [weak self] after, limit in
            let page = try await api.events(conversationId: id, after: after, limit: limit, detail: "summary")
            guard let self else { throw CancellationError() }
            // The transcript projects plaintext; ciphertext is decrypted per page.
            var plain = page
            plain["events"] = .array(
                try await self.receivedPage(page, conversationId: id).map { try JSONValue(encoding: $0.plain) })
            plain["frames"] = nil
            return plain
        }
        try checkRevision(current)
        return ConversationExport.markdown(messages, title: target.title ?? "", maxBytes: maxBytes)
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
        guard manifest.id == id else { throw TodexError.invalid(String(localized: "对话恢复响应不匹配")) }
        // A runtime that has never applied an event opens at the journal tail
        // instead of replaying from sequence 0; earlier pages load on demand.
        var lazyOpened = false
        if (runtimes[id]?.appliedSequence ?? 0) == 0, manifest.lastSequence > 0 {
            lazyOpened = try await seedTailWindow(id, manifest: manifest, api: api, revision: current)
        }
        if lazyOpened { cacheLoaded.insert(id) }
        if !cacheLoaded.contains(id) {
            let cached: CachedHistory
            do { cached = try await persistence.history(eventKey(manifest)) } catch {
                try checkRevision(current)
                reportStorageError(error, namespace: stateNamespace, version: saveVersion)
                cached = CachedHistory()
            }
            try checkRevision(current)
            // Cache files contain a prefix only. Never seed a cursor from a tail.
            var prefix: [ConversationEvent] = []
            for (offset, event) in cached.events.prefix(ConversationEventCache.maximumSequence).enumerated() {
                guard event.sequence == offset + 1, event.conversationId == id else { break }
                prefix.append(event)
            }
            // The cache holds what the backend sent; ciphertext decrypts in memory only.
            let frames = JSONValue.object(cached.frames)
            let cachedEvents = try await received(prefix, frames: frames)
            try checkRevision(current)
            if !cacheLoaded.contains(id) {
                cacheLoaded.insert(id)
                for event in cachedEvents { ingest(event, frames: frames) }
            }
        }
        var highWater = manifest.lastSequence
        try await replayPages(id, target: highWater, api: api, revision: current)
        try await makeRoomForSubscription(id, socket: socket, revision: current)
        for _ in 0..<10_000 {
            try checkRevision(current)
            let before = runtimes[id]?.appliedSequence ?? 0
            let result: JSONValue
            do {
                result = try await socket.command(
                    type: "conversation.subscribe",
                    // Backfill folded like HTTP history pages and capped so a stale
                    // cursor cannot stream a whole journal; `hasMore` then pages the
                    // rest over HTTP below. Older backends ignore both fields.
                    payload: [
                        "conversationId": .string(id), "afterSequence": .number(Double(before)), "limit": 200,
                        "detail": "summary", "backfillLimit": .number(Double(Self.subscribeBackfillLimit)),
                    ],
                    timeout: 45, id: UUID().uuidString)
            } catch {
                if current == revision { liveSubscriptions.removeAll { $0 == id } }
                throw error
            }
            try checkRevision(current)
            liveSubscriptions.removeAll { $0 == id }
            liveSubscriptions.append(id)
            guard result["conversationId"].isNull || result["conversationId"] == .string(id) else {
                throw TodexError.invalid(String(localized: "订阅响应不匹配"))
            }
            guard result["subscribed"].boolValue else { throw TodexError.invalid(String(localized: "后端未确认订阅")) }
            highWater = max(
                highWater, Self.sequence(result["nextSequence"]) ?? 0, Self.sequence(result["lastSequence"]) ?? 0)
            try await ingestReplay(result, conversationId: id, revision: current)
            // The socket ACK can resume this task before the frame-consumer Task
            // has applied its earlier replay frames. Fill through the ACK cursor.
            try await replayPages(id, target: highWater, api: api, revision: current)
            try checkRevision(current)
            if !result["hasMore"].boolValue {
                runtimes[id]?.markReplayComplete(highWater: highWater)
                guard runtimes[id]?.readyForActions == true else { throw TodexError.invalid(String(localized: "历史记录存在缺口，请重新核对")) }
                var updated = manifest
                updated.lastSequence = max(manifest.lastSequence, runtimes[id]?.appliedSequence ?? 0)
                updated.status = runtimes[id]?.status ?? manifest.status
                if let index = conversations.firstIndex(where: { $0.id == id }) {
                    conversations[index] = updated
                } else {
                    conversations.append(updated)
                }
                if activeConversationID == id { readSequences[id] = runtimes[id]?.appliedSequence ?? 0 }
                if let index = conversations.firstIndex(where: { $0.id == id }) {
                    conversations[index] = presentable(conversations[index])
                }
                saveSoon()
                changed(immediate: true)
                await refreshFollowUps(updated)
                return
            }
            guard (runtimes[id]?.appliedSequence ?? 0) > before else { throw TodexError.invalid(String(localized: "订阅分页没有前进，恢复未完成")) }
        }
        throw TodexError.invalid(String(localized: "订阅分页过多，恢复未完成"))
    }
    /// Fetch the full events covering a folded process group and merge them
    /// into the projected timeline. Called when a user expands a group that
    /// arrived as `detail=summary` stubs.
    func hydrateActivity(conversationId id: String, from lower: Int, to upper: Int) async throws {
        guard let api, isConnected else { throw TodexError.disconnected }
        let current = revision
        var events: [ConversationEvent] = []
        var cursor = lower - 1
        for _ in 0..<10_000 {
            try checkRevision(current)
            let page = try await api.events(
                conversationId: id, after: cursor, limit: min(200, max(1, upper - cursor)))
            try checkRevision(current)
            let received = try await receivedPage(page, conversationId: id)
            try checkRevision(current)
            var reached = false
            for event in received.map(\.plain) {
                guard event.sequence > cursor, event.sequence <= upper else { continue }
                events.append(event)
                cursor = event.sequence
                reached = true
            }
            guard reached else { throw TodexError.invalid(String(localized: "过程详情分页没有前进")) }
            if cursor >= upper || !page["hasMore"].boolValue { break }
        }
        guard cursor >= upper else { throw TodexError.invalid(String(localized: "过程详情分页过多")) }
        var runtime = runtimes[id] ?? ConversationRuntime(conversationId: id)
        if runtime.hydrate(events) {
            runtimes[id] = runtime
            changed()
        }
    }

    func hasEarlierHistory(_ id: String) -> Bool { (historyFloors[id] ?? 0) > 0 }
    func isLoadingEarlier(_ id: String) -> Bool { earlierLoading[id] != nil }

    /// Fetch the page of history directly below the loaded window and merge it
    /// as older entries. The runtime's live state is untouched: `prepend`
    /// projects the page on a scratch runtime and appends timeline rows only.
    func loadEarlier(_ id: String) async throws {
        guard let api, isConnected else { throw TodexError.disconnected }
        let floor = historyFloors[id] ?? 0
        guard floor > 0, runtimes[id] != nil, earlierLoading[id] == nil else { return }
        let current = revision
        let token = UUID()
        earlierLoading[id] = token
        changed()
        defer {
            if earlierLoading[id] == token { earlierLoading.removeValue(forKey: id) }
            if current == revision { changed() }
        }
        let page = try await api.events(
            conversationId: id, before: floor, limit: Self.historyPageSize, detail: "summary")
        try checkRevision(current)
        let events = try await receivedPage(page, conversationId: id).map(\.plain)
        try checkRevision(current)
        // A missing page anchor means the backend ignored `beforeSequence`;
        // keep the floor so the forward path still owns those sequences.
        guard let first = events.first, let last = events.last, last.sequence <= floor else { return }
        var runtime = runtimes[id] ?? ConversationRuntime(conversationId: id)
        runtime.prepend(events, below: floor)
        runtimes[id] = runtime
        historyFloors[id] = page["hasMore"].boolValue && first.sequence > 1 ? first.sequence - 1 : 0
        if let pending = pendingSends[id] {
            for event in events
            where event.sequence > pending.afterSequence
                && event.payload["clientRequestId"].stringValue == pending.requestId
            {
                pendingSends.removeValue(forKey: id)
                saveSoon()
                break
            }
        }
        changed()
    }

    /// Open an uninitialized runtime at the journal tail: fetch the newest
    /// page(s) with `beforeSequence`, seed the applied cursor below the window,
    /// then ingest the window forward so buffered live frames still drain in
    /// order. An active turn scans back — bounded — for its `turn.started` so
    /// the running state and pending approvals project correctly.
    /// Returns false when the backend predates `beforeSequence` (its answer is
    /// not anchored at the cursor); the caller falls back to forward replay.
    private func seedTailWindow(
        _ id: String, manifest: ConversationManifest, api: APIClient, revision current: UUID
    ) async throws -> Bool {
        // Manifests from the wire are snake_case; locally refreshed entries can
        // carry the runtime's camelCase spelling.
        let turnActive = ["running", "waiting_permission", "waitingPermission"].contains(manifest.status)
        var pages: [(events: [ReceivedEvent], frames: JSONValue)] = []
        var cursor = manifest.lastSequence
        var hasMore = true
        while cursor > 0, pages.count < (turnActive ? Self.activeTurnScanPages : 1) {
            let page = try await api.events(
                conversationId: id, before: cursor, limit: Self.historyPageSize, detail: "summary")
            try checkRevision(current)
            let events = try await receivedPage(page, conversationId: id)
            try checkRevision(current)
            guard let first = events.first?.raw, let last = events.last?.raw, last.sequence == cursor else {
                return false
            }
            pages.append((events, page["frames"]))
            hasMore = page["hasMore"].boolValue && first.sequence > 1
            cursor = first.sequence - 1
            if !hasMore { break }
            if turnActive,
                events.contains(where: { ConversationRuntime.canonicalType($0.plain) == "turn.started" })
            {
                break
            }
        }
        guard let earliest = pages.last?.events.first?.raw.sequence else { return false }
        let floor = hasMore ? max(0, earliest - 1) : 0
        var runtime = runtimes[id] ?? ConversationRuntime(conversationId: id)
        // If a live frame already applied the journal head, forward replay
        // fills every sequence below the window and no earlier page remains.
        historyFloors[id] = runtime.seedHistoryFloor(floor) ? floor : 0
        runtimes[id] = runtime
        for page in pages.reversed() {
            for event in page.events { ingest(event, frames: page.frames) }
        }
        return true
    }

    /// Unsubscribe the least valuable subscriptions until `id` fits the local
    /// budget. Idle watch-only rows go first, then idle opened conversations;
    /// the open conversation is never evicted. An evicted runtime re-enters
    /// replay so reopening it recovers the events it stopped receiving.
    private func makeRoomForSubscription(_ id: String, socket: any SessionSocket, revision current: UUID) async throws {
        guard !liveSubscriptions.contains(id) else { return }
        while liveSubscriptions.count >= Self.subscriptionBudget {
            let busy = { (id: String) -> Bool in
                let status = self.runtimes[id]?.status ?? self.conversations.first { $0.id == id }?.status ?? ""
                return ["running", "waitingPermission", "waiting_permission"].contains(status)
            }
            let candidates = liveSubscriptions.filter { $0 != id && $0 != activeConversationID }
            guard
                let victim = candidates.first(where: { runtimes[$0] == nil && !busy($0) })
                    ?? candidates.first(where: { !busy($0) }) ?? candidates.first
            else { return }
            liveSubscriptions.removeAll { $0 == victim }
            runtimes[victim]?.beginReplay()
            _ = try await socket.command(
                type: "conversation.unsubscribe", payload: ["conversationId": .string(victim)], timeout: 15,
                id: UUID().uuidString)
            try checkRevision(current)
        }
    }
    /// Desktop parity: subscribe the backend's unarchived conversations so the
    /// list's running, approval and unread state updates without a refresh.
    /// Rows never opened have no runtime and project through `applyWatchedEvent`;
    /// a previously opened runtime sees the gap on its first new event and
    /// recovers in full, so only conversations with activity pay for replay.
    /// Runs one subscribe at a time so it never competes with an open one.
    private func watchConversations() {
        guard isConnected, let socket else { return }
        watchTask?.cancel()
        let current = revision
        let listed = Set(conversations.map(\.id))
        let stale = liveSubscriptions.filter { !listed.contains($0) }
        let targets = conversations
            .filter { $0.archivedAt == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { (id: $0.id, after: $0.lastSequence) }
        watchTask = Task { [weak self] in
            do {
                for id in stale {
                    guard let self, current == revision else { return }
                    liveSubscriptions.removeAll { $0 == id }
                    _ = try await socket.command(
                        type: "conversation.unsubscribe", payload: ["conversationId": .string(id)], timeout: 15,
                        id: UUID().uuidString)
                }
                for target in targets {
                    guard let self, current == revision, !Task.isCancelled else { return }
                    guard liveSubscriptions.count < Self.subscriptionBudget - Self.watchHeadroom else { return }
                    guard !liveSubscriptions.contains(target.id), recoveryTasks[target.id] == nil else { continue }
                    liveSubscriptions.append(target.id)
                    let result: JSONValue
                    do {
                        result = try await socket.command(
                            type: "conversation.subscribe",
                            payload: [
                                "conversationId": .string(target.id), "afterSequence": .number(Double(target.after)),
                                "limit": .number(Double(Self.watchBackfillLimit)), "detail": "summary",
                                "backfillLimit": .number(Double(Self.watchBackfillLimit)),
                            ],
                            timeout: 30, id: UUID().uuidString)
                    } catch {
                        if current == revision { liveSubscriptions.removeAll { $0 == target.id } }
                        throw error
                    }
                    guard current == revision else { return }
                    if !result["subscribed"].boolValue { liveSubscriptions.removeAll { $0 == target.id } }
                }
            } catch {
                // Watching is an optimization over the HTTP list: stop at the first
                // failure instead of hammering a limit or an outage, and say so.
                guard let self, current == revision, !(error is CancellationError) else { return }
                operationError = String(localized: "后台对话状态同步已暂停：\(error.localizedDescription)")
                changed()
            }
        }
    }
    private func replayPages(_ id: String, target: Int, api: APIClient, revision current: UUID) async throws {
        var highWater = target
        for _ in 0..<10_000 {
            try checkRevision(current)
            let before = runtimes[id]?.appliedSequence ?? 0
            let page = try await api.events(conversationId: id, after: before, limit: 200, detail: "summary")
            try checkRevision(current)
            try await ingestReplay(page, conversationId: id, revision: current)
            let runtime = runtimes[id] ?? ConversationRuntime(conversationId: id)
            highWater = max(
                highWater, runtime.highWaterSequence, Self.sequence(page["nextSequence"]) ?? 0,
                Self.sequence(page["lastSequence"]) ?? 0)
            if !page["hasMore"].boolValue, runtime.appliedSequence >= highWater { return }
            guard runtime.appliedSequence > before else { throw TodexError.invalid(String(localized: "历史记录存在缺口，请重新核对")) }
        }
        throw TodexError.invalid(String(localized: "历史分页过多，恢复未完成"))
    }
    /// Ingests one history page or subscribe backfill (`events` + `frames`).
    private func ingestReplay(_ page: JSONValue, conversationId: String, revision current: UUID) async throws {
        // A subscribe ACK without backfill has no `events`.
        guard !page["events"].isNull else { return }
        let events = try await receivedPage(page, conversationId: conversationId, sorted: false)
        try checkRevision(current)
        for event in events { ingest(event, frames: page["frames"]) }
    }
    /// Decodes a page's `events` (all of `conversationId`), optionally in
    /// sequence order, and decrypts them with the page's `frames`.
    private func receivedPage(_ page: JSONValue, conversationId: String, sorted: Bool = true) async throws
        -> [ReceivedEvent]
    {
        guard case .array(let values) = page["events"] else {
            throw TodexError.invalid(String(localized: "历史分页响应无效"))
        }
        var events: [ConversationEvent] = []
        for value in values {
            let event = try value.decoded(ConversationEvent.self)
            guard event.conversationId == conversationId else {
                throw TodexError.invalid(String(localized: "历史事件属于其他对话"))
            }
            events.append(event)
        }
        if sorted { events.sort { $0.sequence < $1.sequence } }
        return try await received(events, frames: page["frames"])
    }
    /// Pairs each event with its plaintext. Plain journals pass through
    /// without touching the history key.
    private func received(_ events: [ConversationEvent], frames: JSONValue) async throws -> [ReceivedEvent] {
        guard events.contains(where: { HistoryEncryption.isEncrypted($0.payload) }) else {
            return events.map { ReceivedEvent(raw: $0, plain: $0) }
        }
        for event in events where HistoryEncryption.isEncrypted(event.payload) {
            encryptedConversations.insert(event.conversationId)
        }
        let keys: HistoryDecryptor
        do { keys = try historyKeys() } catch {
            // No usable device key (Keychain unavailable): the content stays
            // locked, the journal still advances, and the reason is shown.
            operationError = error.localizedDescription
            changed()
            return events.map { event in
                var locked = event
                if HistoryEncryption.isEncrypted(event.payload) {
                    locked.payload = HistoryEncryption.lockedPayload(event.payload)
                }
                return ReceivedEvent(raw: event, plain: locked)
            }
        }
        // Key lookups that fail in transit throw: the page is retried rather
        // than recorded as locked.
        let plain = try await keys.decrypt(events, frames: frames)
        return zip(events, plain).map { ReceivedEvent(raw: $0, plain: $1) }
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
    /// `nativeQueue: false` keeps a busy-time follow-up in the local queue: the
    /// agent's own queue carries text only, so a draft that depends on changed
    /// composer settings (e.g. `/plan <task>`) must wait for a real prompt.
    func send(
        _ draft: ComposerDraft, in conversation: ConversationManifest, enqueueWhenBusy: Bool = true,
        nativeQueue: Bool = true
    ) async throws {
        try await send(draft, in: conversation, enqueueWhenBusy: enqueueWhenBusy, queued: nil, nativeQueue: nativeQueue)
    }
    private func send(
        _ draft: ComposerDraft, in conversation: ConversationManifest, enqueueWhenBusy: Bool, queued: QueuedDraft?,
        nativeQueue: Bool = true
    ) async throws {
        let id = conversation.id
        let current = revision
        guard !draft.isEmpty else { return }
        guard stateLoaded else { throw TodexError.invalid(storageError ?? String(localized: "本地草稿仍在加载")) }
        guard let socket, isConnected else { throw TodexError.disconnected }
        guard conversations.contains(where: { $0.id == id && $0.workspace == conversation.workspace }) else {
            throw TodexError.invalid(String(localized: "对话已切换，请重新打开"))
        }
        guard pendingSends[id] == nil, sending[id] == nil else { throw TodexError.unknownOutcome(String(localized: "已有消息等待核对")) }
        guard let runtime = runtimes[id], runtime.readyForActions else { throw TodexError.invalid(String(localized: "请等待历史记录同步完成")) }
        if ["running", "waitingPermission", "waiting_permission"].contains(runtime.status) {
            guard enqueueWhenBusy else { throw TodexError.server(code: "CONFLICT", message: String(localized: "当前任务尚未结束")) }
            // The daemon holds follow-ups (attachments and skills included)
            // and starts them itself once the turn completes.
            if hasBackendQueue(conversation) {
                _ = try await queueFollowUp(draft, itemId: UUID().uuidString, conversation: conversation)
                try checkRevision(current)
                if drafts[id] == draft { drafts[id] = ComposerDraft() }
                persist()
                changed(immediate: true)
                return
            }
            // Desktop parity: a plain-text follow-up goes to the agent's own
            // queue when the provider has one; attachments and skills can only
            // travel through a prompt, so they wait in the local queue.
            // Only while nothing waits locally, or it would overtake earlier drafts.
            if nativeQueue, provider(for: conversation)?.capabilities["followUpQueue"].boolValue == true,
                draft.attachments.isEmpty, draft.skills.isEmpty, (queues[id] ?? []).isEmpty
            {
                _ = try await liveControl(
                    ["action": "queueAdd", "itemId": .string(UUID().uuidString), "text": .string(draft.text)],
                    conversation: conversation)
                try checkRevision(current)
                if drafts[id] == draft { drafts[id] = ComposerDraft() }
                persist()
                changed(immediate: true)
                return
            }
            guard (queues[id]?.count ?? 0) < 32 else { throw TodexError.invalid(String(localized: "候选消息最多 32 条")) }
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
        let payload = try promptPayload(draft, conversation: conversation)
        let requestID = UUID().uuidString
        if !draft.attachments.isEmpty {
            sentAttachments.append(
                SentAttachmentRecord(
                    conversationId: id, requestId: requestID, text: draft.text,
                    attachments: Self.prepareSentAttachments(draft.attachments)))
            pruneSentAttachments()
        }
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
        } catch let sendError {
            guard current == revision else { throw CancellationError() }
            var error = sendError
            // The backend was busy after all (a turn started below the loaded
            // window, or on another device): queue the prompt there under the
            // same id instead of reporting the conflict.
            if submitted, case TodexError.server(code: "CONFLICT", _) = sendError, hasBackendQueue(conversation),
                pendingSends[id]?.requestId == requestID
            {
                do {
                    try await queueFollowUp(draft, itemId: requestID, conversation: conversation)
                    guard current == revision else { throw CancellationError() }
                    if pendingSends[id]?.requestId == requestID { pendingSends.removeValue(forKey: id) }
                    persist()
                    changed(immediate: true)
                    return
                } catch let queueError {
                    guard current == revision else { throw CancellationError() }
                    error = queueError
                }
            }
            if pendingSends[id]?.requestId == requestID {
                if !submitted || Self.knownRejection(error) {
                    pendingSends.removeValue(forKey: id)
                    sentAttachments.removeAll { $0.conversationId == id && $0.requestId == requestID }
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
    /// `conversation.prompt` fields shared by direct sends and backend queue items.
    private func promptPayload(_ draft: ComposerDraft, conversation: ConversationManifest) throws -> JSONValue {
        let pref = preferences(for: conversation)
        let modes =
            provider(for: conversation)?.capabilities["permissionConfig"]["modes"].arrayValue.compactMap(\.optionalString)
            ?? []
        guard modes.isEmpty || modes.contains(pref.permissionMode) else {
            throw TodexError.invalid(String(localized: "当前 Agent 不支持所选权限模式，请重新选择权限"))
        }
        var payload: JSONValue = [
            "conversationId": .string(conversation.id), "text": .string(draft.text),
            "content": .array(
                draft.attachments
                    .filter { draft.text.contains($0.token) }
                    .map(\.wireValue)),
            "skills": .array(draft.skills.map { ["resourceId": .string($0.id), "name": .string($0.name)] }),
            "permissionMode": .string(pref.permissionMode), "workMode": .string(pref.workMode),
        ]
        if !pref.model.isEmpty { payload["model"] = .string(pref.model) }
        if !pref.reasoningEffort.isEmpty { payload["reasoningEffort"] = .string(pref.reasoningEffort) }
        return payload
    }
    /// The connected backend holds this conversation's follow-ups
    /// (`conversation.queue.*`) instead of the local candidate queue.
    func hasBackendQueue(_ conversation: ConversationManifest) -> Bool {
        provider(for: conversation)?.capabilities["backendQueue"].boolValue == true
    }
    /// Adds a follow-up to the backend queue. The item id is also the prompt's
    /// clientRequestId, so re-adding after a lost ACK or a relaunch never runs
    /// it twice. An idle conversation starts it at once (`status: started`).
    @discardableResult
    private func queueFollowUp(_ draft: ComposerDraft, itemId: String, conversation: ConversationManifest)
        async throws -> JSONValue
    {
        var payload = try promptPayload(draft, conversation: conversation)
        payload["itemId"] = .string(itemId)
        if !draft.attachments.isEmpty,
            !sentAttachments.contains(where: { $0.conversationId == conversation.id && $0.requestId == itemId })
        {
            sentAttachments.append(
                SentAttachmentRecord(
                    conversationId: conversation.id, requestId: itemId, text: draft.text,
                    attachments: Self.prepareSentAttachments(draft.attachments)))
            pruneSentAttachments()
        }
        return try await command("conversation.queue.add", payload, timeout: 45)
    }
    /// Reads the backend queue into the runtime; the loaded window may not hold
    /// its latest `followups.updated`.
    func refreshFollowUps(_ conversation: ConversationManifest) async {
        guard hasBackendQueue(conversation), isConnected else { return }
        do {
            let result = try await command("conversation.queue.list", ["conversationId": .string(conversation.id)], timeout: 15)
            runtimes[conversation.id]?.adoptFollowUpQueue(result["queue"])
            changed()
        } catch {
            DebugLog.record("followups.list.failed", ["error": String(describing: error)], level: .error)
            operationError = error.localizedDescription
            changed()
        }
    }
    /// Removes one item from, clears, or resumes the backend queue.
    func editFollowUps(_ operation: String, itemId: String? = nil, conversation: ConversationManifest) async throws {
        var payload: JSONValue = ["conversationId": .string(conversation.id)]
        if let itemId { payload["itemId"] = .string(itemId) }
        let result = try await command("conversation.queue.\(operation)", payload, timeout: 15)
        runtimes[conversation.id]?.adoptFollowUpQueue(result["queue"])
        changed()
    }
    /// Moves local candidates (restored after a relaunch, or queued while the
    /// backend's capabilities were unknown) into the backend queue, in order,
    /// once the local queue is resumed; restarts and disconnects still pause it.
    /// The backend then decides when each one runs, busy or not.
    private func handOverQueue(_ id: String, conversation: ConversationManifest) {
        guard isConnected, !pausedQueues.contains(id), queueDispatches[id] == nil, !(queues[id] ?? []).isEmpty
        else { return }
        let current = revision
        let token = UUID()
        queueDispatches[id] = token
        Task { [weak self] in
            guard let self, current == revision, queueDispatches[id] == token else { return }
            defer { if current == revision, queueDispatches[id] == token { queueDispatches.removeValue(forKey: id) } }
            while let first = queues[id]?.first {
                do {
                    try await queueFollowUp(first.draft, itemId: first.id, conversation: conversation)
                } catch {
                    guard current == revision else { return }
                    pausedQueues.insert(id)
                    if !(error is CancellationError) { operationError = error.localizedDescription }
                    persist()
                    changed()
                    return
                }
                guard current == revision else { return }
                queues[id]?.removeAll { $0.id == first.id }
                persist()
                changed()
            }
        }
    }
    /// Receipts for one conversation, oldest first, for the timeline to join
    /// against user entries via payload.clientRequestId.
    func sentAttachments(for conversationId: String) -> [SentAttachmentRecord] {
        sentAttachments.filter { $0.conversationId == conversationId }
    }
    private static func imagePreview(_ data: Data) -> String? {
        // The macOS session-test package has no UIKit; receipts keep metadata only.
        #if canImport(UIKit)
            guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0
            else { return nil }
            for edge in [640.0, 480, 320, 160] {
                let scale = min(1, edge / max(image.size.width, image.size.height))
                let size = CGSize(
                    width: max(1, (image.size.width * scale).rounded()),
                    height: max(1, (image.size.height * scale).rounded()))
                let rendered = UIGraphicsImageRenderer(size: size).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                guard let jpeg = rendered.jpegData(compressionQuality: 0.75), jpeg.count <= 100 * 1024
                else { continue }
                return "data:image/jpeg;base64," + jpeg.base64EncodedString()
            }
        #endif
        return nil
    }
    /// A broken image still leaves a receipt row; only the thumbnail is dropped.
    private static func prepareSentAttachments(_ attachments: [MessageAttachment]) -> [SentAttachment] {
        attachments.map { item in
            SentAttachment(
                id: item.id, kind: item.isImage ? "image" : "file", name: item.name,
                mimeType: item.mimeType, sizeBytes: item.data.count,
                preview: item.isImage ? imagePreview(item.data) : nil,
                textContent: item.isImage
                    ? nil : String(decoding: item.data.prefix(100 * 1024), as: UTF8.self))
        }
    }
    /// Recent 150 records; previews and text are evicted oldest-first past a
    /// shared 2 MB budget.
    private func pruneSentAttachments() {
        if sentAttachments.count > 150 { sentAttachments.removeFirst(sentAttachments.count - 150) }
        var remaining = 2 * 1024 * 1024
        for index in sentAttachments.indices.reversed() {
            for attachment in sentAttachments[index].attachments.indices {
                let item = sentAttachments[index].attachments[attachment]
                let bytes = (item.preview?.utf8.count ?? 0) + (item.textContent?.utf8.count ?? 0)
                if bytes > remaining {
                    sentAttachments[index].attachments[attachment].preview = nil
                    sentAttachments[index].attachments[attachment].textContent = nil
                } else {
                    remaining -= bytes
                }
            }
        }
    }
    func reconcile(_ id: String) async throws {
        let current = revision
        try await recover(id)
        try checkRevision(current)
        // A lazily opened window may end above the pending send's events; page
        // backward until the clientRequestId match resolves it or the journal
        // head is reached.
        while pendingSends[id] != nil, hasEarlierHistory(id) {
            try await loadEarlier(id)
            try checkRevision(current)
        }
        if pendingSends[id] != nil { throw TodexError.unknownOutcome(String(localized: "完整记录中仍未找到这次请求，原消息保留在待核对区")) }
    }
    func restoreUnknownAsDraft(_ id: String) {
        guard sending[id] == nil, let pending = pendingSends[id] else { return }
        guard drafts[id]?.isEmpty != false else {
            operationError = String(localized: "输入框已有草稿，请先保留它再恢复待核对消息")
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
        if let conversation = conversations.first(where: { $0.id == id }), hasBackendQueue(conversation) {
            handOverQueue(id, conversation: conversation)
            return
        }
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
        // Adapter approvals carry the sidecar's session on `runtimeId` and go
        // through `codex.local.approval.respond`; the conversation-level
        // `conversation.permission.respond` would misroute them.
        if permission.runtimeId.hasPrefix("codex-local:") {
            let sessionId = String(permission.runtimeId.dropFirst("codex-local:".count))
            guard let conversation = conversations.first(where: { CodexLocal.sessionId(for: $0.id) == sessionId }),
                let workspace = workspace(for: conversation)
            else { throw TodexError.invalid(String(localized: "审批已失效，请同步当前记录")) }
            let codex = permission.payload["codex"]
            _ = try await command(
                "codex.local.approval.respond",
                CodexLocal.approvalRespondPayload(
                    sessionId: sessionId, tenantId: workspace.tenantId,
                    requestId: codex["requestId"].stringValue.isEmpty ? permission.id : codex["requestId"].stringValue,
                    requestType: codex["requestType"].stringValue,
                    request: permission.payload["details"], decision: decision),
                timeout: 15)
            var resolved = CodexLocal.Effects()
            resolved.resolvedRequests = [permission.id]
            _ = runtimes[conversation.id]?.applyLocal(resolved)
            changed()
            return
        }
        guard let runtime = runtimes[conversationId], runtime.readyForActions,
            runtime.pendingPermissions.contains(where: { $0.id == permission.id && $0.turnId == permission.turnId })
        else { throw TodexError.invalid(String(localized: "审批已失效，请同步当前记录")) }
        _ = try await command(
            "conversation.permission.respond",
            ["conversationId": .string(conversationId), "permissionId": .string(permission.id), "decision": decision])
    }
    func control(_ action: String, conversation: ConversationManifest) async throws -> JSONValue {
        guard runtimes[conversation.id]?.readyForActions == true else { throw TodexError.invalid(String(localized: "请等待历史记录同步完成")) }
        guard provider(for: conversation)?.capabilities["controlActions"].arrayValue.contains(.string(action)) == true
        else { throw TodexError.invalid(String(localized: "当前 Agent 不支持此操作")) }
        var payload: JSONValue = ["conversationId": .string(conversation.id)]
        // An e2e backend cannot read the last prompt back; retry sends the
        // decrypted original text (history v3 §7). Only the newest user
        // message will do: when a locked run is newer, an older prompt would
        // just be refused (CONFLICT), so say why instead.
        if action == "retry", historyEncryption?.isEnabled == true || encryptedConversations.contains(conversation.id) {
            guard
                let latest = runtimes[conversation.id]?.messages.first(where: {
                    $0.role == "user" || $0.category == ConversationRuntime.lockedCategory
                }),
                latest.role == "user", !latest.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw TodexError.invalid(String(localized: "此设备读不到上一轮的原始消息，无法重试")) }
            payload["prompt"] = .string(latest.text)
        }
        return try await command("conversation.\(action)", payload, timeout: action == "compact" ? 310 : 45)
    }

    // MARK: - History encryption (history v3, docs/history-encryption.md)

    /// The manifest with its encrypted title shown, once decrypted.
    private func presentable(_ manifest: ConversationManifest) -> ConversationManifest {
        guard let ciphertext = manifest.titleEnc?["ct"].optionalString, let title = decryptedTitles[ciphertext]
        else { return manifest }
        var shown = manifest
        shown.title = title
        return shown
    }

    /// Decrypts `manifest.titleEnc` of listed conversations in the background.
    private func decryptTitles() {
        let pending = conversations.filter { conversation in
            guard let ciphertext = conversation.titleEnc?["ct"].optionalString else { return false }
            return decryptedTitles[ciphertext] == nil
        }
        guard !pending.isEmpty, isConnected else { return }
        let current = revision
        Task { [weak self] in
            guard let self else { return }
            let keys: HistoryDecryptor
            do { keys = try historyKeys() } catch {
                operationError = error.localizedDescription
                changed()
                return
            }
            for conversation in pending {
                guard let titleEnc = conversation.titleEnc else { continue }
                let title: String?
                do { title = try await keys.decryptTitle(titleEnc, conversationId: conversation.id) } catch {
                    // A lookup failed in transit; the next refresh tries again.
                    DebugLog.record("history.title.failed", ["error": String(describing: error)], level: .warn)
                    return
                }
                guard current == revision else { return }
                guard let title else { continue }
                decryptedTitles[titleEnc["ct"].stringValue] = title
                if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                    conversations[index] = presentable(conversations[index])
                }
                changed()
            }
        }
    }

    /// This backend profile's decryptor, created with the device history key
    /// on first need. Wrapped keys are fetched over whichever socket is live.
    private func historyKeys() throws -> HistoryDecryptor {
        if let historyDecryptor { return historyDecryptor }
        guard let connection else { throw TodexError.disconnected }
        let seed = try historySeed(for: connection.id)
        let deviceRid = try HistoryCrypto.recipientID(
            publicKey: HistoryCrypto.recipientKey(seed: seed).publicKey.rawRepresentation)
        let keys = try HistoryDecryptor(deviceSeed: seed) { [weak self] conversationId, kids, rid in
            guard let api = await self?.historyAPI() else { throw TodexError.disconnected }
            // The device's own wraps use the default (caller) recipient.
            return try await api.wraps(conversationId: conversationId, kids: kids, rid: rid == deviceRid ? nil : rid)
        }
        historyDecryptor = keys
        return keys
    }

    /// The device history seed (Keychain, this device only), generated once.
    private func historySeed(for id: String) throws -> Data {
        if let seed = try historySeeds.load(id) { return seed }
        let seed = try HistoryCrypto.generateRecipientKey().seedRepresentation
        try historySeeds.save(seed, id)
        return seed
    }

    private func historyAPI() -> HistoryAPI? {
        guard let socket, isConnected else { return nil }
        return HistoryAPI { type, payload in
            try await socket.command(type: type, payload: payload, timeout: 30, id: UUID().uuidString)
        }
    }

    /// This device's recipient id on the current backend, once its key exists.
    var historyDeviceRecipientID: String? {
        historyDecryptor.map { HistoryEncryption.encodeID($0.deviceRecipientID) }
    }

    /// After connecting: learn the backend's mode and register this device.
    /// Backends without history encryption reject the command; that is quiet.
    private func probeHistoryEncryption() {
        historyProbe?.cancel()
        let current = revision
        historyProbe = Task { [weak self] in
            do { try await self?.refreshHistoryEncryption() } catch {
                guard let self, current == revision, !(error is CancellationError) else { return }
                DebugLog.record("history.probe.failed", ["error": String(describing: error)], level: .info)
            }
        }
    }

    /// Reads the history-encryption state and registers this device's public
    /// key when the backend does not list it (first use, or a replaced key).
    @discardableResult
    func refreshHistoryEncryption() async throws -> HistoryEncryptionState {
        guard let api = historyAPI(), let connection else { throw TodexError.disconnected }
        let current = revision
        var state: HistoryEncryptionState
        do { state = try await api.state() } catch {
            if current == revision {
                historyEncryption = nil
                changed()
            }
            throw error
        }
        try checkRevision(current)
        // Registration binds the key to the connection's enrolled device id.
        if !connection.deviceSecret.isEmpty {
            let keys = try historyKeys()
            if state.myRid != HistoryEncryption.encodeID(keys.deviceRecipientID) {
                _ = try await api.register(publicKey: keys.devicePublicKey)
                try checkRevision(current)
                state = try await api.state()
                try checkRevision(current)
            }
        }
        historyEncryption = state
        changed()
        return state
    }

    /// Turns e2e on (after uploading the optional recovery public key, so the
    /// first keys are wrapped for it too) or off.
    func setHistoryEncryption(enabled: Bool, recoverySeed: Data? = nil) async throws {
        guard let api = historyAPI() else { throw TodexError.disconnected }
        let current = revision
        let state: HistoryEncryptionState
        if enabled {
            try await refreshHistoryEncryption()
            if let recoverySeed {
                _ = try await api.setRecovery(
                    publicKey: HistoryCrypto.recipientKey(seed: recoverySeed).publicKey.rawRepresentation)
            }
            state = try await api.enable()
        } else {
            state = try await api.disable()
        }
        try checkRevision(current)
        historyEncryption = state
        changed()
    }

    /// Replaces the recovery recipient with a new key's public half.
    func replaceRecoveryKey(seed: Data) async throws {
        guard let api = historyAPI() else { throw TodexError.disconnected }
        _ = try await api.setRecovery(publicKey: HistoryCrypto.recipientKey(seed: seed).publicKey.rawRepresentation)
        try await refreshHistoryEncryption()
    }

    func revokeHistoryRecipient(_ rid: String) async throws {
        guard let api = historyAPI() else { throw TodexError.disconnected }
        let current = revision
        let state = try await api.revoke(rid: rid)
        try checkRevision(current)
        historyEncryption = state
        changed()
    }

    /// Asks an authorized device for access to history from before this
    /// device registered.
    func requestHistoryGrant() async throws {
        guard let api = historyAPI() else { throw TodexError.disconnected }
        try await refreshHistoryEncryption()
        _ = try await api.requestGrant()
        try await refreshHistoryEncryption()
    }

    func dismissHistoryGrant(_ grantId: String) async throws {
        guard let api = historyAPI() else { throw TodexError.disconnected }
        try await api.dismissGrant(grantId)
        defaults.removeObject(forKey: key("history-grant-\(grantId)"))
        try await refreshHistoryEncryption()
    }

    /// Re-wraps every key this device can read for the requesting device.
    /// Progress is saved after each committed page, so a later call resumes.
    func authorizeHistoryGrant(
        _ grant: HistoryGrantRequest, progress: @escaping @MainActor (HistoryGrant.Progress) -> Void
    ) async throws -> HistoryGrant.Progress {
        guard let api = historyAPI(), let connection else { throw TodexError.disconnected }
        let state = try await refreshHistoryEncryption()
        guard let target = grant.recipient ?? state.recipients.first(where: { $0.rid == grant.rid && !$0.isRevoked })
        else {
            throw TodexError.invalid(String(localized: "请求授权的设备尚未登记历史密钥，或已被吊销"))
        }
        guard !state.recipients.contains(where: { $0.rid == grant.rid && $0.isRevoked }), grant.isPending else {
            throw TodexError.invalid(String(localized: "请求授权的设备尚未登记历史密钥，或已被吊销"))
        }
        let source = try HistoryCrypto.recipientKey(seed: historySeed(for: connection.id))
        let resumeKey = key("history-grant-\(grant.grantId)")
        let resume = defaults.data(forKey: resumeKey).flatMap { try? JSONDecoder().decode(HistoryGrant.Progress.self, from: $0) }
        let result = try await HistoryGrant.fulfill(
            api: api, grantId: grant.grantId, target: target, source: source, sourceRid: nil, resume: resume
        ) { [weak self] value in
            await self?.recordGrantProgress(value, key: resumeKey)
            await progress(value)
        }
        defaults.removeObject(forKey: resumeKey)
        try await refreshHistoryEncryption()
        return result
    }

    private func recordGrantProgress(_ value: HistoryGrant.Progress, key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    /// Imports the recovery key (24 words or QR text) and grants this device
    /// every key the recovery recipient holds (a self-grant without grantId).
    /// The recovery seed is used in memory only and never stored.
    func importRecoveryKey(
        _ seed: Data, progress: @escaping @MainActor (HistoryGrant.Progress) -> Void
    ) async throws -> HistoryGrant.Progress {
        guard let api = historyAPI() else { throw TodexError.disconnected }
        let state = try await refreshHistoryEncryption()
        let recovery = try HistoryCrypto.recipientKey(seed: seed)
        let recoveryRid = try HistoryCrypto.recipientID(publicKey: recovery.publicKey.rawRepresentation)
        guard state.activeRecovery?.rid == HistoryEncryption.encodeID(recoveryRid) else {
            throw TodexError.invalid(String(localized: "此恢复密钥与后端当前登记的恢复密钥不一致"))
        }
        guard let mine = state.recipients.first(where: { $0.rid == state.myRid && !$0.isRevoked }) else {
            throw TodexError.invalid(String(localized: "此设备尚未登记历史密钥，请先完成设备配对"))
        }
        let keys = try historyKeys()
        try await keys.setRecoverySeed(seed)
        let result: HistoryGrant.Progress
        do {
            result = try await HistoryGrant.fulfill(
                api: api, grantId: nil, target: mine, source: recovery, sourceRid: recoveryRid
            ) { value in await progress(value) }
        } catch {
            try? await keys.setRecoverySeed(nil)
            throw error
        }
        try? await keys.setRecoverySeed(nil)
        await reloadDecryptedHistory()
        return result
    }

    /// Re-reads locked history after new keys arrived: forget unavailable
    /// keys and rebuild encrypted conversations from the ciphertext cache
    /// and the backend. The open conversation recovers at once.
    func reloadDecryptedHistory() async {
        await historyDecryptor?.forgetUnavailable()
        decryptTitles()
        for id in encryptedConversations where recoveryTasks[id] == nil && runtimes[id] != nil {
            runtimes[id] = id == activeConversationID ? ConversationRuntime(conversationId: id) : nil
            historyFloors.removeValue(forKey: id)
            earlierLoading.removeValue(forKey: id)
            cacheLoaded.remove(id)
        }
        changed(immediate: true)
        guard let id = activeConversationID, runtimes[id] != nil, isConnected else { return }
        do { try await recover(id) } catch { /* recover reports once for all waiters. */ }
    }
    /// Desktop-parity fork from the list: unlike `control`, it needs no replayed
    /// runtime, so a never-opened conversation can be forked. The copy inherits
    /// the source's composer preferences, as on desktop.
    func fork(_ conversation: ConversationManifest) async throws -> ConversationManifest {
        guard provider(for: conversation)?.capabilities["controlActions"].arrayValue.contains("fork") == true else {
            throw TodexError.invalid(String(localized: "当前 Agent 未提供已验证的原生分叉能力。"))
        }
        let busy = ["running", "waitingPermission", "waiting_permission"]
        let statuses = [runtimes[conversation.id]?.status, conversations.first { $0.id == conversation.id }?.status]
        guard !statuses.contains(where: { busy.contains($0 ?? "") }) else {
            throw TodexError.invalid(String(localized: "请先结束当前任务再分叉对话。"))
        }
        let title = conversation.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let result = try await command(
            "conversation.fork",
            [
                "conversationId": .string(conversation.id),
                "title": .string(String(localized: "\(title.isEmpty ? String(localized: "对话") : title) · 分叉")),
            ], timeout: 45)
        guard let id = result["conversationId"].optionalString, !id.isEmpty else {
            throw TodexError.invalid(String(localized: "分叉已响应，但未返回新对话标识，请刷新对话列表核对。"))
        }
        try await refresh()
        guard let created = conversations.first(where: { $0.id == id }) else {
            throw TodexError.invalid(String(localized: "分叉已完成，但新对话尚未出现在列表中，请刷新核对。"))
        }
        if let source = preferences[conversation.id] { updatePreferences(source, for: created) }
        return created
    }
    func liveControl(_ control: JSONValue, conversation: ConversationManifest) async throws -> JSONValue {
        guard let runtime = runtimes[conversation.id], runtime.readyForActions, !runtime.activeTurnId.isEmpty else {
            throw TodexError.invalid(String(localized: "没有已同步的运行任务"))
        }
        return try await command(
            "conversation.control",
            [
                "conversationId": .string(conversation.id), "expectedTurnId": .string(runtime.activeTurnId),
                "control": control,
            ])
    }

    // MARK: - Codex local adapter sidecar (desktop `codex.local.*` parity)

    /// Snapshot the UI reads; `threadId` falls back to the persisted value so
    /// a freshly launched app still knows which thread the adapter owns.
    func sidecar(for conversationId: String) -> CodexLocalSidecar {
        var state = sidecars[conversationId] ?? CodexLocalSidecar()
        if state.threadId.isEmpty { state.threadId = localThreads[conversationId] ?? "" }
        return state
    }
    /// Codex-only gate for the slash table: the sidecar talks to the Codex
    /// app-server, so other providers must not see these commands fire.
    func supportsLocalAdapter(_ conversation: ConversationManifest) -> Bool {
        conversation.provider == "codex"
    }
    private func localWorkspace(_ conversation: ConversationManifest) throws -> WorkspaceRecord {
        guard let workspace = workspace(for: conversation) else {
            throw TodexError.invalid(String(localized: "找不到对话所属工作区"))
        }
        return workspace
    }

    /// `startLocalAdapter`: lazily boots the adapter process; concurrent
    /// callers share one flight and an "adapter already owns this session"
    /// response counts as success because the goal state is reached.
    @discardableResult
    func ensureLocalAdapter(_ conversation: ConversationManifest) async throws -> CodexLocalSidecar {
        let id = conversation.id
        var sidecar = sidecars[id] ?? CodexLocalSidecar()
        if sidecar.threadId.isEmpty { sidecar.threadId = localThreads[id] ?? "" }
        if sidecar.phase == .running { return sidecar }
        if let task = sidecarStarts[id] {
            try await task.value
            return self.sidecar(for: id)
        }
        sidecar.phase = .starting
        sidecar.lastError = ""
        sidecars[id] = sidecar
        changed()
        let task = Task<Void, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            let workspace = try localWorkspace(conversation)
            sidecars[id]?.tenantId = workspace.tenantId
            let remembered = lastPreferencesByProvider["codex"] ?? ConversationPreferences()
            do {
                _ = try await command(
                    "codex.local.start",
                    CodexLocal.startPayload(
                        sessionId: CodexLocal.sessionId(for: id), workspace: workspace,
                        defaults: (
                            model: remembered.model, reasoningEffort: remembered.reasoningEffort,
                            approvalsReviewer: "")),
                    timeout: 30)
            } catch {
                // The session survived an app restart or a desktop client owns it.
                guard CodexLocal.isAlreadyRunning(error.localizedDescription) else { throw error }
            }
        }
        sidecarStarts[id] = task
        defer { sidecarStarts.removeValue(forKey: id) }
        do {
            try await task.value
            if sidecars[id]?.phase == .starting { sidecars[id]?.phase = .running }
            changed()
            return self.sidecar(for: id)
        } catch {
            sidecars[id]?.phase = .error
            sidecars[id]?.lastError = CodexLocal.describeError(error.localizedDescription)
            changed()
            throw error
        }
    }

    /// `ensureThreadId`: first call runs `thread/start`; later calls reuse the
    /// stored id. `forceNew` drops it first (desktop clears the field).
    @discardableResult
    func ensureLocalThread(_ conversation: ConversationManifest, forceNew: Bool = false) async throws -> String {
        try await ensureLocalAdapter(conversation)
        let id = conversation.id
        if forceNew {
            sidecars[id]?.threadId = ""
            localThreads.removeValue(forKey: id)
        }
        if let threadId = sidecars[id]?.threadId, !threadId.isEmpty { return threadId }
        if let stored = localThreads[id], !stored.isEmpty {
            sidecars[id]?.threadId = stored
            return stored
        }
        if let task = localThreadStarts[id] { return try await task.value }
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            let workspace = try localWorkspace(conversation)
            let remembered = lastPreferencesByProvider["codex"] ?? ConversationPreferences()
            let result = try await command(
                "codex.local.request",
                CodexLocal.requestPayload(
                    sessionId: CodexLocal.sessionId(for: id), tenantId: workspace.tenantId,
                    method: "thread/start",
                    params: CodexLocal.threadStartParams(
                        workspace: workspace,
                        defaults: (
                            model: remembered.model, reasoningEffort: remembered.reasoningEffort,
                            approvalPolicy: "", approvalsReviewer: "", sandboxMode: ""))),
                timeout: 60)
            let threadId = CodexLocal.threadId(in: result)
            guard !threadId.isEmpty else {
                throw TodexError.unknownOutcome(String(localized: "本地线程已创建但未返回标识"))
            }
            return threadId
        }
        localThreadStarts[id] = task
        defer { localThreadStarts.removeValue(forKey: id) }
        let threadId = try await task.value
        sidecars[id]?.threadId = threadId
        localThreads[id] = threadId
        saveSoon()
        changed()
        return threadId
    }

    /// `sendLocalMethodRequest`: `codex.local.request` on the conversation's
    /// adapter session. Starts the adapter first when needed.
    @discardableResult
    func localRequest(
        _ method: String, params: JSONValue? = nil, in conversation: ConversationManifest,
        timeout: TimeInterval = 30
    ) async throws -> JSONValue {
        try await ensureLocalAdapter(conversation)
        let workspace = try localWorkspace(conversation)
        return try await command(
            "codex.local.request",
            CodexLocal.requestPayload(
                sessionId: CodexLocal.sessionId(for: conversation.id), tenantId: workspace.tenantId,
                method: method, params: params),
            timeout: timeout)
    }

    /// `sendThreadMethod`/`sendNativeThreadAction` folded together: ensure the
    /// adapter thread exists, then call `method` with `threadId` merged into
    /// `params`. `requireExisting` matches desktop's action table — fork,
    /// resume, rollback and unsubscribe never create a thread implicitly.
    @discardableResult
    func localThreadRequest(
        _ method: String, params: JSONValue? = nil, in conversation: ConversationManifest,
        requireExisting: Bool = false, timeout: TimeInterval = 30
    ) async throws -> JSONValue {
        try await ensureLocalAdapter(conversation)
        let id = conversation.id
        if requireExisting, sidecar(for: id).threadId.isEmpty {
            throw TodexError.invalid(String(localized: "当前对话没有可恢复的本地线程"))
        }
        let threadId = try await ensureLocalThread(conversation)
        var body = params ?? .object([:])
        body["threadId"] = .string(threadId)
        return try await localRequest(method, params: body, in: conversation, timeout: timeout)
    }

    /// `sendLocalTurn` (desktop): submits an adapter turn for /init, /review
    /// targets and side threads. Mirrors the unified composer's permission
    /// preset so the sidecar obeys the same mode the user picked.
    func sendLocalTurn(
        _ text: String, in conversation: ConversationManifest, workMode: String? = nil
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TodexError.invalid(String(localized: "内容为空")) }
        let pref = preferences(for: conversation)
        let workspace = try localWorkspace(conversation)
        guard let preset = CodexLocal.PermissionPreset.forMode(pref.permissionMode) else {
            throw TodexError.invalid(String(localized: "当前权限模式无法用于本地 Codex 会话"))
        }
        let threadId = try await ensureLocalThread(conversation)
        let current = revision
        _ = try await command(
            "codex.local.turn",
            CodexLocal.turnPayload(
                sessionId: CodexLocal.sessionId(for: conversation.id), tenantId: workspace.tenantId,
                threadId: threadId, input: CodexLocal.inputItems(text: trimmed, images: []),
                preset: preset, workMode: workMode ?? pref.workMode,
                model: pref.model.isEmpty ? workspace.model : pref.model,
                reasoningEffort: pref.reasoningEffort.isEmpty
                    ? (workspace.reasoningEffort ?? "") : pref.reasoningEffort,
                serviceTier: workspace.serviceTier),
            timeout: 45)
        try checkRevision(current)
    }

    /// `codex.local.interrupt`: stops the adapter turn, not the unified one —
    /// `/interrupt` on desktop targets the sidecar thread.
    func interruptLocal(_ conversation: ConversationManifest) async throws {
        let sidecar = sidecar(for: conversation.id)
        guard !sidecar.threadId.isEmpty else {
            throw TodexError.invalid(String(localized: "当前对话没有运行中的本地任务"))
        }
        let workspace = try localWorkspace(conversation)
        _ = try await command(
            "codex.local.interrupt",
            CodexLocal.interruptPayload(
                sessionId: CodexLocal.sessionId(for: conversation.id), tenantId: workspace.tenantId,
                threadId: sidecar.threadId, turnId: sidecar.turnId),
            timeout: 15)
    }

    /// `codex.local.stop`: ends the adapter process (`/stop`, `/quit`,
    /// `/exit`, conversation removal). The thread id stays — `thread/resume`
    /// can reopen it after a fresh start.
    func stopLocal(_ conversation: ConversationManifest, force: Bool = false) async throws {
        let workspace = try localWorkspace(conversation)
        let id = conversation.id
        _ = try await command(
            "codex.local.stop",
            CodexLocal.stopPayload(
                sessionId: CodexLocal.sessionId(for: id), tenantId: workspace.tenantId, force: force),
            timeout: 15)
        sidecars[id]?.phase = .stopped
        sidecars[id]?.turnId = ""
        runtimes[id]?.clearLocalPermissions(sessionId: CodexLocal.sessionId(for: id))
        changed()
    }

    /// `codex.local.status`: `/status` without a subcommand.
    func localStatus(_ conversation: ConversationManifest) async throws -> JSONValue {
        let workspace = try localWorkspace(conversation)
        return try await command(
            "codex.local.status",
            CodexLocal.statusPayload(
                sessionId: CodexLocal.sessionId(for: conversation.id), tenantId: workspace.tenantId),
            timeout: 15)
    }

    /// `codex.local.attach` republishes events after the persisted cursor.
    /// The backend never sends a correlated ack (RealtimeClient marks it
    /// unresolvable), so a timeout equals success; other errors propagate.
    func attachLocal(_ conversation: ConversationManifest) async throws {
        let workspace = try localWorkspace(conversation)
        let sessionId = CodexLocal.sessionId(for: conversation.id)
        do {
            _ = try await command(
                "codex.local.attach",
                CodexLocal.attachPayload(
                    sessionId: sessionId, tenantId: workspace.tenantId,
                    afterCursor: legacyCursors[sessionId]),
                timeout: 10)
        } catch TodexError.invalid { /* no correlated ack — timing out is the end */ }
    }

    /// `codex.local.replay` (`/replay`): refetches the recent event window
    /// from the start when no cursor argument is passed.
    func replayLocal(_ conversation: ConversationManifest) async throws {
        let workspace = try localWorkspace(conversation)
        do {
            _ = try await command(
                "codex.local.replay",
                CodexLocal.replayPayload(
                    sessionId: CodexLocal.sessionId(for: conversation.id), tenantId: workspace.tenantId),
                timeout: 10)
        } catch TodexError.invalid { /* same unacknowledged contract as attach */ }
    }

    /// `model/list` cached on the sidecar (desktop `modelCatalog`): the CLI's
    /// own model menu, which also carries per-model service tiers for `/fast`
    /// and the dynamic tier commands.
    @discardableResult
    func localModelCatalog(for conversation: ConversationManifest, forceReload: Bool = false) async throws -> [JSONValue] {
        if !forceReload, let cached = sidecars[conversation.id]?.models, !cached.isEmpty { return cached }
        let result = try await localRequest(
            "model/list", params: ["limit": .number(50), "includeHidden": .bool(false)], in: conversation)
        let catalog = CodexLocal.modelCatalog(from: result)
        sidecars[conversation.id]?.models = catalog
        return catalog
    }

    /// `thread/fork` (`/fork`, `/side`, `/btw`): clones the adapter thread;
    /// the clone becomes the sidecar's current thread (desktop `selectResult`).
    @discardableResult
    func forkLocalThread(_ conversation: ConversationManifest, ephemeral: Bool) async throws -> JSONValue {
        let workspace = try localWorkspace(conversation)
        let remembered = lastPreferencesByProvider["codex"] ?? ConversationPreferences()
        var params = CodexLocal.threadStartParams(
            workspace: workspace,
            defaults: (
                model: remembered.model, reasoningEffort: remembered.reasoningEffort,
                approvalPolicy: "", approvalsReviewer: "", sandboxMode: ""))
        params["ephemeral"] = .bool(ephemeral)
        let result = try await localThreadRequest(
            "thread/fork", params: params, in: conversation, requireExisting: true)
        let forked = CodexLocal.threadId(in: result)
        if !forked.isEmpty, forked != sidecars[conversation.id]?.threadId {
            sidecars[conversation.id]?.threadId = forked
            localThreads[conversation.id] = forked
            saveSoon()
            changed()
        }
        return result
    }

    /// Route one `codex.*` frame to its conversation. Session ids map through
    /// the `v2_<conversationId>` convention; frames for unknown sessions only
    /// keep their cursor fresh, exactly as the legacy path did.
    private func routeCodex(_ frame: JSONValue, type: String) {
        let sessionId = CodexLocal.sessionId(from: frame)
        guard !sessionId.isEmpty else { return }
        let cursor = CodexLocal.cursor(of: frame)
        if cursor > (legacyCursors[sessionId] ?? 0) {
            legacyCursors[sessionId] = cursor
            saveSoon()
        }
        guard let conversationId = CodexLocal.conversationId(forSessionId: sessionId),
            conversations.contains(where: { $0.id == conversationId })
        else { return }
        var sidecar = sidecars[conversationId] ?? CodexLocalSidecar()
        if sidecar.threadId.isEmpty { sidecar.threadId = localThreads[conversationId] ?? "" }
        let effects = CodexLocal.classify(
            type: type, frame: frame, sessionId: sessionId, activeTurnId: sidecar.turnId)
        var touched = false
        if let threadId = effects.threadId, threadId != sidecar.threadId {
            sidecar.threadId = threadId
            localThreads[conversationId] = threadId
            touched = true
            saveSoon()
        }
        if let started = effects.turnStarted { sidecar.turnId = started; touched = true }
        if effects.turnSettled != nil { sidecar.turnId = ""; touched = true }
        if let phase = effects.lifecycle, phase != sidecar.phase { sidecar.phase = phase; touched = true }
        if let alert = effects.alert { sidecar.lastError = alert; touched = true }
        if let catalog = effects.modelCatalog { sidecar.models = catalog; touched = true }
        if touched { sidecars[conversationId] = sidecar }
        let applied = runtimes[conversationId]?.applyLocal(effects) == true
        if touched || applied { changed() }
    }

    /// The conversation vanished (delete/other client): stop the adapter
    /// process it owned so no orphan Codex instance keeps running.
    private func discardSidecar(_ conversationId: String) {
        sidecarStarts[conversationId]?.cancel()
        sidecarStarts.removeValue(forKey: conversationId)
        localThreadStarts[conversationId]?.cancel()
        localThreadStarts.removeValue(forKey: conversationId)
        guard sidecars[conversationId] != nil || localThreads[conversationId] != nil else { return }
        let tenantId = sidecars[conversationId]?.tenantId ?? ""
        sidecars.removeValue(forKey: conversationId)
        localThreads.removeValue(forKey: conversationId)
        if let socket, isConnected {
            let sessionId = CodexLocal.sessionId(for: conversationId)
            Task { [socket] in
                _ = try? await socket.command(
                    type: "codex.local.stop",
                    payload: CodexLocal.stopPayload(sessionId: sessionId, tenantId: tenantId),
                    timeout: 10, id: UUID().uuidString)
            }
        }
    }

    /// The plaintext of an encrypted live `conversation.event`; nil for every
    /// other frame. A key lookup that fails in transit leaves the event out and
    /// sends the conversation through recovery, which pages it in again.
    private func decryptLive(_ frame: JSONValue) async -> Result<ConversationEvent, any Error>? {
        guard frame["type"] == "conversation.event", HistoryEncryption.isEncrypted(frame["payload"]["payload"]),
            let event = try? frame["payload"].decoded(ConversationEvent.self)
        else { return nil }
        do {
            guard let plain = try await received([event], frames: frame["frames"]).first?.plain else {
                throw TodexError.invalid(String(localized: "历史分页响应无效"))
            }
            return .success(plain)
        } catch {
            DebugLog.record("history.decrypt.failed", ["error": String(describing: error)], level: .warn)
            return .failure(error)
        }
    }
    private func receive(_ frame: JSONValue, decrypted: Result<ConversationEvent, any Error>? = nil) {
        for continuation in wireSubscribers.values {
            if case .dropped = continuation.yield(frame) {
                // Consumers must refresh any projection that missed a wire frame.
                continuation.yield([
                    "type": "connection.gap",
                    "payload": ["message": .string(String(localized: "实时事件缓冲区已满，请重新同步")), "reason": "subscriberOverflow"],
                ])
            }
        }
        let type = frame["type"].stringValue
        if type == "connection.closed" {
            invalidateTransport()
            operationError = frame["payload"]["message"].stringValue
            lastConnectionError = TodexError.server(
                code: frame["payload"]["code"].optionalString ?? "CONNECTION_CLOSED", message: operationError ?? "")
            DebugLog.record(
                "connection.closed",
                ["code": frame["payload"]["code"].stringValue, "message": operationError ?? "",
                 "retryable": "\(frame["payload"]["retryable"] != false)"], level: .warn)
            connectionStatus = String(localized: "连接已中断")
            stopReconnectingIfPermanent(frame["payload"]["retryable"] == false)
            persist()
            scheduleReconnect()
            changed(immediate: true)
            return
        }
        if type == "conversation.event", let event = try? frame["payload"].decoded(ConversationEvent.self) {
            // Watched conversations have no runtime; only their list row updates.
            // The plaintext envelope fields carry everything the row needs.
            guard runtimes[event.conversationId] != nil else {
                applyWatchedEvent(event)
                return
            }
            switch decrypted {
            case .failure: runtimes[event.conversationId]?.beginReplay()
            case .success(let plain): ingest(ReceivedEvent(raw: event, plain: plain), frames: frame["frames"], live: true)
            case nil: ingest(ReceivedEvent(raw: event, plain: event), live: true)
            }
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
            routeCodex(frame, type: type)
        } else if type == "server.error", frame["id"].isNull {
            let payload = frame["payload"]
            // The backend replays after a lag notice; nothing is lost.
            guard payload["code"] != "EVENT_STREAM_LAGGED" else { return }
            let id = payload["conversationId"].stringValue
            if !id.isEmpty {
                // That conversation's forwarder died server-side and released its
                // slot. Drop the marker so the next subscribe is not skipped, and
                // resubscribe the open conversation through a full recovery.
                liveSubscriptions.removeAll { $0 == id }
                runtimes[id]?.beginReplay()
                if id == activeConversationID, recoveryTasks[id] == nil, isConnected {
                    let current = revision
                    Task { [weak self] in
                        guard let self, current == revision else { return }
                        do { try await recover(id) } catch { /* recover reports once for all waiters. */ }
                    }
                }
            }
            operationError = payload["message"].stringValue
            changed()
        }
    }
    private func recordUsage(_ id: String, _ record: JSONValue) {
        usageRecords = UsageLedger.merge(
            usageRecords, runtime: [record],
            provider: conversations.first { $0.id == id }?.provider ?? "", model: preferences[id]?.model ?? "")
        saveSoon()
    }
    /// Lightweight projection for watch-only subscriptions: keep the list's
    /// running/approval/unread state and completion alerts current without
    /// building a timeline. Opening the conversation recovers it in full.
    private func applyWatchedEvent(_ event: ConversationEvent) {
        guard let index = conversations.firstIndex(where: { $0.id == event.conversationId }),
            event.sequence > conversations[index].lastSequence
        else { return }
        let old = conversations[index].status
        conversations[index].lastSequence = event.sequence
        let payload = event.payload
        let sessionScoped = (payload["scope"].optionalString ?? payload["details"]["scope"].optionalString) == "session"
        switch ConversationRuntime.canonicalType(event) {
        case "turn.started": conversations[index].status = "running"
        case "permission.requested" where !sessionScoped, "tool.awaitingApproval" where !sessionScoped:
            conversations[index].status = "waiting_permission"
        case "permission.resolved" where ["waiting_permission", "waitingPermission"].contains(old):
            conversations[index].status = "running"
        case "turn.completed": conversations[index].status = payload["stopReason"] == "error" ? "failed" : "completed"
        case "turn.failed": conversations[index].status = "failed"
        case "turn.cancelled": conversations[index].status = "cancelled"
        case "turn.interrupted": conversations[index].status = "interrupted"
        default: break
        }
        if conversations[index].status == "completed", old != "completed" {
            notifyTurnCompleted(event.conversationId, reply: "")
        }
        saveSoon()
        changed()
    }
    /// `live` marks events from the open socket; cache and history replays pass
    /// the default so completion alerts only fire for turns that finish now.
    private func ingest(_ received: ReceivedEvent, frames: JSONValue = .null, live: Bool = false) {
        let event = received.plain
        let id = event.conversationId
        var runtime = runtimes[id] ?? ConversationRuntime(conversationId: id)
        let before = runtime.appliedSequence
        let oldStatus = runtime.status
        let oldTurn = runtime.activeTurnId
        let usageHead = runtime.usageRecords.first
        runtime.ingest(event)
        runtimes[id] = runtime
        // Records only ever change by (re)inserting at the head; a final turn
        // record's removal of that turn's partials is mirrored by the ledger.
        if let head = runtime.usageRecords.first, head != usageHead { recordUsage(id, head) }
        // Only the received form is cached: ciphertext stays ciphertext on disk.
        if eventCache.record(received.raw, frames: frames) { dirtyCaches.insert(id) }
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
                if live {
                    let reply = runtime.messages.first {
                        $0.role == "assistant" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }?.text ?? ""
                    notifyTurnCompleted(id, reply: reply)
                }
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

    /// Desktop parity: alert only for a turn the user is not watching — the
    /// app is backgrounded, or another screen than this conversation is shown.
    /// SceneDelegate presents foreground banners.
    private func notifyTurnCompleted(_ id: String, reply: String) {
        guard !foreground || viewingConversationID != id, CompletionNotifications.isEnabled(in: defaults)
        else { return }
        let manifest = conversations.first { $0.id == id }
        let workspaceName = manifest.map {
            $0.workspace.contains("/") ? URL(fileURLWithPath: $0.workspace).lastPathComponent : $0.workspace
        }
        let title = [manifest?.title, workspaceName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "TodeX"
        let excerpt = reply.components(separatedBy: .whitespacesAndNewlines).joined(separator: " ")
        let body = excerpt.isEmpty
            ? String(localized: "任务已完成")
            : String(excerpt.prefix(160)) + (excerpt.count > 160 ? "…" : "")
        CompletionNotifications.post(conversationId: id, title: title, body: body)
    }

    private func removeCache(_ id: String) {
        eventCache.remove(id)
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
    /// Sets or clears (nil) a conversation's local label color.
    func setConversationLabel(_ color: String?, for id: String) {
        let value = color.flatMap(BackendConnection.normalizeLabelColor)
        guard conversationLabels[id] != value else { return }
        conversationLabels[id] = value
        saveSoon()
        changed(immediate: true)
    }
    /// Read-only cached state of another configured backend, for the Home list.
    /// Nothing from it enters this session, so per-backend isolation holds.
    func cachedSnapshot(for connection: BackendConnection) async throws -> SessionSnapshot? {
        let namespace = LocalStore.namespace(connection)
        guard namespace != stateNamespace else { return nil }
        if let unsaved = unsavedSnapshots[namespace]?.snapshot { return unsaved }
        return try await persistence.load("\(namespace)-state")
    }
    // MARK: Task plan (synced through the backend; local snapshot is the cache)
    private static let kanbanTombstoneRetention = 30 * 24 * 60 * 60 * 1_000
    var taskConversationIDs: Set<String> {
        Set(tasks.filter { $0.deletedAt == nil }.compactMap(\.conversationId))
    }
    func tasks(for workspaceId: String) -> [KanbanTask] {
        tasks.filter { $0.workspaceId == workspaceId && $0.deletedAt == nil }.sorted { left, right in
            let a = KanbanTask.Status.allCases.firstIndex(of: left.status) ?? 0
            let b = KanbanTask.Status.allCases.firstIndex(of: right.status) ?? 0
            return a == b
                ? (left.createdAt, left.id) < (right.createdAt, right.id) : a < b
        }
    }
    @discardableResult func addTask(
        workspaceId: String, title: String, description: String? = nil, dueDate: String? = nil
    ) -> KanbanTask? {
        let name = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let activeCount = tasks.filter { $0.deletedAt == nil }.count
        guard !workspaceId.isEmpty, !name.isEmpty, activeCount < 500 else { return nil }
        var task = KanbanTask(workspaceId: workspaceId, title: name)
        task.description = Self.taskDescription(description)
        task.dueDate = Self.taskDueDate(dueDate)
        tasks.append(task)
        tasksChanged()
        return task
    }
    /// Edits description and due date together; empty or malformed values clear them.
    func updateTaskDetails(_ id: String, description: String?, dueDate: String?) {
        let description = Self.taskDescription(description)
        let dueDate = Self.taskDueDate(dueDate)
        guard let task = tasks.first(where: { $0.id == id && $0.deletedAt == nil }),
            task.description != description || task.dueDate != dueDate
        else { return }
        mutateTask(id) {
            $0.description = description
            $0.dueDate = dueDate
        }
    }
    /// Desktop limits: description trimmed to 2000 characters, due date `YYYY-MM-DD`.
    private static func taskDescription(_ value: String?) -> String? {
        let text = String((value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        return text.isEmpty ? nil : text
    }
    private static func taskDueDate(_ value: String?) -> String? {
        guard let value, value.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil else { return nil }
        return value
    }
    func renameTask(_ id: String, title: String) {
        let name = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !name.isEmpty else { return }
        mutateTask(id) { $0.title = name }
    }
    func setTaskStatus(_ id: String, _ status: KanbanTask.Status) {
        mutateTask(id) { $0.status = status }
    }
    func attachTask(_ id: String, conversationId: String?) {
        mutateTask(id) { $0.conversationId = conversationId }
    }
    /// Deletion writes a tombstone so the remove propagates through sync; the
    /// record is pruned once the tombstone outlives the retention window.
    func removeTask(_ id: String) {
        mutateTask(id) { task in
            guard task.deletedAt == nil else { return }
            task.deletedAt = Int(Date().timeIntervalSince1970 * 1_000)
        }
    }
    private func mutateTask(_ id: String, _ change: (inout KanbanTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { return }
        change(&tasks[index])
        tasks[index].updatedAt = Int(Date().timeIntervalSince1970 * 1_000)
        tasksChanged()
    }
    private func tasksChanged() {
        let cutoff = Int(Date().timeIntervalSince1970 * 1_000) - Self.kanbanTombstoneRetention
        tasks.removeAll { task in task.deletedAt.map { $0 < cutoff } ?? false }
        saveSoon()
        changed(immediate: true)
        scheduleKanbanPush()
    }
    /// Pull-merge by task id keeping the newest updatedAt; tombstones count as
    /// ordinary writes so a remote delete beats an older local copy.
    private func mergeRemoteKanbanTasks(_ remote: [KanbanTaskRecord]) {
        var changed = false
        for record in remote {
            let task = KanbanTask(record: record)
            guard let index = tasks.firstIndex(where: { $0.id == task.id }) else {
                tasks.append(task)
                changed = true
                continue
            }
            if task.updatedAt >= tasks[index].updatedAt, tasks[index] != task {
                tasks[index] = task
                changed = true
            }
        }
        if changed { tasksChanged() }
    }
    /// Kanban failures stay off the main refresh: a 404 marks the backend as
    /// pre-sync, anything else just waits for the next refresh or push.
    private func remoteKanbanTasks() async -> [KanbanTaskRecord]? {
        guard let api else { return nil }
        do {
            return try await api.kanbanTasks()
        } catch let error as TodexError {
            if case .server(let code, _) = error, code == "404" {
                kanbanSyncSupported = false
            }
            return nil
        } catch {
            return nil
        }
    }
    private func scheduleKanbanPush() {
        guard kanbanSyncSupported, isConnected, api != nil else { return }
        kanbanPushTask?.cancel()
        kanbanPushTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            await self?.pushKanbanTasks()
        }
    }
    private func pushKanbanTasks() async {
        guard let api, kanbanSyncSupported, isConnected else { return }
        let current = revision
        do {
            let remote = try await api.replaceKanbanTasks(tasks.map(\.wireRecord))
            // A backend switch mid-flight must not merge stale tasks into the
            // new connection's namespace.
            try checkRevision(current)
            mergeRemoteKanbanTasks(remote)
        } catch let error as TodexError {
            if case .server(let code, _) = error, code == "404" {
                kanbanSyncSupported = false
            }
        } catch {}
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
            guard let conversation = conversations.first(where: { $0.id == id }), let history = eventCache.stored(id)
            else { continue }
            saveVersion += 1
            cacheWrites[eventKey(conversation)] = CacheWrite(
                namespace: stateNamespace, version: saveVersion, history: history)
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
        // Decrypted titles stay in memory; the snapshot keeps their ciphertext.
        let storedConversations = conversations.map { conversation in
            var stored = conversation
            if stored.titleEnc != nil { stored.title = nil }
            return stored
        }
        let snapshot = SessionSnapshot(
            workspaces: workspaces, conversations: storedConversations, drafts: drafts, preferences: preferences,
            lastPreferencesByProvider: lastPreferencesByProvider, lastAgent: lastAgent,
            queues: queues, pendingSends: pendingSends, legacyCursors: legacyCursors,
            localThreads: localThreads, readSequences: reads,
            pinnedWorkspaces: pinnedWorkspaces, pinnedConversations: pinnedConversations,
            pausedQueues: pausedQueues, activeConversationID: activeConversationID, tasks: tasks,
            sentAttachments: sentAttachments, conversationLabels: conversationLabels,
            usageRecords: usageRecords)
        let checkpoint = Checkpoint(version: saveVersion, snapshot: snapshot)
        unsavedSnapshots[stateNamespace] = checkpoint
        return checkpoint
    }
    private func persistDurably() async throws {
        guard stateLoaded else { throw TodexError.invalid(storageError ?? String(localized: "本地状态未完成加载")) }
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
                    do { try await persistence.saveHistory(write.history, key: key, version: write.version) } catch {
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
        let message = String(localized: "草稿和待确认消息仍保留在内存中。\(error.localizedDescription)")
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
        rejectedWorkspaces = []
        conversations = []
        providers = []
        runtimes = [:]
        models = [:]
        commands = [:]
        drafts = [:]
        preferences = [:]
        lastPreferencesByProvider = [:]
        lastAgent = nil
        queues = [:]
        pendingSends = [:]
        pausedQueues = []
        pinnedWorkspaces = []
        pinnedConversations = []
        tasks = []
        usageRecords = []
        readSequences = [:]
        conversationLabels = [:]
        legacyCursors = [:]
        sidecars = [:]
        sidecarStarts = [:]
        localThreadStarts = [:]
        localThreads = [:]
        eventCache.removeAll()
        historyFloors = [:]
        earlierLoading = [:]
        cacheLoaded = []
        historyEncryption = nil
        historyDecryptor = nil
        encryptedConversations = []
        decryptedTitles = [:]
        dirtyCaches = []
        activeConversationID = nil
        modelRevisions = [:]
        commandRevisions = [:]
        operationError = nil
        lastConnectionError = nil
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
                lastPreferencesByProvider =
                    snapshot.lastPreferencesByProvider.merging(lastPreferencesByProvider) { _, edited in edited }
                lastAgent = lastAgent ?? snapshot.lastAgent
                queues = snapshot.queues.merging(queues) { _, edited in edited }
                pendingSends = snapshot.pendingSends
                legacyCursors = snapshot.legacyCursors
                localThreads = snapshot.localThreads.merging(localThreads) { _, live in live }
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
                tasks = (snapshot.tasks + tasks).reduce(into: [String: KanbanTask]()) { $0[$1.id] = $1 }
                    .values.sorted { $0.createdAt < $1.createdAt || ($0.createdAt == $1.createdAt && $0.id < $1.id) }
                sentAttachments = snapshot.sentAttachments
                conversationLabels = snapshot.conversationLabels.merging(conversationLabels) { _, edited in edited }
                usageRecords = UsageLedger.union(usageRecords, snapshot.usageRecords)
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
