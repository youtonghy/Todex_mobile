import Foundation
import Testing

@testable import TodexCore

@Suite
struct AgentProviderFormTests {
    @Test func claudeRoundTripKeepsUnknownKeysAndMaskedSecret() {
        let stored: JSONValue = [
            "env": [
                "ANTHROPIC_BASE_URL": "https://old.test", "ANTHROPIC_AUTH_TOKEN": "__TODEX_MASKED__",
                "ANTHROPIC_MODEL": "claude-x", "EXTRA_ENV": "keep",
            ],
            "permissions": ["allow": ["Bash"]],
        ]
        var form = AgentProviderForm.extract(agent: "claude-code", name: "A", settings: stored)
        #expect(form.baseURL == "https://old.test")
        #expect(form.apiKey == AgentProviderForm.maskedSecret)
        #expect(form.model == "claude-x")
        form.baseURL = " https://new.test "
        let built = AgentProviderForm.build(agent: "claude-code", form: form, existing: stored)
        #expect(built["env"]["ANTHROPIC_BASE_URL"] == "https://new.test")
        #expect(built["env"]["ANTHROPIC_AUTH_TOKEN"] == "__TODEX_MASKED__")
        #expect(built["env"]["EXTRA_ENV"] == "keep")
        #expect(built["permissions"] == ["allow": ["Bash"]])
    }

    @Test func codexPatchesTomlInPlace() {
        let config = """
            model_provider = "corp"
            model = "gpt-5"
            approval_policy = "never"

            [model_providers.corp]
            name = "Corp"
            base_url = "https://old.test/v1"
            wire_api = "responses"
            """
        let stored: JSONValue = ["auth": ["OPENAI_API_KEY": "__TODEX_MASKED__"], "config": .string(config)]
        var form = AgentProviderForm.extract(agent: "codex", name: "Corp", settings: stored)
        #expect(form.baseURL == "https://old.test/v1")
        #expect(form.model == "gpt-5")
        #expect(form.contextWindow == "")
        form.model = "gpt-6"
        form.reasoningEffort = "high"
        form.contextWindow = "272000"
        form.baseURL = "https://new.test/v1"
        let built = AgentProviderForm.build(agent: "codex", form: form, existing: stored)
        let text = built["config"].stringValue
        #expect(text.contains("model = \"gpt-6\""))
        #expect(text.contains("model_reasoning_effort = \"high\""))
        #expect(text.hasPrefix("model_context_window = 272000\n"))
        #expect(text.contains("approval_policy = \"never\""))
        #expect(text.contains("base_url = \"https://new.test/v1\""))
        #expect(!text.contains("old.test"))
        #expect(built["auth"] == ["OPENAI_API_KEY": "__TODEX_MASKED__"])
        let again = AgentProviderForm.extract(agent: "codex", name: "Corp", settings: built)
        #expect(again.contextWindow == "272000")
        #expect(again.reasoningEffort == "high")
        form.contextWindow = "1.5"
        #expect(AgentProviderForm.validate(agent: "codex", form: form, existing: stored) == .invalidNumber)
    }

    @Test func piModelsRoundTripThinkingLevelsAndUnknownFields() {
        let stored: JSONValue = [
            "baseUrl": "https://pi.test", "api": "openai-completions", "apiKey": "__TODEX_MASKED__",
            "headers": ["x-custom": "1"],
            "models": [
                [
                    "id": "m1", "contextWindow": 128000, "reasoning": true, "cost": ["input": 1],
                    "thinkingLevelMap": ["off": nil, "high": "max-thinking", "xhigh": "xhigh"],
                ],
                ["id": "m2"],
            ],
        ]
        var form = AgentProviderForm.extract(agent: "pi", settings: stored)
        #expect(form.models.map(\.id) == ["m1", "m2"])
        #expect(form.models[0].contextWindow == "128000")
        #expect(form.models[0].efforts == ["minimal", "low", "medium", "high", "xhigh"])
        form.models[0].efforts.removeAll { $0 == "minimal" }
        form.models[1].reasoning = true
        form.models[1].efforts = AgentProviderForm.defaultEfforts(for: "pi")
        form.models.append(.init(id: "m3"))
        let built = AgentProviderForm.build(agent: "pi", form: form, existing: stored)
        #expect(built["headers"] == ["x-custom": "1"])
        let models = built["models"].arrayValue
        #expect(models.count == 3)
        #expect(models[0]["cost"] == ["input": 1])
        #expect(models[0]["thinkingLevelMap"]["high"] == "max-thinking")
        #expect(models[0]["thinkingLevelMap"]["minimal"] == .null)
        #expect(models[0]["thinkingLevelMap"]["low"] == "low")
        #expect(models[1]["thinkingLevelMap"]["off"] == "off")
        #expect(models[1]["thinkingLevelMap"]["max"] == .null)
        #expect(models[2] == ["id": "m3"])
    }

    @Test func opencodeLimitsAndVariants() {
        let stored: JSONValue = [
            "npm": "@ai-sdk/openai-compatible",
            "options": ["baseURL": "https://oc.test", "apiKey": "__TODEX_MASKED__", "timeout": 5],
            "models": [
                "m1": [
                    "limit": ["context": 200000, "output": 8000], "reasoning": true,
                    "variants": ["high": ["reasoningEffort": "high"], "custom": ["x": 1]],
                ]
            ],
        ]
        var form = AgentProviderForm.extract(agent: "opencode", settings: stored)
        #expect(form.models.first?.efforts == ["high"])
        #expect(form.models.first?.maxTokens == "8000")
        form.models[0].efforts = ["low"]
        form.models[0].contextWindow = "1000000"
        let built = AgentProviderForm.build(agent: "opencode", form: form, existing: stored)
        #expect(built["npm"] == "@ai-sdk/openai-compatible")
        #expect(built["options"]["timeout"] == 5)
        let entry = built["models"]["m1"]
        #expect(entry["limit"] == ["context": 1000000, "output": 8000])
        #expect(entry["variants"]["high"] == ["reasoningEffort": "high", "disabled": true])
        #expect(entry["variants"]["low"] == ["reasoningEffort": "low"])
        #expect(entry["variants"]["custom"] == ["x": 1])

        var partial = AgentProviderForm.Values()
        var model = AgentProviderForm.Model(id: "new")
        model.contextWindow = "128000"
        partial.models = [model]
        #expect(AgentProviderForm.validate(agent: "opencode", form: partial, existing: nil) == .outputRequired)
    }

    @Test func grokApiAndSubscriptionModes() {
        let fresh = AgentProviderForm.extract(agent: "grok-build", settings: nil)
        #expect(fresh.authMode == .api)
        var form = fresh
        #expect(AgentProviderForm.validate(agent: "grok-build", form: form, existing: nil) == .modelRequired)
        form.model = "grok 4"
        form.apiKey = "xai-secret"
        form.apiKind = "responses"
        let built = AgentProviderForm.build(agent: "grok-build", form: form, existing: nil)
        let config = built["config"].stringValue
        #expect(config.contains("[models]\ndefault = \"grok 4\""))
        #expect(config.contains("[model.\"grok 4\"]"))
        #expect(config.contains("base_url = \"\(AgentProviderForm.grokXAIBaseURL)\""))
        #expect(config.contains("api_key = \"xai-secret\""))
        #expect(built["auth"] == .null)
        let reread = AgentProviderForm.extract(agent: "grok-build", settings: built)
        #expect(reread.model == "grok 4")
        #expect(reread.apiKind == "responses")
        #expect(reread.authMode == .api)

        let subscription: JSONValue = [
            "auth": ["default": ["auth_mode": "oauth", "email": "me@example.test"]],
            "config": .string(config),
        ]
        var sub = AgentProviderForm.extract(agent: "grok-build", settings: subscription)
        #expect(sub.authMode == .subscription)
        #expect(AgentProviderForm.baseURL(agent: "grok-build", settings: subscription) == "me@example.test")
        sub.model = "grok 4"
        let saved = AgentProviderForm.build(agent: "grok-build", form: sub, existing: subscription)
        #expect(!saved["config"].stringValue.contains("api_key"))
        #expect(saved["auth"] == subscription["auth"])
    }

    @Test func codexBaseURLFollowsTheActiveProviderTable() {
        let config = """
            model_provider = 'openrouter'
            [model_providers.azure]
            base_url = "https://azure.example"
            [model_providers.openrouter2]
            base_url = "https://wrong.example"
            [model_providers.openrouter]
            base_url = "https://openrouter.example"
            """
        let values = AgentProviderForm.extract(agent: "codex", settings: ["config": .string(config)])
        #expect(values.baseURL == "https://openrouter.example")
        #expect(AgentProviderForm.tomlScalar(config, "model_provider") == "openrouter")
    }

    @Test func tomlScalarUnescapesSoPatchRoundTripsAreStable() {
        let original = #"path = "C:\\dir\\\"q\"""#
        let value = AgentProviderForm.tomlScalar(original, "path")
        #expect(value == #"C:\dir\"q""#)
        #expect(AgentProviderForm.patchTomlScalar(original, "path", value) == original)
    }

    @Test func tomlHelpersInsertInsteadOfDropping() {
        #expect(
            AgentProviderForm.patchTomlScalar("", "k", "v", within: { $0 == "t" }, newTable: "t") == "[t]\nk = \"v\"\n")
        #expect(AgentProviderForm.patchTomlScalar("[t]\na = 1", "k", "q\"", within: { $0 == "t" }) == "[t]\nk = \"q\\\"\"\na = 1")
        #expect(AgentProviderForm.tomlScalar("x = \"top\"\n[t]\nx = \"in\"", "x", within: { $0 == "t" }) == "in")
        #expect(AgentProviderForm.tomlNumber("[t]\nn = 5", "n") == "")
        #expect(AgentProviderForm.modelIDs(fromText: " a, b\nc ,,") == ["a", "b", "c"])
    }
}

@Suite
struct ConnectionDiagnosticTests {
    @Test(arguments: [
        (URLError(.cannotConnectToHost) as any Error, ConnectionDiagnostic.Category.backendUnreachable, true),
        (URLError(.timedOut), .timeout, true),
        (URLError(.notConnectedToInternet), .networkOffline, true),
        (URLError(.serverCertificateUntrusted), .tls, true),
        (TodexError.configuration("后端要求 x25519 加密，请导入对应公钥"), .encryptionPolicy, false),
        (TodexError.server(code: "401", message: "后端拒绝认证"), .authenticationFailed, false),
        (TodexError.server(code: "UNAUTHORIZED", message: "x"), .authenticationFailed, false),
        (TodexError.server(code: "502", message: "WebSocket 握手失败（HTTP 502）"), .serverError, true),
        (TodexError.server(code: "426", message: "WebSocket 握手失败（HTTP 426）"), .handshakeFailed, true),
        (TodexError.invalid(CoreMessage.v1Removed), .protocolMismatch, false),
        (TodexError.invalid(CoreMessage.enterValidAddress), .invalidServerURL, false),
        (TodexError.invalid(CoreMessage.handshakeFailed), .handshakeFailed, true),
        (NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost), .backendUnreachable, true),
    ])
    func classifiesTransportFailures(_ error: any Error, _ category: ConnectionDiagnostic.Category, _ retryable: Bool) {
        let diagnostic = ConnectionDiagnostic.classify(error)
        #expect(diagnostic.category == category)
        #expect(diagnostic.retryable == retryable)
        #expect(!diagnostic.title.isEmpty && !diagnostic.suggestion.isEmpty)
    }
}

@Suite(.serialized)
struct DebugLogTests {
    @Test func redactsSecretsBeforeStoring() {
        #expect(DebugLog.redact("api_key=sk-123 other") == "api_key=[REDACTED] other")
        #expect(DebugLog.redact(#"{"apiKey": "sk-123"}"#).contains("[REDACTED]"))
        #expect(!DebugLog.redact(#"{"apiKey": "sk-123"}"#).contains("sk-123"))
        #expect(DebugLog.redact("Authorization: Bearer abc.def") == "Authorization: [REDACTED] [REDACTED]")
        #expect(DebugLog.redact("wss://h:7345/v2/ws?sig=abc&device=1") == "wss://h:7345/v2/ws?[REDACTED]")
        #expect(DebugLog.redact("http://user:pw@h/x") == "http://[REDACTED]@h/x")
        #expect(DebugLog.redact("data:image/png;base64,AAAA").hasPrefix("[data-url"))
        #expect(DebugLog.sensitiveKey("deviceSecret"))
    }

    @Test func ringBufferIsBoundedAndMasksSensitiveKeys() {
        DebugLog.clear()
        defer { DebugLog.clear() }
        for index in 0..<(DebugLog.capacity + 5) { DebugLog.record("tick", ["n": String(index)]) }
        DebugLog.record("connect", ["token": "plain-secret", "url": "http://h/?proof=x"])
        let lines = DebugLog.export().split(separator: "\n")
        guard DebugLog.isEnabled else {
            #expect(lines.isEmpty)
            return
        }
        #expect(lines.count == DebugLog.capacity)
        let last = String(lines.last ?? "")
        #expect(last.contains("token=[REDACTED]"))
        #expect(!last.contains("plain-secret"))
        #expect(!last.contains("proof=x"))
    }
}
