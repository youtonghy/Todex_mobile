import Foundation

/// Per-conversation state of the Codex local-adapter sidecar
/// (desktop `conversation.localAdapterState` + `threadId`/`turnId` tracking).
/// The value lives in AppSession's map keyed by conversation id; `threadId`
/// is the only field worth persisting because the adapter may still own the
/// thread on the backend host across app restarts.
public struct CodexLocalSidecar: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case idle, starting, running, stopped, error
    }
    public var phase: Phase = .idle
    /// Tenant that owns the adapter session; needed to send `codex.local.stop`
    /// after the conversation that created it no longer exists.
    public var tenantId = ""
    /// Native Codex thread the sidecar currently targets; "" until the first
    /// `thread/start` response lands.
    public var threadId = ""
    /// Adapter turn currently in flight on that thread; "" when idle.
    public var turnId = ""
    /// Last lifecycle/transport failure shown to the user.
    public var lastError = ""
    /// Latest `model/list` catalog for this adapter session (a Codex CLI's
    /// model menu), so `/model` can offer real entries on Codex sessions.
    public var models: [JSONValue] = []

    public init() {}
    public var isBusy: Bool { !turnId.isEmpty }
}

/// Wire-shape builders, event classification and approval bridging for the
/// `codex.local.*` command family. Every payload mirrors
/// `TodeX_desktop/src/renderer/session/useTodeXSession.ts` so both clients
/// emit byte-identical command bodies for the same action.
public enum CodexLocal {
    /// v2 conversations get a dedicated adapter session id so their events can
    /// be routed back to the manifest (desktop `conversationFromManifest`).
    public static func sessionId(for conversationId: String) -> String {
        "v2_\(conversationId)"
    }
    /// Inverse of `sessionId(for:)`; nil for legacy `cdxs_*` workspace
    /// sessions, which never map to a mobile conversation.
    public static func conversationId(forSessionId sessionId: String) -> String? {
        sessionId.hasPrefix("v2_") ? String(sessionId.dropFirst(3)) : nil
    }
    /// The adapter session id a frame belongs to, from either envelope shape:
    /// wrapped (`payload.codex_session_id`) or data-level fields.
    public static func sessionId(from frame: JSONValue) -> String {
        let payload = frame["payload"]
        return payload["codex_session_id"].optionalString
            ?? payload["codexSessionId"].optionalString
            ?? frame["codex_session_id"].optionalString
            ?? payload["data"]["codexSessionId"].optionalString
            ?? payload["data"]["codex_session_id"].optionalString
            ?? ""
    }
    /// `eventPayloadData` parity: wrapped adapter events carry their real
    /// fields under `payload.data`.
    public static func data(of frame: JSONValue) -> JSONValue {
        let payload = frame["payload"]
        if case .object = payload, case .object = payload["data"] { return payload["data"] }
        return payload
    }
    public static func cursor(of frame: JSONValue) -> Int {
        let value = frame["payload"]["cursor"].intValue
        return value > 0 ? value : frame["payload"]["data"]["cursor"].intValue
    }

    // MARK: - Command payloads

    /// `codex.local.start` (desktop `startLocalAdapter`): lazily boots the
    /// adapter process for this conversation's sidecar session.
    public static func startPayload(sessionId: String, workspace: WorkspaceRecord, defaults: (model: String, reasoningEffort: String, approvalsReviewer: String)) -> JSONValue {
        var payload: JSONValue = [
            "codexSessionId": .string(sessionId),
            "tenantId": .string(workspace.tenantId),
            "cwd": .string(workspace.path),
            "approvalPolicy": .string(workspace.approvalPolicy),
            "sandboxMode": .string(workspace.sandboxMode),
        ]
        let model = workspace.model.isEmpty ? defaults.model : workspace.model
        if !model.isEmpty { payload["model"] = .string(model) }
        let reviewer = workspace.approvalsReviewer ?? (defaults.approvalsReviewer.isEmpty ? nil : defaults.approvalsReviewer)
        if let reviewer { payload["approvalsReviewer"] = .string(reviewer) }
        let effort = workspace.reasoningEffort ?? (defaults.reasoningEffort.isEmpty ? nil : defaults.reasoningEffort)
        if let effort { payload["configOverrides"] = ["reasoningEffort": .string(effort)] }
        return payload
    }

    /// `codex.local.request` (desktop `sendLocalMethodRequest`).
    public static func requestPayload(sessionId: String, tenantId: String, method: String, params: JSONValue?) -> JSONValue {
        [
            "codexSessionId": .string(sessionId),
            "tenantId": .string(tenantId),
            "method": .string(method),
            "params": params ?? .object([:]),
        ]
    }

    /// `thread/start` params (desktop `ensureThreadId`): workspace permission
    /// fields map straight through — `sandbox` only when no profile is set.
    public static func threadStartParams(workspace: WorkspaceRecord, defaults: (model: String, reasoningEffort: String, approvalPolicy: String, approvalsReviewer: String, sandboxMode: String)) -> JSONValue {
        var params: JSONValue = ["cwd": .string(workspace.path)]
        let model = workspace.model.isEmpty ? defaults.model : workspace.model
        if !model.isEmpty { params["model"] = .string(model) }
        let effort = workspace.reasoningEffort ?? (defaults.reasoningEffort.isEmpty ? nil : defaults.reasoningEffort)
        if let effort { params["reasoningEffort"] = .string(effort) }
        let approval = workspace.approvalPolicy.isEmpty ? defaults.approvalPolicy : workspace.approvalPolicy
        if !approval.isEmpty { params["approvalPolicy"] = .string(approval) }
        let reviewer = workspace.approvalsReviewer ?? (defaults.approvalsReviewer.isEmpty ? nil : defaults.approvalsReviewer)
        if let reviewer { params["approvalsReviewer"] = .string(reviewer) }
        if let profile = workspace.permissionProfile, !profile.isEmpty {
            params["permissions"] = .string(profile)
        } else {
            let sandbox = workspace.sandboxMode.isEmpty ? defaults.sandboxMode : workspace.sandboxMode
            if !sandbox.isEmpty { params["sandbox"] = .string(sandbox) }
        }
        if let tier = workspace.serviceTier, !tier.isEmpty { params["serviceTier"] = .string(tier) }
        return params
    }

    /// A codex permission preset for the conversation's run mode
    /// (desktop `PERMISSION_PRESETS`): the sidecar turn payload carries the
    /// resolved policy, not the UI-level mode name.
    public struct PermissionPreset: Sendable, Equatable {
        public var approvalPolicy: String
        public var approvalsReviewer: String
        public var sandboxMode: String
        public var profileId: String
        public init(approvalPolicy: String, approvalsReviewer: String, sandboxMode: String, profileId: String) {
            self.approvalPolicy = approvalPolicy
            self.approvalsReviewer = approvalsReviewer
            self.sandboxMode = sandboxMode
            self.profileId = profileId
        }
        /// ask → workspace-write + on-request/user; auto → + auto_review;
        /// full-access → danger-full-access + never.
        public static func forMode(_ mode: String) -> PermissionPreset? {
            switch mode {
            case "ask", "default":
                return PermissionPreset(approvalPolicy: "on-request", approvalsReviewer: "user", sandboxMode: "workspace-write", profileId: ":workspace")
            case "auto", "auto-review":
                return PermissionPreset(approvalPolicy: "on-request", approvalsReviewer: "auto_review", sandboxMode: "workspace-write", profileId: ":workspace")
            case "full-access":
                return PermissionPreset(approvalPolicy: "never", approvalsReviewer: "user", sandboxMode: "danger-full-access", profileId: ":danger-full-access")
            default:
                return nil
            }
        }
    }

    /// `sandboxPolicyForMode` parity for `codex.local.turn`.
    public static func sandboxPolicy(for mode: String) -> JSONValue {
        switch mode.trimmingCharacters(in: .whitespaces).lowercased() {
        case "read-only", "readonly":
            return ["type": "readOnly", "networkAccess": .bool(false)]
        case "workspace-write", "workspacewrite":
            return [
                "type": "workspaceWrite", "writableRoots": .array([]), "networkAccess": .bool(false),
                "excludeTmpdirEnvVar": .bool(false), "excludeSlashTmp": .bool(false),
            ]
        case "danger-full-access", "dangerfullaccess", "full-access":
            return ["type": "dangerFullAccess"]
        default:
            return .null
        }
    }

    /// `codex.local.turn` payload (desktop `sendLocalTurn`). `input` items are
    /// codex input entries: text plus image references.
    public static func turnPayload(
        sessionId: String, tenantId: String, threadId: String, input: [JSONValue],
        preset: PermissionPreset, workMode: String, model: String, reasoningEffort: String, serviceTier: String?
    ) -> JSONValue {
        var payload: JSONValue = [
            "codexSessionId": .string(sessionId),
            "tenantId": .string(tenantId),
            "threadId": .string(threadId),
            "input": .array(input),
            "approvalPolicy": .string(preset.approvalPolicy),
            "approvalsReviewer": .string(preset.approvalsReviewer),
        ]
        if preset.profileId.isEmpty {
            if !preset.sandboxMode.isEmpty { payload["sandboxPolicy"] = sandboxPolicy(for: preset.sandboxMode) }
        } else {
            payload["permissions"] = .string(preset.profileId)
        }
        if let serviceTier, !serviceTier.isEmpty { payload["serviceTier"] = .string(serviceTier) }
        var settings: JSONValue = ["model": .string(model)]
        if !reasoningEffort.isEmpty { settings["reasoningEffort"] = .string(reasoningEffort) }
        settings["developerInstructions"] = .null
        payload["collaborationMode"] = [
            "mode": .string(workMode == "plan" ? "plan" : "default"),
            "settings": settings,
        ]
        return payload
    }

    /// `codexInputFromComposer` parity for text + image inputs. Mobile skill
    /// attachments carry a resource id rather than a codex path, so sidecar
    /// turns only send text and images.
    public static func inputItems(text: String, images: [(name: String, data: Data, mimeType: String)]) -> [JSONValue] {
        var items: [JSONValue] = [["type": "text", "text": .string(text)]]
        for image in images {
            items.append([
                "type": "image",
                "url": .string("data:\(image.mimeType);base64,\(image.data.base64EncodedString())"),
                "name": .string(image.name),
                "mimeType": .string(image.mimeType),
                "sizeBytes": .number(Double(image.data.count)),
            ])
        }
        return items
    }

    public static func interruptPayload(sessionId: String, tenantId: String, threadId: String, turnId: String) -> JSONValue {
        var payload: JSONValue = [
            "codexSessionId": .string(sessionId), "tenantId": .string(tenantId),
            "threadId": .string(threadId),
        ]
        if !turnId.isEmpty { payload["turnId"] = .string(turnId) }
        return payload
    }
    public static func stopPayload(sessionId: String, tenantId: String, force: Bool = false) -> JSONValue {
        ["codexSessionId": .string(sessionId), "tenantId": .string(tenantId), "force": .bool(force)]
    }
    public static func statusPayload(sessionId: String, tenantId: String) -> JSONValue {
        ["codexSessionId": .string(sessionId), "tenantId": .string(tenantId)]
    }
    public static func attachPayload(sessionId: String, tenantId: String, afterCursor: Int?, replayLimit: Int = 200) -> JSONValue {
        var payload: JSONValue = [
            "codexSessionId": .string(sessionId), "tenantId": .string(tenantId),
            "replayLimit": .number(Double(replayLimit)),
        ]
        payload["afterCursor"] = afterCursor.map { .number(Double($0)) } ?? .null
        return payload
    }
    public static func replayPayload(sessionId: String, tenantId: String, afterCursor: Int? = nil, limit: Int = 200) -> JSONValue {
        [
            "codexSessionId": .string(sessionId), "tenantId": .string(tenantId),
            "afterCursor": afterCursor.map { .number(Double($0)) } ?? .null, "limit": .number(Double(limit)),
        ]
    }

    // MARK: - Approval bridge

    /// `inferApprovalResponseType` parity: the request event type decides the
    /// JSON-RPC response method embedded in `codex.local.approval.respond`.
    public static func approvalResponseType(for requestType: String) -> String {
        switch requestType {
        case "codex.approval.commandExecution.request": return "codex.approval.commandExecution.respond"
        case "codex.approval.fileChange.request": return "codex.approval.fileChange.respond"
        case "codex.approval.permissions.request": return "codex.approval.permissions.respond"
        case "codex.tool.requestUserInput.request": return "codex.tool.requestUserInput.respond"
        case "codex.tool.call.request": return "codex.tool.call.respond"
        case "codex.mcp.elicitation.request": return "codex.mcp.elicitation.respond"
        case "codex.account.chatgptAuthTokens.refresh": return "codex.account.chatgptAuthTokens.refresh.respond"
        default: return "codex.approval.permissions.respond"
        }
    }

    /// `approvalResponsePayload` parity, fed with the normalized permission
    /// payload stored on `PendingPermission` and the UI decision
    /// (`outcome`/`data` produced by PermissionViewController).
    public static func approvalResponse(requestType: String, request: JSONValue, decision: JSONValue) -> JSONValue {
        let outcome = decision["outcome"].stringValue
        let accepted = ["allow_once", "allow_always", "answer"].contains(outcome)
        switch requestType {
        case "codex.approval.permissions.request":
            return [
                "permissions": accepted ? request["permissions"] : .object([:]),
                "scope": "turn",
                "strictAutoReview": .bool(false),
            ]
        case "codex.tool.requestUserInput.request":
            if outcome == "answer", case .object = decision["data"]["answers"] {
                return ["answers": decision["data"]["answers"]]
            }
            var answers: [String: JSONValue] = [:]
            for question in request["questions"].arrayValue {
                if let id = question["id"].optionalString, !id.isEmpty {
                    answers[id] = ["answers": [.string(accepted ? "yes" : "no")]]
                }
            }
            return ["answers": .object(answers.isEmpty ? ["response": ["answers": [.string(accepted ? "yes" : "no")]]] : answers)]
        case "codex.mcp.elicitation.request":
            if outcome == "answer" { return ["action": "accept", "content": decision["data"], "_meta": .null] }
            return ["action": .string(accepted ? "accept" : "decline"), "content": .object([:]), "_meta": .null]
        default:
            return ["decision": .string(accepted ? "accept" : "decline")]
        }
    }

    public static func approvalRespondPayload(sessionId: String, tenantId: String, requestId: String, requestType: String, request: JSONValue, decision: JSONValue) -> JSONValue {
        [
            "codexSessionId": .string(sessionId),
            "tenantId": .string(tenantId),
            "requestId": .string(requestId),
            "responseType": .string(approvalResponseType(for: requestType)),
            "response": approvalResponse(requestType: requestType, request: request, decision: decision),
        ]
    }

    // MARK: - Lifecycle classification helpers

    /// Backend text patterns that prove a start actually succeeded even when
    /// the response framed it as an error (desktop `isLocalAdapterAlreadyRunning`).
    public static func isAlreadyRunning(_ text: String) -> Bool {
        text.range(of: #"adapter already owns this session"#, options: .regularExpression) != nil
    }
    public static func isThreadNotFound(_ text: String) -> Bool {
        text.range(of: "thread not found", options: .caseInsensitive) != nil
    }
    /// Raw error text → the user-facing line the desktop shows for the same
    /// failure (`localTurnErrorMessage`).
    public static func describeError(_ text: String) -> String {
        if isThreadNotFound(text) {
            return String(localized: "本地线程已失效，请重试操作", bundle: .module)
        }
        if text.range(of: #"local Codex adapter is not ready;\s*current state is Failed"#, options: .regularExpression) != nil {
            return String(localized: "本地 Codex 会话状态不可用，请停止后重试", bundle: .module)
        }
        if isAlreadyRunning(text) {
            return String(localized: "本地 Codex 会话已在运行", bundle: .module)
        }
        if text.range(of: "unsupported_action", options: .caseInsensitive) != nil
            || text.range(of: "not running for this session", options: .caseInsensitive) != nil
        {
            return String(localized: "本地 Codex 会话未运行", bundle: .module)
        }
        return text
    }

    /// `threadId`/`turnId` extraction shared by event frames and command
    /// results (desktop `threadIdFromEventData`/`turnIdFromEventData`).
    public static func threadId(in data: JSONValue) -> String {
        let result = data["result"]
        let candidates: [JSONValue] = [
            data["threadId"], data["thread_id"], data["codexThreadId"], data["codex_thread_id"],
            result["threadId"], result["thread_id"], result["codexThreadId"], result["codex_thread_id"],
            result["id"], result["thread"]["id"], result["thread"]["threadId"], result["thread"]["thread_id"],
            data["payload"]["threadId"], data["payload"]["thread_id"], data["payload"]["codexThreadId"],
            data["payload"]["codex_thread_id"],
        ]
        for candidate in candidates {
            if let value = candidate.optionalString, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return value.trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }
    public static func turnId(in data: JSONValue) -> String {
        let candidates = [
            data["turnId"], data["turn_id"], data["codexTurnId"], data["codex_turn_id"],
            data["turn"]["id"], data["result"]["turnId"], data["result"]["turn_id"], data["result"]["turn"]["id"],
        ]
        for candidate in candidates {
            if let value = candidate.optionalString, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return value.trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }
    public static func requestId(in data: JSONValue) -> String {
        for candidate in [data["requestId"], data["request_id"], data["permissionId"], data["permission_id"], data["id"]] {
            if let value = candidate.optionalString, !value.isEmpty { return value }
        }
        return ""
    }

    /// `isPendingRequestType` parity.
    public static func isRequest(_ type: String) -> Bool {
        type.hasSuffix(".request")
            || type == "codex.tool.requestUserInput.request"
            || type == "codex.account.chatgptAuthTokens.refresh"
    }

    /// `titleForRequest` parity.
    public static func requestTitle(_ type: String, data: JSONValue) -> String {
        let requestId = requestId(in: data)
        let base = requestId.isEmpty ? "" : "\(requestId) · "
        switch type {
        case "codex.approval.commandExecution.request": return "\(base)command approval"
        case "codex.approval.fileChange.request": return "\(base)file approval"
        case "codex.approval.permissions.request": return "\(base)permission approval"
        case "codex.tool.requestUserInput.request": return "\(base)question"
        case "codex.tool.call.request": return "\(base)tool call"
        case "codex.account.chatgptAuthTokens.refresh": return "\(base)token refresh"
        default: return "\(base)\(type)"
        }
    }

    /// The `kind` the permission sheet understands, derived from the adapter
    /// request type so its form controls match the wire schema.
    public static func requestKind(_ type: String) -> String {
        switch type {
        case "codex.tool.requestUserInput.request": return "user_input"
        case "codex.mcp.elicitation.request": return "elicitation"
        default: return "approval"
        }
    }
    /// Options adapter requests expose. A payload that already carries the v2
    /// option schema passes through unchanged; otherwise the request type gets
    /// the accept/decline (plus answer where a form exists) set the desktop
    /// offers.
    public static func requestOptions(type: String, data: JSONValue) -> [JSONValue] {
        let existing = data["options"].arrayValue
        if !existing.isEmpty, existing.allSatisfy({ $0["optionId"].optionalString != nil && $0["kind"].optionalString != nil }) {
            return existing
        }
        switch type {
        case "codex.tool.requestUserInput.request", "codex.mcp.elicitation.request":
            return [
                ["optionId": "answer", "name": "Submit", "kind": "answer"],
                ["optionId": "decline", "name": "Decline", "kind": "reject_once"],
            ]
        default:
            return [
                ["optionId": "accept", "name": "Approve", "kind": "allow_once"],
                ["optionId": "decline", "name": "Decline", "kind": "reject_once"],
            ]
        }
    }

    // MARK: - Event classification

    /// Everything one `codex.*` frame implies for a conversation's UI state.
    /// `ConversationRuntime.applyLocal` consumes it; entries are unsequenced
    /// sidecar rows, never journal events.
    public struct Effects: Sendable {
        public var entries: [TimelineMessage] = []
        /// Adapter permission requests to surface as pending approvals.
        public var requests: [PendingPermission] = []
        /// Request ids a `codex.serverRequest.resolved` frame just settled.
        public var resolvedRequests: [String] = []
        /// Native thread id discovered on the wire (thread/start result,
        /// thread/* notifications) — the sidecar adopts it.
        public var threadId: String?
        /// Adapter turn lifecycle for the sidecar's own turn tracker.
        public var turnStarted: String?
        public var turnSettled: (id: String, status: String)?
        /// Adapter lifecycle hint from control frames (ready/stopped).
        public var lifecycle: CodexLocalSidecar.Phase?
        /// Fresh model/list catalog carried by a response or notification.
        public var modelCatalog: [JSONValue]?
        /// Text worth an immediate error/status row (adapter failure, denied).
        public var alert: String?
        public init() {}
    }

    /// Classify one wire frame. `session` is the sidecar id this frame was
    /// routed under; control ack frames are filtered out because the awaiting
    /// command already surfaced their result.
    public static func classify(type: String, frame: JSONValue, sessionId: String, activeTurnId: String) -> Effects {
        var effects = Effects()
        let data = data(of: frame)
        switch type {
        case "codex.control.ready", "codex.local.lifecycle":
            if data["lifecycleState"].optionalString == nil || data["lifecycleState"].stringValue == "ready" {
                effects.lifecycle = .running
            } else if data["lifecycleState"].stringValue == "stopped" {
                effects.lifecycle = .stopped
            }
            return effects
        case "codex.control.stopped":
            effects.lifecycle = .stopped
            return effects
        case "codex.control.status", "codex.control.response", "codex.control.request.accepted":
            return effects
        case "codex.local.snapshot", "codex.local.unsupported":
            return effects
        case "codex.control.error", "codex.error":
            let message = data["message"].optionalString ?? data["error"]["message"].optionalString ?? data["error"].optionalString ?? type
            effects.alert = describeError(message)
            effects.entries.append(errorEntry(message, turnId: activeTurnId))
            return effects
        default:
            break
        }

        if type == "codex.serverRequest.resolved" || type == "permission.resolved" {
            let id = requestId(in: data)
            if !id.isEmpty { effects.resolvedRequests.append(id) }
            return effects
        }

        if isRequest(type) {
            let id = requestId(in: data)
            if !id.isEmpty {
                var payload: JSONValue = [
                    "kind": .string(requestKind(type)),
                    "title": .string(requestTitle(type, data: data)),
                    "details": data,
                    "options": .array(requestOptions(type: type, data: data)),
                ]
                payload["codex"] = [
                    "requestType": .string(type),
                    "requestId": .string(id),
                    "codexSessionId": .string(sessionId),
                ]
                effects.requests.append(
                    PendingPermission(id: id, turnId: "", payload: payload, scope: "session", runtimeId: "codex-local:\(sessionId)"))
                effects.entries.append(progressEntry(
                    id: "local-req-\(id)", title: requestTitle(type, data: data), category: "approval", status: "awaitingApproval",
                    detail: data, turnId: activeTurnId))
            }
            return effects
        }

        // Thread notifications patch sidecar state (desktop nativeThreadPatch).
        if let patch = threadPatch(type: type, data: data) {
            effects.threadId = patch
        }
        switch type {
        case "codex.turn.started":
            let id = turnId(in: data)
            effects.turnStarted = id.isEmpty ? nil : id
            effects.entries.append(statusEntry("turn", text: String(localized: "Codex 本地任务开始", bundle: .module), turnId: id, detail: data))
            return effects
        case "codex.turn.completed":
            let id = turnId(in: data)
            effects.turnSettled = (id, "completed")
            return effects
        case "codex.turn.interrupted":
            let id = turnId(in: data)
            effects.turnSettled = (id, "cancelled")
            effects.entries.append(statusEntry("turn", text: String(localized: "本地任务已中断", bundle: .module), turnId: id, detail: data))
            return effects
        case "codex.turn.failed":
            let id = turnId(in: data)
            effects.turnSettled = (id, "failed")
            let message = progressText(data) ?? data["error"]["message"].optionalString ?? data["error"].optionalString ?? ""
            effects.entries.append(errorEntry(message.isEmpty ? String(localized: "本地任务失败", bundle: .module) : message, turnId: id))
            return effects
        default:
            break
        }

        // Assistant stream: deltas and full items append to one row per item.
        if type == "codex.item.agentMessage.delta" {
            let itemId = data["itemId"].optionalString ?? data["item_id"].optionalString ?? UUID().uuidString
            let delta = data["delta"].stringValue
            if !delta.isEmpty {
                effects.entries.append(
                    TimelineMessage(
                        id: "local-item-\(itemId)", turnId: activeTurnId, role: "assistant",
                        category: "assistant_final", text: delta, status: "streaming",
                        detail: data, streamed: true))
            }
            return effects
        }
        let item = data["item"]
        if case .object = item, type == "codex.item.started" || type == "codex.item.completed" {
            let itemType = item["type"].stringValue
            if itemType == "agentMessage" || itemType == "agent_message" {
                let itemId = item["id"].optionalString ?? UUID().uuidString
                let text = itemText(item)
                effects.entries.append(
                    TimelineMessage(
                        id: "local-item-\(itemId)", turnId: activeTurnId, role: "assistant",
                        category: "assistant_final", text: text.isEmpty ? "…" : text,
                        status: type == "codex.item.completed" ? "completed" : "streaming",
                        detail: data, streamed: true))
            } else {
                effects.entries.append(contentsOf: itemEntries(item, type: type, turnId: activeTurnId))
            }
            return effects
        }

        // Everything else is progress noise: reasoning, tool calls, MCP…
        if let entry = progressRow(type: type, data: data, turnId: activeTurnId) {
            effects.entries.append(entry)
        }
        return effects
    }

    /// `nativeThreadPatchFromNotification` parity: thread/* notifications that
    /// carry a thread id the sidecar should adopt or annotate.
    private static func threadPatch(type: String, data: JSONValue) -> String? {
        let id = threadId(in: data)
        guard !id.isEmpty else { return nil }
        switch type {
        case "codex.thread/started", "codex.thread.started",
            "codex.thread/archived", "codex.thread.archived",
            "codex.thread/unarchived", "codex.thread.unarchived",
            "codex.thread/closed", "codex.thread.closed",
            "codex.thread/status/changed", "codex.thread.status.changed",
            "codex.thread/name/updated", "codex.thread.name.updated":
            return id
        default:
            return data["method"].stringValue.hasPrefix("thread/") ? id : nil
        }
    }

    /// Tool/command items render as trace rows (desktop classifyProgressEvent):
    /// started → running, completed → completed, failed → failed.
    private static func itemEntries(_ item: JSONValue, type: String, turnId: String) -> [TimelineMessage] {
        let itemType = item["type"].stringValue
        let isReasoning = ["reasoning", "thinking", "thought", "analysis"].contains {
            itemType.range(of: $0, options: .caseInsensitive) != nil
        }
        let text = itemText(item)
        guard !text.isEmpty else { return [] }
        let id = item["id"].optionalString ?? UUID().uuidString
        let status = type.hasSuffix(".completed") ? "completed" : "running"
        return [
            TimelineMessage(
                id: "local-item-\(id)", turnId: turnId, role: "system",
                category: isReasoning ? "reasoning" : "tool", text: text, status: status,
                detail: item)
        ]
    }

    /// The last leg of `classifyProgressEvent`: reasoning/tool patterns on the
    /// event type itself, interrupted/failed markers, and plain status lines.
    private static func progressRow(type: String, data: JSONValue, turnId: String) -> TimelineMessage? {
        let text = progressText(data) ?? ""
        let reasoning = type.range(of: "reasoning|thinking|thought|analysis", options: [.regularExpression, .caseInsensitive]) != nil
        let tooling = type.range(of: "tool|command|mcp|approval|requestUserInput", options: [.regularExpression, .caseInsensitive]) != nil
        if reasoning {
            guard !text.isEmpty, !isLifecycleText(text) else { return nil }
            return TimelineMessage(
                id: "local-progress-\(UUID().uuidString)", turnId: turnId, role: "system",
                category: "reasoning", text: text, status: "completed", detail: data)
        }
        if tooling {
            guard !text.isEmpty || type.hasSuffix(".request") else { return nil }
            return progressEntry(
                id: "local-progress-\(UUID().uuidString)", title: text.isEmpty ? type : text,
                category: type.hasSuffix(".request") ? "approval" : "status",
                status: type.hasSuffix(".completed") ? "completed" : "running", detail: data, turnId: turnId)
        }
        if type.range(of: "interrupted|failed|error", options: [.regularExpression, .caseInsensitive]) != nil {
            return errorEntry(text.isEmpty ? type : text, turnId: turnId)
        }
        return nil
    }

    /// `progressTextFromData` parity: pick the first human-readable field.
    private static func progressText(_ data: JSONValue) -> String? {
        for key in ["delta", "text", "message", "summary", "status", "reason", "operation", "command", "question"] {
            if let value = data[key].optionalString, !value.isEmpty { return value }
        }
        for question in data["questions"].arrayValue {
            if let text = question["question"].optionalString, !text.isEmpty { return text }
        }
        if case .object = data["item"], let text = Optional(itemText(data["item"])), !text.isEmpty { return text }
        if case .object = data["result"], let text = progressText(data["result"]) { return text }
        return nil
    }
    private static func isLifecycleText(_ text: String) -> Bool {
        ["starting", "ready", "started", "completed", "running", "idle", "busy"]
            .contains(text.trimmingCharacters(in: .whitespaces).lowercased())
    }
    private static func itemText(_ item: JSONValue) -> String {
        if let direct = item["text"].optionalString ?? item["message"].optionalString ?? item["summary"].optionalString {
            return direct
        }
        var parts: [String] = []
        for part in item["content"].arrayValue {
            if let text = part.optionalString { parts.append(text); continue }
            if let text = part["text"].optionalString { parts.append(text); continue }
            if let name = part["name"].optionalString, !name.isEmpty { parts.append("@\(name)"); continue }
            if let path = part["path"].optionalString { parts.append(path); continue }
            if let url = part["url"].optionalString { parts.append(url) }
        }
        if let command = item["command"].optionalString ?? item["name"].optionalString ?? item["toolName"].optionalString
            ?? item["tool_name"].optionalString, parts.isEmpty
        {
            return command
        }
        return parts.joined()
    }

    private static func progressEntry(id: String, title: String, category: String, status: String, detail: JSONValue, turnId: String) -> TimelineMessage {
        TimelineMessage(
            id: id, turnId: turnId, role: "system", category: category,
            text: title, status: status, detail: detail)
    }
    private static func statusEntry(_ prefix: String, text: String, turnId: String, detail: JSONValue) -> TimelineMessage {
        TimelineMessage(
            id: "local-\(prefix)-\(turnId.isEmpty ? UUID().uuidString : turnId)-started",
            turnId: turnId, role: "system", category: "status", text: text, status: "completed", detail: detail)
    }
    private static func errorEntry(_ text: String, turnId: String) -> TimelineMessage {
        TimelineMessage(
            id: "local-error-\(UUID().uuidString)", turnId: turnId, role: "system",
            category: "error", text: describeError(text), status: "failed", detail: .null)
    }

    // MARK: - Result parsers (result pages)

    /// `parseCodexModelListResponse` parity: normalize whatever the adapter
    /// returned into catalog entries; empty when the response lacks models.
    public static func modelCatalog(from result: JSONValue) -> [JSONValue] {
        var seen = Set<String>()
        var items: [JSONValue] = []
        let containers: [JSONValue] = [result, result["result"], result["payload"], result["data"], result["models"], result["result"]["models"]]
        var raw: [JSONValue] = []
        for container in containers {
            if case .array(let list) = container { raw = list; break }
            if case .array(let list) = container["models"] { raw = list; break }
            if case .array(let list) = container["items"] { raw = list; break }
        }
        for entry in raw {
            guard case .object = entry else { continue }
            let model = entry["model"].optionalString ?? entry["id"].optionalString ?? entry["name"].optionalString ?? ""
            guard !model.isEmpty, seen.insert(model).inserted else { continue }
            var item = entry
            item["model"] = .string(model)
            if item["displayName"].isNull, let name = entry["display_name"].optionalString ?? entry["name"].optionalString {
                item["displayName"] = .string(name)
            }
            items.append(item)
        }
        return items
    }
    /// Catalog entries grouped for the picker: model id → display label and
    /// supported service tiers (desktop `serviceTiersForModel`).
    public static func serviceTiers(for model: String, catalog: [JSONValue]) -> [JSONValue] {
        let entry = catalog.first {
            $0["model"].stringValue == model || $0["id"].stringValue == model
        }
        let tiers = (entry?["serviceTiers"].arrayValue ?? entry?["service_tiers"].arrayValue ?? [])
        return tiers.isEmpty ? [["id": "default", "name": "default"], ["id": "fast", "name": "fast"]] : tiers
    }
    /// `/fast` toggles to the catalog's fast tier and back (desktop
    /// `toggleFastServiceTier`): nil when the catalog offers no fast tier.
    public static func fastTier(for model: String, catalog: [JSONValue]) -> JSONValue? {
        serviceTiers(for: model, catalog: catalog).first {
            $0["id"].stringValue == "fast" || $0["name"].stringValue.lowercased() == "fast"
        }
    }
    /// Dynamic service-tier slash command names for the suggestion list
    /// (desktop `serviceTierSlashCommandsForModel`): every tier name the
    /// catalog advertises that is not a built-in command already.
    public static func serviceTierCommands(for model: String, catalog: [JSONValue], existing: Set<String>) -> [String] {
        serviceTiers(for: model, catalog: catalog).compactMap { tier in
            let name = tier["name"].optionalString ?? tier["id"].optionalString ?? ""
            let command = "/\(name.lowercased())"
            return name.isEmpty || existing.contains(command) ? nil : command
        }
    }
    public static func serviceTier(forCommand command: String, model: String, catalog: [JSONValue]) -> JSONValue? {
        let name = command.dropFirst().lowercased()
        guard !name.isEmpty else { return nil }
        return serviceTiers(for: model, catalog: catalog).first {
            $0["name"].stringValue.lowercased() == name || $0["id"].stringValue.lowercased() == name
        }
    }
}
