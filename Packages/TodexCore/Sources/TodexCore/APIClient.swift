import Foundation

/// Named wrappers for the backend's 41 HTTP method/path pairs.
/// Provider-specific request and response fields remain JSONValue.
public final class APIClient: Sendable {
    public let http: HTTPClient
    private let session: URLSession

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
        http = HTTPClient(connection: connection, session: session)
        self.session = session
    }

    /// `/health` returns text/plain, unlike the JSON endpoints handled by HTTPClient.
    public func health() async throws -> JSONValue {
        var request = URLRequest(url: try http.url(path: "/health"))
        request.httpMethod = "GET"
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        return try await receiveGET(request, textResponse: true)
    }

    /// Axum's form query decoder treats a literal + as a space. HTTPClient's
    /// URLQueryItem builder leaves + unescaped, so repair only affected GETs here.
    private func queryRequest(path: String, query: [String: String]) async throws -> JSONValue {
        guard query.values.contains(where: { $0.contains("+") }) else {
            return try await http.request(path: path, query: query)
        }
        let url = try http.url(path: path, query: query)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw TodexError.invalid("接口地址无效")
        }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let encodedURL = components.url else { throw TodexError.invalid("接口地址无效") }
        var request = URLRequest(url: encodedURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let device = DeviceIdentity(secretKeyBase64URL: http.connection.deviceSecret) {
            let components = URLComponents(url: encodedURL, resolvingAgainstBaseURL: false)
            let target = (components?.percentEncodedPath ?? "/")
                + (components?.percentEncodedQuery.map { "?\($0)" } ?? "")
            for (key, value) in try device.authHeaders(method: "GET", pathAndQuery: target) {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        return try await receiveGET(request)
    }

    /// Special GET responses retain HTTPClient's status, size and JSON error semantics.
    private func receiveGET(_ request: URLRequest, textResponse: Bool = false) async throws -> JSONValue {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw TodexError.invalid("后端响应无效")
        }
        guard data.count <= 20 * 1024 * 1024 else {
            throw TodexError.invalid("后端响应过大")
        }
        guard (200..<300).contains(response.statusCode) else {
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
            throw TodexError.server(
                code: value?["code"].optionalString ?? String(response.statusCode),
                message: value?["message"].optionalString
                    ?? value?["error"]["message"].optionalString
                    ?? value?["error"].optionalString
                    ?? "HTTP \(response.statusCode)"
            )
        }
        if textResponse {
            guard let text = String(data: data, encoding: .utf8) else {
                throw TodexError.invalid("健康检查未返回有效文本")
            }
            return .string(text)
        }
        if data.isEmpty { return .null }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw TodexError.invalid("后端未返回有效 JSON")
        }
        return value
    }

    public func version() async throws -> JSONValue {
        try await http.request(path: "/v2/version", authenticated: false)
    }

    public func transportPolicy() async throws -> JSONValue {
        try await http.request(path: "/v2/transport-policy", authenticated: false)
    }

    public func createDevicePairing(clientPublicKey: String, deviceName: String) async throws -> JSONValue {
        try await http.request(
            .post, path: "/v2/device-pairing/create",
            body: [
                "clientPublicKey": .string(clientPublicKey), "deviceName": .string(deviceName),
            ], authenticated: false)
    }

    public func pollDevicePairing(requestId: String, proof: String) async throws -> JSONValue {
        try await http.request(
            .post, path: "/v2/device-pairing/poll",
            body: [
                "requestId": .string(requestId), "proof": .string(proof),
            ], authenticated: false)
    }

    /// Cancel proof uses a different derivation domain from poll proof.
    public func cancelDevicePairing(requestId: String, proof: String) async throws -> JSONValue {
        try await http.request(
            .post, path: "/v2/device-pairing/cancel",
            body: [
                "requestId": .string(requestId), "proof": .string(proof),
            ], authenticated: false)
    }

    public func workspaces() async throws -> [WorkspaceRecord] {
        let value = try await http.request(path: "/v2/workspaces")
        return try value["workspaces"].decoded([WorkspaceRecord].self)
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
        try await queryRequest(
            path: "/v2/workspace/entries",
            query: [
                "cwd": cwd, "query": query, "limit": String(limit),
            ])
    }

    public func workspaceDirectories(path: String? = nil, limit: Int? = nil) async throws -> JSONValue {
        var query: [String: String] = [:]
        query["path"] = path
        query["limit"] = limit.map(String.init)
        return try await queryRequest(path: "/v2/workspace/directories", query: query)
    }

    public func workspaceFile(path: String) async throws -> JSONValue {
        try await queryRequest(path: "/v2/workspace/file", query: ["path": path])
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
        try await queryRequest(path: "/v2/git/scan", query: ["workspacePath": workspacePath])
    }

    public func gitRun(_ request: JSONValue) async throws -> JSONValue {
        try await http.request(.post, path: "/v2/git/run", body: request)
    }

    public func gitWorkspace(workspacePath: String) async throws -> JSONValue {
        try await queryRequest(path: "/v2/git/workspace", query: ["workspacePath": workspacePath])
    }

    public func gitStatus(workspacePath: String) async throws -> JSONValue {
        try await queryRequest(path: "/v2/git/status", query: ["workspacePath": workspacePath])
    }

    public func gitOperation(_ request: JSONValue) async throws -> JSONValue {
        try await http.request(.post, path: "/v2/git/operation", body: request)
    }

    public func gitPullRequest(workspacePath: String) async throws -> JSONValue {
        try await queryRequest(path: "/v2/git/pull-request", query: ["workspacePath": workspacePath])
    }

    public func gitDiff(workspacePath: String, path: String) async throws -> JSONValue {
        try await queryRequest(
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

    public func providerUpgradeOperation(id: String) async throws -> JSONValue {
        try await http.request(path: "/v2/providers/upgrades/\(HTTPClient.segment(id))")
    }

    public func providerModels(provider: String, workspace: String) async throws -> JSONValue {
        try await queryRequest(path: "/v2/providers/models", query: ["provider": provider, "workspace": workspace])
    }

    public func providerImageInput(
        provider: String, workspace: String, profile: String? = nil, model: String? = nil
    ) async throws -> JSONValue {
        var query = ["provider": provider, "workspace": workspace]
        query["profile"] = profile
        query["model"] = model
        return try await queryRequest(path: "/v2/providers/image-input", query: query)
    }

    public func providerCommands(provider: String, workspace: String) async throws -> JSONValue {
        try await queryRequest(path: "/v2/providers/commands", query: ["provider": provider, "workspace": workspace])
    }

    public func skills(provider: String, workspace: String) async throws -> JSONValue {
        try await queryRequest(path: "/v2/catalog/skills", query: ["provider": provider, "workspace": workspace])
    }

    public func skillResource(id: String, provider: String, workspace: String) async throws -> JSONValue {
        try await queryRequest(
            path: "/v2/catalog/skills/\(HTTPClient.segment(id))",
            query: [
                "provider": provider, "workspace": workspace,
            ])
    }

    public func mcpCatalog(provider: String, workspace: String) async throws -> JSONValue {
        try await queryRequest(path: "/v2/catalog/mcp", query: ["provider": provider, "workspace": workspace])
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
        var query = ["afterSequence": String(after), "limit": String(limit)]
        // `summary` folds process-only events down to detailStub markers; the
        // full payloads for a sequence range are fetched on demand.
        if detail != "full" { query["detail"] = detail }
        return try await queryRequest(path: "\(conversationPath(conversationId))/events", query: query)
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
