import Foundation
import Testing

@testable import TodexCore

/// Cases mirror TodeX_protocol/tests/unit/tool-presentation.test.cjs; Codex
/// items arrive under `item` in the merged event payload the runtime keeps.
struct ToolPresentationTests {
    private func describe(_ json: String) throws -> ToolPresentation {
        ToolPresentation.describe(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }

    @Test func piAndAcpExposeNameKeyArgumentAndOutput() throws {
        let pi = try describe(
            #"{"toolName":"bash","arguments":{"command":"ls -la\necho done"},"result":{"content":[{"type":"text","text":"file.txt"}]},"isError":false}"#
        )
        #expect(pi.name == "bash")
        #expect(pi.summary == "ls -la")
        #expect(pi.argsText.contains("\"command\""))
        #expect(pi.outputText == "file.txt")
        #expect(pi.status == .completed)
        let acp = try describe(
            #"{"toolCallId":"c1","toolName":"read","title":"Read notes.md","status":"in_progress","tool":{"kind":"read"}}"#)
        #expect(acp.name == "read")
        #expect(acp.summary == "Read notes.md")
        #expect(acp.status == .running)
        #expect(
            try describe(#"{"toolName":"bash","arguments":{"command":"false"},"result":"boom","isError":true}"#).status
                == .failed)
    }

    @Test func claudeToolUseAndQuestionsReadNestedRecords() throws {
        let claude = try describe(
            #"{"provider":"claude-code","tool":{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/repo/a.ts"}}}"#)
        #expect(claude.name == "Read")
        #expect(claude.summary == "/repo/a.ts")
        #expect(claude.status == .unknown)
        let question = try describe(
            #"{"toolName":"AskUserQuestion","arguments":{"questions":[{"question":"Which color?"},{"question":"Which fruits?"}]}}"#
        )
        #expect(question.summary == "Which color? / Which fruits?")
    }

    @Test func codexItemsMapToKindsWithTheirIdentifyingField() throws {
        let command = try describe(
            #"{"item":{"type":"commandExecution","id":"i1","command":"pnpm test","cwd":"/repo","status":"completed","exitCode":1,"aggregatedOutput":"fail"}}"#
        )
        #expect(command.kind == .command)
        #expect(command.name == "")
        #expect(command.summary == "pnpm test")
        #expect(command.outputText == "fail")
        #expect(command.status == .failed)
        let change = try describe(
            #"{"item":{"type":"fileChange","changes":[{"path":"a.ts","kind":"update"},{"path":"b.ts","kind":"add"}],"status":"completed"}}"#
        )
        #expect(change.kind == .fileChange)
        #expect(change.summary == "a.ts, b.ts")
        #expect(change.outputText == nil)
        #expect(try describe(#"{"item":{"type":"webSearch","query":"heroui chat tool"}}"#).summary == "heroui chat tool")
        let mcp = try describe(
            #"{"item":{"type":"mcpToolCall","server":"docs","tool":"search","arguments":{"query":"x"},"error":{"message":"denied"},"status":"failed"}}"#
        )
        #expect(mcp.name == "docs.search")
        #expect(mcp.summary == "x")
        #expect(mcp.errorText == "denied")
        #expect(mcp.status == .failed)
        #expect(try describe(#"{"item":{"type":"imageView","path":"/tmp/a.png"}}"#).name == "imageView")
    }

    @Test func plainTextFallsBackAndSummariesStayBounded() throws {
        let plain = ToolPresentation.describe(.null, fallbackText: "{\"command\": \"ls")
        #expect(plain.name == "")
        #expect(plain.summary == "{\"command\": \"ls")
        #expect(plain.status == .unknown)
        #expect(try describe(#"{"command":"pwd"}"#).kind == .command)
        let long = ToolPresentation.describe([
            "toolName": "write",
            "arguments": ["path": .string(String(repeating: "x", count: 500)), "content": .string(String(repeating: "y", count: 20_000))],
        ])
        #expect(long.summary.count <= 161)
        #expect(long.argsText.count <= 8_001)
    }
}
