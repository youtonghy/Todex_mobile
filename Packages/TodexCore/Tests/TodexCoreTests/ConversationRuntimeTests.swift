import Foundation
import Testing

@testable import TodexCore

/// Payloads below are excerpts from the actual shared-client regression fixtures
/// and backend emitters, not values synthesized by the Swift reducer:
/// - TodeX_protocol/tests/unit/conversation-runtime.test.cjs
/// - TodeX_protocol/tests/unit/conversation-recovery.test.cjs
/// - TodeX_protocol/tests/unit/mobile-parity.test.cjs
/// - TodeX_backend/src/provider/codex.rs (codex_item_event)
/// - TodeX_backend/src/provider/pi.rs (pi_completed_message_events, pi_tool_payload)
/// Only the journal sequence/conversation wrapper is supplied by `event`.
struct ConversationRuntimeTests {
    private func event(
        _ sequence: Int, _ type: String, _ payload: String = "{}",
        normalizedType: String? = nil, conversationId: String = "c",
        time: String = "2026-09-06T00:00:00.000Z"
    ) throws -> ConversationEvent {
        ConversationEvent(
            sequence: sequence, eventId: "event-\(sequence)", conversationId: conversationId,
            time: time, type: type, normalizedType: normalizedType,
            payload: try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)))
    }

    @Test(arguments: [[3, 4, 1, 2], [1, 3, 2, 4], [4, 3, 2, 1], [1, 2, 3, 4]])
    func liveAndReplayUseOneContiguousCursor(delivery: [Int]) throws {
        // conversation-runtime.test.cjs: live/replay interleaving.
        let events = [
            try event(1, "turn.started", #"{"turnId":"t"}"#),
            try event(2, "message.delta", #"{"turnId":"t","text":"Hello"}"#),
            try event(3, "message.delta", #"{"turnId":"t","text":" world"}"#),
            try event(4, "turn.completed", #"{"turnId":"t"}"#),
        ]
        var runtime = ConversationRuntime(conversationId: "c")
        for sequence in delivery { runtime.ingest(events[sequence - 1]) }
        #expect(runtime.appliedSequence == 4)
        #expect(runtime.highWaterSequence == 4)
        #expect(runtime.messages.map(\.text) == ["Hello world"])
        #expect(runtime.messages.first?.status == "completed")
        #expect(runtime.status == "completed")
        #expect(runtime.activeTurnId.isEmpty)
        #expect(!runtime.readyForActions)
        runtime.markReplayComplete(highWater: 4)
        #expect(runtime.readyForActions)
        let messages = runtime.messages
        let progress = runtime.lastProgressAt
        for item in events.reversed() { runtime.ingest(item) }
        #expect(runtime.messages == messages)
        #expect(runtime.lastProgressAt == progress)
        #expect(runtime.readyForActions)
    }

    @Test func partialAndFailedReplayNeverEnableHistoricalApprovals() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"t"}"#))
        runtime.ingest(
            try event(2, "permission.requested", #"{"turnId":"t","permissionId":"p","options":["allow","deny"]}"#))
        #expect(runtime.pendingPermissions.map(\.id) == ["p"])
        #expect(runtime.actionablePermissions.isEmpty)
        runtime.markReplayComplete(highWater: 4)
        #expect(runtime.appliedSequence == 2)
        #expect(runtime.needsRecovery)
        runtime.ingest(try event(4, "permission.requested", #"{"turnId":"t","permissionId":"q"}"#))
        #expect(runtime.pendingPermissions.map(\.id) == ["p"])
        runtime.ingest(try event(3, "permission.resolved", #"{"permissionId":"p"}"#))
        #expect(runtime.appliedSequence == 4)
        #expect(runtime.pendingPermissions.map(\.id) == ["q"])
        #expect(runtime.actionablePermissions.isEmpty)
        runtime.markReplayComplete(highWater: 4)
        #expect(runtime.actionablePermissions.map(\.id) == ["q"])
        runtime.beginReplay()
        #expect(runtime.actionablePermissions.isEmpty)
        // An HTTP failure requires no reducer mutation: beginReplay remains latched.
        runtime.ingest(try event(5, "provider.event"))
        #expect(!runtime.readyForActions)
        runtime.markReplayComplete(highWater: 5)
        #expect(runtime.readyForActions)
    }

    @Test func newLiveGapInvalidatesAnEarlierSuccessfulReplay() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.markReplayComplete(highWater: 0)
        #expect(runtime.readyForActions)
        runtime.ingest(try event(2, "permission.requested", #"{"turnId":"t","permissionId":"p"}"#))
        #expect(runtime.needsRecovery)
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"t"}"#))
        #expect(runtime.appliedSequence == 2)
        #expect(runtime.actionablePermissions.isEmpty)
        runtime.markReplayComplete(highWater: 2)
        #expect(runtime.actionablePermissions.count == 1)
        runtime.markReplayComplete(highWater: -1)
        #expect(runtime.highWaterSequence == 2)
    }

    @Test func foreignEventsAndDuplicateSequencesAreNoOps() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(50, "turn.started", #"{"turnId":"foreign"}"#, conversationId: "other"))
        runtime.ingest(try event(-1, "turn.started"))
        #expect(runtime.highWaterSequence == 0)
        let buffered = try event(2, "message.delta", #"{"turnId":"t","text":"first"}"#)
        runtime.ingest(buffered)
        runtime.ingest(try event(2, "message.delta", #"{"turnId":"t","text":"duplicate"}"#))
        var start = try event(1, "turn.started", #"{"turnId":"t"}"#)
        start.eventId = "toString"
        runtime.ingest(start)
        runtime.ingest(try event(2, "message.delta", #"{"turnId":"t","text":"again"}"#))
        #expect(runtime.messages.map(\.text) == ["first"])
        #expect(runtime.bufferedEventCount == 0)
        #expect(runtime.bufferedByteCount == 0)
    }

    @Test func overflowKeepsARecoverableCursorAndDoesNotDiscardContiguousInput() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        let highWater = ConversationRuntime.maximumBufferedEvents + 3
        for sequence in 2...highWater { runtime.ingest(try event(sequence, "provider.event")) }
        #expect(runtime.bufferedEventCount == ConversationRuntime.maximumBufferedEvents)
        #expect(runtime.highWaterSequence == highWater)
        #expect(runtime.appliedSequence == 0)
        runtime.ingest(try event(1, "provider.event"))
        #expect(runtime.appliedSequence == ConversationRuntime.maximumBufferedEvents + 1)
        #expect(runtime.bufferedEventCount == 0)
        runtime.markReplayComplete(highWater: highWater)
        #expect(runtime.needsRecovery)
        for sequence in (runtime.appliedSequence + 1)...highWater {
            runtime.ingest(try event(sequence, "provider.event"))
        }
        runtime.markReplayComplete(highWater: highWater)
        #expect(runtime.readyForActions)
    }

    @Test func oversizedAndExtremeSequenceFramesDoNotCrashOrEnableActions() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        var huge = try event(2, "provider.event")
        huge.payload = .string(String(repeating: "x", count: ConversationRuntime.maximumBufferedBytes + 1))
        runtime.ingest(huge)
        #expect(runtime.bufferedEventCount == 0)
        #expect(runtime.highWaterSequence == 2)
        runtime.ingest(try event(Int.max, "provider.event"))
        runtime.markReplayComplete(highWater: Int.max)
        #expect(runtime.highWaterSequence == Int.max)
        #expect(runtime.appliedSequence == 0)
        #expect(runtime.needsRecovery)
        #expect(runtime.bufferedByteCount <= ConversationRuntime.maximumBufferedBytes)
    }

    @Test func longJournalDuplicatesDoNotNeedAnUnboundedEventIDCache() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        // Same 8,000-record regression as conversation-runtime.test.cjs.
        for sequence in 1...8_000 { runtime.ingest(try event(sequence, "provider.event")) }
        for sequence in 1...8_000 { runtime.ingest(try event(sequence, "provider.event")) }
        #expect(runtime.appliedSequence == 8_000)
        #expect(runtime.bufferedEventCount == 0)
        #expect(runtime.messages.isEmpty)
    }

    @Test func semanticFullCompletionReplacesWhitespacePreservingDeltas() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"t"}"#))
        runtime.ingest(
            try event(
                2, "message.delta",
                #"{"text":"Hello","block":{"id":"item","category":"assistant_final","phase":"delta","turnId":"t"}}"#))
        runtime.ingest(
            try event(
                3, "message.delta",
                #"{"text":" ","block":{"id":"item","category":"assistant_final","phase":"delta","turnId":"t"}}"#))
        runtime.ingest(
            try event(
                4, "message.delta",
                #"{"text":"world","block":{"id":"item","category":"assistant_final","phase":"delta","turnId":"t"}}"#))
        #expect(runtime.messages.map(\.text) == ["Hello world"])
        let id = try #require(runtime.messages.first?.id)
        runtime.ingest(
            try event(
                5, "message.completed",
                #"{"message":{"role":"assistant","content":"Hello world!"},"block":{"id":"item","category":"assistant_final","phase":"completed","turnId":"t"}}"#,
                normalizedType: "turn.completed"))
        #expect(runtime.messages.map(\.text) == ["Hello world!"])
        #expect(runtime.messages.first?.id == id)
        #expect(runtime.status == "running")
        #expect(runtime.activeTurnId == "t")
        runtime.ingest(
            try event(
                6, "message.delta",
                #"{"text":"late","block":{"id":"item","category":"assistant_final","phase":"delta","turnId":"t"}}"#))
        #expect(runtime.messages.map(\.text) == ["Hello world!"])
    }

    @Test func legacyTextAndMessageIdentityJoinOnCompletion() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "codex.turn.started", #"{"turnId":"t"}"#))
        runtime.ingest(try event(2, "text_delta", #"{"delta":"answer"}"#))
        runtime.ingest(
            try event(
                3, "message.completed",
                #"{"messageId":"m","message":{"role":"assistant","content":"answer corrected"}}"#))
        #expect(runtime.messages.map(\.text) == ["answer corrected"])
        #expect(runtime.status == "running")
        runtime.ingest(try event(4, "conversation.interrupted", #"{"turnId":"t"}"#))
        #expect(runtime.status == "interrupted")
    }

    @Test func narrationSplitsIntoSegmentsAroundSteps() throws {
        // conversation-runtime.test.cjs: assistant narration splits at steps.
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"t"}"#))
        runtime.ingest(try event(2, "message.delta", #"{"turnId":"t","text":"First. "}"#))
        runtime.ingest(
            try event(
                3, "tool.started",
                #"{"arguments":{"command":"ls"},"block":{"category":"tool","id":"tool-1","turnId":"t","phase":"started"}}"#
            ))
        runtime.ingest(try event(4, "message.delta", #"{"turnId":"t","text":"Second."}"#))
        runtime.ingest(try event(5, "message.delta", #"{"turnId":"t","text":" more"}"#))
        runtime.ingest(try event(6, "turn.completed", #"{"turnId":"t"}"#))
        let assistant = runtime.messages.filter { $0.role == "assistant" }
        #expect(assistant.map(\.text) == ["Second. more", "First. "])
        #expect(Set(assistant.map(\.id)).count == 2)
        #expect(runtime.messages.contains { $0.category == "tool" })
        #expect(runtime.status == "completed")
    }

    @Test func codexCommentaryKeepsItsAdvertisedCategoryAcrossDeltas() throws {
        // codex.rs: item/started supplies phase; item/agentMessage/delta has none.
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"t"}"#))
        runtime.ingest(
            try event(
                2, "message.created",
                #"{"provider":"codex","role":"assistant","message":{"id":"m","type":"agentMessage","phase":"commentary","text":""},"block":{"id":"m","turnId":"t","category":"assistant_progress","phase":"started"}}"#
            ))
        runtime.ingest(
            try event(
                3, "message.delta",
                #"{"provider":"codex","role":"assistant","delta":"Checking files","block":{"id":"m","turnId":"t","category":"assistant_final","phase":"delta"}}"#
            ))
        #expect(runtime.messages.map(\.category) == ["assistant_progress"])
        #expect(runtime.messages.first?.role == "system")
        runtime.ingest(
            try event(
                4, "message.completed",
                #"{"provider":"codex","role":"assistant","message":{"id":"m","type":"agentMessage","phase":"commentary","text":"Checked files"},"block":{"id":"m","turnId":"t","category":"assistant_progress","phase":"completed"}}"#
            ))
        #expect(runtime.messages.map(\.text) == ["Checked files"])
        runtime.ingest(try event(5, "turn.started", #"{"turnId":"next"}"#))
        runtime.ingest(
            try event(
                6, "message.delta",
                #"{"text":"Final answer","block":{"id":"m","turnId":"next","category":"assistant_final","phase":"delta"}}"#
            ))
        #expect(runtime.messages.map(\.category) == ["assistant_final", "assistant_progress"])
        #expect(Set(runtime.messages.map(\.id)).count == 2)
    }

    @Test func typedBlocksBeatMisleadingFieldsAndFilterInternalContent() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(
            try event(
                1, "tool.started",
                #"{"arguments":{"command":"pwd"},"thinking":"must not become reasoning","block":{"category":"tool","id":"tool-1","turnId":"t","phase":"started"}}"#
            ))
        runtime.ingest(
            try event(
                2, "tool.completed",
                #"{"result":{"ok":true},"block":{"category":"tool","id":"tool-1","turnId":"t","phase":"completed"}}"#))
        runtime.ingest(
            try event(
                3, "message.completed",
                #"{"message":{"role":"assistant","content":[{"type":"thinking","thinking":"hidden"},{"type":"text","text":"final answer"},{"type":"toolCall","name":"read"}]},"tool":{"name":"misleading"},"block":{"category":"assistant_final","id":"answer-1","turnId":"t","phase":"completed"}}"#
            ))
        #expect(runtime.messages.count == 2)
        #expect(runtime.messages.first?.text == "final answer")
        #expect(runtime.messages.first?.role == "assistant")
        let tool = try #require(runtime.messages.first { $0.category == "tool" })
        #expect(tool.detail["arguments"]["command"] == "pwd")
        #expect(tool.detail["result"]["ok"] == true)
        #expect(tool.status == "completed")
    }

    @Test func piToolSnapshotsAndLegacyThoughtStreamsRemainSeparateFromAnswers() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"t"}"#))
        runtime.ingest(
            try event(2, "thought.delta", #"{"delta":{"type":"thinking_delta","contentIndex":0,"delta":"first"}}"#))
        runtime.ingest(
            try event(3, "thought.delta", #"{"delta":{"type":"thinking_delta","contentIndex":0,"delta":" next"}}"#))
        runtime.ingest(
            try event(4, "tool.updated", #"{"delta":{"type":"toolcall_delta","contentIndex":2,"content":"partial"}}"#))
        runtime.ingest(
            try event(5, "tool.updated", #"{"delta":{"type":"toolcall_end","contentIndex":2,"content":"done"}}"#))
        runtime.ingest(
            try event(
                6, "message.completed",
                #"{"message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"text","text":"draft"}]}}"#))
        runtime.ingest(
            try event(
                7, "message.completed",
                #"{"message":{"role":"toolResult","content":[{"type":"text","text":"internal output"}]}}"#))
        runtime.ingest(try event(8, "context.updated", #"{"content":"internal context, not a response"}"#))
        #expect(runtime.messages.count == 2)
        #expect(runtime.messages.first { $0.category == "reasoning" }?.text == "first next")
        #expect(runtime.messages.first { $0.category == "tool" }?.text == "done")
        #expect(!runtime.messages.contains { $0.category == "assistant_final" })
    }

    @Test func oldTurnEventsCannotResolveCurrentPermissionOrChangeConfiguration() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"old"}"#))
        runtime.ingest(try event(2, "permission.requested", #"{"turnId":"old","permissionId":"p"}"#))
        runtime.ingest(try event(3, "turn.started", #"{"turnId":"new"}"#))
        runtime.ingest(try event(4, "permission.requested", #"{"turnId":"new","permissionId":"p"}"#))
        let progress = runtime.lastProgressAt
        runtime.ingest(
            try event(5, "permission.resolved", #"{"turnId":"old","permissionId":"p"}"#, time: "2026-09-07T00:00:00Z"))
        runtime.ingest(try event(6, "turn.failed", #"{"turnId":"old"}"#))
        runtime.ingest(
            try event(
                7, "turn.configuration", #"{"turnId":"old","effective":{"model":"old","source":"provider-confirmed"}}"#)
        )
        runtime.ingest(
            try event(
                8, "control.requested",
                #"{"turnId":"old","requestId":"r","control":{"action":"configure","model":"old"}}"#))
        runtime.ingest(try event(9, "compaction.failed", #"{"turnId":"old","message":"old failure"}"#))
        runtime.ingest(try event(10, "permission.requested", #"{"turnId":"old","permissionId":"stale"}"#))
        #expect(runtime.activeTurnId == "new")
        #expect(runtime.status == "waitingPermission")
        #expect(runtime.pendingPermissions.map(\.id) == ["p"])
        #expect(runtime.pendingPermissions.first?.turnId == "new")
        #expect(runtime.effectiveConfig.isNull)
        #expect(runtime.requestedConfig.isNull)
        #expect(runtime.compaction["status"] == "idle")
        #expect(runtime.lastProgressAt == progress)
        runtime.ingest(try event(11, "turn.cancelled", #"{"turnId":"new"}"#))
        runtime.ingest(try event(12, "permission.requested", #"{"turnId":"new","permissionId":"late"}"#))
        #expect(runtime.pendingPermissions.isEmpty)
        #expect(runtime.status == "cancelled")
    }

    @Test func configurationRequiresReadbackAndPreservesTheLastEffectiveValueOnRejection() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(
            try event(
                1, "turn.started",
                #"{"turnId":"t","requestedPermissions":{"sandboxMode":"read-only"},"effectivePermissions":{"sandboxMode":"read-only"},"configurationStatus":"validated"}"#
            ))
        #expect(runtime.configurationStatus == "validated")
        #expect(runtime.effectiveConfig["source"] == "locally-validated")
        runtime.ingest(
            try event(
                2, "turn.configuration", #"{"turnId":"t","effective":{"model":"old","source":"provider-confirmed"}}"#))
        runtime.ingest(
            try event(
                3, "control.requested",
                #"{"turnId":"t","requestId":"r","control":{"action":"configure","model":"new"}}"#))
        #expect(runtime.configurationStatus == "pending")
        #expect(runtime.requestedConfig["model"] == "new")
        runtime.ingest(try event(4, "control.completed", #"{"turnId":"t","requestId":"r","result":{}}"#))
        #expect(runtime.configurationStatus == "unknown")
        #expect(runtime.effectiveConfig["model"] == "old")
        runtime.ingest(try event(5, "control.rejected", #"{"turnId":"t","requestId":"unrelated"}"#))
        #expect(runtime.configurationStatus == "unknown")
        runtime.ingest(try event(6, "control.rejected", #"{"turnId":"t","requestId":"r"}"#))
        #expect(runtime.configurationStatus == "rejected")
        #expect(runtime.effectiveConfig["model"] == "old")
        runtime.ingest(
            try event(
                7, "turn.configuration", #"{"turnId":"t","effective":{"model":"new","source":"provider-confirmed"}}"#))
        #expect(runtime.configurationStatus == "provider-confirmed")
        runtime.ingest(try event(8, "control.unknown", #"{"turnId":"t","requestId":"r","message":"ACK lost"}"#))
        #expect(runtime.configurationStatus == "provider-confirmed")
        runtime.ingest(try event(9, "turn.configuration", #"{"turnId":"t","effective":{"model":"no-source"}}"#))
        #expect(runtime.configurationStatus == "unknown")
        #expect(runtime.effectiveConfig["source"] == "unknown")
        runtime.ingest(try event(10, "turn.started", #"{"turnId":"next"}"#))
        #expect(runtime.effectiveConfig.isNull)
        #expect(runtime.requestedConfig.isNull)
    }

    @Test func queueAndAutomaticCompactionDoNotEndTheParentTurn() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"t"}"#))
        runtime.ingest(
            try event(
                2, "queue.updated",
                #"{"turnId":"t","items":[{"id":"q","text":"Next","status":"delivering"},{"itemId":"q2","text":"Later"}]}"#
            ))
        #expect(runtime.queueItems.map { $0["id"] } == ["q", "q2"])
        #expect(runtime.queueItems.last?["status"] == "queued")
        runtime.ingest(try event(3, "compaction.started", #"{"turnId":"t","source":"provider"}"#))
        runtime.ingest(
            try event(
                4, "usage.updated",
                #"{"provider":"codex","turnId":"t","usage":{"last":{"input":80,"output":10,"total":90}},"contextWindow":100}"#
            ))
        #expect(runtime.compaction["status"] == "running")
        #expect(runtime.compaction["recommended"] == true)
        runtime.ingest(
            try event(5, "compaction.completed", #"{"turnId":"t","source":"provider","summary":"Summarized"}"#))
        #expect(runtime.status == "running")
        #expect(runtime.activeTurnId == "t")
        #expect(runtime.compaction["status"] == "completed")
        runtime.ingest(try event(6, "queue.updated", #"{"items":null}"#))
        #expect(runtime.queueItems.count == 2)
        runtime.ingest(try event(7, "turn.failed", #"{"turnId":"t"}"#))
        #expect(runtime.queuePaused)
        #expect(runtime.queueItems.first?["status"] == "delivering")
        runtime.ingest(try event(8, "queue.updated", #"{"items":[],"paused":false}"#))
        #expect(runtime.queueItems.isEmpty)
        #expect(!runtime.queuePaused)
    }

    @Test func unknownUsageDoesNotEraseCompactionAndMemoryConfigurationIsNotContent() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "compaction.failed", #"{"message":"failed"}"#))
        runtime.ingest(try event(2, "usage.updated", #"{"usage":{}}"#))
        #expect(runtime.compaction["status"] == "failed")
        #expect(runtime.compaction["error"] == "failed")
        #expect(runtime.compaction["usedTokens"].isNull)
        runtime.ingest(try event(3, "subagent.started", #"{"subagentId":"s","title":"Worker","task":"Review"}"#))
        runtime.ingest(try event(4, "subagent.completed", #"{"subagentId":"s","result":"Done"}"#))
        #expect(runtime.subagents.count == 1)
        #expect(runtime.subagents.first?["title"] == "Worker")
        #expect(runtime.subagents.first?["status"] == "completed")
        runtime.ingest(try event(5, "memory.updated", #"{"enabled":true,"scope":"workspace"}"#))
        #expect(runtime.memoryEntries.isEmpty)
        runtime.ingest(try event(6, "memory.created", #"{"memoryId":"m","content":"Fact"}"#))
        runtime.ingest(try event(7, "memory.updated", #"{"memoryId":"m","content":"Corrected fact"}"#))
        #expect(runtime.memoryEntries.count == 1)
        #expect(runtime.memoryEntries.first?["content"] == "Corrected fact")
        runtime.ingest(try event(8, "memory.deleted", #"{"memoryId":"m"}"#))
        #expect(runtime.memoryEntries.isEmpty)
    }

    @Test func piMessageUsageAndCompletionShareIdentityWithoutMergingDistinctCalls() throws {
        // pi.rs: unsigned_messages_share_usage_identity_with_final_output.
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"turn-local"}"#))
        runtime.ingest(
            try event(
                2, "usage.updated",
                #"{"provider":"pi","turnId":"turn-local","messageId":"turn-local-message-1","source":"provider","scope":"message","usage":{"input":10,"output":4}}"#
            ))
        runtime.ingest(
            try event(
                3, "message.completed",
                #"{"provider":"pi","turnId":"turn-local","messageId":"turn-local-message-1","role":"assistant","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"answer"}],"usage":{"input":10,"output":4}},"block":{"category":"assistant_final","id":"turn-local-message-1","turnId":"turn-local","phase":"completed"}}"#
            ))
        #expect(runtime.usageRecords.count == 1)
        runtime.ingest(
            try event(
                4, "usage.updated",
                #"{"provider":"pi","turnId":"turn-local","messageId":"turn-local-message-2","scope":"message","usage":{"input":10,"output":4}}"#
            ))
        #expect(runtime.usageRecords.count == 2)
        #expect(runtime.usageRecords.allSatisfy { $0["inputTokens"] == 10 && $0["outputTokens"] == 4 })
        #expect(runtime.usageRecords.allSatisfy { $0["cacheSemantics"] == "unknown" && $0["totalTokens"].isNull })
        #expect(runtime.messages.map(\.text) == ["answer"])
    }

    @Test func usageNormalizesTopLevelKeysAndDoesNotInventMissingCounters() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(
            try event(
                1, "usage.updated",
                #"{"provider":"claude-code","model":"test-model","scope":"turn","turnId":"t","usage":{"input_tokens":40,"output_tokens":15,"cache_read_input_tokens":20,"cache_creation_input_tokens":5}}"#
            ))
        let record = try #require(runtime.usageRecords.first)
        #expect(record["provider"] == "claude-code")
        #expect(record["model"] == "test-model")
        #expect(record["inputTokens"] == 40)
        #expect(record["outputTokens"] == 15)
        #expect(record["cachedInputTokens"] == 20)
        #expect(record["cacheWriteTokens"] == 5)
        #expect(record["totalTokens"] == 80)
        #expect(record["cacheSemantics"] == "additional")
        #expect(record["updatedAt"].doubleValue == 1_788_652_800_000)
        runtime.ingest(
            try event(
                2, "usage.updated",
                #"{"provider":"claude-code","turnId":"t","usage":{"input_tokens":40,"output_tokens":16}}"#))
        let sparse = try #require(runtime.usageRecords.first)
        #expect(runtime.usageRecords.count == 1)
        #expect(sparse["inputTokens"] == 40)
        #expect(sparse["cachedInputTokens"].isNull)
        #expect(sparse["cacheWriteTokens"].isNull)
        #expect(sparse["totalTokens"].isNull)
        #expect(sparse["model"].isNull)
        for key in [
            "provider", "model", "inputTokens", "outputTokens", "cachedInputTokens", "cacheWriteTokens", "totalTokens",
            "cacheSemantics", "updatedAt",
        ] {
            #expect(sparse.objectValue[key] != nil)
        }
    }

    @Test(arguments: ["included", "additional", "unknown"])
    func cacheSemanticsNeverDoubleCountIncludedTokens(semantics: String) throws {
        var runtime = ConversationRuntime(conversationId: "c")
        var sample = try event(1, "usage.updated", #"{"usage":{"input":40,"output":10,"cacheRead":20,"cacheWrite":5}}"#)
        sample.payload["usage"]["cacheSemantics"] = .string(semantics)
        runtime.ingest(sample)
        let total = try #require(runtime.usageRecords.first)["totalTokens"]
        switch semantics {
        case "included": #expect(total == 50)
        case "additional": #expect(total == 75)
        default: #expect(total.isNull)
        }
        #expect(runtime.usageRecords.first?["tokensPerSecond"].isNull == true)
    }

    @Test func invalidNumericUsageRemainsUnknownAndExplicitZeroRemainsZero() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(
            try event(
                1, "usage.updated",
                #"{"provider":"codex","usage":{"input":"NaN","output":-1,"cacheRead":null,"cacheWrite":"0","total":"Infinity"}}"#
            ))
        let record = try #require(runtime.usageRecords.first)
        #expect(record["inputTokens"].isNull)
        #expect(record["outputTokens"].isNull)
        #expect(record["cachedInputTokens"].isNull)
        #expect(record["cacheWriteTokens"] == 0)
        #expect(record["totalTokens"].isNull)
    }

    @Test func codexCumulativeUsageAttributesDifferencesAndHandlesProcessReset() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"a"}"#))
        let first =
            #"{"provider":"codex","turnId":"a","usage":{"cumulative":{"input":40,"output":10,"cacheRead":20,"total":50},"last":{"input":40,"output":10,"cacheRead":20,"total":50}}}"#
        runtime.ingest(try event(2, "usage.updated", first))
        runtime.ingest(try event(3, "usage.updated", first))
        runtime.ingest(try event(4, "turn.completed", #"{"turnId":"a"}"#))
        runtime.ingest(try event(5, "turn.started", #"{"turnId":"b"}"#))
        runtime.ingest(
            try event(
                6, "usage.updated",
                #"{"provider":"codex","turnId":"b","usage":{"cumulative":{"input":100,"output":30,"cacheRead":60,"total":130},"last":{"input":60,"output":20,"cacheRead":40,"total":80}}}"#
            ))
        #expect(runtime.usageRecords.first { $0["turnId"] == "a" }?["totalTokens"] == 50)
        #expect(runtime.usageRecords.first { $0["turnId"] == "b" }?["totalTokens"] == 80)
        #expect(runtime.usageRecords.first { $0["turnId"] == "b" }?["cachedInputTokens"] == 40)
        // Delayed snapshot from a cannot move b's session baseline backwards.
        runtime.ingest(try event(7, "usage.updated", first))
        runtime.ingest(
            try event(
                8, "usage.updated",
                #"{"provider":"codex","turnId":"b","usage":{"cumulative":{"input":110,"output":35,"cacheRead":60,"total":145},"last":{"input":10,"output":5,"total":15}}}"#
            ))
        #expect(runtime.usageRecords.first { $0["turnId"] == "b" }?["totalTokens"] == 95)
        runtime.ingest(
            try event(
                9, "usage.updated",
                #"{"provider":"codex","turnId":"b","usage":{"cumulative":{"input":5,"output":2,"cacheRead":0,"total":7},"last":{"input":5,"output":2,"total":7}}}"#
            ))
        #expect(runtime.usageRecords.first { $0["turnId"] == "b" }?["totalTokens"] == 102)
        #expect(runtime.usageRecords.first { $0["turnId"] == "b" }?["cacheWriteTokens"].isNull == true)
    }

    @Test func legacyCodexTokenUsagePreservesProviderTotalsAndContextWindow() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(
            try event(
                1, "provider.event",
                #"{"provider":"codex","providerMethod":"thread/tokenUsage/updated","metadata":{"tokenUsage":{"modelContextWindow":128000,"last":{"totalTokens":120,"inputTokens":80,"outputTokens":30,"cachedInputTokens":5,"cacheWriteInputTokens":5}}}}"#
            ))
        let usage = try #require(runtime.usageRecords.first)
        #expect(usage["totalTokens"] == 120)
        #expect(usage["inputTokens"] == 80)
        #expect(usage["outputTokens"] == 30)
        #expect(usage["cachedInputTokens"] == 5)
        #expect(usage["cacheWriteTokens"] == 5)
        #expect(runtime.compaction["contextWindow"] == 128_000)
        #expect(runtime.compaction["usedTokens"] == 120)
    }

    @Test func finalTurnUsageSupersedesRequestsWithoutLosingPriorTurns() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"t"}"#))
        runtime.ingest(
            try event(
                2, "usage.updated",
                #"{"provider":"grok-build","turnId":"old","usage":{"last":{"input":4,"output":1,"total":5}}}"#))
        runtime.ingest(
            try event(
                3, "usage.updated",
                #"{"provider":"grok-build","turnId":"t","requestId":"r1","usage":{"last":{"input":10,"output":2}}}"#))
        runtime.ingest(
            try event(
                4, "usage.updated",
                #"{"provider":"grok-build","turnId":"t","requestId":"r2","usage":{"last":{"input":20,"output":3}}}"#))
        runtime.ingest(
            try event(
                5, "usage.updated",
                #"{"provider":"grok-build","turnId":"t","scope":"turn","aggregation":"snapshot","final":true,"usage":{"cacheSemantics":"included","last":{"input":30,"output":5,"cacheRead":10,"total":35}}}"#
            ))
        #expect(runtime.usageRecords.count == 2)
        #expect(runtime.usageRecords.compactMap { $0["totalTokens"].doubleValue }.reduce(0, +) == 40)
        runtime.ingest(
            try event(
                6, "usage.updated",
                #"{"provider":"grok-build","turnId":"t","requestId":"r1","usage":{"last":{"input":10,"output":2}}}"#))
        #expect(runtime.usageRecords.count == 2)
        #expect(runtime.usageRecords.first?["scope"] == "turn")
    }

    @Test func usageMessageIDsAreScopedToTheirTurn() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(
            try event(
                1, "usage.updated",
                #"{"provider":"pi","turnId":"a","messageId":"m","scope":"message","usage":{"totalTokens":20}}"#))
        runtime.ingest(
            try event(
                2, "usage.updated",
                #"{"provider":"pi","turnId":"b","messageId":"m","scope":"message","usage":{"totalTokens":20}}"#))
        #expect(runtime.usageRecords.count == 2)
        #expect(Set(runtime.usageRecords.map { $0["id"] }).count == 2)
    }

    @Test func sparseCumulativeUsageDoesNotResetOrPoisonKnownBaselines() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"t"}"#))
        runtime.ingest(
            try event(
                2, "usage.updated",
                #"{"provider":"codex","turnId":"t","usage":{"cumulative":{"input":40,"output":10,"total":50},"last":{"input":40,"output":10,"total":50}}}"#
            ))
        runtime.ingest(
            try event(
                3, "usage.updated",
                #"{"provider":"codex","turnId":"t","usage":{"cumulative":{"input":45},"last":{"input":5}}}"#))
        #expect(runtime.usageRecords.first?["outputTokens"].isNull == true)
        #expect(runtime.usageRecords.first?["totalTokens"].isNull == true)
        runtime.ingest(
            try event(
                4, "usage.updated",
                #"{"provider":"codex","turnId":"t","usage":{"cumulative":{"input":50,"output":15,"total":65},"last":{"input":5,"output":5,"total":10}}}"#
            ))
        #expect(runtime.usageRecords.count == 1)
        #expect(runtime.usageRecords.first?["inputTokens"] == 50)
        #expect(runtime.usageRecords.first?["outputTokens"] == 15)
        #expect(runtime.usageRecords.first?["totalTokens"] == 65)
    }

    @Test func piExecutionCallbacksKeepArgumentsAndReportErrorResults() throws {
        // pi_tool_payload emits every key, with null for missing callback fields.
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(
            try event(
                1, "tool.started",
                #"{"provider":"pi","toolCallId":"call-1","toolName":"bash","arguments":{"command":"pwd"},"partialResult":null,"result":null,"isError":null,"block":{"category":"tool","id":"call-1","turnId":"t","phase":"started"}}"#
            ))
        runtime.ingest(
            try event(
                2, "tool.updated",
                #"{"provider":"pi","toolCallId":"call-1","toolName":"bash","arguments":null,"partialResult":{"content":[{"type":"text","text":"working"}]},"result":null,"isError":null,"block":{"category":"tool","id":"call-1","turnId":"t","phase":"delta"}}"#
            ))
        runtime.ingest(
            try event(
                3, "tool.completed",
                #"{"provider":"pi","toolCallId":"call-1","toolName":"bash","arguments":null,"partialResult":null,"result":{"content":[{"type":"text","text":"command failed"}]},"isError":true,"block":{"category":"tool","id":"call-1","turnId":"t","phase":"completed"}}"#
            ))
        let tool = try #require(runtime.messages.first)
        #expect(runtime.messages.count == 1)
        #expect(tool.category == "tool")
        #expect(tool.text == "command failed")
        #expect(tool.status == "failed")
        #expect(tool.detail["arguments"]["command"] == "pwd")
        #expect(tool.detail["isError"] == true)
    }

    @Test func explicitEmptyFullMessageReplacesAnEarlierDraft() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"t"}"#))
        runtime.ingest(try event(2, "message.delta", #"{"text":"draft"}"#))
        runtime.ingest(try event(3, "message.completed", #"{"role":"assistant","text":""}"#))
        #expect(runtime.messages.count == 1)
        #expect(runtime.messages.first?.text == "")
        #expect(runtime.messages.first?.status == "completed")
    }

    @Test func errorStopReasonFailsOpenMessagesAndPausesTheQueue() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"t"}"#))
        runtime.ingest(try event(2, "message.delta", #"{"text":"unfinished"}"#))
        runtime.ingest(try event(3, "queue.updated", #"{"items":[{"id":"q","text":"Next"}]}"#))
        runtime.ingest(try event(4, "turn.completed", #"{"turnId":"t","stopReason":"error"}"#))
        #expect(runtime.status == "failed")
        #expect(runtime.messages.first?.status == "failed")
        #expect(runtime.queuePaused)
    }

    @Test func progressOnlyAdvancesForAppliedEventsAndRuntimeCopiesAreIndependent() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(2, "message.delta", #"{"text":"answer"}"#))
        #expect(runtime.lastProgressAt == nil)
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"t"}"#))
        #expect(runtime.lastProgressAt?.timeIntervalSince1970 == 1_788_652_800)
        var copy = runtime
        copy.ingest(try event(3, "message.delta", #"{"text":" more"}"#, time: "invalid-time"))
        #expect(copy.messages.first?.text == "answer more")
        #expect(runtime.messages.first?.text == "answer")
        #expect(copy.lastProgressAt == runtime.lastProgressAt)
        #expect(runtime.appliedSequence == 2)
    }

    @Test func summaryStubsKeepFoldedEntriesAndHydrateFillsContentByID() throws {
        // conversation-runtime.test.cjs: summary stubs + hydrate merge.
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"t"}"#))
        runtime.ingest(
            try event(
                2, "provider.event",
                #"{"turnId":"t","detailStub":true,"block":{"id":"call-1","category":"tool","phase":"completed","turnId":"t"},"toolCallId":"call-1","toolName":"shell"}"#
            ))
        runtime.ingest(
            try event(
                3, "provider.event",
                #"{"turnId":"t","detailStub":true,"block":{"id":"think-1","category":"reasoning","phase":"completed","turnId":"t"}}"#
            ))
        runtime.ingest(try event(4, "message.delta", #"{"turnId":"t","text":"Answer"}"#))
        runtime.ingest(try event(5, "turn.completed", #"{"turnId":"t"}"#))
        #expect(runtime.appliedSequence == 5)
        let toolStub = try #require(runtime.messages.first { $0.category == "tool" })
        let thinkStub = try #require(runtime.messages.first { $0.category == "reasoning" })
        #expect(toolStub.detail["detailStub"].boolValue == true)
        #expect(thinkStub.detail["detailStub"].boolValue == true)
        let hydrated = runtime.hydrate([
            try event(
                3, "provider.event",
                #"{"turnId":"t","thinking":"deep thought","block":{"id":"think-1","category":"reasoning","phase":"completed","turnId":"t"}}"#
            ),
            try event(
                2, "provider.event",
                #"{"turnId":"t","block":{"id":"call-1","category":"tool","phase":"completed","turnId":"t"},"toolCallId":"call-1","result":"file list"}"#
            ),
        ])
        #expect(hydrated)
        let tool = try #require(runtime.messages.first { $0.id == toolStub.id })
        let think = try #require(runtime.messages.first { $0.id == thinkStub.id })
        #expect(tool.detail["detailStub"].isNull)
        #expect(tool.text.contains("file list"))
        #expect(think.text == "deep thought")
        #expect(runtime.appliedSequence == 5)
        #expect(runtime.messages.first { $0.role == "assistant" }?.text == "Answer")
    }

    @Test func stubFallbackCoversHeuristicEventsWhoseContentKeysWereStripped() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"t"}"#))
        runtime.ingest(
            try event(2, "provider.event", #"{"turnId":"t","detailStub":true}"#))
        runtime.ingest(
            try event(3, "provider.event", #"{"turnId":"t","detailStub":true,"toolCall":{"id":"c1"}}"#))
        #expect(runtime.messages.contains { $0.category == "reasoning" && $0.turnId == "t" })
        #expect(runtime.messages.contains { $0.category == "tool" })
    }

    @Test func lazySeedOpensAtTailAndLiveFramesAboveFloorStillApply() throws {
        // Live frames can arrive before the seed lands; they buffer, then the
        // tail window drains them once its contiguous prefix reaches the gap.
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(9, "turn.started", #"{"turnId":"t"}"#))
        runtime.ingest(try event(10, "message.delta", #"{"turnId":"t","text":"live"}"#))
        runtime.ingest(try event(3, "message.delta", #"{"text":"stale"}"#))
        #expect(runtime.bufferedEventCount == 3)
        runtime.seedHistoryFloor(4)
        #expect(runtime.appliedSequence == 4)
        // The frame below the floor is already inside the loaded window.
        #expect(runtime.bufferedEventCount == 2)
        for sequence in 5...8 {
            runtime.ingest(
                try event(
                    sequence, "message.completed",
                    #"{"message":{"role":"assistant","text":"older"}}"#))
        }
        #expect(runtime.appliedSequence == 10)
        #expect(runtime.activeTurnId == "t")
        #expect(runtime.status == "running")
        #expect(runtime.messages.first?.text == "live")
        runtime.markReplayComplete(highWater: 10)
        #expect(runtime.readyForActions)
        // Events at or below the floor never resurrect after the seed.
        runtime.ingest(
            try event(2, "message.completed", #"{"message":{"role":"assistant","text":"old"}}"#))
        #expect(runtime.appliedSequence == 10)
        #expect(runtime.messages.first { $0.text == "old" } == nil)
    }

    @Test func lazySeedIsIgnoredOnceTheRuntimeIsInitialized() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"t"}"#))
        runtime.seedHistoryFloor(40)
        #expect(runtime.appliedSequence == 1)
        runtime.seedHistoryFloor(0)
        #expect(runtime.appliedSequence == 1)
    }

    @Test func prependAppendsOlderWindowWithoutRevivingStaleState() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.seedHistoryFloor(5)
        runtime.ingest(try event(6, "turn.started", #"{"turnId":"t2"}"#))
        runtime.ingest(
            try event(
                7, "message.completed",
                #"{"turnId":"t2","message":{"role":"assistant","text":"new answer"}}"#))
        runtime.ingest(try event(8, "turn.completed", #"{"turnId":"t2"}"#))
        runtime.markReplayComplete(highWater: 8)
        let older = [
            try event(2, "turn.started", #"{"turnId":"t1"}"#),
            try event(
                3, "permission.requested",
                #"{"turnId":"t1","permissionId":"p1","title":"old approval"}"#),
            try event(
                4, "message.completed",
                #"{"turnId":"t1","message":{"role":"assistant","text":"older answer"}}"#),
            try event(5, "turn.completed", #"{"turnId":"t1"}"#),
        ]
        let prepended = runtime.prepend(older, below: 5)
        #expect(prepended)
        // The older turn's unresolved approval must not reopen on the live runtime.
        #expect(runtime.pendingPermissions.isEmpty)
        #expect(runtime.activeTurnId.isEmpty)
        #expect(runtime.status == "completed")
        #expect(runtime.messages.map(\.text) == ["new answer", "older answer", "old approval"])
        #expect(runtime.messages.last?.sequence == 3)
        // Re-prepending the same page is a no-op, and events above the floor
        // belong to the live window rather than the history tail.
        let again = runtime.prepend(older, below: 5)
        #expect(!again)
        let aboveFloor = runtime.prepend(
            [try event(9, "message.completed", #"{"message":{"role":"assistant","text":"late"}}"#)],
            below: 5)
        #expect(!aboveFloor)
    }

    // pi.rs message_update/pi_completed_message_events and conversation-runtime.test.cjs:
    // Pi streams answer text as progress blocks and finalizes it under the native id.
    private func piProgress(_ sequence: Int, _ text: String, block: String = "m-1-assistant_progress-1")
        throws -> ConversationEvent
    {
        try event(
            sequence, "message.delta",
            #"{"provider":"pi","turnId":"t","delta":{"type":"text_delta","contentIndex":1,"delta":"\#(text)"},"block":{"category":"assistant_progress","id":"\#(block)","turnId":"t","phase":"delta","contentIndex":1}}"#
        )
    }

    private func piFinal(_ sequence: Int, supersedes: String?) throws -> ConversationEvent {
        let field = supersedes.map { #","supersedes":["\#($0)"]"# } ?? ""
        return try event(
            sequence, "message.completed",
            #"{"provider":"pi","turnId":"t","role":"assistant","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"Answer"}]},"block":{"category":"assistant_final","id":"native-1","turnId":"t","phase":"completed"\#(field)}}"#
        )
    }

    @Test func piStreamedAnswerIsVisibleAndReplacedByTheFinalAnswer() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"t"}"#))
        runtime.ingest(try piProgress(2, "Ans"))
        runtime.ingest(try piProgress(3, "wer"))
        #expect(runtime.messages.map(\.category) == ["assistant_progress"])
        #expect(runtime.messages.map(\.text) == ["Answer"])
        var legacy = runtime
        runtime.ingest(try piFinal(4, supersedes: "m-1-assistant_progress-1"))
        #expect(runtime.messages.map(\.category) == ["assistant_final"])
        #expect(runtime.messages.map(\.text) == ["Answer"])
        // Journals written before `supersedes` existed keep both rows.
        legacy.ingest(try piFinal(4, supersedes: nil))
        #expect(legacy.messages.count == 2)
    }

    @Test func supersedesOnlyRemovesTheNamedProgressBlocks() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"t"}"#))
        runtime.ingest(try piProgress(2, "Checking files", block: "m-0-assistant_progress-0"))
        runtime.ingest(try event(3, "tool.started", #"{"turnId":"t","toolCallId":"call","toolName":"read"}"#))
        runtime.ingest(try piProgress(4, "Answer"))
        runtime.ingest(try piFinal(5, supersedes: "m-1-assistant_progress-1"))
        #expect(runtime.messages.filter { $0.category.hasPrefix("assistant") }.map(\.text) == ["Answer", "Checking files"])
        #expect(runtime.messages.first { $0.text == "Checking files" }?.category == "assistant_progress")
    }

    @Test func olderPagesAndHydrationCannotReviveSupersededProgress() throws {
        let events = [
            try event(1, "turn.started", #"{"turnId":"t"}"#), try piProgress(2, "Answer"),
            try piFinal(3, supersedes: "m-1-assistant_progress-1"),
        ]
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.seedHistoryFloor(2)
        runtime.ingest(events[2])
        runtime.markReplayComplete(highWater: 3)
        let prepended = runtime.prepend(Array(events[0...1]), below: 2)
        let hydrated = runtime.hydrate(Array(events[0...1]))
        #expect(!prepended)
        #expect(!hydrated)
        #expect(runtime.messages.map(\.category) == ["assistant_final"])
    }

    // claude.rs handle_stream_event and the `assistant` frame: text streams as
    // untyped `text_delta`, then one message.completed per content block.
    private func claudeCompleted(_ sequence: Int, _ part: String) throws -> ConversationEvent {
        try event(
            sequence, "message.completed",
            #"{"provider":"claude-code","turnId":"t","message":{"id":"msg_1","type":"message","role":"assistant","content":[\#(part)]}}"#
        )
    }

    @Test func claudeStreamsAnswersAndBlockCompletionsKeepTheirText() throws {
        var runtime = ConversationRuntime(conversationId: "c")
        runtime.ingest(try event(1, "turn.started", #"{"turnId":"t"}"#))
        runtime.ingest(
            try event(
                2, "thought.delta",
                #"{"provider":"claude-code","role":"assistant","turnId":"t","delta":{"type":"thinking_delta","thinking":"Plan"}}"#))
        runtime.ingest(try claudeCompleted(3, #"{"type":"thinking","thinking":"Plan","signature":"s"}"#))
        for (sequence, text) in [(4, "Hel"), (5, "lo")] {
            runtime.ingest(
                try event(
                    sequence, "message.delta",
                    #"{"provider":"claude-code","role":"assistant","turnId":"t","delta":{"type":"text_delta","text":"\#(text)"}}"#))
        }
        let answers = { runtime.messages.filter { $0.category == "assistant_final" } }
        #expect(answers().map(\.text) == ["Hello"])
        #expect(answers().first?.status == "streaming")
        runtime.ingest(try claudeCompleted(6, #"{"type":"text","text":"Hello"}"#))
        runtime.ingest(try claudeCompleted(7, #"{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}"#))
        // Thinking stays reasoning; the tool_use completion does not blank the answer.
        #expect(answers().map(\.text) == ["Hello"])
        #expect(answers().first?.status == "completed")
        #expect(runtime.messages.contains { $0.category == "reasoning" && $0.text == "Plan" })
    }
}
