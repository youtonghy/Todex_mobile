import Foundation

/// Source-audited command support, not a live provider capability probe.
public enum ProtocolCatalog {
    public static let webSocketPath = "/v2/ws"

    public enum Support: String, Codable, Sendable {
        case supported = "Supported"
        case conditional = "Conditional"
        case limited = "Limited"
        case unsupported = "Unsupported"
    }

    /// All types recognized by is_v2_native_command or ClientMessageKind.
    public enum Command: String, Codable, CaseIterable, Sendable {
        case conversationSubscribe = "conversation.subscribe"
        case conversationUnsubscribe = "conversation.unsubscribe"
        case conversationCreate = "conversation.create"
        case conversationPrompt = "conversation.prompt"
        case conversationFollowUp = "conversation.followUp"
        case conversationRetry = "conversation.retry"
        case conversationResume = "conversation.resume"
        case conversationFork = "conversation.fork"
        case conversationCompact = "conversation.compact"
        case conversationControl = "conversation.control"
        case conversationCancel = "conversation.cancel"
        case conversationInterrupt = "conversation.interrupt"
        case conversationStop = "conversation.stop"
        case conversationPermissionRespond = "conversation.permission.respond"
        case mcpList = "mcp.list"
        case mcpRefresh = "mcp.refresh"
        case mcpCall = "mcp.call"
        case serverPing = "server.ping"
        case sessionResume = "session.resume"
        case codexGatewayControl = "codex.gateway.control"
        case codexLocalStart = "codex.local.start"
        case codexLocalStatus = "codex.local.status"
        case codexLocalStop = "codex.local.stop"
        case codexLocalTurn = "codex.local.turn"
        case codexLocalInput = "codex.local.input"
        case codexLocalSteer = "codex.local.steer"
        case codexLocalInterrupt = "codex.local.interrupt"
        case codexLocalApprovalRespond = "codex.local.approval.respond"
        case codexLocalRequest = "codex.local.request"
        case codexLocalReplay = "codex.local.replay"
        case codexLocalAttach = "codex.local.attach"
        case codexLocalSnapshot = "codex.local.snapshot"
        case codexLocalUnsupported = "codex.local.unsupported"
        case terminalStart = "terminal.start"
        case terminalInput = "terminal.input"
        case terminalStop = "terminal.stop"
        case terminalResize = "terminal.resize"
        case terminalStatus = "terminal.status"
        case codexThreadStart = "codex.thread.start"
        case codexTurnStart = "codex.turn.start"
        case codexTurnSteer = "codex.turn.steer"
        case codexTurnInterrupt = "codex.turn.interrupt"
        case codexMcpServerListStatus = "codex.mcp.server.listStatus"
        case codexMcpResourceRead = "codex.mcp.resource.read"
        case codexMcpToolCall = "codex.mcp.tool.call"
        case codexMcpServerRefresh = "codex.mcp.server.refresh"
        case codexMcpOAuthLogin = "codex.mcp.oauth.login"
        case codexMcpElicitationRespond = "codex.mcp.elicitation.respond"
        case codexCloudTaskCreate = "codex.cloudTask.create"
        case codexCloudTaskList = "codex.cloudTask.list"
        case codexCloudTaskGetSummary = "codex.cloudTask.getSummary"
        case codexCloudTaskGetDiff = "codex.cloudTask.getDiff"
        case codexCloudTaskGetMessages = "codex.cloudTask.getMessages"
        case codexCloudTaskGetText = "codex.cloudTask.getText"
        case codexCloudTaskListSiblingAttempts = "codex.cloudTask.listSiblingAttempts"
        case codexCloudTaskApplyPreflight = "codex.cloudTask.applyPreflight"
        case codexCloudTaskApply = "codex.cloudTask.apply"
    }

    public struct CommandDescriptor: Sendable, Identifiable, Equatable {
        public let command: Command
        public let support: Support
        public let detail: String
        public var id: String { command.rawValue }
        public var type: String { command.rawValue }
    }

    public static let commands: [CommandDescriptor] = Command.allCases.map(descriptor)

    /// Unknown future commands are not mistaken for supported commands.
    public static func descriptor(type: String) -> CommandDescriptor? {
        Command(rawValue: type).map(descriptor)
    }

    public static func descriptor(_ command: Command) -> CommandDescriptor {
        let support: Support
        let detail: String
        switch command {
        case .conversationResume:
            support = .unsupported
            detail = "Native resume returns Unsupported. Use an explicit follow-up to continue."
        case .codexThreadStart, .codexTurnStart, .codexTurnSteer, .codexTurnInterrupt:
            support = .unsupported
            detail =
                "Schema recognized; handler returns Unsupported without an upstream app-server invocation. Use conversation.* or codex.local.*."
        case .codexMcpServerListStatus, .codexMcpResourceRead, .codexMcpToolCall,
            .codexMcpServerRefresh, .codexMcpOAuthLogin, .codexMcpElicitationRespond:
            support = .unsupported
            detail = "Legacy MCP handler returns Unsupported. Unified mcp.* has separate implemented handlers."
        case .codexCloudTaskCreate, .codexCloudTaskList, .codexCloudTaskGetSummary,
            .codexCloudTaskGetDiff, .codexCloudTaskGetMessages, .codexCloudTaskGetText,
            .codexCloudTaskListSiblingAttempts, .codexCloudTaskApplyPreflight, .codexCloudTaskApply:
            support = .unsupported
            detail = "Schema recognized; no cloud HTTP adapter invocation. Handler returns Unsupported."
        case .codexLocalUnsupported:
            support = .unsupported
            detail =
                "Intentionally emits codex.control.error with UNSUPPORTED_LOCAL; it does not execute the requested operation."
        case .codexGatewayControl:
            support = .limited
            detail =
                "Only payload.action = control is accepted and audited; all other actions return Unsupported. Acceptance does not execute a provider operation."
        case .codexLocalSnapshot:
            support = .limited
            detail =
                "Returns empty text with authoritative = false and source = codex.local.events. Replay events for actual content."
        case .conversationFork, .conversationCompact:
            support = .conditional
            detail =
                "Requires the selected provider's native fork/compact capability. Check the live providers catalog."
        case .conversationControl:
            support = .conditional
            detail =
                "Requires expectedTurnId and a typed control payload; support depends on the provider's live control probe."
        case .mcpList, .mcpRefresh, .mcpCall:
            support = .conditional
            detail =
                "Implemented unified MCP handler; requires an owned conversation and a supported configured MCP resource."
        case .codexLocalStart, .codexLocalStatus, .codexLocalStop, .codexLocalTurn,
            .codexLocalInput, .codexLocalSteer, .codexLocalInterrupt,
            .codexLocalApprovalRespond, .codexLocalRequest:
            support = .conditional
            detail =
                "Implemented local Codex adapter. Requires valid tenant/session scope; execution also depends on CLI availability, lifecycle and allowed native methods."
        case .terminalStart, .terminalInput, .terminalStop, .terminalResize, .terminalStatus:
            support = .conditional
            detail = "Implemented PTY handler; requires valid ownership, workspace trust and terminal lifecycle."
        case .sessionResume:
            support = .supported
            detail = "Scopes and replays existing Codex session cursors; this does not resume a provider turn."
        case .codexLocalReplay, .codexLocalAttach:
            support = .supported
            detail = "Replays the owned Codex gateway journal after a cursor."
        case .conversationSubscribe:
            support = .supported
            detail = "Replays through a captured high-water sequence, then forwards live events with gap recovery."
        case .conversationUnsubscribe:
            support = .supported
            detail = "Releases the per-connection subscription slot and stops the forwarding task; idempotent."
        case .conversationCreate, .conversationPrompt, .conversationFollowUp, .conversationRetry,
            .conversationCancel, .conversationInterrupt, .conversationStop, .conversationPermissionRespond:
            support = .supported
            detail =
                "Implemented conversation handler; runtime ownership, provider capability and lifecycle checks still apply."
        case .serverPing:
            support = .supported
            detail = "Returns server.result with pong = true."
        }
        return CommandDescriptor(command: command, support: support, detail: detail)
    }
}

/// Application command inside the plaintext or decrypted WebSocket channel.
/// Payload casing is preserved: v2/local/terminal use camelCase; older gateway/cloud payloads use snake_case.
public struct WebSocketCommandEnvelope: Codable, Sendable, Equatable {
    public var id: String
    public var type: String
    public var payload: JSONValue

    public init(id: String = UUID().uuidString, type: String, payload: JSONValue = .object([:])) {
        self.id = id
        self.type = type
        self.payload = payload
    }

    public init(id: String = UUID().uuidString, command: ProtocolCatalog.Command, payload: JSONValue = .object([:])) {
        self.init(id: id, type: command.rawValue, payload: payload)
    }

    private enum CodingKeys: String, CodingKey { case id, type, payload }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        payload = try c.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .null
    }
}

/// Native replies correlate with id; legacy event_id is a journal identity, not a request id.
public struct WebSocketEventEnvelope: Codable, Sendable, Equatable {
    public var id: String?
    public var type: String
    public var payload: JSONValue
    public var eventId: String?
    public var cursor: Int?
    public var codexSessionId: String?
    public var codexThreadId: String?
    public var codexTurnId: String?
    public var workspaceId: String?
    public var windowId: String?
    public var paneId: String?

    public init(
        id: String? = nil, type: String, payload: JSONValue,
        eventId: String? = nil, cursor: Int? = nil,
        codexSessionId: String? = nil, codexThreadId: String? = nil, codexTurnId: String? = nil,
        workspaceId: String? = nil, windowId: String? = nil, paneId: String? = nil
    ) {
        self.id = id
        self.type = type
        self.payload = payload
        self.eventId = eventId
        self.cursor = cursor
        self.codexSessionId = codexSessionId
        self.codexThreadId = codexThreadId
        self.codexTurnId = codexTurnId
        self.workspaceId = workspaceId
        self.windowId = windowId
        self.paneId = paneId
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, payload, cursor
        case eventId = "event_id"
        case codexSessionId = "codex_session_id"
        case codexThreadId = "codex_thread_id"
        case codexTurnId = "codex_turn_id"
        case workspaceId = "workspace_id"
        case windowId = "window_id"
        case paneId = "pane_id"
    }
}
