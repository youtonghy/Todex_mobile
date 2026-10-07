import Foundation

/// Named wrappers for the backend's HTTP method/path pairs (see docs/api-coverage.md).
/// Provider-specific request and response fields remain JSONValue.
public final class APIClient: Sendable {
    public let http: HTTPClient

    public convenience init(connection: BackendConnection) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(
            configuration: configuration, delegate: APIClientNoRedirectDelegate(), delegateQueue: nil)
        self.init(connection: connection, session: session)
    }

    /// Allows URLProtocol testing and callers with an explicitly configured session.
    /// The caller owns the injected session's redirect, cookie and cache policy.
    public init(connection: BackendConnection, session: URLSession) {
        // HTTPClient applies the transport v2 client rules to every call;
        // HTTPClient.segment escapes `+` so Axum never reads it as a space.
        http = HTTPClient(connection: connection, session: session)
    }

    /// `/health` returns text/plain, unlike the JSON endpoints. It goes
    /// through the same transport as every other call (sealed when pinned).
    public func health() async throws -> JSONValue {
        let result = try await http.response(path: "/health", headers: ["accept": "text/plain"], authenticated: false)
        guard (200..<300).contains(result.statusCode) else { throw result.apiError() }
        guard let text = String(data: result.data, encoding: .utf8) else {
            throw TodexError.invalid(String(localized: "健康检查未返回有效文本", bundle: .module))
        }
        return .string(text)
    }

    /// Signed when the device is enrolled: the backend only returns `data_dir`
    /// and the workspace roots to authenticated callers. An unpaired device
    /// (no usable seed) falls back to an unsigned request inside HTTPClient
    /// and simply gets the version without the path fields.
    public func version() async throws -> JSONValue {
        try await http.request(path: "/v2/version", authenticated: true)
    }

    public func transportPolicy() async throws -> JSONValue {
        try await http.request(path: "/v2/transport-policy", authenticated: false)
    }

    public func workspaces() async throws -> [WorkspaceRecord] {
        let value = try await http.request(path: "/v2/workspaces")
        return try value["workspaces"].decoded([WorkspaceRecord].self)
    }

    /// Usable workspaces plus the stored records whose path the backend rejects.
    public func workspaceCatalog() async throws -> WorkspaceCatalog {
        try WorkspaceCatalog(response: try await http.request(path: "/v2/workspaces"))
    }

    /// The backend merges the supplied records by owned, canonical workspace id.
    public func replaceWorkspaces(_ workspaces: [WorkspaceRecord]) async throws -> JSONValue {
        try await http.request(
            .put, path: "/v2/workspaces",
            body: [
                "workspaces": try JSONValue(encoding: workspaces)
            ])
    }

    /// Kanban board state shared across clients of this backend.
    public func kanbanTasks() async throws -> [KanbanTaskRecord] {
        let value = try await http.request(path: "/v2/kanban/tasks")
        return try value["tasks"].decoded([KanbanTaskRecord].self)
    }

    /// Tombstones ride along in the payload so deletions propagate; the backend
    /// merges by (tenant, id) keeping the newest updatedAt.
    public func replaceKanbanTasks(_ tasks: [KanbanTaskRecord]) async throws -> [KanbanTaskRecord] {
        let value = try await http.request(
            .put, path: "/v2/kanban/tasks",
            body: [
                "tasks": try JSONValue(encoding: tasks)
            ])
        return try value["tasks"].decoded([KanbanTaskRecord].self)
    }

    public func deleteWorkspace(id: String) async throws -> JSONValue {
        try await http.request(.delete, path: "/v2/workspaces/\(HTTPClient.segment(id))")
    }

    public func workspaceTrust(id: String) async throws -> JSONValue {
        try await http.request(path: "/v2/workspaces/\(HTTPClient.segment(id))/trust")
    }

    public func updateWorkspaceTrust(id: String, trusted: Bool) async throws -> JSONValue {
        try await http.request(
            .put, path: "/v2/workspaces/\(HTTPClient.segment(id))/trust",
            body: [
                "trusted": .bool(trusted)
            ])
    }

    public func workspaceEntries(cwd: String, query: String = "", limit: Int = 40) async throws -> JSONValue {
        try await http.request(
            path: "/v2/workspace/entries",
            query: [
                "cwd": cwd, "query": query, "limit": String(limit),
            ])
    }

    /// `GET /v2/ssh/hosts` returns `{ hosts, ftpSites }`; each host carries
    /// `alias`, `agentAccess` and a `resolved` block (`hostName`, `user`, `port`).
    public func sshHosts() async throws -> JSONValue {
        try await http.request(path: "/v2/ssh/hosts")
    }

    public func workspaceDirectories(path: String? = nil, limit: Int? = nil) async throws -> JSONValue {
        var query: [String: String] = [:]
        query["path"] = path
        query["limit"] = limit.map(String.init)
        return try await http.request(path: "/v2/workspace/directories", query: query)
    }

    public func workspaceFile(path: String) async throws -> JSONValue {
        try await http.request(path: "/v2/workspace/file", query: ["path": path])
    }

    /// expectedText is required for the backend's compare-and-save conflict check.
    public func saveWorkspaceFile(path: String, text: String, expectedText: String) async throws -> JSONValue {
        try await http.request(
            .put, path: "/v2/workspace/file",
            body: [
                "path": .string(path), "text": .string(text), "expectedText": .string(expectedText),
            ])
    }

    public func gitScan(workspacePath: String) async throws -> JSONValue {
        try await http.request(path: "/v2/git/scan", query: ["workspacePath": workspacePath])
    }

    public func gitRun(_ request: JSONValue) async throws -> JSONValue {
        try await http.request(.post, path: "/v2/git/run", body: request)
    }

    public func gitWorkspace(workspacePath: String) async throws -> JSONValue {
        try await http.request(path: "/v2/git/workspace", query: ["workspacePath": workspacePath])
    }

    public func gitStatus(workspacePath: String) async throws -> JSONValue {
        try await http.request(path: "/v2/git/status", query: ["workspacePath": workspacePath])
    }

    public func gitOperation(_ request: JSONValue) async throws -> JSONValue {
        try await http.request(.post, path: "/v2/git/operation", body: request)
    }

    public func gitPullRequest(workspacePath: String) async throws -> JSONValue {
        try await http.request(path: "/v2/git/pull-request", query: ["workspacePath": workspacePath])
    }

    /// Newest-first commit page; backends that predate the route answer 404.
    public func gitLog(workspacePath: String, skip: Int, limit: Int) async throws -> JSONValue {
        try await http.request(
            path: "/v2/git/log",
            query: ["workspacePath": workspacePath, "skip": String(skip), "limit": String(limit)])
    }

    public func gitDiff(workspacePath: String, path: String) async throws -> JSONValue {
        try await http.request(
            path: "/v2/git/diff", query: ["workspacePath": workspacePath, "path": path])
    }

    public func browserFetch(url: String) async throws -> JSONValue {
        try await http.request(.post, path: "/v2/browser/fetch", body: ["url": .string(url)])
    }

    public func providers() async throws -> [ProviderDescriptor] {
        let value = try await http.request(path: "/v2/providers")
        return try value["providers"].decoded([ProviderDescriptor].self)
    }

    public func providerVersions() async throws -> JSONValue {
        try await http.request(path: "/v2/providers/versions")
    }

    public func upgradeProvider(provider: String) async throws -> JSONValue {
        try await http.request(.post, path: "/v2/providers/\(HTTPClient.segment(provider))/upgrade")
    }

    /// Starts installing a managed CLI that is not installed (409 otherwise).
    /// Returns the same operation object as upgrades, with `action: "install"`;
    /// poll it with providerUpgradeOperation(id:).
    public func installProvider(provider: String) async throws -> JSONValue {
        try await http.request(.post, path: "/v2/providers/\(HTTPClient.segment(provider))/install")
    }

    /// Serves both install and upgrade operations.
    public func providerUpgradeOperation(id: String) async throws -> JSONValue {
        try await http.request(path: "/v2/providers/upgrades/\(HTTPClient.segment(id))")
    }

    public func providerModels(provider: String, workspace: String) async throws -> JSONValue {
        try await http.request(path: "/v2/providers/models", query: ["provider": provider, "workspace": workspace])
    }

    public func providerImageInput(
        provider: String, workspace: String, profile: String? = nil, model: String? = nil
    ) async throws -> JSONValue {
        var query = ["provider": provider, "workspace": workspace]
        query["profile"] = profile
        query["model"] = model
        return try await http.request(path: "/v2/providers/image-input", query: query)
    }

    public func providerCommands(provider: String, workspace: String) async throws -> JSONValue {
        try await http.request(path: "/v2/providers/commands", query: ["provider": provider, "workspace": workspace])
    }

    /// Managed agent provider accounts (cc-switch model). Secret values in the
    /// returned settingsConfig are masked; writing the mask back keeps the
    /// stored value server-side.
    public func agentProviders(agent: String? = nil) async throws -> JSONValue {
        var query: [String: String] = [:]
        query["agent"] = agent
        return try await http.request(path: "/v2/agent-providers", query: query)
    }

    public func upsertAgentProvider(agent: String, id: String, profile: JSONValue) async throws -> JSONValue {
        try await http.request(
            .put, path: "/v2/agent-providers/\(HTTPClient.segment(agent))/\(HTTPClient.segment(id))",
            body: profile)
    }

    public func deleteAgentProvider(agent: String, id: String) async throws -> JSONValue {
        try await http.request(
            .delete, path: "/v2/agent-providers/\(HTTPClient.segment(agent))/\(HTTPClient.segment(id))")
    }

    public func activateAgentProvider(agent: String, id: String, modelId: String? = nil) async throws -> JSONValue {
        var body: [String: JSONValue] = [:]
        body["modelId"] = modelId.map(JSONValue.string)
        return try await http.request(
            .post,
            path: "/v2/agent-providers/\(HTTPClient.segment(agent))/\(HTTPClient.segment(id))/activate",
            body: .object(body))
    }

    /// Exclusive agents capture the whole live config; additive agents adopt the
    /// live node whose key equals `id`.
    public func importLiveAgentProvider(agent: String, id: String, name: String? = nil) async throws -> JSONValue {
        var body: [String: JSONValue] = ["id": .string(id)]
        body["name"] = name.map(JSONValue.string)
        return try await http.request(
            .post, path: "/v2/agent-providers/\(HTTPClient.segment(agent))/import-live",
            body: .object(body))
    }

    /// One agent's providers as a `todex.agent-providers` file with secrets in
    /// clear. Returns the backend's exact bytes so the file round-trips
    /// without re-encoding opaque settingsConfig values.
    public func exportAgentProviders(agent: String) async throws -> Data {
        let result = try await http.response(
            path: "/v2/agent-providers/\(HTTPClient.segment(agent))/export",
            maximumBytes: AgentProviderTransfer.maximumBytes)
        guard case .object = try result.json() else {
            throw TodexError.invalid(String(localized: "后端返回的供应商导出无效", bundle: .module))
        }
        return result.data
    }

    /// Upserts every provider of an export file by id; providers missing from
    /// the file stay and the current provider is unchanged. The file is sent
    /// byte-for-byte and the agent's updated bucket is returned.
    public func importAgentProviders(agent: String, transfer: Data) async throws -> JSONValue {
        try await http.request(
            .post, path: "/v2/agent-providers/\(HTTPClient.segment(agent))/import", jsonData: transfer)
    }

    /// Model listing proxied by the backend so the API key stays server-side.
    public func agentProviderModels(agent: String, id: String) async throws -> JSONValue {
        try await http.request(
            path: "/v2/agent-providers/\(HTTPClient.segment(agent))/\(HTTPClient.segment(id))/models")
    }

    /// Model catalog for an unsaved editor form. Masked secrets resolve against
    /// the stored profile or the live additive node of the same id.
    public func previewAgentProviderModels(agent: String, id: String, settingsConfig: JSONValue) async throws
        -> JSONValue
    {
        try await http.request(
            .post, path: "/v2/agent-providers/\(HTTPClient.segment(agent))/\(HTTPClient.segment(id))/models",
            body: ["settingsConfig": settingsConfig])
    }

    public func skills(provider: String, workspace: String) async throws -> JSONValue {
        try await http.request(path: "/v2/catalog/skills", query: ["provider": provider, "workspace": workspace])
    }

    public func skillResource(id: String, provider: String, workspace: String) async throws -> JSONValue {
        try await http.request(
            path: "/v2/catalog/skills/\(HTTPClient.segment(id))",
            query: [
                "provider": provider, "workspace": workspace,
            ])
    }

    public func mcpCatalog(provider: String, workspace: String) async throws -> JSONValue {
        try await http.request(path: "/v2/catalog/mcp", query: ["provider": provider, "workspace": workspace])
    }

    public func conversations() async throws -> [ConversationManifest] {
        let value = try await http.request(path: "/v2/conversations")
        return try value["conversations"].decoded([ConversationManifest].self)
    }

    public func conversation(id: String) async throws -> ConversationManifest {
        let value = try await http.request(path: conversationPath(id))
        return try value.decoded(ConversationManifest.self)
    }

    public func events(
        conversationId: String, after: Int, limit: Int = 200, detail: String = "full"
    ) async throws -> JSONValue {
        var query = ["afterSequence": String(after), "limit": String(limit), "historyEncryption": "1"]
        // `summary` folds process-only events down to detailStub markers; the
        // full payloads for a sequence range are fetched on demand.
        // `historyEncryption=1` declares this client can decrypt `$enc`
        // payloads (history v3 §5.4); pages then also carry `frames`.
        if detail != "full" { query["detail"] = detail }
        return try await http.request(path: "\(conversationPath(conversationId))/events", query: query)
    }

    /// Reverse pagination: the last `limit` events with `sequence <= before`.
    /// The next older page starts at `events.first.sequence - 1`; `hasMore`
    /// reports whether earlier events remain. Backends that predate the
    /// parameter ignore it and answer with the journal head instead.
    public func events(
        conversationId: String, before: Int, limit: Int = 200, detail: String = "full"
    ) async throws -> JSONValue {
        var query = ["beforeSequence": String(before), "limit": String(limit), "historyEncryption": "1"]
        if detail != "full" { query["detail"] = detail }
        return try await http.request(path: "\(conversationPath(conversationId))/events", query: query)
    }

    public func createConversation(
        workspace: WorkspaceRecord, provider: String, profile: String? = nil, title: String? = nil
    ) async throws -> ConversationManifest {
        var body: [String: JSONValue] = ["workspace": .string(workspace.path), "provider": .string(provider)]
        body["providerProfile"] = profile.map(JSONValue.string)
        body["title"] = title.map(JSONValue.string)
        let value = try await http.request(.post, path: "/v2/conversations", body: .object(body))
        return try value.decoded(ConversationManifest.self)
    }

    public func updateConversation(id: String, patch: JSONValue) async throws -> ConversationManifest {
        let value = try await http.request(.patch, path: conversationPath(id), body: patch)
        return try value.decoded(ConversationManifest.self)
    }

    public func deleteConversation(id: String) async throws -> JSONValue {
        try await http.request(.delete, path: conversationPath(id))
    }

    public func promptConversation(id: String, prompt: JSONValue) async throws -> JSONValue {
        try await http.request(.post, path: "\(conversationPath(id))/prompt", body: prompt)
    }

    public func cancelConversation(id: String) async throws -> JSONValue {
        try await http.request(.post, path: "\(conversationPath(id))/cancel")
    }

    public func interruptConversation(id: String) async throws -> JSONValue {
        try await http.request(.post, path: "\(conversationPath(id))/interrupt")
    }

    public func respondPermission(conversationId: String, permissionId: String, decision: JSONValue) async throws
        -> JSONValue
    {
        try await http.request(
            .post, path: "\(conversationPath(conversationId))/permissions/\(HTTPClient.segment(permissionId))",
            body: decision)
    }

    // MARK: Agent desktop tools (agent browser and Computer Use on the daemon's host)

    /// `GET /v2/agent-desktop`; an HTTP 404 (`TodexError.server(code: "404")`)
    /// means the daemon predates desktop tools.
    public func agentDesktop() async throws -> AgentDesktopSettings {
        try await http.request(path: "/v2/agent-desktop").decoded(AgentDesktopSettings.self)
    }

    /// Desktop tools on or off; Computer Use additionally needs `computerEnabled`.
    public func setAgentDesktop(enabled: Bool? = nil, computerEnabled: Bool? = nil) async throws
        -> AgentDesktopSettings
    {
        var body: [String: JSONValue] = [:]
        body["enabled"] = enabled.map(JSONValue.bool)
        body["computerEnabled"] = computerEnabled.map(JSONValue.bool)
        return try await http.request(.put, path: "/v2/agent-desktop", body: .object(body))
            .decoded(AgentDesktopSettings.self)
    }

    /// Shows the OS permission prompts (Screen Recording, Accessibility) on the daemon's host.
    public func requestComputerPermissions() async throws -> AgentDesktopSettings {
        try await http.request(.post, path: "/v2/agent-desktop/computer/permissions")
            .decoded(AgentDesktopSettings.self)
    }

    /// The host's screen now (404 unless the conversation controls it), or
    /// with `.browser` the conversation's tab (404 without one).
    public func agentDesktopFrame(conversationId: String, capability: AgentDesktopCapability = .screen)
        async throws -> AgentDesktopImage
    {
        let query = capability == .browser ? ["capability": "browser"] : [:]
        return try await http.request(path: "\(conversationPath(conversationId))/agent-desktop/frame", query: query)
            .decoded(AgentDesktopImage.self)
    }

    /// Stops the agent's browser and/or Computer Use for one conversation
    /// (both when `capability` is nil); its next tool call asks again.
    public func revokeAgentDesktop(conversationId: String, capability: AgentDesktopCapability? = nil)
        async throws -> JSONValue
    {
        var query: [String: String] = [:]
        query["capability"] = capability?.rawValue
        return try await http.request(
            .delete, path: "\(conversationPath(conversationId))/agent-desktop", query: query)
    }

    /// A screenshot journaled with a `desktop.*.action` event.
    public func agentShot(conversationId: String, shotId: String) async throws -> AgentDesktopImage {
        try await http.request(
            path: "\(conversationPath(conversationId))/agent-shots/\(HTTPClient.segment(shotId))"
        ).decoded(AgentDesktopImage.self)
    }

    /// Starts downloading the daemon's pinned Chromium; progress shows in `browser.chromium`.
    public func installAgentBrowser() async throws -> AgentDesktopSettings {
        try await http.request(.post, path: "/v2/agent-browser/install").decoded(AgentDesktopSettings.self)
    }

    public func agentBrowserProfiles() async throws -> AgentBrowserProfiles {
        try await http.request(path: "/v2/agent-browser/profiles").decoded(AgentBrowserProfiles.self)
    }

    public func createAgentBrowserProfile(name: String) async throws -> AgentBrowserProfile {
        try await http.request(.post, path: "/v2/agent-browser/profiles", body: ["name": .string(name)])
            .decoded(AgentBrowserProfile.self)
    }

    public func renameAgentBrowserProfile(id: String, name: String) async throws -> AgentBrowserProfiles {
        try await http.request(
            .put, path: "/v2/agent-browser/profiles/\(HTTPClient.segment(id))", body: ["name": .string(name)]
        ).decoded(AgentBrowserProfiles.self)
    }

    /// Deletes the profile with its cookies, storage and cache.
    public func deleteAgentBrowserProfile(id: String) async throws -> AgentBrowserProfiles {
        try await http.request(.delete, path: "/v2/agent-browser/profiles/\(HTTPClient.segment(id))")
            .decoded(AgentBrowserProfiles.self)
    }

    /// `workspace`: workspace id (path for workspaces without one). Its open tabs close.
    public func assignAgentBrowserProfile(workspace: String, profileId: String) async throws
        -> AgentBrowserProfiles
    {
        try await http.request(
            .put, path: "/v2/agent-browser/workspaces",
            body: ["workspace": .string(workspace), "profileId": .string(profileId)]
        ).decoded(AgentBrowserProfiles.self)
    }

    private func conversationPath(_ id: String) -> String {
        "/v2/conversations/\(HTTPClient.segment(id))"
    }
}

private final class APIClientNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
