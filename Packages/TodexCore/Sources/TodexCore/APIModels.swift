import Foundation

/// The persisted workspace wire record. Timestamps are Unix milliseconds.
public struct WorkspaceRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var path: String
    public var sessionId: String
    public var tenantId: String
    public var threadId: String
    public var model: String
    public var reasoningEffort: String?
    public var approvalPolicy: String
    public var sandboxMode: String
    public var permissionProfile: String?
    public var approvalsReviewer: String?
    public var serviceTier: String?
    /// Codex communication-style preference; the backend only passes it
    /// through, like the sidebar presentation fields below.
    public var personality: String?
    /// Sidebar presentation fields shared with the desktop client; the
    /// backend stores them unvalidated.
    public var icon: String?
    public var iconColor: String?
    public var ringStyle: String?
    /// Manual sidebar order shared with the desktop client; nil sorts first.
    public var sortOrder: Int?
    /// Sidebar grouping shared with the desktop client: workspaces sharing a
    /// `groupId` form one group and each carries the group's name. The backend
    /// trims and caps both at 64 characters; nil means not grouped.
    public var groupId: String?
    public var groupName: String?
    public var createdAt: Int
    public var updatedAt: Int

    /// The backend canonicalizes id, sessionId and tenantId when saving.
    /// An empty model leaves model selection to the provider's default.
    public init(
        id: String = UUID().uuidString,
        name: String,
        path: String,
        sessionId: String? = nil,
        tenantId: String = "local",
        threadId: String = "",
        model: String = "",
        reasoningEffort: String? = nil,
        approvalPolicy: String = "on-request",
        sandboxMode: String = "workspace-write",
        permissionProfile: String? = nil,
        approvalsReviewer: String? = nil,
        serviceTier: String? = nil,
        personality: String? = nil,
        icon: String? = nil,
        iconColor: String? = nil,
        ringStyle: String? = nil,
        sortOrder: Int? = nil,
        groupId: String? = nil,
        groupName: String? = nil,
        createdAt: Int = Int(Date().timeIntervalSince1970 * 1_000),
        updatedAt: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.sessionId = sessionId ?? "cdxs_\(id)"
        self.tenantId = tenantId
        self.threadId = threadId
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.approvalPolicy = approvalPolicy
        self.sandboxMode = sandboxMode
        self.permissionProfile = permissionProfile
        self.approvalsReviewer = approvalsReviewer
        self.serviceTier = serviceTier
        self.personality = personality
        self.icon = icon
        self.iconColor = iconColor
        self.ringStyle = ringStyle
        self.sortOrder = sortOrder
        self.groupId = groupId
        self.groupName = groupName
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, sessionId, tenantId, threadId, model, reasoningEffort
        case approvalPolicy, sandboxMode, permissionProfile, approvalsReviewer, serviceTier
        case personality, icon, iconColor, ringStyle
        case sortOrder, groupId, groupName, createdAt, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        tenantId = try c.decode(String.self, forKey: .tenantId)
        // Older persisted records omit threadId; the Rust model defaults it too.
        threadId = try c.decodeIfPresent(String.self, forKey: .threadId) ?? ""
        model = try c.decode(String.self, forKey: .model)
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
        approvalPolicy = try c.decode(String.self, forKey: .approvalPolicy)
        sandboxMode = try c.decode(String.self, forKey: .sandboxMode)
        permissionProfile = try c.decodeIfPresent(String.self, forKey: .permissionProfile)
        approvalsReviewer = try c.decodeIfPresent(String.self, forKey: .approvalsReviewer)
        serviceTier = try c.decodeIfPresent(String.self, forKey: .serviceTier)
        personality = try c.decodeIfPresent(String.self, forKey: .personality)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        iconColor = try c.decodeIfPresent(String.self, forKey: .iconColor)
        ringStyle = try c.decodeIfPresent(String.self, forKey: .ringStyle)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder)
        groupId = try c.decodeIfPresent(String.self, forKey: .groupId)
        groupName = try c.decodeIfPresent(String.self, forKey: .groupName)
        createdAt = try c.decode(Int.self, forKey: .createdAt)
        updatedAt = try c.decode(Int.self, forKey: .updatedAt)
    }
}

/// Provider and status remain strings so new backend values can be decoded.
public struct ConversationManifest: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var provider: String
    public var workspace: String
    public var workspaceId: String?
    public var title: String?
    /// History v3: `{kid, ct}` when the title is end-to-end encrypted; `title`
    /// is then empty on the wire until the client decrypts it.
    public var titleEnc: JSONValue?
    public var providerProfile: String?
    public var status: String
    public var archivedAt: String?
    public var lastSequence: Int
    public var createdAt: String
    public var updatedAt: String
    /// History v3: a conversation written before forced end-to-end encryption.
    /// Its journal is plaintext and read-only: viewing, export, archive and
    /// delete still work, every write is refused with `HISTORY_READ_ONLY`.
    /// The backend omits the field when false.
    public var legacyPlaintext: Bool?
    public var isLegacyPlaintext: Bool { legacyPlaintext == true }

    public init(
        id: String = UUID().uuidString,
        provider: String,
        workspace: String,
        workspaceId: String? = nil,
        title: String? = nil,
        titleEnc: JSONValue? = nil,
        providerProfile: String? = nil,
        status: String = "idle",
        archivedAt: String? = nil,
        lastSequence: Int = 0,
        createdAt: String = Date().ISO8601Format(),
        updatedAt: String? = nil,
        legacyPlaintext: Bool? = nil
    ) {
        self.id = id
        self.provider = provider
        self.workspace = workspace
        self.workspaceId = workspaceId
        self.title = title
        self.titleEnc = titleEnc
        self.providerProfile = providerProfile
        self.status = status
        self.archivedAt = archivedAt
        self.lastSequence = lastSequence
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.legacyPlaintext = legacyPlaintext
    }
}

public struct ProviderDescriptor: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var displayName: String
    public var available: Bool
    public var unavailableReason: String?
    public var profiles: [String]
    public var capabilities: JSONValue
    public var models: [JSONValue]

    public init(
        id: String,
        displayName: String,
        available: Bool,
        unavailableReason: String? = nil,
        profiles: [String] = [],
        capabilities: JSONValue = .object([:]),
        models: [JSONValue] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.available = available
        self.unavailableReason = unavailableReason
        self.profiles = profiles
        self.capabilities = capabilities
        self.models = models
    }
}

/// A stored workspace the backend could not validate (directory removed,
/// outside the allowed roots). `GET`/`PUT /v2/workspaces` list these apart
/// from the usable records so clients can grey them out.
public struct RejectedWorkspace: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var path: String
    public var code: String
    public var message: String

    public init(id: String, name: String, path: String, code: String = "", message: String = "") {
        self.id = id
        self.name = name
        self.path = path
        self.code = code
        self.message = message
    }

    private enum CodingKeys: String, CodingKey { case id, name, path, code, message }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        path = try c.decode(String.self, forKey: .path)
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }
}

/// Response of `GET`/`PUT /v2/workspaces`; `rejected` is omitted when empty.
public struct WorkspaceCatalog: Sendable, Equatable {
    public var workspaces: [WorkspaceRecord]
    public var rejected: [RejectedWorkspace]

    public init(workspaces: [WorkspaceRecord] = [], rejected: [RejectedWorkspace] = []) {
        self.workspaces = workspaces
        self.rejected = rejected
    }

    public init(response: JSONValue) throws {
        workspaces = try response["workspaces"].decoded([WorkspaceRecord].self)
        rejected = response["rejected"].isNull ? [] : try response["rejected"].decoded([RejectedWorkspace].self)
    }
}

/// The kanban task wire record shared with the desktop and web clients.
/// Timestamps are Unix milliseconds; `deletedAt` marks a tombstone so task
/// deletions propagate to other devices instead of resurrecting on merge.
public struct KanbanTaskRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var tenantId: String
    public var workspaceId: String
    public var title: String
    public var description: String?
    public var dueDate: String?
    public var status: String
    public var conversationId: String?
    public var createdAt: Int
    public var updatedAt: Int
    public var deletedAt: Int?

    /// The backend replaces tenantId with the authenticated owner when merging.
    public init(
        id: String,
        tenantId: String = "local",
        workspaceId: String,
        title: String,
        description: String? = nil,
        dueDate: String? = nil,
        status: String = "planned",
        conversationId: String? = nil,
        createdAt: Int,
        updatedAt: Int,
        deletedAt: Int? = nil
    ) {
        self.id = id
        self.tenantId = tenantId
        self.workspaceId = workspaceId
        self.title = title
        self.description = description
        self.dueDate = dueDate
        self.status = status
        self.conversationId = conversationId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// A persisted journal event, distinct from the outer WebSocket event envelope.
public struct ConversationEvent: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var sequence: Int
    public var eventId: String
    public var conversationId: String
    public var time: String
    public var type: String
    public var normalizedType: String?
    public var rawType: String?
    public var provider: String?
    public var payload: JSONValue

    public init(
        schemaVersion: Int = 2,
        sequence: Int = 0,
        eventId: String = "evt_\(UUID().uuidString)",
        conversationId: String = "",
        time: String = Date().ISO8601Format(),
        type: String,
        normalizedType: String? = nil,
        rawType: String? = nil,
        provider: String? = nil,
        payload: JSONValue = .object([:])
    ) {
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.eventId = eventId
        self.conversationId = conversationId
        self.time = time
        self.type = type
        self.normalizedType = normalizedType
        self.rawType = rawType
        self.provider = provider
        self.payload = payload
    }
}

/// Reads `/v2/providers/versions` entries and CLI operations with the defaults
/// older backends need; the wire values themselves stay JSONValue.
public enum CLIManagement {
    /// Older backends omit `installSupported` and cannot install.
    public static func installSupported(_ cli: JSONValue) -> Bool {
        cli["kind"].stringValue == "managed" && cli["installSupported"].boolValue
    }

    /// A missing CLI is `installed: false` / `status: "notInstalled"`. Either
    /// signal wins, since that state is not an error to report.
    public static func isInstalled(_ cli: JSONValue) -> Bool {
        cli["installed"] != false && cli["status"].stringValue != "notInstalled"
    }

    /// Older backends omit `action` and only run upgrades.
    public static func isInstall(_ operation: JSONValue) -> Bool {
        operation["action"].stringValue == "install"
    }
}

/// Envelope checks for a per-agent provider export (`todex.agent-providers`).
/// settingsConfig stays opaque; the backend remains authoritative for the
/// version, duplicate ids and masked secrets.
public enum AgentProviderTransfer {
    public static let format = "todex.agent-providers"
    /// The backend's import body limit: 100 providers × (256 KiB + 16 KiB).
    public static let maximumBytes = 100 * (256 + 16) * 1024

    /// Lets callers reject a file by its size before reading it.
    public static func checkSize(_ bytes: Int) throws {
        guard bytes <= maximumBytes else {
            throw TodexError.invalid(String(localized: "导入文件过大", bundle: .module))
        }
    }

    /// Number of providers in `data` when it is an export file for `agent`.
    public static func providerCount(in data: Data, agent: String) throws -> Int {
        try checkSize(data.count)
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = value else {
            throw TodexError.invalid(String(localized: "导入文件不是有效的 JSON 对象", bundle: .module))
        }
        guard value["format"].stringValue == format else {
            throw TodexError.invalid(String(localized: "所选文件不是 TodeX 供应商导出文件", bundle: .module))
        }
        let fileAgent = value["agent"].stringValue
        guard fileAgent == agent else {
            throw TodexError.invalid(
                String(localized: "该文件导出自 \(fileAgent.isEmpty ? "?" : fileAgent)，与所选 Agent（\(agent)）不一致", bundle: .module))
        }
        guard case .array(let providers) = value["providers"] else {
            throw TodexError.invalid(String(localized: "导入文件缺少供应商列表", bundle: .module))
        }
        return providers.count
    }
}
