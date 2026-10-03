import Foundation

/// Renders another conversation as Markdown so it can be attached to a prompt
/// (`@chat:`), matching `@todex/protocol/conversationExport` on desktop/web.
public enum ConversationExport {
    /// Fetches one replay page: `(afterSequence, limit)` → the `/events` body.
    public typealias Page = @Sendable (_ after: Int, _ limit: Int) async throws -> JSONValue

    /// Events per page; the backend caps replay pages at 1000.
    static let pageLimit = 1_000
    /// Upper bound on pages so a journal that never reports the end cannot loop forever.
    static let maximumPages = 10_000

    /// Replays the whole journal and returns the user and assistant messages,
    /// oldest first. Process steps (tools, reasoning, approvals) are not part
    /// of a transcript.
    public static func transcript(conversationId: String, page: Page) async throws -> [TimelineMessage] {
        var runtime = ConversationRuntime(conversationId: conversationId)
        for _ in 0..<maximumPages {
            let cursor = runtime.appliedSequence
            let body = try await page(cursor, pageLimit)
            guard case .array(let events) = body["events"] else {
                throw TodexError.invalid(String(localized: "历史分页响应无效", bundle: .module))
            }
            for raw in events { runtime.ingest(try raw.decoded(ConversationEvent.self)) }
            if !body["hasMore"].boolValue, runtime.appliedSequence >= runtime.highWaterSequence {
                return transcriptMessages(runtime.messages)
            }
            guard runtime.appliedSequence > cursor else {
                throw TodexError.invalid(String(localized: "历史记录存在缺口，请重新核对", bundle: .module))
            }
        }
        throw TodexError.invalid(String(localized: "对话历史过长，无法导出", bundle: .module))
    }

    /// Runtime messages are newest first; transcripts read oldest first.
    public static func transcriptMessages(_ messages: [TimelineMessage]) -> [TimelineMessage] {
        messages
            .filter {
                ($0.role == "user" || $0.role == "assistant")
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { $0.sequence < $1.sequence }
    }

    /// Message bodies are already Markdown, so they are embedded verbatim
    /// under a role heading. With `maxBytes`, older messages are dropped first
    /// and the document notes how many were left out.
    public static func markdown(_ messages: [TimelineMessage], title: String, maxBytes: Int? = nil) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = "# \(trimmedTitle.isEmpty ? "Conversation" : trimmedTitle)\n"
        let sections = messages.map {
            "## \($0.role == "user" ? "User" : "Assistant")\n\n\($0.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        guard let maxBytes else { return ([header] + sections).joined(separator: "\n") }
        let note = { (count: Int) in "> \(count) earlier message(s) omitted.\n" }
        // Keep the newest messages that fit, reserving room for the omission note.
        var budget = maxBytes - header.utf8.count - note(messages.count).utf8.count - 2
        var first = sections.count
        while first > 0 {
            let cost = sections[first - 1].utf8.count + 1
            if cost > budget { break }
            budget -= cost
            first -= 1
        }
        var kept = Array(sections[first...])
        if kept.isEmpty, let newest = sections.last {
            // The newest message alone exceeds the budget: keep its beginning.
            kept = [truncated(newest, toBytes: max(0, budget - 1)) + "\n"]
            first = sections.count - 1
        }
        return ([header] + (first > 0 ? [note(first)] : []) + kept).joined(separator: "\n")
    }

    /// Cuts on a character boundary so no partial UTF-8 sequence remains.
    static func truncated(_ text: String, toBytes limit: Int) -> String {
        var bytes = 0
        var end = text.startIndex
        for index in text.indices {
            let size = text[index].utf8.count
            if bytes + size > limit { break }
            bytes += size
            end = text.index(after: index)
        }
        return String(text[..<end])
    }
}
