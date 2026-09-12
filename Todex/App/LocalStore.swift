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
        private static func fallbackTokens() -> [String: String] {
            (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: fallbackURL))) ?? [:]
        }
        private static func setFallback(_ token: String, for id: String) throws {
            var tokens = fallbackTokens()
            if token.isEmpty { tokens[id] = nil } else { tokens[id] = token }
            let data = try JSONEncoder().encode(tokens)
            try FileManager.default.createDirectory(
                at: fallbackURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fallbackURL, options: [.atomic, .completeFileProtection])
        }
    #endif

    static func token(for id: String) -> String {
        #if targetEnvironment(simulator)
            if keychainUnavailable { return fallbackTokens()[id] ?? "" }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.todex.mobile.backend",
            kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ token: String, for id: String) throws {
        #if targetEnvironment(simulator)
            if keychainUnavailable {
                try setFallback(token, for: id)
                return
            }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.todex.mobile.backend",
            kSecAttrAccount as String: id,
        ]
        if token.isEmpty {
            let result = SecItemDelete(query as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw TodexError.invalid("无法删除访问令牌") }
            return
        }
        let values: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if updated == errSecItemNotFound {
            guard SecItemAdd(query.merging(values) { _, rhs in rhs } as CFDictionary, nil) == errSecSuccess else {
                throw TodexError.invalid("无法安全保存访问令牌")
            }
        } else if updated != errSecSuccess {
            throw TodexError.invalid("无法更新访问令牌")
        }
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
        // The protocol has no stable authenticated-account endpoint. A credential
        // change may select a different tenant, so it must use a separate cache.
        return identity(["session-v2", connection.id, endpoint, connection.token])
    }

    func url(_ key: String) -> URL {
        // The global connection catalog already uses this name; it has no tokens.
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

/// A draft, queue removal and outgoing request ledger move together in one
/// atomic file. A crash cannot leave a sent queued draft eligible for auto-send.
nonisolated struct SessionSnapshot: Codable, Sendable {
    var workspaces: [WorkspaceRecord] = []
    var conversations: [ConversationManifest] = []
    var drafts: [String: ComposerDraft] = [:]
    var preferences: [String: ConversationPreferences] = [:]
    var queues: [String: [QueuedDraft]] = [:]
    var pendingSends: [String: PendingSend] = [:]
    var legacyCursors: [String: Int] = [:]
    var readSequences: [String: Int] = [:]
    var pinnedWorkspaces: [String] = []
    var pinnedConversations: [String] = []
    var pausedQueues: Set<String> = []
    var activeConversationID: String?
    var tasks: [KanbanTask] = []
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
        queues = try c.decodeIfPresent([String: [QueuedDraft]].self, forKey: .queues) ?? [:]
        pendingSends = try c.decodeIfPresent([String: PendingSend].self, forKey: .pendingSends) ?? [:]
        legacyCursors = try c.decodeIfPresent([String: Int].self, forKey: .legacyCursors) ?? [:]
        readSequences = try c.decodeIfPresent([String: Int].self, forKey: .readSequences) ?? [:]
        pinnedWorkspaces = try c.decodeIfPresent([String].self, forKey: .pinnedWorkspaces) ?? []
        pinnedConversations = try c.decodeIfPresent([String].self, forKey: .pinnedConversations) ?? []
        pausedQueues = try c.decodeIfPresent(Set<String>.self, forKey: .pausedQueues) ?? []
        activeConversationID = try c.decodeIfPresent(String.self, forKey: .activeConversationID)
        tasks = try c.decodeIfPresent([KanbanTask].self, forKey: .tasks) ?? []
    }
}

/// A local task-plan entry, mirroring the desktop kanban board: tasks live in
/// the namespaced snapshot, independent of the backend, and may link to a
/// conversation of the same workspace.
nonisolated struct KanbanTask: Identifiable, Codable, Sendable, Equatable {
    enum Status: String, Codable, CaseIterable, Sendable {
        case planned
        case inProgress = "in-progress"
        case done
        var label: String {
            switch self {
            case .planned: "计划"
            case .inProgress: "进行中"
            case .done: "已完成"
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
    var conversationId: String?
    var createdAt: Int
    var updatedAt: Int
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
}

/// Serial disk work is isolated from the main actor. Version checks also handle
/// Tasks reaching this actor out of order; an old save cannot overwrite a new one.
actor SessionPersistence {
    private let store: LocalStore
    private var committed: [String: UInt64] = [:]
    private var attempted: [String: UInt64] = [:]
    init(store: LocalStore) { self.store = store }

    func load(_ key: String) throws -> SessionSnapshot? { try store.read(key, as: SessionSnapshot.self) }
    func events(_ key: String) throws -> [ConversationEvent] { try store.read(key, as: [ConversationEvent].self) ?? [] }

    func save(_ snapshot: SessionSnapshot, key: String, version: UInt64) throws {
        try write(snapshot, key: key, version: version)
    }
    func saveEvents(_ events: [ConversationEvent], key: String, version: UInt64) throws {
        try write(events, key: key, version: version)
    }
    private func write<T: Encodable>(_ value: T, key: String, version: UInt64) throws {
        if version <= (committed[key] ?? 0) { return }
        guard version >= (attempted[key] ?? 0) else { throw TodexError.invalid("较新的本地保存尚未成功") }
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
    struct Reference: Codable, Sendable, Equatable {
        var path: String?
        var lineStart: Int?
        var lineEnd: Int?
        var note = ""
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
            let note = reference.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty { parts.append("批注: \(note)") }
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
