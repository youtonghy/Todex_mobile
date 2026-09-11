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
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, sessionId, tenantId, threadId, model, reasoningEffort
        case approvalPolicy, sandboxMode, permissionProfile, approvalsReviewer, serviceTier
        case createdAt, updatedAt
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
    public var providerProfile: String?
    public var status: String
    public var archivedAt: String?
    public var lastSequence: Int
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String = UUID().uuidString,
        provider: String,
        workspace: String,
        workspaceId: String? = nil,
        title: String? = nil,
        providerProfile: String? = nil,
        status: String = "idle",
        archivedAt: String? = nil,
        lastSequence: Int = 0,
        createdAt: String = Date().ISO8601Format(),
        updatedAt: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.workspace = workspace
        self.workspaceId = workspaceId
        self.title = title
        self.providerProfile = providerProfile
        self.status = status
        self.archivedAt = archivedAt
        self.lastSequence = lastSequence
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
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
