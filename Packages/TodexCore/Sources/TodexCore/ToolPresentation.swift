import Foundation

/// Provider-agnostic reading of a tool timeline entry, ported from the shared
/// TypeScript `describeToolCall` (TodeX_protocol/src/toolPresentation.ts) so
/// both clients name a call, summarize its key argument, and keep arguments,
/// output and errors apart. Input is the entry's merged event payload: Codex
/// carries the app-server item under `item`; Pi/ACP/Claude carry
/// `toolName`/`arguments`/`result` (or nested `tool`/`toolCall`) fields.
public struct ToolPresentation: Sendable, Equatable {
    public enum Kind: String, Sendable { case command, fileChange, webSearch, tool }
    public enum Status: String, Sendable { case running, completed, failed, unknown }

    public var kind: Kind
    /// Provider-native tool name; empty when the event carries none.
    public var name: String
    /// One-line key argument (command, path, query); empty when none.
    public var summary: String
    public var argsText: String
    public var outputText: String?
    public var errorText: String?
    public var status: Status

    static let summaryMaxCharacters = 160
    /// Expanded bodies are previews; huge reads or diffs would stall rendering.
    static let detailMaxCharacters = 8_000
    private static let summaryKeys = [
        "command", "cmd", "file_path", "filePath", "path", "notebook_path", "pattern", "query", "url",
        "description", "prompt",
    ]
    private static let codexKinds: [String: Kind] = [
        "commandExecution": .command, "command_execution": .command, "fileChange": .fileChange,
        "file_change": .fileChange, "webSearch": .webSearch, "web_search": .webSearch,
    ]

    public static func describe(_ detail: JSONValue, fallbackText: String = "") -> ToolPresentation {
        let item = detail["item"]
        if case .object = item, let type = nonEmpty(item["type"]) {
            return codexItem(item, type: type)
        }
        guard case .object = detail else {
            return ToolPresentation(
                kind: .tool, name: "", summary: oneLine(fallbackText), argsText: bounded(fallbackText),
                outputText: nil, errorText: nil, status: .unknown)
        }
        let tool = detail["tool"]
        let toolCall = detail["toolCall"].isNull ? detail["tool_call"] : detail["toolCall"]
        let name = nonEmpty(
            detail["toolName"], detail["tool_name"], detail["name"], detail["tool"], tool["name"], toolCall["name"],
            toolCall["toolName"]) ?? ""
        let args = firstPresent(
            detail["arguments"], detail["input"], detail["args"], tool["input"], toolCall["arguments"],
            toolCall["input"])
            ?? (detail["command"].optionalString.map { JSONValue.object(["command": .string($0)]) })
        let title = nonEmpty(detail["title"]) ?? ""
        let summary = args.map(argsSummary).flatMap { $0.isEmpty ? nil : $0 }
            ?? (!title.isEmpty && title != name ? oneLine(title) : "")
        let rawOutput = firstPresent(
            detail["result"], detail["partialResult"], detail["partial_result"], detail["output"])
        let output = rawOutput.flatMap { $0 == "" ? nil : readable($0) }
        let errorText = errorMessage(detail["error"])
        return ToolPresentation(
            kind: name.isEmpty && detail["command"].optionalString != nil ? .command : .tool,
            name: name, summary: summary, argsText: args.map(detailText) ?? "",
            outputText: output.map(detailText).flatMap { $0.isEmpty ? nil : $0 },
            errorText: errorText.isEmpty ? nil : errorText,
            status: callStatus(detail, output: output, errorText: errorText))
    }

    private static func codexItem(_ item: JSONValue, type: String) -> ToolPresentation {
        let kind = codexKinds[type] ?? .tool
        let errorText = errorMessage(item["error"])
        var summary = ""
        var args: JSONValue? = item["arguments"].isNull ? nil : item["arguments"]
        var output = firstPresent(
            item["result"], item["aggregatedOutput"], item["aggregated_output"], item["output"])
        switch kind {
        case .command:
            summary = oneLine(commandText(item["command"]))
            var value: [String: JSONValue] = ["command": item["command"]]
            if let cwd = nonEmpty(item["cwd"]) { value["cwd"] = .string(cwd) }
            args = .object(value)
        case .fileChange:
            let changes = item["changes"].arrayValue.filter { if case .object = $0 { true } else { false } }
            summary = oneLine(changes.compactMap { nonEmpty($0["path"]) }.joined(separator: ", "))
            args = changes.isEmpty ? nil : .array(changes)
            output = nil
        case .webSearch:
            summary = oneLine(nonEmpty(item["query"]) ?? "")
        case .tool:
            summary = argsSummary(item["arguments"])
            if summary.isEmpty { summary = oneLine(nonEmpty(item["path"], item["prompt"]) ?? "") }
        }
        let tool = nonEmpty(item["tool"]) ?? ""
        let server = nonEmpty(item["server"]) ?? ""
        let name = !tool.isEmpty ? (server.isEmpty ? tool : "\(server).\(tool)") : kind == .tool ? type : ""
        let readableOutput = output.flatMap { $0 == "" ? nil : readable($0) }
        return ToolPresentation(
            kind: kind, name: name, summary: summary, argsText: args.map(detailText) ?? "",
            outputText: readableOutput.map(detailText).flatMap { $0.isEmpty ? nil : $0 },
            errorText: errorText.isEmpty ? nil : errorText,
            status: callStatus(item, output: readableOutput, errorText: errorText))
    }

    private static func callStatus(_ value: JSONValue, output: JSONValue?, errorText: String) -> Status {
        if value["isError"] == true || value["is_error"] == true || !errorText.isEmpty { return .failed }
        let exitCode = value["exitCode"].doubleValue ?? value["exit_code"].doubleValue
        if let exitCode, exitCode != 0 { return .failed }
        let state = (nonEmpty(value["status"]) ?? "").lowercased()
            .replacingOccurrences(of: #"[\s_-]"#, with: "", options: .regularExpression)
        if ["failed", "error", "declined", "rejected", "cancelled", "canceled"].contains(state) { return .failed }
        if ["completed", "complete", "success", "succeeded", "done"].contains(state) { return .completed }
        if ["inprogress", "pending", "running", "started"].contains(state) { return .running }
        if !value["result"].isNull { return .completed }
        if exitCode != nil { return .completed }
        return output == nil ? .unknown : .running
    }

    private static func argsSummary(_ args: JSONValue) -> String {
        var parsed = args
        if case .string(let text) = args, let data = text.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        {
            parsed = decoded
        }
        if case .string(let text) = parsed { return oneLine(text) }
        guard case .object = parsed else { return "" }
        // Clarifying-question tools carry no command or path; the questions
        // themselves identify the call.
        let questions = parsed["questions"].arrayValue.compactMap { nonEmpty($0["question"]) }
        if !questions.isEmpty { return oneLine(questions.joined(separator: " / ")) }
        for key in summaryKeys {
            let text = key == "command" || key == "cmd" ? commandText(parsed[key]) : nonEmpty(parsed[key]) ?? ""
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return oneLine(text) }
        }
        return ""
    }

    /// MCP-style results wrap text in `{content: [{type: "text", text}]}`.
    private static func readable(_ value: JSONValue) -> JSONValue {
        let parts = value["content"].arrayValue.compactMap { $0["text"].optionalString }
        return parts.isEmpty ? value : .string(parts.joined(separator: "\n"))
    }

    private static func detailText(_ value: JSONValue) -> String {
        switch value {
        case .null: return ""
        case .string(let text): return bounded(text)
        case .object(let object) where object.isEmpty: return ""
        default: return bounded(value.prettyPrinted)
        }
    }

    private static func errorMessage(_ value: JSONValue) -> String {
        nonEmpty(value, value["message"]) ?? ""
    }

    private static func commandText(_ value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        let parts = value.arrayValue
        guard !parts.isEmpty, parts.allSatisfy({ $0.optionalString != nil }) else { return "" }
        return parts.map(\.stringValue).joined(separator: " ")
    }

    private static func oneLine(_ text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > summaryMaxCharacters ? String(line.prefix(summaryMaxCharacters)) + "…" : line
    }

    private static func bounded(_ text: String) -> String {
        text.count > detailMaxCharacters ? String(text.prefix(detailMaxCharacters)) + "…" : text
    }

    private static func nonEmpty(_ values: JSONValue...) -> String? {
        values.lazy.compactMap { $0.optionalString?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func firstPresent(_ values: JSONValue...) -> JSONValue? {
        values.first { !$0.isNull }
    }
}
