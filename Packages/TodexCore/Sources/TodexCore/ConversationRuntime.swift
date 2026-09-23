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

    public init(
        id: String, turnId: String, role: String, category: String, text: String,
        status: String, detail: JSONValue, sequence: Int = 0
    ) {
        self.id = id
        self.turnId = turnId
        self.role = role
        self.category = category
        self.text = text
        self.status = status
        self.detail = detail
        self.sequence = sequence
    }
}

public struct PendingPermission: Identifiable, Sendable {
    public var id: String
    public var turnId: String
    public var payload: JSONValue

    public init(id: String, turnId: String, payload: JSONValue) {
        self.id = id
        self.turnId = turnId
        self.payload = payload
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
    public private(set) var effectiveConfig: JSONValue = .null
    public private(set) var requestedConfig: JSONValue = .null
    public private(set) var configurationStatus = "unknown"
    public private(set) var compaction: JSONValue = ["status": "idle", "recommended": false, "updatedAt": ""]
    public private(set) var subagents: [JSONValue] = []
    public private(set) var memoryEntries: [JSONValue] = []
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
    /// loaded keep their newer-window version.
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
        guard !older.isEmpty else { return false }
        let merged = Self.droppingSupersededProgress(messages + older)
        guard merged != messages else { return false }
        messages = merged
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
            pendingPermissions.removeAll()
            requestedConfig = Self.objectOrNull(payload["requestedPermissions"])
            effectiveConfig = Self.objectOrNull(payload["effectivePermissions"])
            if !effectiveConfig.isNull { effectiveConfig["source"] = "locally-validated" }
            configurationStatus = payload["configurationStatus"] == "validated" ? "validated" : "unknown"
            configurationRequestId = ""
        }
        let turnId = explicitTurn.isEmpty ? activeTurnId : explicitTurn
        let current = explicitTurn.isEmpty || explicitTurn == latestTurnId
        projectMessage(event, type: type, turnId: turnId)
        projectUsage(event, type: type, turnId: turnId, current: current)

        if type == "permission.requested" || type == "tool.awaitingApproval" {
            let id = Self.string(payload["permissionId"], payload["requestId"])
            if current, !activeTurnId.isEmpty, turnId == activeTurnId, !id.isEmpty {
                pendingPermissions.removeAll { $0.id == id && $0.turnId == turnId }
                pendingPermissions.append(PendingPermission(id: id, turnId: turnId, payload: payload))
                status = "waitingPermission"
            }
        } else if type == "permission.resolved", current {
            let id = Self.string(payload["permissionId"], payload["requestId"])
            pendingPermissions.removeAll { $0.id == id && (explicitTurn.isEmpty || $0.turnId == explicitTurn) }
            if pendingPermissions.isEmpty, status == "waitingPermission" {
                status = activeTurnId.isEmpty ? "idle" : "running"
            }
        }

        if Self.terminalTypes.contains(type) {
            pendingPermissions.removeAll { explicitTurn.isEmpty || $0.turnId == explicitTurn }
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

    private mutating func finishMessages(turnId: String, type: String) {
        let terminalStatus = String(type.dropFirst("turn.".count))
        for index in messages.indices
        where messages[index].turnId == turnId
            && ["streaming", "running", "awaitingApproval"].contains(messages[index].status)
        {
            messages[index].status = terminalStatus
        }
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
        let payload = event.payload
        let isStub = payload["detailStub"].boolValue
        let block = payload["block"]
        let message = payload["message"]
        let role = Self.string(payload["role"], message["role"]).lowercased()
        let user = role == "user" || role == "human"
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
            category = "assistant_final"
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
            sequence: event.sequence)
        if let index { messages[index] = entry } else { messages.insert(entry, at: 0) }
        if category == "assistant_final", !payload["block"]["supersedes"].arrayValue.isEmpty {
            messages = Self.droppingSupersededProgress(messages)
        }
        if family != "assistant", category != "user" { assistantInterrupted = true }
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
        }
        let requestID = Self.string(payload["requestId"])
        if !requestID.isEmpty, requestID == configurationRequestId {
            if type == "control.rejected" {
                configurationStatus = "rejected"
            } else if type == "control.unknown" || (type == "control.completed" && configurationStatus == "pending") {
                // An ACK has no effective configuration readback.
                configurationStatus = "unknown"
            }
        }
    }

    private mutating func projectQueue(_ payload: JSONValue, type: String) {
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
            ? .string(Self.string(event.payload["error"], event.payload["message"], "上下文压缩失败")) : .null
    }

    private mutating func projectAuxiliary(_ event: ConversationEvent, type: String, turnId: String) {
        let payload = event.payload
        if type.hasPrefix("subagent.") {
            let id = Self.string(payload["subagentId"], payload["agentId"], payload["id"])
            guard !id.isEmpty else { return }
            let previous = subagents.first { $0["id"] == .string(id) } ?? .null
            let phase = String(type.dropFirst("subagent.".count))
            let status =
                phase == "started"
                ? "running"
                : ["completed", "failed", "cancelled"].contains(phase)
                    ? phase : Self.string(previous["status"], "queued")
            var run = Self.merge(previous, payload)
            run["id"] = .string(id)
            run["conversationId"] = .string(conversationId)
            run["turnId"] = .string(Self.string(previous["turnId"], .string(turnId)))
            run["title"] = .string(Self.string(payload["title"], previous["title"], "Subagent"))
            run["task"] = .string(Self.string(payload["task"], payload["prompt"], previous["task"]))
            run["status"] = .string(status)
            if status == "running" {
                run["startedAt"] = previous["startedAt"].isNull ? .string(event.time) : previous["startedAt"]
            } else if status != "queued" {
                run["finishedAt"] = .string(event.time)
            }
            subagents.removeAll { $0["id"] == .string(id) }
            subagents.insert(run, at: 0)
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
        default: values = [payload["status"], payload["message"], payload["text"]]
        }
        for value in values {
            let content = text(value, textOnly: ["assistant_final", "assistant_progress", "user"].contains(category))
            if !content.isEmpty { return content }
        }
        return ""
    }
}
