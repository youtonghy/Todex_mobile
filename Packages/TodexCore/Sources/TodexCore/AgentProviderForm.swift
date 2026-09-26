import Foundation

/// Structured form ⇄ settingsConfig mapping for the managed agent provider
/// editor, mirroring desktop `lib/agentProviders.ts`. `build` starts from the
/// existing settingsConfig so keys the form does not model survive a round
/// trip. Masked secrets pass through unchanged; the backend restores the
/// stored value server-side.
public enum AgentProviderForm {
    public static let maskedSecret = "__TODEX_MASKED__"
    /// Pi models.json thinking levels; OpenCode variants omit `off` — a variant
    /// *is* an effort choice there, so "no thinking" is simply absent.
    public static let piThinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
    public static let opencodeThinkingLevels = ["minimal", "low", "medium", "high", "xhigh", "max"]
    public static let grokAPIBackends = ["chat_completions", "responses", "messages"]
    /// Public xAI API endpoint Grok Build uses when a model sets no base_url.
    public static let grokXAIBaseURL = "https://api.x.ai/v1"
    /// `api` values Pi supports in models.json; extension-registered customs
    /// stay possible through JSON mode.
    public static let piAPIKinds = [
        "openai-completions", "openai-responses", "azure-openai-responses", "openai-codex-responses",
        "anthropic-messages", "google-generative-ai", "google-vertex", "mistral-conversations",
        "bedrock-converse-stream", "pi-messages",
    ]
    /// Common context-window sizes; the field still accepts any positive integer.
    public static let contextPresets: [(value: String, label: String)] = [
        ("128000", "128K"), ("272000", "272K"), ("1000000", "1M"),
    ]

    public static func thinkingLevels(for agent: String) -> [String] {
        agent == "pi" ? piThinkingLevels : opencodeThinkingLevels
    }

    /// Enabled levels when a model gains reasoning support without an existing
    /// map: matches what Pi/OpenCode expose for an unconfigured reasoning model.
    public static func defaultEfforts(for agent: String) -> [String] {
        agent == "pi" ? ["off", "minimal", "low", "medium", "high"] : ["low", "medium", "high"]
    }

    /// Grok Build credential source: the `grok login` session kept in auth.json
    /// (official subscription) or a per-model API key in config.toml.
    public enum GrokAuthMode: String, Sendable, CaseIterable {
        case subscription, api
    }

    /// Per-model editor row shared by the additive agents (Pi, OpenCode).
    public struct Model: Sendable, Equatable {
        public var id: String
        public var name = ""
        public var contextWindow = ""
        public var maxTokens = ""
        public var reasoning = false
        public var efforts: [String] = []
        public init(id: String) { self.id = id }
    }

    public struct Values: Sendable, Equatable {
        public var name = ""
        public var baseURL = ""
        public var apiKey = ""
        public var model = ""
        public var reasoningEffort = ""
        /// Pi `api`; Grok Build `api_backend`.
        public var apiKind = ""
        public var authMode: GrokAuthMode = .api
        /// Codex `model_context_window` (top-level TOML number).
        public var contextWindow = ""
        public var models: [Model] = []
        public init() {}
    }

    public enum ValidationError: Error, LocalizedError, Equatable {
        case invalidNumber, outputRequired, modelRequired
        public var errorDescription: String? {
            switch self {
            case .invalidNumber: String(localized: "数值字段必须是正整数", bundle: .module)
            case .outputRequired: String(localized: "填写上下文窗口时必须同时给出最大输出", bundle: .module)
            case .modelRequired: String(localized: "使用 API 密钥时必须填写模型", bundle: .module)
            }
        }
    }

    // MARK: - Extract

    /// `settings == nil` describes a new provider (Grok defaults to API mode).
    public static func extract(agent: String, name: String = "", settings: JSONValue?) -> Values {
        let isNew = settings == nil
        let settings = settings ?? .object([:])
        var values = Values()
        values.name = name
        switch agent {
        case "claude-code":
            let env = settings["env"].objectValue
            values.baseURL = env["ANTHROPIC_BASE_URL"]?.stringValue ?? ""
            values.apiKey = (env["ANTHROPIC_AUTH_TOKEN"] ?? env["ANTHROPIC_API_KEY"])?.stringValue ?? ""
            values.model = env["ANTHROPIC_MODEL"]?.stringValue ?? ""
        case "codex":
            let config = settings["config"].stringValue
            // base_url belongs to the active provider table, not whichever comes first.
            let active = tomlScalar(config, "model_provider")
            values.baseURL = tomlScalar(
                config, "base_url",
                within: { active.isEmpty ? $0.hasPrefix("model_providers.") : $0 == "model_providers.\(active)" })
            values.apiKey = settings["auth"]["OPENAI_API_KEY"].stringValue
            values.model = tomlScalar(config, "model")
            values.reasoningEffort = tomlScalar(config, "model_reasoning_effort")
            values.contextWindow = tomlNumber(config, "model_context_window")
        case "grok-build":
            let fields = grokModelFields(settings["config"].stringValue)
            let authKey = grokAuthAPIKey(settings)
            values.authMode =
                grokHasSession(settings)
                ? .subscription
                : !fields.apiKey.isEmpty || !fields.baseURL.isEmpty || !authKey.isEmpty || isNew
                    ? .api : .subscription
            values.baseURL = fields.baseURL
            values.apiKey = fields.apiKey.isEmpty ? authKey : fields.apiKey
            values.model = fields.model
            values.apiKind = fields.apiBackend
        case "opencode":
            let options = settings["options"].objectValue
            values.baseURL = (options["baseURL"] ?? options["baseUrl"])?.stringValue ?? ""
            values.apiKey = options["apiKey"]?.stringValue ?? ""
            values.models = settings["models"].objectValue.keys.sorted().map { id in
                opencodeEntryToForm(id: id, entry: settings["models"][id])
            }
        case "pi":
            values.baseURL = settings["baseUrl"].stringValue
            values.apiKey = settings["apiKey"].stringValue
            values.apiKind = settings["api"].stringValue
            values.models = settings["models"].arrayValue.map(piEntryToForm).filter { !$0.id.isEmpty }
        default:
            break
        }
        return values
    }

    private static func piEntryToForm(_ entry: JSONValue) -> Model {
        var model = Model(id: entry["id"].stringValue)
        model.name = entry["name"].stringValue
        model.contextWindow = numberField(entry["contextWindow"])
        model.maxTokens = numberField(entry["maxTokens"])
        model.reasoning = entry["reasoning"] == .bool(true)
        // Mirrors the backend's pi_supported_thinking_levels: absent means
        // enabled for the classic levels; xhigh/max must be declared; null disables.
        let map = entry["thinkingLevelMap"].objectValue
        model.efforts =
            model.reasoning
            ? piThinkingLevels.filter { level in
                if map[level] == .some(.null) { return false }
                if level == "xhigh" || level == "max" { return map[level] != nil }
                return true
            } : []
        return model
    }

    private static func opencodeEntryToForm(id: String, entry: JSONValue) -> Model {
        var model = Model(id: id)
        model.name = entry["name"].stringValue
        model.contextWindow = numberField(entry["limit"]["context"])
        model.maxTokens = numberField(entry["limit"]["output"])
        model.reasoning = entry["reasoning"] == .bool(true)
        let variants = entry["variants"].objectValue
        model.efforts = opencodeThinkingLevels.filter { level in
            guard let variant = variants[level] else { return false }
            return variant["disabled"] != .bool(true)
        }
        return model
    }

    // MARK: - Build

    public static func build(agent: String, form: Values, existing: JSONValue?) -> JSONValue {
        let previous = existing.flatMap { $0.objectValue.isEmpty ? nil : $0 } ?? .object([:])
        let trimmed = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch agent {
        case "claude-code":
            var env = previous["env"].objectValue
            if !trimmed(form.baseURL).isEmpty { env["ANTHROPIC_BASE_URL"] = .string(trimmed(form.baseURL)) }
            if !trimmed(form.apiKey).isEmpty { env["ANTHROPIC_AUTH_TOKEN"] = .string(trimmed(form.apiKey)) }
            if !trimmed(form.model).isEmpty { env["ANTHROPIC_MODEL"] = .string(trimmed(form.model)) }
            var next = previous
            next["env"] = .object(env)
            return next
        case "codex":
            // A new key replaces the whole auth object, like desktop: credentials
            // from another login mode must not linger beside it.
            var next = previous
            next["auth"] =
                trimmed(form.apiKey).isEmpty
                ? .object(previous["auth"].objectValue) : ["OPENAI_API_KEY": .string(trimmed(form.apiKey))]
            next["config"] = .string(codexConfig(form: form, previous: previous))
            return next
        case "grok-build":
            return grokSettings(form: form, previous: previous)
        case "opencode":
            var options = previous["options"].objectValue
            if !trimmed(form.baseURL).isEmpty { options["baseURL"] = .string(trimmed(form.baseURL)) }
            if !trimmed(form.apiKey).isEmpty { options["apiKey"] = .string(trimmed(form.apiKey)) }
            var models: [String: JSONValue] = [:]
            for model in form.models {
                models[model.id] = opencodeModelEntry(model, existing: previous["models"][model.id])
            }
            var next = previous
            next["options"] = .object(options)
            next["models"] = .object(models)
            return next
        case "pi":
            var existingByID: [String: JSONValue] = [:]
            for entry in previous["models"].arrayValue where !entry["id"].stringValue.isEmpty {
                existingByID[entry["id"].stringValue] = entry
            }
            var next = previous
            next["models"] = .array(form.models.map { piModelEntry($0, existing: existingByID[$0.id] ?? .object([:])) })
            if !trimmed(form.baseURL).isEmpty { next["baseUrl"] = .string(trimmed(form.baseURL)) }
            if !trimmed(form.apiKey).isEmpty { next["apiKey"] = .string(trimmed(form.apiKey)) }
            if !trimmed(form.apiKind).isEmpty { next["api"] = .string(trimmed(form.apiKind)) }
            return next
        default:
            return previous
        }
    }

    private static let codexTemplate = """
        model_provider = "custom"
        model = "gpt-5"

        [model_providers.custom]
        name = "Custom"
        base_url = "https://example.com/v1"
        wire_api = "responses"
        requires_openai_auth = true

        """

    private static func codexConfig(form: Values, previous: JSONValue) -> String {
        let existing = previous["config"].stringValue
        var config =
            existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? codexTemplate : existing
        let model = form.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { config = patchTomlScalar(config, "model", model) }
        let effort = form.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !effort.isEmpty { config = patchTomlScalar(config, "model_reasoning_effort", effort) }
        if let window = parsePositiveInt(form.contextWindow) {
            config = patchTomlNumber(config, "model_context_window", window)
        }
        let found = tomlScalar(config, "model_provider")
        let table = found.isEmpty ? "custom" : found
        config = patchTomlScalar(config, "model_provider", table)
        let providerTable = "model_providers.\(table)"
        let baseURL = form.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !baseURL.isEmpty {
            config = patchTomlScalar(
                config, "base_url", baseURL, within: { $0 == providerTable }, newTable: providerTable)
        }
        let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            config = patchTomlScalar(
                config, "name", name, within: { $0 == providerTable }, newTable: providerTable)
        }
        return config
    }

    /// Subscription keeps the stored `grok login` session and lets it
    /// authenticate the default model (a per-model api_key would win over it).
    /// API mode points `[models].default` at a `[model.<key>]` entry carrying
    /// the key; an existing entry keeps its catalog key when the model id
    /// changes so a masked api_key still restores against the stored profile.
    private static func grokSettings(form: Values, previous: JSONValue) -> JSONValue {
        var config = previous["config"].stringValue
        let before = grokModelFields(config)
        let formModel = form.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = formModel.isEmpty ? before.model : formModel
        let previousAuth: JSONValue = if case .object = previous["auth"] { previous["auth"] } else { .null }
        var next = previous
        if form.authMode == .subscription {
            if !model.isEmpty {
                let key = before.hasTable && before.model == model ? before.key : model
                config = patchTomlScalar(config, "default", key, within: isModelsTable, newTable: "models")
                config = removeTomlKey(config, "api_key", within: grokModelTable(key))
            }
            next["auth"] = previousAuth
            next["config"] = .string(config)
            return next
        }
        let authKey = grokAuthAPIKey(previous)
        let apiKey = form.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let keepAuthKey = before.apiKey.isEmpty && !authKey.isEmpty && apiKey == authKey && !grokHasSession(previous)
        next["auth"] = keepAuthKey ? previousAuth : .null
        guard !model.isEmpty else {
            next["config"] = .string(config)
            return next
        }
        let key = before.hasTable ? before.key : model
        let table = grokModelTable(key)
        let header = grokModelHeader(key)
        config = patchTomlScalar(config, "default", key, within: isModelsTable, newTable: "models")
        config = patchTomlScalar(config, "model", model, within: table, newTable: header)
        let formBaseURL = form.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedBaseURL = tomlScalar(config, "base_url", within: table)
        let baseURL = !formBaseURL.isEmpty ? formBaseURL : !storedBaseURL.isEmpty ? storedBaseURL : grokXAIBaseURL
        config = patchTomlScalar(config, "base_url", baseURL, within: table, newTable: header)
        if !apiKey.isEmpty, !keepAuthKey {
            config = patchTomlScalar(config, "api_key", apiKey, within: table, newTable: header)
        }
        let apiKind = form.apiKind.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKind.isEmpty {
            config = patchTomlScalar(config, "api_backend", apiKind, within: table, newTable: header)
        }
        let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { config = patchTomlScalar(config, "name", name, within: table, newTable: header) }
        next["config"] = .string(config)
        return next
    }

    private static func applyName(_ entry: inout [String: JSONValue], _ model: Model) {
        let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { entry.removeValue(forKey: "name") } else { entry["name"] = .string(name) }
    }

    private static func applyReasoningFlag(_ entry: inout [String: JSONValue], _ model: Model, existing: JSONValue) {
        if model.reasoning {
            entry["reasoning"] = true
        } else if existing.objectValue["reasoning"] != nil {
            entry["reasoning"] = false
        } else {
            entry.removeValue(forKey: "reasoning")
        }
    }

    /// Pi `models[]` entry: enabled levels keep their provider mapping (identity
    /// by default), disabled ones are `null`. The map is left alone when
    /// reasoning is off so re-enabling restores the previous choices.
    private static func piModelEntry(_ model: Model, existing: JSONValue) -> JSONValue {
        var entry = existing.objectValue
        entry["id"] = .string(model.id)
        applyName(&entry, model)
        if let value = parsePositiveInt(model.contextWindow) {
            entry["contextWindow"] = .number(Double(value))
        } else {
            entry.removeValue(forKey: "contextWindow")
        }
        if let value = parsePositiveInt(model.maxTokens) {
            entry["maxTokens"] = .number(Double(value))
        } else {
            entry.removeValue(forKey: "maxTokens")
        }
        applyReasoningFlag(&entry, model, existing: existing)
        if model.reasoning {
            let previous = existing["thinkingLevelMap"].objectValue
            var map: [String: JSONValue] = [:]
            for level in piThinkingLevels {
                if model.efforts.contains(level) {
                    if case .some(.string) = previous[level] {
                        map[level] = previous[level]
                    } else {
                        map[level] = .string(level)
                    }
                } else {
                    map[level] = .null
                }
            }
            entry["thinkingLevelMap"] = .object(map)
        }
        return .object(entry)
    }

    /// OpenCode `models.<id>` entry: limits live under `limit` (the pair is
    /// required by the config schema); effort choices are `variants` carrying
    /// `{reasoningEffort}`. Unchecking an existing variant keeps it with
    /// `disabled: true` so catalog-supplied variants can be turned off.
    private static func opencodeModelEntry(_ model: Model, existing: JSONValue) -> JSONValue {
        var entry = existing.objectValue
        applyName(&entry, model)
        let context = parsePositiveInt(model.contextWindow)
        let output = parsePositiveInt(model.maxTokens)
        let previousLimit = existing["limit"]
        if context != nil || output != nil,
            let resolvedContext = context ?? positiveInt(previousLimit["context"]),
            let resolvedOutput = output ?? positiveInt(previousLimit["output"])
        {
            var limit = previousLimit.objectValue
            limit["context"] = .number(Double(resolvedContext))
            limit["output"] = .number(Double(resolvedOutput))
            entry["limit"] = .object(limit)
        } else {
            // Absent or incomplete pair: validate reports the latter before save.
            entry.removeValue(forKey: "limit")
        }
        applyReasoningFlag(&entry, model, existing: existing)
        let previousVariants = existing["variants"].objectValue
        var variants = previousVariants.filter { !opencodeThinkingLevels.contains($0.key) }
        for level in opencodeThinkingLevels {
            let previous = previousVariants[level]
            if model.efforts.contains(level) {
                var merged = previous?.objectValue ?? [:]
                merged["reasoningEffort"] = .string(level)
                merged.removeValue(forKey: "disabled")
                variants[level] = .object(merged)
            } else if let previous {
                var disabled = previous.objectValue
                disabled["disabled"] = true
                variants[level] = .object(disabled)
            }
        }
        if variants.isEmpty { entry.removeValue(forKey: "variants") } else { entry["variants"] = .object(variants) }
        return .object(entry)
    }

    // MARK: - Validation and summaries

    public static func validate(agent: String, form: Values, existing: JSONValue?) -> ValidationError? {
        let invalid = { (text: String) in
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsePositiveInt(text) == nil
        }
        switch agent {
        case "codex": return invalid(form.contextWindow) ? .invalidNumber : nil
        case "grok-build":
            return form.authMode == .api && form.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .modelRequired : nil
        case "pi", "opencode": break
        default: return nil
        }
        let settings = existing ?? .object([:])
        for model in form.models {
            if invalid(model.contextWindow) || invalid(model.maxTokens) { return .invalidNumber }
            guard agent == "opencode" else { continue }
            let hasContext = !model.contextWindow.trimmingCharacters(in: .whitespaces).isEmpty
            let hasOutput = !model.maxTokens.trimmingCharacters(in: .whitespaces).isEmpty
            if hasContext != hasOutput {
                let limit = settings["models"][model.id]["limit"]
                if positiveInt(hasContext ? limit["output"] : limit["context"]) == nil { return .outputRequired }
            }
        }
        return nil
    }

    /// Declared model ids of a stored provider or live node.
    public static func modelIDs(agent: String, settings: JSONValue) -> [String] {
        switch agent {
        case "opencode": return settings["models"].objectValue.keys.sorted()
        case "pi": return settings["models"].arrayValue.map { $0["id"].stringValue }.filter { !$0.isEmpty }
        case "claude-code": return [settings["env"]["ANTHROPIC_MODEL"].stringValue].filter { !$0.isEmpty }
        case "codex": return [tomlScalar(settings["config"].stringValue, "model")].filter { !$0.isEmpty }
        case "grok-build": return [grokModelFields(settings["config"].stringValue).model].filter { !$0.isEmpty }
        default: return []
        }
    }

    /// Human-readable endpoint for the provider row; Grok Build subscription
    /// profiles show the signed-in account instead.
    public static func baseURL(agent: String, settings: JSONValue) -> String {
        switch agent {
        case "claude-code":
            return settings["env"]["ANTHROPIC_BASE_URL"].stringValue
        case "codex":
            return tomlScalar(settings["config"].stringValue, "base_url", within: { $0.hasPrefix("model_providers.") })
        case "grok-build":
            let session = grokAuthScopes(settings).first { $0.entry["auth_mode"] != "api_key" }
            let email = session?.entry["email"].stringValue ?? ""
            return email.isEmpty ? grokModelFields(settings["config"].stringValue).baseURL : email
        case "opencode":
            let options = settings["options"].objectValue
            return (options["baseURL"] ?? options["baseUrl"])?.stringValue ?? ""
        case "pi":
            return settings["baseUrl"].stringValue
        default:
            return ""
        }
    }

    public static func modelIDs(fromText text: String) -> [String] {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            .filter { !$0.isEmpty }
    }

    public static func parsePositiveInt(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Int(trimmed), value > 0 else { return nil }
        return value
    }

    private static func positiveInt(_ value: JSONValue) -> Int? {
        guard let number = value.doubleValue, number.isFinite, number > 0, number.rounded() == number,
            number < Double(Int.max)
        else { return nil }
        return Int(number)
    }

    private static func numberField(_ value: JSONValue) -> String {
        guard let number = value.doubleValue, number.isFinite else { return "" }
        if number.rounded() == number, abs(number) < 1e15 { return String(Int(number)) }
        return String(number)
    }

    // MARK: - Grok Build

    private static func isModelsTable(_ name: String) -> Bool { name == "models" }

    /// `[model.<id>]` header for a Grok Build model entry (quoted unless bare).
    static func grokModelHeader(_ id: String) -> String {
        id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
            ? "model.\(id)" : "model.\"\(id.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func grokModelTable(_ id: String) -> (String) -> Bool {
        let accepted: Set<String> = ["model.\(id)", "model.\"\(id)\"", "model.'\(id)'", grokModelHeader(id)]
        return { accepted.contains($0) }
    }

    /// Scopes sorted by name: JSON object order is not preserved on decode.
    private static func grokAuthScopes(_ settings: JSONValue) -> [(scope: String, entry: JSONValue)] {
        settings["auth"].objectValue.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Key from a `grok login --api-key` scope, which lives in auth.json.
    private static func grokAuthAPIKey(_ settings: JSONValue) -> String {
        grokAuthScopes(settings).first { $0.entry["auth_mode"] == "api_key" }?.entry["key"].stringValue ?? ""
    }

    private static func grokHasSession(_ settings: JSONValue) -> Bool {
        grokAuthScopes(settings).contains { $0.entry["auth_mode"] != "api_key" }
    }

    private struct GrokFields {
        var key: String
        var hasTable: Bool
        var model: String
        var apiKey: String
        var baseURL: String
        var apiBackend: String
    }

    /// The `[models].default` entry: its catalog key, whether a `[model.<key>]`
    /// table exists, and the model id sent to the API (`model`, else the key).
    private static func grokModelFields(_ config: String) -> GrokFields {
        let key = tomlScalar(config, "default", within: isModelsTable)
        let table: (String) -> Bool = key.isEmpty ? { _ in false } : grokModelTable(key)
        let hasTable =
            !key.isEmpty && config.components(separatedBy: "\n").contains { tableHeader($0).map(table) ?? false }
        let model = tomlScalar(config, "model", within: table)
        return GrokFields(
            key: key, hasTable: hasTable, model: model.isEmpty ? key : model,
            apiKey: tomlScalar(config, "api_key", within: table),
            baseURL: tomlScalar(config, "base_url", within: table),
            apiBackend: tomlScalar(config, "api_backend", within: table))
    }

    // MARK: - Line-level TOML helpers (same subset as desktop)

    static func tableHeader(_ line: String) -> String? {
        guard let match = line.firstMatch(of: /^\s*\[([^\]]+)\]/) else { return nil }
        return String(match.1).trimmingCharacters(in: .whitespaces)
    }

    private static func keyPattern(_ key: String, value: String = "") -> NSRegularExpression? {
        try? NSRegularExpression(pattern: "^\\s*\(NSRegularExpression.escapedPattern(for: key))\\s*=\(value)")
    }

    private static func capture(_ regex: NSRegularExpression?, in line: String) -> String? {
        guard let regex,
            let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
            match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: line)
        else { return nil }
        return String(line[range])
    }

    private static func matches(_ regex: NSRegularExpression?, _ line: String) -> Bool {
        regex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Pull the string scalar `key` out of the TOML top level (`within == nil`)
    /// or the first matching table. Basic strings are unescaped (so a patch
    /// round trip does not double backslashes); literal '…' strings are raw.
    static func tomlScalar(_ text: String, _ key: String, within: ((String) -> Bool)? = nil) -> String {
        let regex = keyPattern(key, value: #"\s*(?:"((?:[^"\\]|\\.)*)"|'([^']*)')"#)
        var inTarget = within == nil
        for line in text.components(separatedBy: "\n") {
            if let header = tableHeader(line) {
                inTarget = within?(header) ?? false
                continue
            }
            guard inTarget, let regex,
                let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
            else { continue }
            if let range = Range(match.range(at: 1), in: line) { return unescapeBasic(String(line[range])) }
            if let range = Range(match.range(at: 2), in: line) { return String(line[range]) }
        }
        return ""
    }

    private static func unescapeBasic(_ value: String) -> String {
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                result.append(character)
                continue
            }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            default: result.append(next)
            }
        }
        return result
    }

    /// Reads a bare integer `key = <n>` from the TOML top level.
    static func tomlNumber(_ text: String, _ key: String) -> String {
        let regex = keyPattern(key, value: #"\s*(\d+)"#)
        for line in text.components(separatedBy: "\n") {
            if tableHeader(line) != nil { return "" }
            if let value = capture(regex, in: line) { return value }
        }
        return ""
    }

    /// Replaces `key = "…"` in the top level or a matching table. When absent
    /// the key is inserted instead of dropping user config: into the first
    /// matching table, else a new `[newTable]`.
    static func patchTomlScalar(
        _ text: String, _ key: String, _ value: String, within: ((String) -> Bool)? = nil, newTable: String? = nil
    ) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let assignment = "\(key) = \"\(escaped)\""
        let regex = keyPattern(key)
        var lines = text.components(separatedBy: "\n")
        var inTarget = within == nil
        var firstTableLine: Int?
        for index in lines.indices {
            if let header = tableHeader(lines[index]) {
                inTarget = within?(header) ?? false
                if inTarget, firstTableLine == nil { firstTableLine = index }
                continue
            }
            if inTarget, matches(regex, lines[index]) {
                lines[index] = assignment
                return lines.joined(separator: "\n")
            }
        }
        guard within != nil else {
            return "\(assignment)\n\(text.hasPrefix("\n") ? "" : "\n")\(text)"
        }
        if let firstTableLine {
            // The table exists without the key: a second header would be invalid TOML.
            lines.insert(assignment, at: firstTableLine + 1)
            return lines.joined(separator: "\n")
        }
        guard let newTable else { return text }
        var head = text
        while let last = head.last, last.isWhitespace { head.removeLast() }
        return "\(head)\(head.isEmpty ? "" : "\n\n")[\(newTable)]\n\(assignment)\n"
    }

    /// Drops `key = …` lines inside the matching tables.
    static func removeTomlKey(_ text: String, _ key: String, within: (String) -> Bool) -> String {
        let regex = keyPattern(key)
        var inTarget = false
        return text.components(separatedBy: "\n").filter { line in
            if let header = tableHeader(line) {
                inTarget = within(header)
                return true
            }
            return !(inTarget && matches(regex, line))
        }.joined(separator: "\n")
    }

    /// Like patchTomlScalar but writes a bare integer on the TOML top level.
    static func patchTomlNumber(_ text: String, _ key: String, _ value: Int) -> String {
        let regex = keyPattern(key)
        var lines = text.components(separatedBy: "\n")
        for index in lines.indices {
            if tableHeader(lines[index]) != nil { break }
            if matches(regex, lines[index]) {
                lines[index] = "\(key) = \(value)"
                return lines.joined(separator: "\n")
            }
        }
        return "\(key) = \(value)\n\(text.hasPrefix("\n") ? "" : "\n")\(text)"
    }
}
