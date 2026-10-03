import Foundation
import Testing

@testable import TodexCore

/// Mirrors TodeX_protocol/tests/unit/conversation-export.test.cjs.
struct ConversationExportTests {
    private static let journal: [String] = [
        #"{"schemaVersion":2,"sequence":1,"eventId":"e1","conversationId":"c","time":"2026-10-03T00:00:00Z","type":"message.created","payload":{"role":"user","content":"Fix the **build**"}}"#,
        #"{"schemaVersion":2,"sequence":2,"eventId":"e2","conversationId":"c","time":"2026-10-03T00:00:00Z","type":"turn.started","payload":{"turnId":"t"}}"#,
        #"{"schemaVersion":2,"sequence":3,"eventId":"e3","conversationId":"c","time":"2026-10-03T00:00:00Z","type":"message.delta","payload":{"turnId":"t","text":"Looking"}}"#,
        #"{"schemaVersion":2,"sequence":4,"eventId":"e4","conversationId":"c","time":"2026-10-03T00:00:00Z","type":"tool.started","payload":{"turnId":"t","toolCallId":"x","toolName":"ls"}}"#,
        #"{"schemaVersion":2,"sequence":5,"eventId":"e5","conversationId":"c","time":"2026-10-03T00:00:00Z","type":"message.delta","payload":{"turnId":"t","text":"Done."}}"#,
        #"{"schemaVersion":2,"sequence":6,"eventId":"e6","conversationId":"c","time":"2026-10-03T00:00:00Z","type":"turn.completed","payload":{"turnId":"t"}}"#,
    ]

    private final class Calls: @unchecked Sendable { var afters: [Int] = [] }

    private static func pagedReplay(pageSize: Int, calls: Calls = Calls()) -> ConversationExport.Page {
        { after, _ in
            calls.afters.append(after)
            let events = try journal.dropFirst(after).prefix(pageSize).map {
                try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
            }
            let last = after + events.count
            return ["events": .array(Array(events)), "hasMore": .bool(last < journal.count)]
        }
    }

    private static func message(_ role: String, _ text: String, _ sequence: Int) -> TimelineMessage {
        TimelineMessage(
            id: "\(sequence)", turnId: "", role: role, category: role == "user" ? "user" : "assistant_final",
            text: text, status: "completed", detail: .null, sequence: sequence)
    }

    @Test
    func fetchesEveryPageAndKeepsOnlyUserAndAssistantMessages() async throws {
        let calls = Calls()
        let messages = try await ConversationExport.transcript(
            conversationId: "c", page: Self.pagedReplay(pageSize: 2, calls: calls))
        #expect(calls.afters == [0, 2, 4])
        #expect(messages.map(\.role) == ["user", "assistant", "assistant"])
        #expect(messages.map(\.text) == ["Fix the **build**", "Looking", "Done."])
    }

    @Test
    func reportsAJournalThatStopsAdvancing() async {
        await #expect(throws: TodexError.self) {
            try await ConversationExport.transcript(conversationId: "c") { _, _ in
                ["events": .array([]), "hasMore": .bool(true)]
            }
        }
    }

    @Test
    func rendersMessagesUnderRoleHeadings() async throws {
        let messages = try await ConversationExport.transcript(
            conversationId: "c", page: Self.pagedReplay(pageSize: 10))
        #expect(
            ConversationExport.markdown(messages, title: "Build fix")
                == "# Build fix\n\n## User\n\nFix the **build**\n\n## Assistant\n\nLooking\n\n## Assistant\n\nDone.\n")
    }

    @Test
    func dropsTheOldestMessagesToFitTheBudget() {
        let messages = [Self.message("user", "one", 1), Self.message("assistant", "two", 2), Self.message("user", "three", 3)]
        let markdown = ConversationExport.markdown(messages, title: "T", maxBytes: 70)
        #expect(markdown.utf8.count <= 70)
        #expect(markdown.contains("earlier message(s) omitted"))
        #expect(markdown.contains("three"))
        #expect(!markdown.contains("one"))
    }

    @Test
    func truncatesASingleMessageLargerThanTheBudget() {
        let markdown = ConversationExport.markdown(
            [Self.message("assistant", String(repeating: "界", count: 200), 1)], title: "T", maxBytes: 120)
        #expect(markdown.utf8.count <= 120)
        #expect(markdown.contains("## Assistant"))
        #expect(!markdown.contains("\u{FFFD}"))
    }
}
