import CryptoKit
import Foundation
import Security
import TodexCore

enum CredentialStore {
    #if targetEnvironment(simulator)
        // Unsigned simulator builds (CODE_SIGNING_ALLOWED=NO) have no application-identifier
        // entitlement; every SecItem call fails with errSecMissingEntitlement. Fall back to a
        // plain file so the developer workflow still persists credentials. Devices never hit this.
        private static let keychainUnavailable: Bool = {
            let probe: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.todex.mobile.probe", kSecAttrAccount as String: "probe",
                kSecValueData as String: Data("x".utf8),
            ]
            let added = SecItemAdd(probe as CFDictionary, nil)
            SecItemDelete(probe as CFDictionary)
            return added == errSecMissingEntitlement
        }()
        private static var fallbackURL: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TodeX", isDirectory: true)
                .appendingPathComponent("credentials", isDirectory: false)
                .appendingPathExtension("json")
        }
        private static func fallbackSecrets() -> [String: String] {
            (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: fallbackURL))) ?? [:]
        }
        private static func setFallback(_ secret: String, for id: String) throws {
            var secrets = fallbackSecrets()
            if secret.isEmpty { secrets[id] = nil } else { secrets[id] = secret }
            let data = try JSONEncoder().encode(secrets)
            try FileManager.default.createDirectory(
                at: fallbackURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fallbackURL, options: [.atomic, .completeFileProtection])
        }
    #endif

    /// Returns the base64url-encoded Ed25519 device seed for this backend
    /// profile, or "" when the device is not enrolled on it. Any other
    /// Keychain failure (locked before first unlock, corrupted item) throws:
    /// treating it as "not enrolled" would silently drop the credential.
    static func deviceSecret(for id: String) throws -> String {
        #if targetEnvironment(simulator)
            if keychainUnavailable { return fallbackSecrets()[id] ?? "" }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.todex.mobile.backend",
            kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let secret = String(data: data, encoding: .utf8)
        else { throw TodexError.invalid(String(localized: "无法读取设备密钥")) }
        return secret
    }
    static func save(_ secret: String, for id: String) throws {
        #if targetEnvironment(simulator)
            if keychainUnavailable {
                try setFallback(secret, for: id)
                return
            }
        #endif
        try write(secret.isEmpty ? nil : Data(secret.utf8), service: "com.todex.mobile.backend", account: id)
    }

    /// The 32-byte X-Wing seed this device decrypts conversation history with
    /// on one backend profile (history v3). Nil until first needed.
    static func historySeed(for id: String) throws -> Data? {
        #if targetEnvironment(simulator)
            if keychainUnavailable {
                return fallbackSecrets()[historyFallbackKey(id)].flatMap { Data(base64Encoded: $0) }
            }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: historyService,
            kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
            throw TodexError.invalid(String(localized: "无法读取历史记录密钥"))
        }
        return data
    }

    /// Stores (or with nil, deletes) the history seed.
    static func saveHistorySeed(_ seed: Data?, for id: String) throws {
        #if targetEnvironment(simulator)
            if keychainUnavailable {
                try setFallback(seed?.base64EncodedString() ?? "", for: historyFallbackKey(id))
                return
            }
        #endif
        try write(seed, service: historyService, account: id)
    }

    private static let historyService = "com.todex.mobile.history"
    private static func historyFallbackKey(_ id: String) -> String { "history:\(id)" }

    /// WhenUnlockedThisDeviceOnly: never synced, never in backups.
    private static func write(_ data: Data?, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let data else {
            let result = SecItemDelete(query as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw TodexError.invalid(String(localized: "无法删除设备密钥")) }
            return
        }
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if updated == errSecItemNotFound {
            guard SecItemAdd(query.merging(values) { _, rhs in rhs } as CFDictionary, nil) == errSecSuccess else {
                throw TodexError.invalid(String(localized: "无法安全保存设备密钥"))
            }
        } else if updated != errSecSuccess {
            throw TodexError.invalid(String(localized: "无法更新设备密钥"))
        }
    }
}

/// Where AppSession keeps each backend profile's history seed; tests inject
/// an in-memory store.
struct HistorySeedStore {
    var load: (String) throws -> Data?
    var save: (Data?, String) throws -> Void
    static var keychain: HistorySeedStore {
        HistorySeedStore(
            load: { try CredentialStore.historySeed(for: $0) }, save: { try CredentialStore.saveHistorySeed($0, for: $1) })
    }
}

/// File names retain the complete identity through a digest, rather than removing
/// punctuation (which made distinct server URLs and IDs collide).
nonisolated struct LocalStore: Sendable {
    let root: URL

    init(
        root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TodeX", isDirectory: true)
    ) { self.root = root }

    static func identity(_ parts: [String]) -> String {
        let value = parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func namespace(_ connection: BackendConnection?) -> String {
        guard let connection else { return "unconnected-v2" }
        let endpoint = (try? connection.normalizedURL().absoluteString) ?? connection.serverURL
        // The protocol has no stable authenticated-account endpoint. A device
        // change may select different permissions, so it uses a separate cache.
        return identity(["session-v2", connection.id, endpoint, connection.deviceSecret])
    }

    func url(_ key: String) -> URL {
        // The global connection catalog already uses this name; it has no keys.
        root.appendingPathComponent(key == "connections" ? "connections" : Self.identity([key]))
            .appendingPathExtension("json")
    }

    func read<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        let path = url(key)
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: path)) } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    func save<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // File-protection classes exist only on iOS; a macOS session-test binary
        // cannot set the attribute.
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
            options.insert(.completeFileProtection)
        #endif
        try data.write(to: url(key), options: options)
    }
}

/// The provider/profile pair chosen when a conversation was created. Composer
/// memory replays it as the default choice for the next conversation.
nonisolated struct AgentSelection: Codable, Sendable, Equatable {
    var provider = ""
    var profile: String?
}

/// A draft, queue removal and outgoing request ledger move together in one
/// atomic file. A crash cannot leave a sent queued draft eligible for auto-send.
nonisolated struct SessionSnapshot: Codable, Sendable {
    var workspaces: [WorkspaceRecord] = []
    var conversations: [ConversationManifest] = []
    var drafts: [String: ComposerDraft] = [:]
    var preferences: [String: ConversationPreferences] = [:]
    var lastPreferencesByProvider: [String: ConversationPreferences] = [:]
    var lastAgent: AgentSelection?
    /// Legacy: local candidate messages written by builds that kept the queue on
    /// the device. Decoded only so they can be handed to the backend once; they
    /// are encoded again only while that migration is still pending.
    var queues: [String: [QueuedDraft]] = [:]
    var pendingSends: [String: PendingSend] = [:]
    var legacyCursors: [String: Int] = [:]
    /// conversationId → Codex adapter thread id. The adapter process can
    /// outlive the app; keeping the mapping lets a relaunch resume the same
    /// local thread instead of silently starting a new one.
    var localThreads: [String: String] = [:]
    var readSequences: [String: Int] = [:]
    var pinnedWorkspaces: [String] = []
    var pinnedConversations: [String] = []
    /// Workspace group ids folded in the home list (local, per backend).
    var collapsedWorkspaceGroups: Set<String> = []
    /// Legacy companion of `queues` (conversations whose local queue was paused).
    var pausedQueues: Set<String> = []
    var activeConversationID: String?
    var tasks: [KanbanTask] = []
    var sentAttachments: [SentAttachmentRecord] = []
    var conversationLabels: [String: String] = [:]
    var usageRecords: [JSONValue] = []

    // Spelled out because both coding methods are custom.
    private enum CodingKeys: String, CodingKey {
        case workspaces, conversations, drafts, preferences, lastPreferencesByProvider, lastAgent, queues
        case pendingSends, legacyCursors, localThreads, readSequences, pinnedWorkspaces, pinnedConversations
        case collapsedWorkspaceGroups, pausedQueues, activeConversationID, tasks, sentAttachments
        case conversationLabels, usageRecords
    }
}

/// Every field decodes with decodeIfPresent so a snapshot written by an older
/// build (missing newer keys) still loads instead of discarding local state.
extension SessionSnapshot {
    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try c.decodeIfPresent([WorkspaceRecord].self, forKey: .workspaces) ?? []
        conversations = try c.decodeIfPresent([ConversationManifest].self, forKey: .conversations) ?? []
        drafts = try c.decodeIfPresent([String: ComposerDraft].self, forKey: .drafts) ?? [:]
        preferences = try c.decodeIfPresent([String: ConversationPreferences].self, forKey: .preferences) ?? [:]
        lastPreferencesByProvider =
            try c.decodeIfPresent([String: ConversationPreferences].self, forKey: .lastPreferencesByProvider) ?? [:]
        lastAgent = try c.decodeIfPresent(AgentSelection.self, forKey: .lastAgent)
        queues = try c.decodeIfPresent([String: [QueuedDraft]].self, forKey: .queues) ?? [:]
        pendingSends = try c.decodeIfPresent([String: PendingSend].self, forKey: .pendingSends) ?? [:]
        legacyCursors = try c.decodeIfPresent([String: Int].self, forKey: .legacyCursors) ?? [:]
        localThreads = try c.decodeIfPresent([String: String].self, forKey: .localThreads) ?? [:]
        readSequences = try c.decodeIfPresent([String: Int].self, forKey: .readSequences) ?? [:]
        pinnedWorkspaces = try c.decodeIfPresent([String].self, forKey: .pinnedWorkspaces) ?? []
        pinnedConversations = try c.decodeIfPresent([String].self, forKey: .pinnedConversations) ?? []
        collapsedWorkspaceGroups = try c.decodeIfPresent(Set<String>.self, forKey: .collapsedWorkspaceGroups) ?? []
        pausedQueues = try c.decodeIfPresent(Set<String>.self, forKey: .pausedQueues) ?? []
        activeConversationID = try c.decodeIfPresent(String.self, forKey: .activeConversationID)
        tasks = try c.decodeIfPresent([KanbanTask].self, forKey: .tasks) ?? []
        sentAttachments = try c.decodeIfPresent([SentAttachmentRecord].self, forKey: .sentAttachments) ?? []
        conversationLabels = try c.decodeIfPresent([String: String].self, forKey: .conversationLabels) ?? [:]
        usageRecords = try c.decodeIfPresent([JSONValue].self, forKey: .usageRecords) ?? []
    }

    /// Mirrors the synthesized encoding except that the legacy candidate queue
    /// keys are omitted once nothing is left to migrate.
    nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(workspaces, forKey: .workspaces)
        try c.encode(conversations, forKey: .conversations)
        try c.encode(drafts, forKey: .drafts)
        try c.encode(preferences, forKey: .preferences)
        try c.encode(lastPreferencesByProvider, forKey: .lastPreferencesByProvider)
        try c.encodeIfPresent(lastAgent, forKey: .lastAgent)
        if !queues.isEmpty { try c.encode(queues, forKey: .queues) }
        try c.encode(pendingSends, forKey: .pendingSends)
        try c.encode(legacyCursors, forKey: .legacyCursors)
        try c.encode(localThreads, forKey: .localThreads)
        try c.encode(readSequences, forKey: .readSequences)
        try c.encode(pinnedWorkspaces, forKey: .pinnedWorkspaces)
        try c.encode(pinnedConversations, forKey: .pinnedConversations)
        try c.encode(collapsedWorkspaceGroups, forKey: .collapsedWorkspaceGroups)
        if !pausedQueues.isEmpty { try c.encode(pausedQueues, forKey: .pausedQueues) }
        try c.encodeIfPresent(activeConversationID, forKey: .activeConversationID)
        try c.encode(tasks, forKey: .tasks)
        try c.encode(sentAttachments, forKey: .sentAttachments)
        try c.encode(conversationLabels, forKey: .conversationLabels)
        try c.encode(usageRecords, forKey: .usageRecords)
    }
}

/// Cross-conversation usage history, bounded like desktop MAX_USAGE_RECORDS.
/// A runtime holds only its loaded event window, so records merge by id
/// instead of replacing a conversation's set. A turn-scoped record (the
/// cumulative or final turn snapshot) supersedes that turn's other records,
/// exactly as ConversationRuntime collapses them.
nonisolated enum UsageLedger {
    static let limit = 2_000

    static func merge(_ stored: [JSONValue], runtime: [JSONValue], provider: String, model: String) -> [JSONValue] {
        guard !runtime.isEmpty else { return stored }
        // Desktop parity: fill an unknown provider/model from the conversation.
        let incoming = runtime.map { record -> JSONValue in
            var record = record
            if !provider.isEmpty, ["", "unknown"].contains(record["provider"].stringValue) {
                record["provider"] = .string(provider)
            }
            if !model.isEmpty, (record["model"].optionalString ?? "").isEmpty { record["model"] = .string(model) }
            return record
        }
        let ids = Set(incoming.map { $0["id"] })
        let turns = Set(
            incoming.filter { $0["scope"] == "turn" && !$0["turnId"].stringValue.isEmpty }.map(turnKey))
        let kept = stored.filter { !ids.contains($0["id"]) && !turns.contains(turnKey($0)) }
        return newestFirst(incoming + kept)
    }

    /// Loaded snapshot records under records gathered while it loaded.
    static func union(_ current: [JSONValue], _ loaded: [JSONValue]) -> [JSONValue] {
        guard !current.isEmpty else { return Array(loaded.prefix(limit)) }
        let ids = Set(current.map { $0["id"] })
        return newestFirst(current + loaded.filter { !ids.contains($0["id"]) })
    }

    private static func turnKey(_ record: JSONValue) -> [JSONValue] {
        [record["conversationId"], record["turnId"], record["provider"]]
    }

    /// Stable: ties (and records without a time) keep their incoming order.
    private static func newestFirst(_ records: [JSONValue]) -> [JSONValue] {
        records.enumerated().sorted {
            let lhs = $0.element["updatedAt"].doubleValue ?? 0
            let rhs = $1.element["updatedAt"].doubleValue ?? 0
            return lhs != rhs ? lhs > rhs : $0.offset < $1.offset
        }.prefix(limit).map(\.element)
    }
}

/// A task-plan entry shared with the desktop and web kanban boards. The local
/// snapshot already lives in a per-backend namespace, so records carry no
/// connection tag; `deletedAt` is a tombstone that lets deletions propagate
/// through sync instead of resurrecting from another device's stale copy.
nonisolated struct KanbanTask: Identifiable, Codable, Sendable, Equatable {
    enum Status: String, Codable, CaseIterable, Sendable {
        case planned
        case inProgress = "in-progress"
        case done
        var label: String {
            switch self {
            case .planned: String(localized: "计划")
            case .inProgress: String(localized: "进行中")
            case .done: String(localized: "已完成")
            }
        }
        var symbol: String {
            switch self {
            case .planned: "circle"
            case .inProgress: "circle.dotted.circle"
            case .done: "checkmark.circle.fill"
            }
        }
    }
    var id: String
    var workspaceId: String
    var title: String
    var status: Status
    var description: String?
    var dueDate: String?
    var conversationId: String?
    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    init(workspaceId: String, title: String) {
        let now = Int(Date().timeIntervalSince1970 * 1_000)
        self.init(
            id: "task-\(UUID().uuidString)", workspaceId: workspaceId, title: title, status: .planned,
            createdAt: now, updatedAt: now)
    }
    init(id: String, workspaceId: String, title: String, status: Status, createdAt: Int, updatedAt: Int) {
        self.id = id
        self.workspaceId = workspaceId
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    init(record: KanbanTaskRecord) {
        self.init(
            id: record.id, workspaceId: record.workspaceId, title: record.title,
            status: Status(rawValue: record.status) ?? .planned,
            createdAt: record.createdAt, updatedAt: record.updatedAt)
        description = record.description
        dueDate = record.dueDate
        conversationId = record.conversationId
        deletedAt = record.deletedAt
    }
    var wireRecord: KanbanTaskRecord {
        KanbanTaskRecord(
            id: id, workspaceId: workspaceId, title: title,
            description: description, dueDate: dueDate, status: status.rawValue,
            conversationId: conversationId, createdAt: createdAt, updatedAt: updatedAt,
            deletedAt: deletedAt)
    }
}

/// Serial disk work is isolated from the main actor. Version checks also handle
/// Tasks reaching this actor out of order; an old save cannot overwrite a new one.
actor SessionPersistence {
    private let store: LocalStore
    private var committed: [String: UInt64] = [:]
    private var attempted: [String: UInt64] = [:]
    init(store: LocalStore) { self.store = store }

    func load(_ key: String) throws -> SessionSnapshot? { try store.read(key, as: SessionSnapshot.self) }
    /// Cached journal prefix, exactly as received (ciphertext under history encryption).
    func history(_ key: String) throws -> CachedHistory { try store.read(key, as: CachedHistory.self) ?? CachedHistory() }

    func save(_ snapshot: SessionSnapshot, key: String, version: UInt64) throws {
        try write(snapshot, key: key, version: version)
    }
    func saveHistory(_ history: CachedHistory, key: String, version: UInt64) throws {
        try write(history, key: key, version: version)
    }
    private func write<T: Encodable>(_ value: T, key: String, version: UInt64) throws {
        if version <= (committed[key] ?? 0) { return }
        guard version >= (attempted[key] ?? 0) else { throw TodexError.invalid(String(localized: "较新的本地保存尚未成功")) }
        attempted[key] = version
        try store.save(value, key: key)
        committed[key] = version
    }
}

nonisolated struct MessageAttachment: Identifiable, Codable, Sendable, Equatable {
    var id = UUID().uuidString
    var name: String
    var mimeType: String
    var data: Data
    var reference: Reference?
    var isImage: Bool { mimeType.hasPrefix("image/") }
    var isReference: Bool { reference != nil }
    /// Single canonical inline token for this attachment, shared with the
    /// desktop composer so a draft reads the same on both clients.
    var token: String { Self.token(name: name, isImage: isImage, isReference: isReference) }
    static func token(name: String, isImage: Bool, isReference: Bool) -> String {
        if isReference { return "[引用:\(name)]" }
        if isImage { return "[图片:\(name)]" }
        return "[文件:\(name)]"
    }
    struct Reference: Codable, Sendable, Equatable {
        var path: String?
        var lineStart: Int?
        var lineEnd: Int?
        var messageId: String?
        var location: String {
            guard let path, !path.isEmpty else { return "" }
            guard let lineStart else { return path }
            let tail = lineEnd != nil && lineEnd != lineStart ? "-\(lineEnd ?? lineStart)" : ""
            return "\(path):\(lineStart)\(tail)"
        }
    }
    var wireValue: JSONValue {
        if isImage {
            return ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mimeType)]
        }
        if let reference {
            let location = reference.location.isEmpty ? name : reference.location
            var parts = ["[引用: \(location)]"]
            let excerpt = String(decoding: data, as: UTF8.self)
            if !excerpt.isEmpty { parts.append("Content:\n\(excerpt)") }
            return ["type": "text", "text": .string(parts.joined(separator: "\n"))]
        }
        return ["type": "text", "text": .string("附件：\(name)\n\(String(decoding: data, as: UTF8.self))")]
    }
}
nonisolated struct SkillAttachment: Identifiable, Codable, Sendable, Equatable {
    var id: String
    var name: String
}
nonisolated struct ComposerDraft: Codable, Sendable, Equatable {
    var text = ""
    var attachments: [MessageAttachment] = []
    var skills: [SkillAttachment] = []
    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty && skills.isEmpty
    }
    /// `self` followed by `other`, for restoring a rejected message in front of
    /// text typed in the meantime without discarding either.
    func combined(with other: ComposerDraft) -> ComposerDraft {
        var result = self
        let tail = other.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.text += (result.text.isEmpty ? "" : "\n\n") + other.text }
        result.attachments += other.attachments.filter { item in !attachments.contains { $0.id == item.id } }
        result.skills += other.skills.filter { item in !skills.contains { $0.id == item.id } }
        return result
    }
}

extension ComposerDraft {
    /// The composer draft behind a `conversation.queue.take` item: `text` keeps
    /// its inline tokens, and `content` holds what `MessageAttachment.wireValue`
    /// sent (inline images, `附件：name` file text, `[引用: location]` excerpts).
    /// Parts without a counterpart in the composer (paths, unknown text) are
    /// appended to the text so nothing the user queued is lost.
    nonisolated init(takenItem item: JSONValue) {
        var text = item["text"].stringValue
        var tokens: [String: [String]] = [:]
        if let pattern = try? NSRegularExpression(pattern: "\\[(图片|文件|引用):([^\\]]*)\\]") {
            let whole = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: whole) {
                guard let kind = Range(match.range(at: 1), in: text), let name = Range(match.range(at: 2), in: text)
                else { continue }
                tokens[String(text[kind]), default: []].append(String(text[name]))
            }
        }
        func next(_ kind: String) -> String? { tokens[kind]?.isEmpty == false ? tokens[kind]?.removeFirst() : nil }
        var extra: [String] = []
        var restored: [MessageAttachment] = []
        for part in item["content"].arrayValue {
            switch part["type"].stringValue {
            case "image":
                guard let data = Data(base64Encoded: part["data"].stringValue) else {
                    extra.append(String(localized: "[图片无法恢复]"))
                    continue
                }
                var name = next("图片")
                if name == nil {
                    name = "image\(restored.filter(\.isImage).count + 1).jpg"
                    text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + "[图片:\(name ?? "")]"
                }
                restored.append(
                    MessageAttachment(
                        name: name ?? "", mimeType: part["mimeType"].optionalString ?? "image/jpeg", data: data))
            case "text":
                let body = part["text"].stringValue
                if body.hasPrefix("附件：") {
                    let lines = body.dropFirst("附件：".count).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    let name = lines.first.map(String.init) ?? ""
                    let content = lines.count > 1 ? String(lines[1]) : ""
                    restored.append(MessageAttachment(name: name, mimeType: "text/plain", data: Data(content.utf8)))
                } else if body.hasPrefix("[引用: "), let close = body.firstIndex(of: "]") {
                    let location = String(body[body.index(body.startIndex, offsetBy: "[引用: ".count)..<close])
                    var excerpt = String(body[body.index(after: close)...])
                    if excerpt.hasPrefix("\nContent:\n") { excerpt.removeFirst("\nContent:\n".count) }
                    var reference = MessageAttachment.Reference()
                    reference.path = location
                    restored.append(
                        MessageAttachment(
                            name: next("引用") ?? location, mimeType: "text/plain", data: Data(excerpt.utf8),
                            reference: reference))
                } else if !body.isEmpty {
                    extra.append(body)
                }
            default:
                let path = part["path"].stringValue
                if !path.isEmpty { extra.append(path) }
            }
        }
        if !extra.isEmpty { text += (text.isEmpty ? "" : "\n") + extra.joined(separator: "\n") }
        self.init(
            text: text, attachments: restored,
            skills: item["skills"].arrayValue.compactMap { skill in
                let id = skill["resourceId"].stringValue
                return id.isEmpty ? nil : SkillAttachment(id: id, name: skill["name"].stringValue)
            })
    }
}
nonisolated struct ConversationPreferences: Codable, Sendable {
    var model = ""
    var reasoningEffort = ""
    var permissionMode = "ask"
    var workMode = "implement"
    var fast = false
}
nonisolated struct QueuedDraft: Identifiable, Codable, Sendable {
    var id = UUID().uuidString
    var draft: ComposerDraft
}
nonisolated struct PendingSend: Codable, Sendable {
    var requestId: String
    var draft: ComposerDraft
    var afterSequence: Int
    var unknown = true
}

/// Local receipt of what an outgoing message carried. Backend events do not
/// echo attachments, so the timeline joins these by clientRequestId; `preview`
/// is a small JPEG data URL kept under a total budget, mirroring the desktop
/// WebP receipts.
nonisolated struct SentAttachment: Codable, Sendable, Equatable {
    var id: String
    var kind: String
    var name: String
    var mimeType: String
    var sizeBytes: Int?
    var preview: String?
    /// UTF-8 text of a file attachment (≤100 KB, desktop parity) for the
    /// read-only receipt preview; shares the preview eviction budget.
    var textContent: String?
}
nonisolated struct SentAttachmentRecord: Codable, Sendable, Equatable {
    var conversationId: String
    var requestId: String
    var text: String
    var attachments: [SentAttachment]
}
