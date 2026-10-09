import Foundation
import Synchronization
import Testing

@testable import TodexCore

@Suite
struct APIClientTests {
    @Test(arguments: EndpointCase.all)
    private func endpointWire(_ endpoint: EndpointCase) async throws {
        let calls = Mutex(0)
        let fixture = APIFixture { request in
            calls.withLock { $0 += 1 }
            #expect(request.httpMethod == endpoint.method)
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.percentEncodedPath == endpoint.path)
            let query = try backendQuery(components.percentEncodedQuery)
            #expect(query == endpoint.query)
            #expect(components.fragment == nil)
            #expect(
                request.value(forHTTPHeaderField: "x-todex-device-id")
                    == (endpoint.authenticated ? "dev_1-HghL4hOwHlBoUq" : nil))
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(
                request.value(forHTTPHeaderField: "Accept")
                    == (endpoint.name == "health" ? "text/plain" : "application/json"))
            #expect(
                request.value(forHTTPHeaderField: "Content-Type") == (endpoint.body == nil ? nil : "application/json"))
            #expect(try requestJSON(request) == endpoint.body)
            if endpoint.name == "health" { return .text("ok") }
            return try .json(endpoint.response)
        }
        defer { fixture.close() }
        let value = try await endpoint.invoke(fixture.api)
        #expect(value == (endpoint.expectedResult ?? endpoint.response))
        #expect(calls.withLock { $0 } == 1)
    }

    /// The backend only reveals `data_dir`/workspace roots to signed callers;
    /// an unpaired device must still reach /v2/version, just unsigned.
    @Test
    func versionIsSignedWhenEnrolledAndFallsBackToUnsignedWhenNot() async throws {
        let signed = Mutex<[String?]>([])
        for secret in ["FRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRU", "", "bad-seed"] {
            let fixture = APIFixture(deviceSecret: secret) { request in
                signed.withLock { $0.append(request.value(forHTTPHeaderField: "x-todex-device-id")) }
                return try .json(["version": "1.0.0"])
            }
            defer { fixture.close() }
            #expect(try await fixture.api.version()["version"] == "1.0.0")
        }
        #expect(signed.withLock { $0 } == ["dev_1-HghL4hOwHlBoUq", nil, nil])
    }

    @Test
    func agentDesktopModelsAcceptLegacyDaemonsAndDecodeDataURLs() throws {
        // Daemons where the browser and Computer Use still ran on desktops omit both statuses.
        let legacy: JSONValue = ["enabled": true, "computerEnabled": false, "executors": []]
        let settings = try legacy.decoded(AgentDesktopSettings.self)
        #expect(settings.enabled && settings.computer == nil && settings.browser == nil)
        let image = AgentDesktopImage(shotId: nil, mimeType: "image/jpeg", dataUrl: "data:image/jpeg;base64,AQID")
        #expect(image.data == Data([1, 2, 3]))
        #expect(AgentDesktopImage(shotId: nil, mimeType: "image/jpeg", dataUrl: "https://x.test/a.jpg").data == nil)
    }

    @Test
    func workspaceCatalogKeepsRejectedRecordsApart() throws {
        let workspace = try JSONValue(encoding: WorkspaceRecord(id: "w", name: "项目", path: "/work/project"))
        let plain = try WorkspaceCatalog(response: ["workspaces": [workspace], "updatedAt": 1])
        #expect(plain.workspaces.map(\.id) == ["w"] && plain.rejected.isEmpty)
        let catalog = try WorkspaceCatalog(
            response: [
                "workspaces": [workspace], "updatedAt": 1,
                "rejected": [
                    [
                        "id": "gone", "name": "旧目录", "path": "/work/gone", "code": "WORKSPACE_PATH_NOT_FOUND",
                        "message": "missing",
                    ]
                ],
            ])
        #expect(catalog.rejected == [RejectedWorkspace(
            id: "gone", name: "旧目录", path: "/work/gone", code: "WORKSPACE_PATH_NOT_FOUND", message: "missing")])
    }

    @Test
    func backendLabelColorMatchesDesktopDerivation() throws {
        // Values computed with desktop `backendLabelColor` for the same ids.
        #expect(BackendConnection.defaultLabelColor(for: "stable") == "#ef4444")
        #expect(BackendConnection.defaultLabelColor(for: "simulator-fixture") == "#3b82f6")
        #expect(BackendConnection.defaultLabelColor(for: "后端-一") == "#f97316")
        #expect(BackendConnection(id: "stable", color: "#8B5CF6").color == "#8b5cf6")
        #expect(BackendConnection(id: "stable").color == "#ef4444")
        // "teal" from older builds is not a hex color and resolves to the default.
        let legacy = try JSONValue(encoding: ["id": "stable", "name": "n", "serverURL": "http://h", "color": "teal"])
        #expect(try legacy.decoded(BackendConnection.self).color == "#ef4444")
        var edited = BackendConnection(id: "stable")
        edited.color = "purple"
        #expect(edited.labelColor == "#ef4444")
    }

    @Test
    func workspaceDefaultsEncodeAllRequiredWireFields() throws {
        let workspace = WorkspaceRecord(name: "项目", path: "/work/project")
        let wire = try JSONValue(encoding: workspace)
        for key in [
            "id", "name", "path", "sessionId", "tenantId", "threadId", "model", "approvalPolicy", "sandboxMode",
        ] {
            #expect(wire[key].optionalString != nil)
        }
        #expect(!workspace.id.isEmpty)
        #expect(workspace.sessionId == "cdxs_\(workspace.id)")
        #expect(workspace.approvalPolicy == "on-request")
        #expect(workspace.sandboxMode == "workspace-write")
        #expect(workspace.createdAt > 0)
        #expect(workspace.updatedAt == workspace.createdAt)
        #expect(wire["createdAt"].intValue == workspace.createdAt)
        #expect(try wire.decoded(WorkspaceRecord.self) == workspace)

        var oldWire = TestWire.workspace.objectValue
        oldWire.removeValue(forKey: "threadId")
        oldWire.removeValue(forKey: "reasoningEffort")
        oldWire.removeValue(forKey: "permissionProfile")
        oldWire.removeValue(forKey: "approvalsReviewer")
        oldWire.removeValue(forKey: "serviceTier")
        let old = try JSONValue.object(oldWire).decoded(WorkspaceRecord.self)
        #expect(old.threadId.isEmpty)
        #expect(old.reasoningEffort == nil)
        #expect(old.permissionProfile == nil)
    }

    @Test
    func preservesManifestProviderAndEventWire() throws {
        var manifest = TestWire.manifest
        manifest["provider"] = "future-provider"
        manifest["status"] = "future-status"
        manifest["archivedAt"] = "2026-09-10T12:00:00.123456Z"
        manifest["schemaVersion"] = 2
        manifest["ownerId"] = "tenant-1"
        let decoded = try manifest.decoded(ConversationManifest.self)
        #expect(decoded.provider == "future-provider")
        #expect(decoded.status == "future-status")
        #expect(decoded.archivedAt == "2026-09-10T12:00:00.123456Z")
        #expect(decoded.createdAt == "2026-09-10T11:00:00.123456Z")
        #expect(decoded.lastSequence == 7)
        #expect(!decoded.isLegacyPlaintext && decoded.legacyPlaintext == nil)
        // History v3: the backend omits `legacyPlaintext` when false; when set
        // it survives a local round trip (the cached conversation list).
        manifest["legacyPlaintext"] = true
        let legacy = try manifest.decoded(ConversationManifest.self)
        #expect(legacy.isLegacyPlaintext)
        #expect(try JSONValue(encoding: legacy).decoded(ConversationManifest.self).isLegacyPlaintext)
        #expect(try JSONValue(encoding: decoded)["legacyPlaintext"] == .null)

        let provider = try TestWire.provider.decoded(ProviderDescriptor.self)
        #expect(provider.profiles == ["local", "custom"])
        #expect(provider.capabilities["futureCapability"]["enabled"] == true)
        #expect(provider.models.first?["futureModelField"] == [1, "x", nil])
        #expect(try JSONValue(encoding: provider) == TestWire.provider)
        // Queue capabilities default to false; control is a separate bit.
        #expect(!provider.supportsBackendQueue && !provider.supportsBackendQueueControl)
        var queued = provider
        queued.capabilities = ["backendQueue": true]
        #expect(queued.supportsBackendQueue && !queued.supportsBackendQueueControl)
        queued.capabilities = ["backendQueue": true, "backendQueueControl": true]
        #expect(queued.supportsBackendQueue && queued.supportsBackendQueueControl)

        let event = try TestWire.event.decoded(ConversationEvent.self)
        #expect(event.sequence == 7)
        #expect(event.time == "2026-09-10T12:00:00.123456Z")
        #expect(event.type == "provider.event")
        #expect(event.rawType == "item/started")
        #expect(try JSONValue(encoding: event) == TestWire.event)
        var oldEvent = TestWire.event.objectValue
        oldEvent.removeValue(forKey: "normalizedType")
        oldEvent.removeValue(forKey: "rawType")
        oldEvent.removeValue(forKey: "provider")
        let old = try JSONValue.object(oldEvent).decoded(ConversationEvent.self)
        #expect(old.provider == nil)
        #expect(old.rawType == nil)
        #expect(old.normalizedType == nil)
        #expect(try JSONValue(encoding: old) == .object(oldEvent))
        let simple = ConversationEvent(
            sequence: 1, conversationId: "c", type: "message.delta", payload: ["text": "hello"])
        #expect(simple.schemaVersion == 2)
        #expect(try JSONValue(encoding: simple).decoded(ConversationEvent.self) == simple)
    }

    @Test
    func optionalQueriesAndCreateFieldsAreOmitted() async throws {
        let fixture = APIFixture { request in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            switch url.path {
            case "/v2/conversations":
                #expect(try requestJSON(request) == ["workspace": "/work/project", "provider": "codex"])
                return try .json(TestWire.manifest)
            case "/v2/workspace/directories":
                #expect(components.queryItems == nil)
            case "/v2/providers/image-input":
                #expect(Set((components.queryItems ?? []).map(\.name)) == ["provider", "workspace"])
            case "/v2/workspace/entries":
                let query = Dictionary(
                    uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                #expect(query == ["cwd": "/work/project", "query": "", "limit": "40"])
            default:
                Issue.record("Unexpected path: \(url.path)")
            }
            return try .json([:])
        }
        defer { fixture.close() }
        _ = try await fixture.api.createConversation(
            workspace: WorkspaceRecord(name: "Project", path: "/work/project"), provider: "codex", profile: nil,
            title: nil)
        _ = try await fixture.api.workspaceDirectories()
        _ = try await fixture.api.providerImageInput(provider: "codex", workspace: "/work/project")
        _ = try await fixture.api.workspaceEntries(cwd: "/work/project")
    }

    @Test
    func paginationUsesAfterSequenceAndExplicitLimit() async throws {
        let fixture = APIFixture { request in
            let url = try #require(request.url)
            #expect(url.query == "afterSequence=0&historyEncryption=1&limit=17")
            return try .json(TestWire.replay)
        }
        defer { fixture.close() }
        let replay = try await fixture.api.events(conversationId: "c", after: 0, limit: 17)
        #expect(replay["hasMore"] == true)
        #expect(replay["nextSequence"] == 7)
        #expect(try replay["events"].decoded([ConversationEvent].self).first?.sequence == 7)
    }

    @Test
    func paginationUsesBeforeSequenceForTailWindows() async throws {
        let fixture = APIFixture { request in
            let url = try #require(request.url)
            #expect(url.query == "beforeSequence=40&detail=summary&historyEncryption=1&limit=17")
            return try .json(TestWire.replay)
        }
        defer { fixture.close() }
        let replay = try await fixture.api.events(conversationId: "c", before: 40, limit: 17, detail: "summary")
        #expect(replay["hasMore"] == true)
        #expect(try replay["events"].decoded([ConversationEvent].self).first?.sequence == 7)
    }

    @Test(arguments: [
        ErrorCase(
            status: 401, body: ["code": "UNAUTHORIZED", "message": "signature rejected"], code: "UNAUTHORIZED",
            message: "signature rejected"),
        ErrorCase(status: 409, body: ["error": ["message": "file changed"]], code: "409", message: "file changed"),
        ErrorCase(
            status: 501, body: ["code": "UNSUPPORTED", "error": "native operation unavailable"], code: "UNSUPPORTED",
            message: "native operation unavailable"),
        ErrorCase(status: 302, body: [:], code: "302", message: "HTTP 302"),
    ])
    private func httpErrors(_ error: ErrorCase) async throws {
        let fixture = APIFixture { _ in try .json(error.body, status: error.status) }
        defer { fixture.close() }
        do {
            _ = try await fixture.api.cancelConversation(id: "c")
            Issue.record("Expected an HTTP error")
        } catch TodexError.server(let code, let message) {
            #expect(code == error.code)
            #expect(message == error.message)
        }
    }

    @Test
    func malformedJSONAndMissingRequiredFieldsFail() async throws {
        let invalidJSON = APIFixture { _ in .text("<html>gateway error</html>") }
        defer { invalidJSON.close() }
        do {
            _ = try await invalidJSON.api.providers()
            Issue.record("Expected invalid JSON to fail")
        } catch TodexError.invalid {}

        let malformedList = APIFixture { _ in try .json(["workspaces": [["id": "only-id"]]]) }
        defer { malformedList.close() }
        await #expect(throws: DecodingError.self) { _ = try await malformedList.api.workspaces() }

        let missingList = APIFixture { _ in try .json([:]) }
        defer { missingList.close() }
        await #expect(throws: DecodingError.self) { _ = try await missingList.api.conversations() }
    }

    @Test
    func emptyResponseAndHealthErrors() async throws {
        let fixture = APIFixture { request in
            if request.url?.path == "/health" { return .text("unavailable", status: 503) }
            return .text("", status: 204)
        }
        defer { fixture.close() }
        #expect(try await fixture.api.deleteConversation(id: "c") == .null)
        do {
            _ = try await fixture.api.health()
            Issue.record("Expected health failure")
        } catch TodexError.server(let code, let message) {
            #expect(code == "503")
            #expect(message == "HTTP 503")
        }
    }

    @Test
    func transportFailureDoesNotRetryMutation() async throws {
        let calls = Mutex(0)
        let fixture = APIFixture { _ in
            calls.withLock { $0 += 1 }
            throw URLError(.timedOut)
        }
        defer { fixture.close() }
        do {
            _ = try await fixture.api.conversations()
            Issue.record("Expected timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
        #expect(calls.withLock { $0 } == 1)
        do {
            _ = try await fixture.api.promptConversation(id: "c", prompt: ["text": "hello"])
            Issue.record("Expected unknown mutation outcome")
        } catch TodexError.unknownOutcome {}
        #expect(calls.withLock { $0 } == 2)
    }

    @Test
    func commandAndEventEnvelopesMatchBothProtocols() throws {
        let command = WebSocketCommandEnvelope(
            id: "r1", command: .conversationSubscribe, payload: ["conversationId": "c", "afterSequence": 7])
        #expect(
            try JSONValue(encoding: command) == [
                "id": "r1", "type": "conversation.subscribe", "payload": ["conversationId": "c", "afterSequence": 7],
            ])
        let payload: JSONValue = ["codex_session_id": "s", "tenant_id": "t", "action": "control"]
        let legacyCommand = WebSocketCommandEnvelope(id: "r2", command: .codexGatewayControl, payload: payload)
        #expect(try JSONValue(encoding: legacyCommand)["payload"] == payload)
        let omitted: JSONValue = ["id": "ping", "type": "server.ping"]
        #expect(try omitted.decoded(WebSocketCommandEnvelope.self).payload == .null)

        let result: JSONValue = ["id": "r1", "type": "server.result", "payload": ["subscribed": true]]
        let response = try result.decoded(WebSocketEventEnvelope.self)
        #expect(response.id == "r1")
        #expect(try JSONValue(encoding: response) == result)
        let unsolicited: JSONValue = ["type": "conversation.event", "payload": TestWire.event]
        let event = try unsolicited.decoded(WebSocketEventEnvelope.self)
        #expect(event.id == nil)
        #expect(try event.payload.decoded(ConversationEvent.self).sequence == 7)

        let legacy: JSONValue = [
            "event_id": "evt_legacy", "type": "codex.local.event", "cursor": 12,
            "codex_session_id": "s", "codex_thread_id": "t", "codex_turn_id": "turn",
            "workspace_id": "w", "window_id": "win", "pane_id": "pane", "payload": ["unknown": [true, nil]],
        ]
        let old = try legacy.decoded(WebSocketEventEnvelope.self)
        #expect(old.id == nil)
        #expect(old.eventId == "evt_legacy")
        #expect(old.cursor == 12)
        #expect(try JSONValue(encoding: old) == legacy)
        let unknown: JSONValue = ["id": nil, "type": "future.event", "payload": ["key": [1, false, nil]]]
        #expect(try unknown.decoded(WebSocketEventEnvelope.self).type == "future.event")
    }

    @Test
    func catalogMatchesRecognizedTypesAndHonestSupport() {
        let expected = Set(
            """
            conversation.subscribe conversation.unsubscribe conversation.create conversation.prompt conversation.followUp conversation.retry
            conversation.queue.add conversation.queue.remove conversation.queue.clear conversation.queue.resume conversation.queue.list
            conversation.queue.pause conversation.queue.take
            conversation.resume conversation.fork conversation.compact conversation.control conversation.cancel
            conversation.interrupt conversation.stop conversation.permission.respond mcp.list mcp.refresh mcp.call server.ping session.resume
            codex.gateway.control codex.local.start codex.local.status codex.local.stop codex.local.turn codex.local.input
            codex.local.steer codex.local.interrupt codex.local.approval.respond codex.local.request codex.local.replay
            codex.local.attach codex.local.snapshot codex.local.unsupported terminal.start terminal.input terminal.stop terminal.resize terminal.status
            codex.thread.start codex.turn.start codex.turn.steer codex.turn.interrupt codex.mcp.server.listStatus
            codex.mcp.resource.read codex.mcp.tool.call codex.mcp.server.refresh codex.mcp.oauth.login codex.mcp.elicitation.respond
            codex.cloudTask.create codex.cloudTask.list codex.cloudTask.getSummary codex.cloudTask.getDiff codex.cloudTask.getMessages
            codex.cloudTask.getText codex.cloudTask.listSiblingAttempts codex.cloudTask.applyPreflight codex.cloudTask.apply
            agentBrowser.watch agentBrowser.unwatch
            history.encryption.get history.recipient.register
            history.recipient.revoke history.recovery.set history.grant.request history.grant.list history.grant.dismiss
            history.keys.list history.keys.wraps history.grant.fulfill history.device.restore
            """.split(whereSeparator: \.isWhitespace).map(String.init))
        #expect(Set(ProtocolCatalog.commands.map(\.type)) == expected)
        #expect(ProtocolCatalog.commands.count == expected.count)
        for entry in ProtocolCatalog.commands {
            #expect(!entry.detail.isEmpty)
            if entry.type.hasPrefix("codex.cloudTask.") || entry.type.hasPrefix("codex.mcp.")
                || entry.type.hasPrefix("codex.turn.") || entry.type == "codex.thread.start"
            {
                #expect(entry.support == .unsupported)
            }
        }
        #expect(ProtocolCatalog.descriptor(.conversationResume).support == .unsupported)
        #expect(ProtocolCatalog.descriptor(.codexLocalUnsupported).support == .unsupported)
        #expect(ProtocolCatalog.descriptor(.codexLocalSnapshot).support == .limited)
        #expect(ProtocolCatalog.descriptor(.codexGatewayControl).support == .limited)
        #expect(ProtocolCatalog.descriptor(.conversationFork).support == .conditional)
        #expect(ProtocolCatalog.descriptor(.sessionResume).support == .supported)
        #expect(ProtocolCatalog.descriptor(.mcpCall).support == .conditional)
        #expect(ProtocolCatalog.descriptor(type: "future.command") == nil)
    }

    @Test
    func cliInstallFieldsDefaultForOlderBackends() async throws {
        let fixture = APIFixture { request in
            switch request.url?.path {
            case "/v2/providers/versions":
                return try .json([
                    "clis": [
                        [
                            "id": "pi", "name": "Pi", "kind": "managed", "installed": false, "status": "notInstalled",
                            "latestVersion": "1.2.3", "upgradeSupported": true, "installSupported": true,
                        ],
                        [
                            "id": "codex", "name": "Codex", "kind": "managed", "installed": true,
                            "currentVersion": "0.9.0", "status": "upToDate", "upgradeSupported": true,
                        ],
                    ],
                    "checkedAt": "2026-09-28T00:00:00Z",
                ])
            case "/v2/providers/pi/install":
                return try .json([
                    "id": "op-1", "provider": "pi", "action": "install", "status": "running",
                    "startedAt": "2026-09-28T00:00:00Z",
                ])
            default:
                return try .json(
                    ["id": "op-0", "provider": "codex", "status": "succeeded", "startedAt": "2026-09-28T00:00:00Z"])
            }
        }
        defer { fixture.close() }
        let clis = try await fixture.api.providerVersions()["clis"].arrayValue
        #expect(clis.map(CLIManagement.installSupported) == [true, false])
        #expect(clis.map(CLIManagement.isInstalled) == [false, true])
        #expect(clis[0]["error"].isNull)
        #expect(!CLIManagement.isInstalled(["installed": true, "status": "notInstalled"]))
        #expect(!CLIManagement.installSupported(["kind": "external", "installSupported": true]))

        #expect(CLIManagement.isInstall(try await fixture.api.installProvider(provider: "pi")))
        // Operations from backends that predate install carry no action.
        #expect(!CLIManagement.isInstall(try await fixture.api.providerUpgradeOperation(id: "op-0")))
    }

    @Test
    func agentProviderTransferTravelsVerbatim() async throws {
        // Integers beyond Double precision and the original key order must
        // survive export → file → import untouched.
        let file = Data(
            #"{"format":"todex.agent-providers","version":1,"agent":"codex","exportedAt":1790000000000,"providers":[{"id":"p","name":"P","settingsConfig":{"z":1,"big":12345678901234567890,"auth":{"OPENAI_API_KEY":"sk-clear"}}}]}"#
                .utf8)
        let sent = Mutex<Data?>(nil)
        let fixture = APIFixture { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v2/agent-providers/codex/export"):
                return StubResponse(status: 200, data: file, contentType: "application/json")
            case ("POST", "/v2/agent-providers/codex/import"):
                sent.withLock { $0 = try? requestBody(request) }
                return try .json(["agent": "codex", "currentProviderId": nil, "providers": [["id": "p", "name": "P"]]])
            default:
                Issue.record("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return try .json([:], status: 404)
            }
        }
        defer { fixture.close() }
        let exported = try await fixture.api.exportAgentProviders(agent: "codex")
        #expect(exported == file)
        #expect(try AgentProviderTransfer.providerCount(in: exported, agent: "codex") == 1)
        let bucket = try await fixture.api.importAgentProviders(agent: "codex", transfer: exported)
        #expect(sent.withLock { $0 } == file)
        #expect(bucket["providers"].arrayValue.count == 1)

        let notObject = APIFixture { _ in try .json(["not", "an", "object"]) }
        defer { notObject.close() }
        await #expect(throws: TodexError.self) { _ = try await notObject.api.exportAgentProviders(agent: "codex") }
    }

    @Test
    func agentProviderTransferEnvelopeIsCheckedBeforeUpload() throws {
        func count(_ text: String, agent: String = "pi") throws -> Int {
            try AgentProviderTransfer.providerCount(in: Data(text.utf8), agent: agent)
        }
        #expect(try count(#"{"format":"todex.agent-providers","version":1,"agent":"pi","providers":[{},{}]}"#) == 2)
        for invalid in [
            "not json", #"["todex.agent-providers"]"#,
            #"{"format":"cc-switch","agent":"pi","providers":[]}"#,
            #"{"format":"todex.agent-providers","agent":"codex","providers":[]}"#,
            #"{"format":"todex.agent-providers","providers":[]}"#,
            #"{"format":"todex.agent-providers","agent":"pi","providers":{}}"#,
        ] {
            #expect(throws: TodexError.self) { try count(invalid) }
        }
        let oversized = Data(count: AgentProviderTransfer.maximumBytes + 1)
        #expect(throws: TodexError.self) {
            try AgentProviderTransfer.providerCount(in: oversized, agent: "pi")
        }
    }
}

private enum TestWire {
    // Deliberately literal fixtures, independent of Swift's encoders and initializers.
    static let workspace: JSONValue = [
        "id": "w", "name": "项目", "path": "/work/project", "sessionId": "cdxs_w", "tenantId": "local",
        "threadId": "t", "model": "custom-model", "reasoningEffort": "medium", "approvalPolicy": "on-request",
        "sandboxMode": "workspace-write", "permissionProfile": ":workspace", "approvalsReviewer": "user",
        "serviceTier": "fast", "createdAt": 1_789_035_200_123, "updatedAt": 1_789_035_201_456,
    ]
    static let manifest: JSONValue = [
        "id": "c", "provider": "codex", "workspace": "/work/project", "workspaceId": "w", "title": "讨论",
        "providerProfile": "custom", "status": "idle", "lastSequence": 7,
        "createdAt": "2026-09-10T11:00:00.123456Z", "updatedAt": "2026-09-10T12:00:00Z",
    ]
    static let provider: JSONValue = [
        "id": "future-provider", "displayName": "Future Provider", "available": false,
        "unavailableReason": "not installed",
        "profiles": ["local", "custom"], "capabilities": ["cancel": true, "futureCapability": ["enabled": true]],
        "models": [["id": "custom-model", "futureModelField": [1, "x", nil]]],
    ]
    static let event: JSONValue = [
        "schemaVersion": 2, "sequence": 7, "eventId": "evt_7", "conversationId": "c",
        "time": "2026-09-10T12:00:00.123456Z", "type": "provider.event", "normalizedType": "tool.started",
        "rawType": "item/started", "provider": "codex",
        "payload": ["providerMethod": "item/started", "extra": [false, nil, 42]],
    ]
    static let replay: JSONValue = [
        "conversationId": "c", "fromSequence": 0, "nextSequence": 7, "hasMore": true, "events": .array([event]),
    ]
}

private struct ErrorCase: Sendable {
    let status: Int
    let body: JSONValue
    let code: String
    let message: String
}

private struct EndpointCase: Sendable, CustomStringConvertible {
    let name: String
    let method: String
    let path: String
    var query: [String: String] = [:]
    var body: JSONValue? = nil
    var authenticated = true
    var response: JSONValue = ["accepted": true, "futureResponse": [1, nil]]
    var expectedResult: JSONValue? = nil
    let invoke: @Sendable (APIClient) async throws -> JSONValue
    var description: String { name }

    // Every dynamic route segment contains reserved characters. Expected paths are literal,
    // so a regression in HTTPClient.segment cannot also rewrite the expectation.
    static let id = "a/b ?#%&+"
    static let escaped = "a%2Fb%20%3F%23%25%26%2B"
    static let workspacePath = "/work/项目 space?x=1&y=%2F+#"
    static let transfer: JSONValue = [
        "format": "todex.agent-providers", "version": 1, "agent": "grok-build", "exportedAt": 1_790_000_000_000,
        "providers": [["id": "xai", "name": "xAI", "settingsConfig": ["apiKey": "xai-clear"], "sortIndex": 0]],
    ]

    static let all: [EndpointCase] = [
        .init(name: "health", method: "GET", path: "/health", authenticated: false, response: "ok") {
            try await $0.health()
        },
        .init(name: "version", method: "GET", path: "/v2/version") { try await $0.version() },
        .init(name: "transportPolicy", method: "GET", path: "/v2/transport-policy", authenticated: false) {
            try await $0.transportPolicy()
        },
        .init(
            name: "workspaces", method: "GET", path: "/v2/workspaces",
            response: ["workspaces": .array([TestWire.workspace]), "updatedAt": 123],
            expectedResult: .array([TestWire.workspace])
        ) { try JSONValue(encoding: await $0.workspaces()) },
        .init(
            name: "replaceWorkspaces", method: "PUT", path: "/v2/workspaces",
            body: ["workspaces": .array([TestWire.workspace])]
        ) {
            try await $0.replaceWorkspaces([
                WorkspaceRecord(
                    id: "w", name: "项目", path: "/work/project", sessionId: "cdxs_w", tenantId: "local", threadId: "t",
                    model: "custom-model", reasoningEffort: "medium", approvalPolicy: "on-request",
                    sandboxMode: "workspace-write", permissionProfile: ":workspace", approvalsReviewer: "user",
                    serviceTier: "fast", createdAt: 1_789_035_200_123, updatedAt: 1_789_035_201_456)
            ])
        },
        .init(name: "deleteWorkspace", method: "DELETE", path: "/v2/workspaces/\(escaped)") {
            try await $0.deleteWorkspace(id: id)
        },
        .init(name: "workspaceTrust", method: "GET", path: "/v2/workspaces/\(escaped)/trust") {
            try await $0.workspaceTrust(id: id)
        },
        .init(
            name: "updateWorkspaceTrust", method: "PUT", path: "/v2/workspaces/\(escaped)/trust",
            body: ["trusted": false]
        ) { try await $0.updateWorkspaceTrust(id: id, trusted: false) },
        .init(
            name: "workspaceEntries", method: "GET", path: "/v2/workspace/entries",
            query: ["cwd": workspacePath, "query": "搜索 &+?#%", "limit": "23"]
        ) { try await $0.workspaceEntries(cwd: workspacePath, query: "搜索 &+?#%", limit: 23) },
        .init(
            name: "workspaceDirectories", method: "GET", path: "/v2/workspace/directories",
            query: ["path": workspacePath, "limit": "12"]
        ) { try await $0.workspaceDirectories(path: workspacePath, limit: 12) },
        .init(name: "workspaceFile", method: "GET", path: "/v2/workspace/file", query: ["path": workspacePath]) {
            try await $0.workspaceFile(path: workspacePath)
        },
        .init(
            name: "saveWorkspaceFile", method: "PUT", path: "/v2/workspace/file",
            body: ["path": .string(workspacePath), "text": "new\n\"文\"", "expectedText": "old\n"]
        ) { try await $0.saveWorkspaceFile(path: workspacePath, text: "new\n\"文\"", expectedText: "old\n") },
        .init(name: "gitScan", method: "GET", path: "/v2/git/scan", query: ["workspacePath": workspacePath]) {
            try await $0.gitScan(workspacePath: workspacePath)
        },
        .init(
            name: "gitRun", method: "POST", path: "/v2/git/run",
            body: [
                "workspacePath": .string(workspacePath), "action": "commit", "message": "fix", "includeUnstaged": false,
            ]
        ) {
            try await $0.gitRun([
                "workspacePath": .string(workspacePath), "action": "commit", "message": "fix", "includeUnstaged": false,
            ])
        },
        .init(name: "gitWorkspace", method: "GET", path: "/v2/git/workspace", query: ["workspacePath": workspacePath]) {
            try await $0.gitWorkspace(workspacePath: workspacePath)
        },
        .init(name: "gitStatus", method: "GET", path: "/v2/git/status", query: ["workspacePath": workspacePath]) {
            try await $0.gitStatus(workspacePath: workspacePath)
        },
        .init(
            name: "gitOperation", method: "POST", path: "/v2/git/operation",
            body: [
                "workspacePath": .string(workspacePath),
                "operation": ["action": "create-branch", "branchName": "feature/one"],
            ]
        ) {
            try await $0.gitOperation([
                "workspacePath": .string(workspacePath),
                "operation": ["action": "create-branch", "branchName": "feature/one"],
            ])
        },
        .init(
            name: "gitPullRequest", method: "GET", path: "/v2/git/pull-request",
            query: ["workspacePath": workspacePath]
        ) { try await $0.gitPullRequest(workspacePath: workspacePath) },
        .init(
            name: "gitLog", method: "GET", path: "/v2/git/log",
            query: ["workspacePath": workspacePath, "skip": "5", "limit": "5"]
        ) { try await $0.gitLog(workspacePath: workspacePath, skip: 5, limit: 5) },
        .init(
            name: "gitDiff", method: "GET", path: "/v2/git/diff",
            query: ["workspacePath": workspacePath, "path": "src/文件 &+?#%.swift"]
        ) { try await $0.gitDiff(workspacePath: workspacePath, path: "src/文件 &+?#%.swift") },
        .init(
            name: "browserFetch", method: "POST", path: "/v2/browser/fetch",
            body: ["url": "https://example.test/a?x=1&y=2"]
        ) { try await $0.browserFetch(url: "https://example.test/a?x=1&y=2") },
        .init(
            name: "providers", method: "GET", path: "/v2/providers",
            response: ["providers": .array([TestWire.provider])], expectedResult: .array([TestWire.provider])
        ) { try JSONValue(encoding: await $0.providers()) },
        .init(name: "providerVersions", method: "GET", path: "/v2/providers/versions") {
            try await $0.providerVersions()
        },
        .init(name: "upgradeProvider", method: "POST", path: "/v2/providers/\(escaped)/upgrade") {
            try await $0.upgradeProvider(provider: id)
        },
        .init(
            name: "installProvider", method: "POST", path: "/v2/providers/\(escaped)/install",
            response: ["id": "op", "provider": "pi", "action": "install", "status": "running"]
        ) { try await $0.installProvider(provider: id) },
        .init(name: "providerUpgradeOperation", method: "GET", path: "/v2/providers/upgrades/\(escaped)") {
            try await $0.providerUpgradeOperation(id: id)
        },
        .init(
            name: "providerModels", method: "GET", path: "/v2/providers/models",
            query: ["provider": "codex", "workspace": workspacePath]
        ) { try await $0.providerModels(provider: "codex", workspace: workspacePath) },
        .init(
            name: "providerImageInput", method: "GET", path: "/v2/providers/image-input",
            query: ["provider": "acp", "workspace": workspacePath, "profile": "profile &+?", "model": "model/#%+"]
        ) {
            try await $0.providerImageInput(
                provider: "acp", workspace: workspacePath, profile: "profile &+?", model: "model/#%+")
        },
        .init(
            name: "providerCommands", method: "GET", path: "/v2/providers/commands",
            query: ["provider": "codex", "workspace": workspacePath]
        ) { try await $0.providerCommands(provider: "codex", workspace: workspacePath) },
        .init(
            name: "agentProviders", method: "GET", path: "/v2/agent-providers",
            query: ["agent": "codex"]
        ) { try await $0.agentProviders(agent: "codex") },
        .init(
            name: "upsertAgentProvider", method: "PUT", path: "/v2/agent-providers/claude-code/\(escaped)",
            body: [
                "name": "custom",
                "settingsConfig": ["env": ["ANTHROPIC_BASE_URL": "https://example.test"]],
            ]
        ) {
            try await $0.upsertAgentProvider(
                agent: "claude-code", id: id,
                profile: [
                    "name": "custom",
                    "settingsConfig": ["env": ["ANTHROPIC_BASE_URL": "https://example.test"]],
                ])
        },
        .init(name: "deleteAgentProvider", method: "DELETE", path: "/v2/agent-providers/pi/\(escaped)") {
            try await $0.deleteAgentProvider(agent: "pi", id: id)
        },
        .init(
            name: "activateAgentProvider", method: "POST",
            path: "/v2/agent-providers/opencode/\(escaped)/activate",
            body: ["modelId": "model &+?"]
        ) { try await $0.activateAgentProvider(agent: "opencode", id: id, modelId: "model &+?") },
        .init(
            name: "importLiveAgentProvider", method: "POST",
            path: "/v2/agent-providers/codex/import-live",
            body: ["id": .string(id), "name": "已导入"]
        ) { try await $0.importLiveAgentProvider(agent: "codex", id: id, name: "已导入") },
        .init(
            name: "exportAgentProviders", method: "GET", path: "/v2/agent-providers/grok-build/export",
            response: transfer
        ) { try JSONDecoder().decode(JSONValue.self, from: await $0.exportAgentProviders(agent: "grok-build")) },
        .init(
            name: "importAgentProviders", method: "POST", path: "/v2/agent-providers/grok-build/import",
            body: transfer
        ) { try await $0.importAgentProviders(agent: "grok-build", transfer: JSONEncoder().encode(transfer)) },
        .init(name: "agentProviderModels", method: "GET", path: "/v2/agent-providers/codex/\(escaped)/models") {
            try await $0.agentProviderModels(agent: "codex", id: id)
        },
        .init(
            name: "previewAgentProviderModels", method: "POST", path: "/v2/agent-providers/pi/\(escaped)/models",
            body: ["settingsConfig": ["baseUrl": "https://example.test/v1", "apiKey": "__TODEX_MASKED__"]],
            response: ["models": [["id": "m-1", "name": "Model 1"]]]
        ) {
            try await $0.previewAgentProviderModels(
                agent: "pi", id: id,
                settingsConfig: ["baseUrl": "https://example.test/v1", "apiKey": "__TODEX_MASKED__"])
        },
        .init(
            name: "skills", method: "GET", path: "/v2/catalog/skills",
            query: ["provider": "codex", "workspace": workspacePath]
        ) { try await $0.skills(provider: "codex", workspace: workspacePath) },
        .init(
            name: "skillResource", method: "GET", path: "/v2/catalog/skills/\(escaped)",
            query: ["provider": "codex", "workspace": workspacePath]
        ) { try await $0.skillResource(id: id, provider: "codex", workspace: workspacePath) },
        .init(
            name: "mcpCatalog", method: "GET", path: "/v2/catalog/mcp",
            query: ["provider": "codex", "workspace": workspacePath]
        ) { try await $0.mcpCatalog(provider: "codex", workspace: workspacePath) },
        .init(
            name: "conversations", method: "GET", path: "/v2/conversations",
            response: ["conversations": .array([TestWire.manifest])], expectedResult: .array([TestWire.manifest])
        ) { try JSONValue(encoding: await $0.conversations()) },
        .init(name: "conversation", method: "GET", path: "/v2/conversations/\(escaped)", response: TestWire.manifest) {
            try JSONValue(encoding: await $0.conversation(id: id))
        },
        .init(
            name: "events", method: "GET", path: "/v2/conversations/\(escaped)/events",
            query: ["afterSequence": "7", "limit": "200", "historyEncryption": "1"], response: TestWire.replay
        ) { try await $0.events(conversationId: id, after: 7) },
        .init(
            name: "createConversation", method: "POST", path: "/v2/conversations",
            body: ["workspace": "/work/project", "provider": "codex", "providerProfile": "custom", "title": "讨论"],
            response: TestWire.manifest
        ) {
            try JSONValue(
                encoding: await $0.createConversation(
                    workspace: WorkspaceRecord(name: "Project", path: "/work/project"), provider: "codex",
                    profile: "custom", title: "讨论"))
        },
        .init(
            name: "updateConversation", method: "PATCH", path: "/v2/conversations/\(escaped)",
            body: ["title": "新标题", "archived": false], response: TestWire.manifest
        ) { try JSONValue(encoding: await $0.updateConversation(id: id, patch: ["title": "新标题", "archived": false])) },
        .init(name: "deleteConversation", method: "DELETE", path: "/v2/conversations/\(escaped)") {
            try await $0.deleteConversation(id: id)
        },
        .init(
            name: "promptConversation", method: "POST", path: "/v2/conversations/\(escaped)/prompt",
            body: ["text": "hello", "clientRequestId": "r", "content": [["type": "text", "text": "hello"]]]
        ) {
            try await $0.promptConversation(
                id: id,
                prompt: ["text": "hello", "clientRequestId": "r", "content": [["type": "text", "text": "hello"]]])
        },
        .init(name: "cancelConversation", method: "POST", path: "/v2/conversations/\(escaped)/cancel") {
            try await $0.cancelConversation(id: id)
        },
        .init(
            name: "cancelConversationTurn", method: "POST", path: "/v2/conversations/\(escaped)/cancel",
            body: ["turnId": "turn_1"], response: ["cancelled": false, "activeTurnId": nil],
            expectedResult: ["cancelled": false, "activeTurnId": nil]
        ) { try await $0.cancelConversation(id: id, turnId: "turn_1") },
        .init(name: "interruptConversation", method: "POST", path: "/v2/conversations/\(escaped)/interrupt") {
            try await $0.interruptConversation(id: id)
        },
        .init(
            name: "respondPermission", method: "POST", path: "/v2/conversations/\(escaped)/permissions/\(escaped)",
            body: ["outcome": "allow_once", "optionId": "opt", "data": ["answer": "yes"]]
        ) {
            try await $0.respondPermission(
                conversationId: id, permissionId: id,
                decision: ["outcome": "allow_once", "optionId": "opt", "data": ["answer": "yes"]])
        },
        .init(
            name: "kanbanTasks", method: "GET", path: "/v2/kanban/tasks",
            response: ["tasks": .array([])], expectedResult: .array([])
        ) { try JSONValue(encoding: await $0.kanbanTasks()) },
        .init(
            name: "replaceKanbanTasks", method: "PUT", path: "/v2/kanban/tasks",
            body: ["tasks": .array([])], response: ["tasks": .array([])], expectedResult: .array([])
        ) { try JSONValue(encoding: await $0.replaceKanbanTasks([])) },
        .init(name: "agentDesktop", method: "GET", path: "/v2/agent-desktop", response: agentDesktop) {
            try JSONValue(encoding: await $0.agentDesktop())
        },
        .init(
            name: "setAgentDesktop", method: "PUT", path: "/v2/agent-desktop", body: ["computerEnabled": true],
            response: ["enabled": true, "computerEnabled": true]
        ) { try JSONValue(encoding: await $0.setAgentDesktop(computerEnabled: true)) },
        .init(
            name: "requestComputerPermissions", method: "POST", path: "/v2/agent-desktop/computer/permissions",
            response: agentDesktop
        ) { try JSONValue(encoding: await $0.requestComputerPermissions()) },
        .init(
            name: "computerApps", method: "GET", path: "/v2/agent-desktop/computer/apps",
            response: ["apps": [["id": "com.apple.TextEdit", "name": "TextEdit", "running": true]]],
            expectedResult: [["id": "com.apple.TextEdit", "name": "TextEdit", "running": true]]
        ) { try JSONValue(encoding: await $0.computerApps()) },
        .init(
            name: "agentDesktopFrame", method: "GET", path: "/v2/conversations/\(escaped)/agent-desktop/frame",
            query: ["capability": "browser"], response: frame
        ) { try JSONValue(encoding: await $0.agentDesktopFrame(conversationId: id, capability: .browser)) },
        .init(
            name: "revokeAgentDesktop", method: "DELETE", path: "/v2/conversations/\(escaped)/agent-desktop",
            query: ["capability": "screen"]
        ) { try await $0.revokeAgentDesktop(conversationId: id, capability: .screen) },
        .init(
            name: "agentShot", method: "GET", path: "/v2/conversations/\(escaped)/agent-shots/\(escaped)",
            response: ["shotId": "shot_1", "mimeType": "image/jpeg", "dataUrl": "data:image/jpeg;base64,/9j/"]
        ) { try JSONValue(encoding: await $0.agentShot(conversationId: id, shotId: id)) },
        .init(
            name: "installAgentBrowser", method: "POST", path: "/v2/agent-browser/install", response: agentDesktop
        ) { try JSONValue(encoding: await $0.installAgentBrowser()) },
        .init(name: "agentBrowserProfiles", method: "GET", path: "/v2/agent-browser/profiles", response: profiles) {
            try JSONValue(encoding: await $0.agentBrowserProfiles())
        },
        .init(
            name: "createAgentBrowserProfile", method: "POST", path: "/v2/agent-browser/profiles",
            body: ["name": "工作 &+?"], response: ["id": "p2", "name": "工作 &+?", "createdAt": 1_789_000_000_001]
        ) { try JSONValue(encoding: await $0.createAgentBrowserProfile(name: "工作 &+?")) },
        .init(
            name: "renameAgentBrowserProfile", method: "PUT", path: "/v2/agent-browser/profiles/\(escaped)",
            body: ["name": "个人"], response: profiles
        ) { try JSONValue(encoding: await $0.renameAgentBrowserProfile(id: id, name: "个人")) },
        .init(
            name: "deleteAgentBrowserProfile", method: "DELETE", path: "/v2/agent-browser/profiles/\(escaped)",
            response: profiles
        ) { try JSONValue(encoding: await $0.deleteAgentBrowserProfile(id: id)) },
        .init(
            name: "assignAgentBrowserProfile", method: "PUT", path: "/v2/agent-browser/workspaces",
            body: ["workspace": .string(workspacePath), "profileId": "p1"], response: profiles
        ) { try JSONValue(encoding: await $0.assignAgentBrowserProfile(workspace: workspacePath, profileId: "p1")) },
    ]

    static let agentDesktop: JSONValue = [
        "enabled": true, "computerEnabled": false,
        "computer": [
            "supported": true, "available": false, "reason": "Accessibility is not granted", "host": "Mac",
            "platform": "macos", "permissions": ["screen": true, "accessibility": false],
        ],
        "browser": [
            "available": true, "host": "Mac",
            "chromium": [
                "version": "141.0.7390.54", "installed": false, "downloading": true, "progress": 0.5,
                "overridden": false,
            ],
        ],
    ]
    static let frame: JSONValue = ["mimeType": "image/jpeg", "dataUrl": "data:image/jpeg;base64,/9j/"]
    static let profiles: JSONValue = [
        "profiles": [["id": "p1", "name": "默认", "createdAt": 1_789_000_000_000]],
        "workspaces": [workspacePath: "p1"],
    ]
}

private struct StubResponse: Sendable {
    let status: Int
    let data: Data
    let contentType: String

    static func json(_ value: JSONValue, status: Int = 200) throws -> Self {
        Self(status: status, data: try JSONEncoder().encode(value), contentType: "application/json")
    }

    static func text(_ value: String, status: Int = 200) -> Self {
        Self(status: status, data: Data(value.utf8), contentType: "text/plain")
    }
}

/// Each fixture has its own host and session. The only shared state is mutex-protected.
/// Every request on a stub session is intercepted, including unregistered/incorrect URLs.
private final class APIURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> StubResponse
    static let handlers = Mutex<[String: Handler]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let url = request.url, let host = url.host,
                let handler = Self.handlers.withLock({ $0[host] })
            else {
                throw URLError(.unsupportedURL)
            }
            let stub = try handler(request)
            guard
                let response = HTTPURLResponse(
                    url: url, statusCode: stub.status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": stub.contentType])
            else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct APIFixture {
    let host: String
    let session: URLSession
    let api: APIClient

    init(
        deviceSecret: String = "FRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRU", handler: @escaping APIURLProtocol.Handler
    ) {
        let host = uniqueLoopbackHost()
        self.host = host
        APIURLProtocol.handlers.withLock { $0[host] = handler }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [APIURLProtocol.self]
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config)
        api = APIClient(
            connection: BackendConnection(serverURL: "https://\(host)/v2/", deviceSecret: deviceSecret), session: session)
    }

    func close() {
        session.invalidateAndCancel()
        _ = APIURLProtocol.handlers.withLock { $0.removeValue(forKey: host) }
    }
}

private func requestJSON(_ request: URLRequest) throws -> JSONValue? {
    try requestBody(request).map { try JSONDecoder().decode(JSONValue.self, from: $0) }
}

/// URLSession hands URLProtocol either httpBody or a stream; read both as bytes.
private func requestBody(_ request: URLRequest) throws -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
        if count == 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return data.isEmpty ? nil : data
}

/// Match serde_urlencoded's decoding, including the easily missed + → space rule.
private func backendQuery(_ encoded: String?) throws -> [String: String] {
    guard let encoded, !encoded.isEmpty else { return [:] }
    return try Dictionary(
        uniqueKeysWithValues: encoded.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = try #require(String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding)
            let value = try #require(
                String(parts.count > 1 ? parts[1] : "").replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            )
            return (key, value)
        })
}
