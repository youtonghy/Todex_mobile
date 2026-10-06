import Foundation

public struct TimelineMessage: Identifiable, Sendable, Equatable {
    public var id: String
    public var turnId: String
    public var role: String
    public var category: String
    public var text: String
    public var status: String
    public var detail: JSONValue
    /// Source event sequence; process-detail hydration merges and orders by it.
    public var sequence: Int
    /// The row grew from streamed deltas, so a completion carrying the full
    /// text can cover it; rows created by complete snapshots never do.
    public var streamed: Bool

    public init(
        id: String, turnId: String, role: String, category: String, text: String,
        status: String, detail: JSONValue, sequence: Int = 0, streamed: Bool = false
    ) {
        self.id = id
        self.turnId = turnId
        self.role = role
        self.category = category
        self.text = text
        self.status = status
        self.detail = detail
        self.sequence = sequence
        self.streamed = streamed
    }
}

public struct PendingPermission: Identifiable, Sendable {
    public var id: String
    /// Empty for session-scoped requests, which outlive any single turn.
    public var turnId: String
    public var payload: JSONValue
    /// "session" requests (e.g. Pi extension dialogs) stay pending across turn
    /// boundaries; "turn" requests are cleared when their turn ends.
    public var scope: String
    /// Provider runtime that owns the request; its stop invalidates the request.
    public var runtimeId: String

    public init(id: String, turnId: String, payload: JSONValue, scope: String = "turn", runtimeId: String = "") {
        self.id = id
        self.turnId = turnId
        self.payload = payload
        self.scope = scope
        self.runtimeId = runtimeId
    }
    public var isSessionScoped: Bool { scope == "session" }

    /// Whether `deviceID` may answer. Requests that name their answering
    /// devices (`allowedDeviceIds`) are rejected by the daemon from any other
    /// device; `nil` means allowed, otherwise the names to show (from
    /// `details.executors`, possibly empty). Mirrors `permissionDeviceGate`.
    public func requiredDeviceNames(for deviceID: String?) -> [String]? {
        guard case .array(let raw) = payload["allowedDeviceIds"] else { return nil }
        let allowed = raw.compactMap(\.optionalString)
        if let deviceID, allowed.contains(deviceID) { return nil }
        var names: [String] = []
        for executor in payload["details"]["executors"].arrayValue {
            guard let id = executor["deviceId"].optionalString, allowed.contains(id) else { continue }
            let name = executor["deviceName"].stringValue.trimmingCharacters(in: .whitespaces)
            let label = name.isEmpty ? id : name
            if !names.contains(label) { names.append(label) }
        }
        return names
    }
}

/// A single value projection shared by REST replay and live delivery. As in the
/// shared TypeScript runtime, messages and usage records are newest first.
public struct ConversationRuntime: Sendable {
    public let conversationId: String
    public private(set) var appliedSequence = 0
    public private(set) var highWaterSequence = 0
    public var needsRecovery: Bool { !replayComplete || appliedSequence < highWaterSequence }
    public var readyForActions: Bool { !needsRecovery }
    public private(set) var status = "idle"
    public private(set) var activeTurnId = ""
    public private(set) var messages: [TimelineMessage] = []
    public private(set) var pendingPermissions: [PendingPermission] = []
    /// Normalized top-level counters use null for unknown values, including totals
    /// that cannot be inferred safely from the provider's cache semantics.
    public private(set) var usageRecords: [JSONValue] = []
    public private(set) var queueItems: [JSONValue] = []
    public private(set) var queuePaused = false
    /// The daemon-held follow-up queue (`followups.updated` or
    /// `conversation.queue.list`), separate from a provider's native queue.
    /// Items carry `id`, `text`, `status`, `queuedAt`, `contentCount`, `skills`.
    public private(set) var followUps: [JSONValue] = []
    public private(set) var followUpsPaused = false
    public private(set) var followUpsPauseReason = ""
    public private(set) var followUpsPauseMessage = ""
    public private(set) var effectiveConfig: JSONValue = .null
    public private(set) var requestedConfig: JSONValue = .null
    public private(set) var configurationStatus = "unknown"
    /// Why the provider rejected the latest configure request; empty otherwise.
    public private(set) var configurationError = ""
    public private(set) var compaction: JSONValue = ["status": "idle", "recommended": false, "updatedAt": ""]
    public private(set) var subagents: [JSONValue] = []
    public private(set) var memoryEntries: [JSONValue] = []
    /// Agent desktop browser: grant, open tab and newest actions
    /// (`desktop.browser.*`). History pages do not extend it.
    public private(set) var desktopBrowser = DesktopBrowserState()
    /// Computer Use: session, host grant and newest actions
    /// (`desktop.computer.*`). History pages do not extend it.
    public private(set) var desktopComputer = DesktopComputerState()
    public private(set) var lastProgressAt: Date?

    public static let maximumBufferedEvents = 1_024
    public static let maximumBufferedBytes = 8 * 1_024 * 1_024
    public var bufferedEventCount: Int { pendingEvents.count }
    public var bufferedByteCount: Int { pendingBytes }
    public var actionablePermissions: [PendingPermission] { readyForActions ? pendingPermissions : [] }

    private struct BufferedEvent: Sendable {
        let event: ConversationEvent
        let bytes: Int
    }
    private var pendingEvents: [Int: BufferedEvent] = [:]
    private var pendingBytes = 0
    private var replayComplete = false
    /// The shared assistant stream splits into a new segment whenever activity
    /// lands between two chunks, so narration interleaves with folded steps.
    private var assistantSegment = 0
    private var assistantInterrupted = false
    private var latestTurnId = ""
    private var startedTurns: Set<String> = []
    private var retiredRuntimeIds: Set<String> = []
    private var messageCategories: [String: String] = [:]
    private var configurationRequestId = ""
    private var cumulativeUsage: [String: [String: Double]] = [:]
    private var turnCumulativeUsage: [String: [String: Double]] = [:]
    private var turnUsageTotals: [String: [String: Double]] = [:]
    private var finalUsageTurns: Set<String> = []

    public init(conversationId: String) { self.conversationId = conversationId }

    /// Call before reconnect/replay, even when no sequence gap is visible yet.
    /// Failed or partial replay leaves actions disabled until a successful retry.
    public mutating func beginReplay() { replayComplete = false }

    /// Open recovery at the journal tail instead of sequence 0: `floor` becomes
    /// the applied cursor so the next event accepted is `floor + 1`. Live frames
    /// buffered before the seed stay buffered when they belong above the floor;
    /// frames at or below it are already inside the loaded window and drop.
    /// Returns false once any event has applied — the forward replay path then
    /// owns every sequence below the tail window.
    @discardableResult
    public mutating func seedHistoryFloor(_ floor: Int) -> Bool {
        guard appliedSequence == 0, floor > 0 else { return false }
        appliedSequence = floor
        pendingEvents = pendingEvents.filter { $0.key > floor }
        pendingBytes = pendingEvents.values.reduce(0) { $0 + $1.bytes }
        return true
    }

    /// Merge a page of older history fetched with `beforeSequence`. The events
    /// replay on a scratch runtime so stale turn/permission/usage state cannot
    /// overwrite the newest window; only projected timeline entries append
    /// (newest-first list, so older pages go to the tail). Entries already
    /// loaded keep their newer-window version. Auxiliary collections (subagent
    /// runs, memory entries) merge per entry: a run whose `subagent.started`
    /// pages in below the window fills the title, task and lifecycle the
    /// loaded window only saw as `subagent.updated` frames.
    @discardableResult
    public mutating func prepend(_ events: [ConversationEvent], below floor: Int) -> Bool {
        let sorted = events
            .filter { $0.conversationId == conversationId && $0.sequence <= floor }
            .sorted { $0.sequence < $1.sequence }
        guard !sorted.isEmpty else { return false }
        var scratch = ConversationRuntime(conversationId: conversationId)
        for event in sorted {
            scratch.apply(event)
        }
        let existing = Set(messages.map(\.id))
        let older = scratch.messages.filter { !existing.contains($0.id) }
        let merged = Self.droppingCoveredAssistantSegments(
            Self.droppingSupersededProgress(messages + older))
        let mergedSubagents = Self.partitionSettledSubagents(
            Self.mergingEarlier(scratch.subagents, into: subagents, merge: Self.mergeEarlierSubagent))
        let mergedMemories = Self.mergingEarlier(scratch.memoryEntries, into: memoryEntries)
        guard merged != messages || mergedSubagents != subagents || mergedMemories != memoryEntries
        else { return false }
        messages = merged
        subagents = mergedSubagents
        memoryEntries = mergedMemories
        return true
    }

    public mutating func markReplayComplete(highWater: Int) {
        guard highWater >= 0 else { return }
        highWaterSequence = max(highWaterSequence, highWater)
        replayComplete = appliedSequence >= highWaterSequence && pendingEvents.isEmpty
    }

    public mutating func ingest(_ event: ConversationEvent) {
        guard event.conversationId == conversationId, event.sequence > appliedSequence,
            !event.eventId.isEmpty, !event.type.isEmpty, !event.time.isEmpty,
            pendingEvents[event.sequence] == nil
        else { return }
        highWaterSequence = max(highWaterSequence, event.sequence)
        // sequence > appliedSequence proves that adding one cannot overflow.
        if event.sequence == appliedSequence + 1 {
            apply(event)
            while appliedSequence < Int.max,
                let next = pendingEvents.removeValue(forKey: appliedSequence + 1)
            {
                pendingBytes -= next.bytes
                apply(next.event)
            }
        } else {
            replayComplete = false
            // Overflow drops only unapplied data. The high-water mark remains,
            // so replay must fetch it again from the contiguous applied cursor.
            guard pendingEvents.count < Self.maximumBufferedEvents,
                let bytes = try? JSONEncoder().encode(event).count,
                bytes <= Self.maximumBufferedBytes - pendingBytes
            else { return }
            pendingEvents[event.sequence] = BufferedEvent(event: event, bytes: bytes)
            pendingBytes += bytes
        }
    }

    private mutating func apply(_ event: ConversationEvent) {
        appliedSequence = event.sequence
        let payload = event.payload
        let type = Self.canonicalType(event)
        let explicitTurn = Self.string(
            payload["turnId"], payload["turn_id"],
            payload["block"]["turnId"], payload["block"]["turn_id"])
        if type == "turn.started", !explicitTurn.isEmpty, !startedTurns.contains(explicitTurn) {
            startedTurns.insert(explicitTurn)
            latestTurnId = explicitTurn
            activeTurnId = explicitTurn
            assistantSegment = 0
            assistantInterrupted = false
            status = "running"
            pendingPermissions.removeAll { !$0.isSessionScoped }
            requestedConfig = Self.objectOrNull(payload["requestedPermissions"])
            effectiveConfig = Self.objectOrNull(payload["effectivePermissions"])
            if !effectiveConfig.isNull { effectiveConfig["source"] = "locally-validated" }
            configurationStatus = payload["configurationStatus"] == "validated" ? "validated" : "unknown"
            configurationRequestId = ""
            configurationError = ""
        }
        let permissionEvent = ["permission.requested", "permission.resolved", "tool.awaitingApproval"].contains(type)
        // Mirrors the shared TS runtime: session-scoped requests are not bound
        // to a turn, so they neither need an active turn nor end with one.
        let sessionScoped = permissionEvent && Self.permissionScope(payload) == "session"
        let turnId = sessionScoped ? "" : explicitTurn.isEmpty ? activeTurnId : explicitTurn
        let current = explicitTurn.isEmpty || explicitTurn == latestTurnId
        projectMessage(event, type: type, turnId: turnId)
        projectUsage(event, type: type, turnId: turnId, current: current)

        if type == "permission.requested" || type == "tool.awaitingApproval" {
            let id = Self.string(payload["permissionId"], payload["requestId"])
            let runtimeId = Self.string(payload["runtimeId"], payload["details"]["runtimeId"])
            let liveRuntime = runtimeId.isEmpty || !retiredRuntimeIds.contains(runtimeId)
            if sessionScoped, !id.isEmpty, liveRuntime {
                pendingPermissions.removeAll { $0.id == id && $0.isSessionScoped }
                pendingPermissions.append(
                    PendingPermission(id: id, turnId: "", payload: payload, scope: "session", runtimeId: runtimeId))
            } else if !sessionScoped, current, liveRuntime, !activeTurnId.isEmpty, turnId == activeTurnId, !id.isEmpty {
                pendingPermissions.removeAll { $0.id == id && $0.turnId == turnId }
                pendingPermissions.append(
                    PendingPermission(id: id, turnId: turnId, payload: payload, runtimeId: runtimeId))
                status = "waitingPermission"
            }
        } else if type == "permission.resolved", current || sessionScoped {
            let id = Self.string(payload["permissionId"], payload["requestId"])
            pendingPermissions.removeAll {
                $0.id == id && ($0.isSessionScoped || explicitTurn.isEmpty || $0.turnId == explicitTurn)
            }
            settleWaitingStatus()
        } else if type == "provider.runtime", payload["status"] == "stopped" {
            // A stopped provider runtime can no longer answer its requests.
            let runtimeId = Self.string(payload["runtimeId"])
            if !runtimeId.isEmpty {
                retiredRuntimeIds.insert(runtimeId)
                pendingPermissions.removeAll { $0.runtimeId == runtimeId }
                settleWaitingStatus()
            }
        }

        if Self.terminalTypes.contains(type) {
            pendingPermissions.removeAll {
                !$0.isSessionScoped && (explicitTurn.isEmpty || $0.turnId == explicitTurn)
            }
            let terminalType = type == "turn.completed" && payload["stopReason"] == "error" ? "turn.failed" : type
            finishMessages(turnId: turnId, type: terminalType)
            if current {
                activeTurnId = ""
                status = String(terminalType.dropFirst("turn.".count))
                configurationRequestId = ""
                if terminalType != "turn.completed" { queuePaused = !queueItems.isEmpty }
            }
        }

        if current {
            projectConfiguration(payload, type: type)
            projectQueue(payload, type: type)
            projectCompaction(event, type: type)
            if let time = Self.date(event.time), lastProgressAt.map({ time > $0 }) ?? true {
                lastProgressAt = time
            }
        }
        projectAuxiliary(event, type: type, turnId: turnId)
    }

    /// Session-scoped requests never hold the turn in waitingPermission.
    private mutating func settleWaitingStatus() {
        guard status == "waitingPermission", !pendingPermissions.contains(where: { !$0.isSessionScoped }) else { return }
        status = activeTurnId.isEmpty ? "idle" : "running"
    }

    private static func permissionScope(_ payload: JSONValue) -> String {
        (payload["scope"].optionalString ?? payload["details"]["scope"].optionalString) == "session" ? "session" : "turn"
    }

    private mutating func finishMessages(turnId: String, type: String) {
        let terminalStatus = String(type.dropFirst("turn.".count))
        for index in messages.indices
        where messages[index].turnId == turnId
            && ["streaming", "running", "awaitingApproval"].contains(messages[index].status)
        {
            messages[index].status = terminalStatus
        }
    }

    /// Apply one classified `codex.*` sidecar frame. Local entries carry no
    /// journal sequence — they ride at `appliedSequence` so hydrate/prepend
    /// merges keep their relative position, and their ids are `local-`
    /// namespaced so journal rows can never replace or merge into them.
    /// Returns false when nothing changed (e.g. a pure control ack).
    @discardableResult
    public mutating func applyLocal(_ effects: CodexLocal.Effects) -> Bool {
        var changed = false
        for entry in effects.entries {
            var entry = entry
            entry.sequence = appliedSequence
            if let index = messages.firstIndex(where: { $0.id == entry.id }) {
                let previous = messages[index]
                // A streaming row absorbs its next delta; a finished row keeps
                // its terminal state when a late delta for it still arrives.
                if previous.status == "streaming", entry.status == "streaming", previous.streamed, entry.streamed {
                    messages[index].text = previous.text + entry.text
                    messages[index].detail = Self.merge(previous.detail, entry.detail)
                    changed = true
                } else if !Self.finishedStatuses.contains(previous.status) || !entry.streamed {
                    if messages[index] != entry {
                        if !entry.text.isEmpty, entry.text != previous.text {
                            messages[index].text = entry.text
                        }
                        messages[index].status = entry.status
                        messages[index].detail = Self.merge(previous.detail, entry.detail)
                        changed = true
                    }
                }
            } else {
                messages.insert(entry, at: 0)
                changed = true
            }
        }
        for request in effects.requests {
            pendingPermissions.removeAll { $0.id == request.id && $0.runtimeId == request.runtimeId }
            pendingPermissions.append(request)
            changed = true
        }
        if !effects.resolvedRequests.isEmpty {
            let before = pendingPermissions.count
            pendingPermissions.removeAll { effects.resolvedRequests.contains($0.id) }
            changed = changed || pendingPermissions.count != before
        }
        if let settle = effects.turnSettled {
            let terminalStatus = settle.status
            for index in messages.indices
            where messages[index].turnId == settle.id
                && ["streaming", "running", "awaitingApproval"].contains(messages[index].status)
            {
                messages[index].status = terminalStatus
                changed = true
            }
        }
        return changed
    }

    /// Drop adapter approvals owned by a stopped sidecar (desktop clears them
    /// when the local session ends); returns whether anything was removed.
    @discardableResult
    public mutating func clearLocalPermissions(sessionId: String) -> Bool {
        let runtimeId = "codex-local:\(sessionId)"
        let before = pendingPermissions.count
        pendingPermissions.removeAll { $0.runtimeId == runtimeId }
        return pendingPermissions.count != before
    }

    /// Hydrate folded process entries after a `detail=summary` replay. Full
    /// events for an expanded group's sequence range are projected on a
    /// scratch runtime, then merged back by message id. Only process
    /// categories merge: visible output already arrived complete and
    /// assistant segment ids depend on stream context outside the range.
    @discardableResult
    public mutating func hydrate(_ events: [ConversationEvent]) -> Bool {
        let detailCategories: Set<String> = ["tool", "reasoning", "status", "assistant_progress"]
        let sorted = events
            .filter { $0.conversationId == conversationId }
            .sorted { $0.sequence < $1.sequence }
        guard !sorted.isEmpty else { return false }
        var scratch = ConversationRuntime(conversationId: conversationId)
        for event in sorted {
            scratch.apply(event)
        }
        let original = messages
        var changed = false
        for entry in scratch.messages where detailCategories.contains(entry.category) {
            if let index = messages.firstIndex(where: { $0.id == entry.id }) {
                if messages[index] != entry {
                    messages[index] = entry
                    changed = true
                }
            } else {
                let position = messages.firstIndex { $0.sequence < entry.sequence } ?? messages.endIndex
                messages.insert(entry, at: position)
                changed = true
            }
        }
        // Hydrated progress rows may belong to an answer that already replaced them.
        messages = Self.droppingSupersededProgress(messages)
        return changed && messages != original
    }

    /// A final answer names the progress blocks its text was streamed under
    /// (`block.supersedes`); those copies are dropped so the answer shows once.
    private static func droppingSupersededProgress(_ messages: [TimelineMessage]) -> [TimelineMessage] {
        var superseded = Set<String>()
        for message in messages where message.category == "assistant_final" {
            for blockID in message.detail["block"]["supersedes"].arrayValue {
                if let blockID = blockID.optionalString, !blockID.isEmpty {
                    superseded.insert(identity([message.turnId, blockID]))
                }
            }
        }
        guard !superseded.isEmpty else { return messages }
        return messages.filter {
            $0.category != "assistant_progress"
                || !superseded.contains(identity([$0.turnId, string($0.detail["block"]["id"])]))
        }
    }

    private mutating func projectMessage(_ event: ConversationEvent, type: String, turnId: String) {
        // Agent SSH commands and desktop browser / Computer Use actions already show as the
        // agent's MCP tool call (as in the shared TS classifier); their own
        // events belong to side views, not the timeline.
        if type.hasPrefix("ssh.exec.") || type.hasPrefix("desktop.") { return }
        let payload = event.payload
        if HistoryEncryption.isLocked(payload) {
            projectLocked(event, type: type, turnId: turnId)
            return
        }
        let isStub = payload["detailStub"].boolValue
        let block = payload["block"]
        let message = payload["message"]
        let role = Self.string(payload["role"], message["role"]).lowercased()
        let user = role == "user" || role == "human"
        // Events emitted for a subagent's frames (providers tag them from
        // `parent_tool_use_id`) still fold into the trace but must not reach
        // the assistant stream.
        let subagentId = Self.string(
            payload["subagentId"], payload["subagent_id"],
            payload["parentToolUseId"], payload["parent_tool_use_id"])
        if type == "message.completed",
            user || message["stopReason"] == "toolUse"
                || message["stop_reason"] == "toolUse"
                || (!Self.string(message["role"]).isEmpty && message["role"] != "assistant")
        {
            return
        }

        let nativeID = Self.string(block["id"], payload["messageId"], message["id"])
        let validBlock =
            !Self.string(block["id"]).isEmpty
            && Self.categories.contains(block["category"].stringValue)
            && ["started", "delta", "completed", "failed"].contains(block["phase"].stringValue)
        let deltaType = Self.string(
            payload["delta"]["type"], payload["delta"]["deltaType"], payload["delta"]["delta_type"])
        let method = Self.string(payload["providerMethod"], payload["provider_method"], payload["method"])
        let discriminator = [type, deltaType, method].joined(separator: " ").lowercased()
        var category: String
        if type == "message.created", user {
            category = "user"
        } else if validBlock {
            category = block["category"].stringValue
        } else if type.hasPrefix("permission.") || type == "tool.awaitingApproval" {
            category = "approval"
        } else if type == "turn.failed" {
            category = "error"
        } else if type == "provider.commands.updated"
            || (type == "provider.event" && method.hasPrefix("_"))
        {
            return
        } else if type == "provider.event", method.lowercased().contains("mcp"),
            method.lowercased().contains("initialized") || method.lowercased().contains("status")
        {
            return
        } else if ["tool", "command", "function", "mcp"].contains(where: discriminator.contains)
            || ["tool", "toolCall", "tool_call", "command", "function"].contains(where: { !payload[$0].isNull })
        {
            category = "tool"
        } else if ["thought", "reasoning", "thinking", "analysis"].contains(where: discriminator.contains)
            || ["thought", "thoughtText", "reasoning", "thinking", "analysis"].contains(where: { !payload[$0].isNull })
        {
            category = "reasoning"
        } else if ["message.created", "message.started", "message.completed", "assistant.delta", "message.delta"]
            .contains(type)
        {
            // A subagent's message is trace detail: streamed text folds into
            // one status step per run; its envelopes add nothing the run's
            // result does not already show — and must never replace or merge
            // into the main answer.
            guard subagentId.isEmpty || type == "assistant.delta" || type == "message.delta"
            else { return }
            category = subagentId.isEmpty ? "assistant_final" : "status"
        } else if isStub {
            // Summary replays strip the content fields the heuristics match
            // on; preserved tool markers decide between the two detail kinds.
            category =
                ["tool", "toolCall", "tool_call", "command", "function", "functionCall", "function_call"]
                .contains { !payload[$0].isNull } ? "tool" : "reasoning"
        } else {
            return
        }
        guard category != "usage" else { return }

        let phase: String
        if validBlock {
            phase = block["phase"].stringValue
        } else if type.hasSuffix(".failed") {
            phase = "failed"
        } else if type.hasSuffix(".completed") || type == "permission.resolved" || deltaType.hasSuffix("_end") {
            phase = "completed"
        } else if type.hasSuffix(".delta") || deltaType.hasSuffix("_delta") {
            phase = "delta"
        } else {
            phase = "started"
        }

        let categoryKey = Self.identity([turnId, nativeID])
        if validBlock, category == "assistant_final" || category == "assistant_progress" {
            if phase == "delta", let advertised = messageCategories[categoryKey] {
                category = advertised
            } else {
                messageCategories[categoryKey] = category
            }
        }

        let family = category == "assistant_final" || category == "assistant_progress" ? "assistant" : category
        let contentIndex = payload["delta"]["contentIndex"].doubleValue ?? payload["delta"]["content_index"].doubleValue
        let fallback = contentIndex.map { "content-\($0)" } ?? "current"
        var streamID: String
        if category == "user" {
            streamID = nativeID.isEmpty ? event.eventId : nativeID
        } else if category == "approval" {
            streamID = Self.string(payload["permissionId"], payload["requestId"], .string(event.eventId))
        } else if category == "tool" {
            streamID = Self.string(
                block["id"], payload["toolCallId"], payload["tool_call_id"],
                payload["callId"], payload["toolCall"]["id"], payload["delta"]["toolCall"]["id"],
                .string(contentIndex == nil ? event.eventId : fallback))
        } else {
            streamID = nativeID.isEmpty ? fallback : nativeID
        }
        // A subagent's thinking folds into the trace under its own stream,
        // never into the main reasoning row it would otherwise corrupt.
        if !subagentId.isEmpty {
            if category == "reasoning" { streamID = "subagent-\(subagentId)-thought" }
            if category == "status" { streamID = "subagent-\(subagentId)-text" }
        }
        if family == "assistant", nativeID.isEmpty {
            if assistantInterrupted {
                assistantSegment += 1
                assistantInterrupted = false
            }
            streamID += "#seg\(assistantSegment)"
        }
        var id = Self.identity([conversationId, turnId, family, streamID])
        var index = messages.firstIndex { $0.id == id }
        // Legacy deltas may lack the message ID that appears on the final frame.
        if index == nil, phase == "completed", family == "assistant", !nativeID.isEmpty {
            let candidates = messages.indices.filter {
                messages[$0].turnId == turnId && messages[$0].category == category
                    && ["running", "streaming"].contains(messages[$0].status)
                    && Self.string(
                        messages[$0].detail["block"]["id"], messages[$0].detail["messageId"],
                        messages[$0].detail["message"]["id"]
                    ).isEmpty
            }
            if candidates.count == 1, let candidate = candidates.first {
                index = candidate
                id = messages[candidate].id
            }
        }
        // A late delta must never reopen or append to an authoritative full result.
        if let index, phase == "delta", Self.finishedStatuses.contains(messages[index].status) { return }
        let previous = index.map { messages[$0] }
        // Pi emits null for tool fields omitted on later execution callbacks.
        // Keep the earlier arguments alongside the final result in the detail view.
        let detail = Self.merge(previous?.detail ?? .null, payload, preservingNulls: category == "tool")
        let text = Self.messageText(payload, category: category)
        let structuredToolDelta =
            category == "tool"
            && ["toolCall", "tool_call", "partialResult", "partial_result"]
                .contains(where: { !payload[$0].isNull || !payload["delta"][$0].isNull })
        let nextText: String
        if phase == "delta", !structuredToolDelta {
            nextText = (previous?.text ?? "") + text
        } else if text.isEmpty,
            !(phase == "completed" && family == "assistant"
                && (!payload["text"].isNull || !payload["content"].isNull
                    || !payload["message"]["text"].isNull || Self.carriesText(payload["message"]["content"])))
        {
            nextText = previous?.text ?? ""
        } else {
            nextText = text
        }
        guard !nextText.isEmpty || isStub || ["tool", "approval", "error"].contains(category) || previous != nil
        else { return }
        let toolFailed = category == "tool" && (payload["isError"].boolValue || payload["is_error"].boolValue)
        let messageStatus =
            toolFailed
            ? "failed"
            : type == "tool.awaitingApproval" || type == "permission.requested"
                ? "awaitingApproval"
                : phase == "delta"
                    ? "streaming" : phase == "started" ? (category == "user" ? "completed" : "running") : phase
        let entry = TimelineMessage(
            id: id, turnId: turnId,
            role: category == "user" ? "user" : category == "assistant_final" ? "assistant" : "system",
            category: category, text: nextText, status: messageStatus, detail: detail,
            sequence: event.sequence,
            streamed: previous?.streamed ?? (index == nil && phase == "delta" && family == "assistant"))
        if let index { messages[index] = entry } else { messages.insert(entry, at: 0) }
        if category == "assistant_final", !payload["block"]["supersedes"].arrayValue.isEmpty {
            messages = Self.droppingSupersededProgress(messages)
        }
        // A full assistant message already carries the text its streamed
        // fragments were rendered under; covered segments drop so the answer
        // shows once. A non-matching chain keeps every row.
        if family == "assistant", phase != "delta", !nextText.isEmpty {
            dropCoveredAssistantSegments(covering: entry)
        }
        // A step between two chunks opens a new segment; steps a provider
        // tags as a subagent's run alongside the stream and never split it.
        if family != "assistant", category != "user", subagentId.isEmpty {
            assistantInterrupted = true
        }
    }

    /// Content this device cannot decrypt (`detailLocked`, history v3) shows
    /// as one quiet row per uninterrupted run instead of one per event.
    /// Lifecycle events still drive status through their plaintext envelope.
    private mutating func projectLocked(_ event: ConversationEvent, type: String, turnId: String) {
        let contentPrefixes = ["message.", "assistant.", "tool.", "thought.", "reasoning.", "subagent.", "permission.requested"]
        guard contentPrefixes.contains(where: type.hasPrefix) else { return }
        if messages.first?.category == Self.lockedCategory {
            messages[0].sequence = event.sequence
            messages[0].detail["lastSequence"] = .number(Double(event.sequence))
            return
        }
        messages.insert(
            TimelineMessage(
                id: "locked-\(event.eventId)", turnId: turnId, role: "system", category: Self.lockedCategory, text: "",
                status: "locked",
                detail: [
                    HistoryEncryption.lockedField: true, "firstSequence": .number(Double(event.sequence)),
                    "lastSequence": .number(Double(event.sequence)),
                ], sequence: event.sequence), at: 0)
    }
    /// Timeline category of a run of undecryptable history.
    public static let lockedCategory = "locked"

    /// `#seg` rows of one turn's anonymous assistant stream whose joined text
    /// a completion's text already covers. Rows walk newest→oldest; a row
    /// stays covered only while prepending its text keeps a strict suffix
    /// match, so an older fragment of a different message ends the chain
    /// instead of being dropped.
    private mutating func dropCoveredAssistantSegments(covering entry: TimelineMessage) {
        var acc = ""
        var covered: [String] = []
        for message in messages {
            guard message.id != entry.id, Self.isAssistantSegment(message, turnId: entry.turnId)
            else { continue }
            let joined = message.text + acc
            guard joined.count <= entry.text.count, entry.text.hasSuffix(joined) else { break }
            acc = joined
            covered.append(message.id)
            if acc == entry.text { break }
        }
        guard !covered.isEmpty else { return }
        messages.removeAll { covered.contains($0.id) }
    }

    /// A row belongs to a turn's anonymous assistant stream — the stream id
    /// inside its identity ends in `#seg<n>` — while native-id rows and
    /// per-subagent steps never do.
    private static func isAssistantSegment(_ message: TimelineMessage, turnId: String) -> Bool {
        message.turnId == turnId && message.category == "assistant_final"
            && message.id.range(of: "#seg[0-9]+$", options: .regularExpression) != nil
    }

    /// Fragments of a completed message that page in below it carry the head
    /// of its text, not a suffix: walking the same-turn segments below each
    /// completion oldest→newest, a fragment is covered while its text
    /// continues the accumulated prefix exactly. Rows that fail to advance
    /// the match are skipped, so a middle page completes once the head page
    /// has arrived.
    private static func droppingCoveredAssistantSegments(_ messages: [TimelineMessage]) -> [TimelineMessage]
    {
        var dropped = Set<String>()
        for index in messages.indices {
            let cover = messages[index]
            guard !dropped.contains(cover.id), cover.category == "assistant_final",
                !cover.streamed, !cover.text.isEmpty
            else { continue }
            var position = cover.text.startIndex
            for candidate in ((index + 1)..<messages.count).reversed()
            where !dropped.contains(messages[candidate].id)
                && isAssistantSegment(messages[candidate], turnId: cover.turnId)
                && cover.text[position...].hasPrefix(messages[candidate].text)
            {
                position = cover.text.index(position, offsetBy: messages[candidate].text.count)
                dropped.insert(messages[candidate].id)
                if position == cover.text.endIndex { break }
            }
        }
        return dropped.isEmpty ? messages : messages.filter { !dropped.contains($0.id) }
    }

    private mutating func projectConfiguration(_ payload: JSONValue, type: String) {
        if type == "turn.configuration" || !payload["effectiveConfig"].isNull {
            if case .object = payload["requested"] { requestedConfig = payload["requested"] }
            let effective = Self.objectOrNull(
                payload["effective"].isNull ? payload["effectiveConfig"] : payload["effective"])
            if !effective.isNull {
                effectiveConfig = Self.merge(effectiveConfig, effective)
                let source = Self.string(effective["source"])
                effectiveConfig["source"] = .string(source.isEmpty ? "unknown" : source)
                configurationStatus =
                    source == "provider-confirmed"
                    ? "provider-confirmed"
                    : source == "locally-validated" ? "validated" : "unknown"
                if source == "provider-confirmed" { configurationRequestId = "" }
            }
        }
        if type == "control.requested", payload["control"]["action"] == "configure" {
            var requested = payload["control"].objectValue
            requested.removeValue(forKey: "action")
            requestedConfig = Self.merge(requestedConfig, .object(requested))
            configurationRequestId = Self.string(payload["requestId"])
            configurationStatus = "pending"
            configurationError = ""
        }
        let requestID = Self.string(payload["requestId"])
        if !requestID.isEmpty, requestID == configurationRequestId {
            if type == "control.rejected" {
                configurationStatus = "rejected"
                configurationError = Self.string(
                    payload["error"]["message"], payload["error"], payload["message"], payload["reason"],
                    .string(String(localized: "Agent 未接受新的模型或思考深度配置", bundle: .module)))
            } else if type == "control.unknown" || (type == "control.completed" && configurationStatus == "pending") {
                // An ACK has no effective configuration readback.
                configurationStatus = "unknown"
            }
        }
    }

    /// Adopts a backend follow-up queue snapshot. A lazily opened window may
    /// not hold the latest `followups.updated`, so callers also apply the
    /// `conversation.queue.list` result; later events replace it again.
    public mutating func adoptFollowUpQueue(_ snapshot: JSONValue) {
        var seen: Set<String> = []
        followUps = snapshot["items"].arrayValue.compactMap { value in
            let id = value["id"].stringValue
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            var item = value
            item["text"] = .string(value["text"].stringValue)
            item["status"] = .string(Self.string(value["status"], "queued"))
            return item
        }
        followUpsPaused = snapshot["paused"].boolValue && !followUps.isEmpty
        followUpsPauseReason = followUpsPaused ? snapshot["pauseReason"].stringValue : ""
        followUpsPauseMessage = followUpsPaused ? snapshot["pauseMessage"].stringValue : ""
    }

    private mutating func projectQueue(_ payload: JSONValue, type: String) {
        if type == "followups.updated" {
            adoptFollowUpQueue(payload)
            return
        }
        if type == "queue.updated", case .array(let items) = payload["items"] {
            var seen: Set<String> = []
            queueItems = items.compactMap { value in
                let id = Self.string(value["id"], value["itemId"])
                guard !id.isEmpty, seen.insert(id).inserted else { return nil }
                var item = value
                item["id"] = .string(id)
                item["text"] = .string(value["text"].stringValue)
                item["status"] = .string(Self.string(value["status"], "queued"))
                return item
            }
            queuePaused = payload["paused"].boolValue
        } else if type == "queue.paused" {
            queuePaused = !queueItems.isEmpty
        }
    }

    private mutating func projectCompaction(_ event: ConversationEvent, type: String) {
        guard type.hasPrefix("compaction.") else { return }
        let phase = String(type.dropFirst("compaction.".count))
        guard ["started", "completed", "failed", "cancelled"].contains(phase) else { return }
        compaction = Self.merge(compaction, event.payload)
        compaction["status"] = .string(phase == "started" ? "running" : phase == "cancelled" ? "idle" : phase)
        compaction["updatedAt"] = .string(event.time)
        compaction["summary"] = event.payload["summary"]
        compaction["error"] =
            phase == "failed"
            ? .string(Self.string(event.payload["error"], event.payload["message"], .string(String(localized: "上下文压缩失败", bundle: .module)))) : .null
    }

    private mutating func projectAuxiliary(_ event: ConversationEvent, type: String, turnId: String) {
        let payload = event.payload
        if type == "desktop.browser.action" || type == "desktop.browser.grant" {
            desktopBrowser.apply(type: type, payload: payload, time: event.time)
        } else if type == "desktop.computer.action" || type == "desktop.computer.session"
            || type == "desktop.computer.grant"
        {
            desktopComputer.apply(type: type, payload: payload, time: event.time)
        } else if type.hasPrefix("subagent.") {
            let id = Self.string(payload["subagentId"], payload["agentId"], payload["id"])
            guard !id.isEmpty else { return }
            let previous = subagents.first { $0["id"] == .string(id) } ?? .null
            let phase = String(type.dropFirst("subagent.".count))
            // 'queued' marks a run whose start event sits below the loaded
            // window; a progress frame reporting the real phase outranks it.
            let previousStatus = previous["status"].stringValue
            let reportedStatus = Self.subagentStatus(payload["status"])
            let status =
                phase == "started"
                ? "running"
                : ["completed", "failed", "cancelled"].contains(phase)
                    ? phase
                    : previousStatus.isEmpty || previousStatus == "queued"
                        ? (reportedStatus ?? "queued") : previousStatus
            var run = Self.merge(previous, payload)
            run["id"] = .string(id)
            run["conversationId"] = .string(conversationId)
            run["turnId"] = .string(Self.string(previous["turnId"], .string(turnId)))
            run["title"] = .string(Self.string(payload["title"], previous["title"], "Subagent"))
            run["task"] = .string(Self.string(payload["task"], payload["prompt"], previous["task"]))
            run["status"] = .string(status)
            if case .object = payload["usage"], !payload["usage"].objectValue.isEmpty {
                run["usage"] = payload["usage"]
            } else if case .object = payload["metadata"]["usage"], !payload["metadata"]["usage"].objectValue.isEmpty {
                run["usage"] = payload["metadata"]["usage"]
            }
            if status == "running" {
                run["startedAt"] = previous["startedAt"].isNull ? .string(event.time) : previous["startedAt"]
            } else if status != "queued" {
                run["finishedAt"] = .string(event.time)
            }
            // Runs keep their slot while they update — only a first sighting
            // or the transition into a settled status changes position, so the
            // list does not reshuffle on every progress event and finished
            // runs collect below the active ones.
            if previous.isNull
                || Self.settledSubagentStatuses.contains(previousStatus) != Self.settledSubagentStatuses.contains(status) {
                subagents.removeAll { $0["id"] == .string(id) }
                let boundary = Self.settledSubagentStatuses.contains(status)
                    ? (subagents.firstIndex { Self.settledSubagentStatuses.contains($0["status"].stringValue) } ?? subagents.count)
                    : 0
                subagents.insert(run, at: boundary)
            } else if let index = subagents.firstIndex(where: { $0["id"] == .string(id) }) {
                subagents[index] = run
            }
        } else if type == "memory.created" || type == "memory.updated" {
            let id = Self.string(payload["memoryId"], payload["id"])
            // An explicitly empty update is valid; configuration-only events are not content.
            let content = payload["content"].optionalString ?? payload["text"].optionalString
            guard !id.isEmpty, let content else { return }
            let previous = memoryEntries.first { $0["id"] == .string(id) } ?? .null
            var entry = Self.merge(previous, payload)
            entry["id"] = .string(id)
            entry["content"] = .string(content)
            entry["scope"] =
                ["user", "workspace"].contains(payload["scope"].stringValue) ? payload["scope"] : "conversation"
            entry["createdAt"] = previous["createdAt"].isNull ? .string(event.time) : previous["createdAt"]
            entry["updatedAt"] = .string(event.time)
            memoryEntries.removeAll { $0["id"] == .string(id) }
            memoryEntries.insert(entry, at: 0)
        } else if type == "memory.deleted" {
            let id = Self.string(payload["memoryId"], payload["id"])
            memoryEntries.removeAll { $0["id"] == .string(id) }
        }
    }

    private mutating func projectUsage(_ event: ConversationEvent, type: String, turnId: String, current: Bool) {
        let payload = event.payload
        let message = payload["message"]
        let normalized = payload["usage"]
        let tokenUsage = Self.firstObject(
            payload["tokenUsage"], payload["token_usage"],
            payload["metadata"]["tokenUsage"], payload["metadata"]["token_usage"])
        let method = Self.string(payload["providerMethod"], payload["provider_method"], payload["method"])
        let isTokenUsage = method == "thread/tokenUsage/updated" || type.lowercased().contains("tokenusage")
        guard
            type == "usage.updated" || payload["block"]["category"] == "usage"
                || (type == "message.completed" && Self.string(message["role"], payload["role"]) == "assistant"
                    && !message["usage"].isNull)
                || (isTokenUsage && !tokenUsage.isNull)
        else { return }
        let raw = Self.firstObject(
            normalized["last"], tokenUsage["last"], tokenUsage["latest"], tokenUsage["current"],
            message["usage"], normalized)
        let cumulative = Self.firstObject(normalized["cumulative"], tokenUsage["total"])
        let provider = Self.string(event.provider.map(JSONValue.string) ?? .null, payload["provider"], "unknown")
        let turnKey = Self.identity([provider, turnId])
        let isFinal =
            payload["scope"] == "turn" && payload["aggregation"] == "snapshot" && payload["final"] == true
            && !turnId.isEmpty
        if finalUsageTurns.contains(turnKey), !isFinal { return }
        let messageID = Self.string(payload["messageId"], message["id"], payload["block"]["id"])
        let requestID = Self.string(payload["usageId"], payload["requestId"])
        let messageScope = payload["scope"] == "message" || type == "message.completed"
        let requestScope = !messageID.isEmpty || !requestID.isEmpty || messageScope
        let identity = Self.string(
            .string(messageID), .string(requestID), .string(messageScope ? event.eventId : turnId),
            .string(event.eventId))
        let turnRecordID = Self.identity([conversationId, "usage", provider, turnId])
        var id = requestScope ? Self.identity([conversationId, "usage", provider, turnId, identity]) : turnRecordID
        var scope = requestScope ? "request" : turnId.isEmpty ? "unknown" : "turn"
        let advertisedSemantics = Self.string(normalized["cacheSemantics"], payload["cacheSemantics"])
        let semantics =
            ["included", "additional", "unknown"].contains(advertisedSemantics)
            ? advertisedSemantics
            : provider == "codex" ? "included" : provider == "claude-code" ? "additional" : "unknown"
        var counters = Self.counters(raw)
        if !cumulative.isNull, !Self.counters(cumulative).isEmpty {
            id = turnRecordID
            scope = turnId.isEmpty ? "unknown" : "turn"
            let incoming = Self.counters(cumulative)
            let prior = current ? cumulativeUsage[provider] : turnCumulativeUsage[turnKey]
            // A late old-turn snapshot must not reset the running turn's session baseline.
            if !current, prior == nil { return }
            let reset =
                prior.map { baseline in incoming.contains { key, value in baseline[key].map { value < $0 } ?? false } }
                ?? false
            let baseline = reset ? nil : prior
            // Keep known baselines internally: a sparse public snapshot reports
            // null, but must not corrupt the next complete cumulative snapshot.
            var totals = turnUsageTotals[turnKey] ?? [:]
            counters = [:]
            for (key, value) in incoming {
                if let baseline, baseline[key] == nil { continue }
                let delta = value - (baseline?[key] ?? 0)
                let total = (totals[key] ?? 0) + max(0, delta)
                if total.isFinite {
                    counters[key] = total
                    totals[key] = total
                }
            }
            let nextBaseline = (baseline ?? [:]).merging(incoming) { _, new in new }
            if current { cumulativeUsage[provider] = nextBaseline }
            turnCumulativeUsage[turnKey] = nextBaseline
            turnUsageTotals[turnKey] = totals
        }

        var record: JSONValue = [
            "id": .string(id), "conversationId": .string(conversationId), "turnId": .string(turnId),
            "provider": .string(provider), "model": .null, "scope": .string(scope),
            "sequence": .number(Double(event.sequence)), "cacheSemantics": .string(semantics),
            "updatedAt": Self.date(event.time).map { .number($0.timeIntervalSince1970 * 1_000) } ?? .null,
        ]
        let model = Self.string(
            message["model"], message["modelId"], message["model_id"], payload["model"], payload["modelId"],
            payload["model_id"])
        if !model.isEmpty { record["model"] = .string(model) }
        for key in Self.counterKeys { record[key] = counters[key].map(JSONValue.number) ?? .null }
        if record["totalTokens"].isNull, let total = Self.usageTotalTokens(record) {
            record["totalTokens"] = .number(total)
        }
        if isFinal {
            finalUsageTurns.insert(turnKey)
            usageRecords.removeAll { $0["turnId"] == .string(turnId) && $0["provider"] == .string(provider) }
            record["id"] = .string(turnRecordID)
            record["scope"] = "turn"
        }
        usageRecords.removeAll { $0["id"] == record["id"] }
        usageRecords.insert(record, at: 0)
        if usageRecords.count > 2_000 { usageRecords.removeLast(usageRecords.count - 2_000) }

        if current {
            let context = Self.counters(raw)
            let used = context["totalTokens"] ?? Self.sum(context["inputTokens"], context["outputTokens"])
            let window =
                Self.number(payload["contextWindow"]) ?? Self.number(payload["context_window"])
                ?? Self.number(tokenUsage["modelContextWindow"]) ?? Self.number(tokenUsage["contextWindow"])
                ?? Self.number(tokenUsage["model_context_window"]) ?? Self.number(tokenUsage["context_window"])
            if let used { compaction["usedTokens"] = .number(used) }
            if let window { compaction["contextWindow"] = .number(window) }
            if let used = Self.number(compaction["usedTokens"]), let window = Self.number(compaction["contextWindow"]),
                window > 0
            {
                compaction["recommended"] = .bool(used / window >= 0.8)
            }
        }
    }

    public static func usageTotalTokens(_ record: JSONValue) -> Double? {
        if let total = number(record["totalTokens"]) { return total }
        guard let base = sum(number(record["inputTokens"]), number(record["outputTokens"])) else { return nil }
        switch record["cacheSemantics"].stringValue {
        case "included": return base
        case "additional":
            return sum(base, sum(number(record["cachedInputTokens"]), number(record["cacheWriteTokens"])))
        default: return nil
        }
    }

    private static let categories: Set<String> = [
        "assistant_final", "assistant_progress", "reasoning", "tool", "approval", "status", "error", "usage",
    ]
    private static let terminalTypes: Set<String> = [
        "turn.completed", "turn.cancelled", "turn.failed", "turn.interrupted",
    ]
    private static let finishedStatuses: Set<String> = ["completed", "cancelled", "failed", "interrupted"]
    private static let counterKeys = [
        "inputTokens", "outputTokens", "cachedInputTokens", "cacheWriteTokens", "totalTokens",
    ]

    /// Wire type normalized through the provider alias table. Recovery scans
    /// for `turn.started` with the same canonicalization the reducer applies.
    public static func canonicalType(_ event: ConversationEvent) -> String {
        let aliases = [
            "codex.turn.started": "turn.started", "codex.turn.completed": "turn.completed",
            "conversation.interrupted": "turn.interrupted", "conversation.failed": "turn.failed",
            "message.delta": "assistant.delta", "text_delta": "assistant.delta",
            "thought.delta": "reasoning.delta", "thinking_delta": "reasoning.delta",
            "tool.created": "tool.started", "tool.result": "tool.completed", "tool.error": "tool.failed",
        ]
        if let alias = aliases[event.type] { return alias }
        if ["message.", "turn.", "permission.", "usage.", "subagent.", "compaction.", "memory."].contains(
            where: event.type.hasPrefix)
        {
            return event.type
        }
        return event.normalizedType.flatMap { $0.isEmpty ? nil : $0 } ?? event.type
    }

    private static func counters(_ value: JSONValue) -> [String: Double] {
        let aliases = [
            "inputTokens": ["input", "inputTokens", "input_tokens"],
            "outputTokens": ["output", "outputTokens", "output_tokens"],
            "cachedInputTokens": [
                "cacheRead", "cache_read", "cachedInputTokens", "cached_input_tokens", "cacheReadInputTokens",
                "cache_read_input_tokens",
            ],
            "cacheWriteTokens": [
                "cacheWrite", "cache_write", "cacheWriteTokens", "cache_write_tokens", "cacheWriteInputTokens",
                "cache_write_input_tokens", "cacheCreationInputTokens", "cache_creation_input_tokens",
            ],
            "totalTokens": ["total", "totalTokens", "total_tokens"],
        ]
        var result: [String: Double] = [:]
        for (key, keys) in aliases {
            for alias in keys where !value[alias].isNull {
                result[key] = number(value[alias])
                break
            }
        }
        return result
    }

    private static func number(_ value: JSONValue) -> Double? {
        let number = value.doubleValue ?? value.optionalString.flatMap(Double.init)
        return number.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
    private static func sum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs, (lhs + rhs).isFinite else { return nil }
        return lhs + rhs
    }
    private static func string(_ values: JSONValue...) -> String {
        values.compactMap(\.optionalString).first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }
    private static func identity(_ parts: [String]) -> String {
        parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
    private static func objectOrNull(_ value: JSONValue) -> JSONValue {
        if case .object = value { return value }
        return .null
    }
    private static func firstObject(_ values: JSONValue...) -> JSONValue {
        values.first {
            if case .object = $0 { return true }
            return false
        } ?? .null
    }
    private static func merge(_ previous: JSONValue, _ next: JSONValue, preservingNulls: Bool = false) -> JSONValue {
        guard case .object(let update) = next else { return previous }
        var result = previous.objectValue
        for (key, value) in update {
            if preservingNulls, value.isNull, result[key] != nil { continue }
            if case .object = value {
                result[key] = merge(result[key] ?? .null, value, preservingNulls: preservingNulls)
            } else {
                result[key] = value
            }
        }
        return .object(result)
    }
    /// `subagent.*` progress frames carry the provider's own phase names;
    /// normalize them onto the shared lifecycle vocabulary.
    private static func subagentStatus(_ value: JSONValue) -> String? {
        let status = value.stringValue
        if ["queued", "running", "completed", "failed", "cancelled"].contains(status) { return status }
        switch status {
        case "inProgress", "in_progress": return "running"
        case "errored", "notFound": return "failed"
        case "interrupted", "shutdown", "stopped", "killed": return "cancelled"
        case "pendingInit", "pending": return "queued"
        default: return nil
        }
    }
    /// Newer fields win; fields the newer entry lacks or holds as null take the
    /// earlier projection's value. Used when an older history page merges in.
    private static func mergeEarlierFields(_ older: JSONValue, _ newer: JSONValue) -> JSONValue {
        var merged = newer.objectValue
        for (key, value) in older.objectValue where merged[key]?.isNull ?? true {
            merged[key] = value
        }
        return .object(merged)
    }

    private static let settledSubagentStatuses: Set<String> = ["completed", "failed", "cancelled"]

    /// Keep the active-before-settled group order after an earlier page
    /// merged: a still-running run whose events all sit below the loaded
    /// window appends at the tail and would otherwise land below finished
    /// runs. Returns the input unchanged when the order already holds.
    private static func partitionSettledSubagents(_ runs: [JSONValue]) -> [JSONValue] {
        guard let firstSettled = runs.firstIndex(where: { settledSubagentStatuses.contains($0["status"].stringValue) }),
              runs[firstSettled...].contains(where: { !settledSubagentStatuses.contains($0["status"].stringValue) })
        else { return runs }
        return runs.filter { !settledSubagentStatuses.contains($0["status"].stringValue) }
            + runs.filter { settledSubagentStatuses.contains($0["status"].stringValue) }
    }

    /// 'Subagent', '' and 'queued' are placeholders for a run whose start sits
    /// below the loaded window, so the paged-in start replaces them; every
    /// other field keeps the newer projection's value.
    private static func mergeEarlierSubagent(_ older: JSONValue, _ newer: JSONValue) -> JSONValue {
        var merged = mergeEarlierFields(older, newer)
        if merged["title"].stringValue == "Subagent", !older["title"].stringValue.isEmpty {
            merged["title"] = older["title"]
        }
        if merged["task"].stringValue.isEmpty, !older["task"].stringValue.isEmpty {
            merged["task"] = older["task"]
        }
        if merged["status"].stringValue == "queued", !["", "queued"].contains(older["status"].stringValue) {
            merged["status"] = older["status"]
        }
        if !older["startedAt"].isNull {
            merged["startedAt"] = older["startedAt"]
        }
        return merged
    }
    /// Fold collection entries projected from an earlier page into the loaded
    /// collection: known ids merge via `merge`, unseen entries append at the
    /// tail to preserve newest-first ordering.
    private static func mergingEarlier(
        _ earlier: [JSONValue], into current: [JSONValue],
        merge: (JSONValue, JSONValue) -> JSONValue = mergeEarlierFields
    ) -> [JSONValue] {
        guard !earlier.isEmpty else { return current }
        let olderById = Dictionary(uniqueKeysWithValues: earlier.map { ($0["id"].stringValue, $0) })
        var merged = current.map { item -> JSONValue in
            guard let older = olderById[item["id"].stringValue] else { return item }
            return merge(older, item)
        }
        let known = Set(current.map { $0["id"].stringValue })
        merged.append(contentsOf: earlier.filter { !known.contains($0["id"].stringValue) })
        return merged
    }
    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func text(_ value: JSONValue, depth: Int = 0, textOnly: Bool = false) -> String {
        guard depth <= 5 else { return "" }
        switch value {
        case .string(let value): return value
        case .array(let values): return values.map { text($0, depth: depth + 1, textOnly: textOnly) }.joined()
        case .object:
            if textOnly, let type = value["type"].optionalString,
                !["text", "text_delta", "message", "output_text", "input_text", "agentMessage", "agent_message"]
                    .contains(type)
            {
                return ""
            }
            let keys =
                textOnly
                ? ["text", "content", "delta", "output_text", "outputText"]
                : [
                    "text", "content", "thinking", "reasoning", "analysis", "delta", "output_text", "outputText",
                    "summary", "message", "partialResult", "partial_result", "result",
                ]
            for key in keys {
                let result = text(value[key], depth: depth + 1, textOnly: textOnly)
                if !result.isEmpty { return result }
            }
            return ""
        default: return ""
        }
    }

    /// Claude sends one completion per content block; a thinking or tool_use
    /// completion carries no answer text and must not blank the streamed draft.
    private static func carriesText(_ content: JSONValue) -> Bool {
        switch content {
        case .string: return true
        case .array(let parts):
            return parts.contains {
                if case .string = $0 { return true }
                let type = $0["type"].stringValue
                return type.isEmpty || ["text", "output_text", "input_text"].contains(type)
            }
        default: return false
        }
    }

    private static func messageText(_ payload: JSONValue, category: String) -> String {
        let values: [JSONValue]
        switch category {
        case "assistant_final", "assistant_progress", "user":
            values = [
                payload["text"], payload["content"], payload["delta"], payload["message"], payload["block"]["text"],
            ]
        case "reasoning":
            values = [
                payload["thought"], payload["thoughtText"], payload["thought_text"], payload["reasoning"],
                payload["thinking"], payload["analysis"], payload["delta"], payload["text"],
            ]
        case "tool":
            let value = [
                payload["partialResult"], payload["partial_result"], payload["result"], payload["delta"],
                payload["arguments"], payload["item"], payload["tool"], payload["toolCall"], payload["tool_call"],
            ].first { !$0.isNull }
            guard let value else { return "" }
            let content = text(value)
            return content.isEmpty ? value.prettyPrinted : content
        case "approval": values = [payload["title"], payload["question"], payload["message"]]
        case "error": values = [payload["message"], payload["error"], payload["reason"]]
        default: values = [payload["status"], payload["message"], payload["text"], payload["delta"]]
        }
        for value in values {
            let content = text(value, textOnly: ["assistant_final", "assistant_progress", "user"].contains(category))
            if !content.isEmpty { return content }
        }
        return ""
    }
}
