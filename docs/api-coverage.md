# Swift API 覆盖与验证

核对日期：2026-09-10。以当前后端源码为准：

- 路由：[routes.rs](../../TodeX_backend/src/server/routes.rs)、[v2.rs](../../TodeX_backend/src/server/v2.rs)、[device_pairing.rs](../../TodeX_backend/src/server/device_pairing.rs)。
- WS 分派及 wire：[websocket.rs](../../TodeX_backend/src/server/websocket.rs)、[protocol.rs](../../TodeX_backend/src/server/protocol.rs)。
- 模型：[workspace_store.rs](../../TodeX_backend/src/workspace_store.rs)、[conversation/model.rs](../../TodeX_backend/src/conversation/model.rs)、[provider/types.rs](../../TodeX_backend/src/provider/types.rs)。共享客户端 [v2.ts](../../TodeX_protocol/src/v2.ts) 仅作交叉参考。

**45/45 个普通 HTTP method + path 已封装，57/57 个 WS 可识别命令已编目。** `GET /v2/ws` 是 WebSocket upgrade，单独列入协议覆盖，不计入 45 个普通 HTTP 接口。未添加已移除的 /v1 路由或不存在的 HTTP resume/fork/compact、配对 approve 接口。

## 验证范围

[APIClientTests.swift](../Packages/TodexCore/Tests/TodexCoreTests/APIClientTests.swift) 在 Swift 6.3.3、macOS 的临时包副本中通过：11 个 Swift Testing 测试函数，其中 `endpointWire` 包含 45 个参数用例，`httpErrors` 包含 4 个参数用例，其余 9 个函数分别验证模型、默认值、分页、错误和协议。依赖使用本机已缓存的 swift-sodium 0.11.0；包副本的 Package.swift 与工作区原文件一致。

这里的通过是 **URLProtocol 拦截 URLSession 实际构造请求后的本地契约测试**：逐项检查 HTTP method、编码后的 path、按后端规则解码的 query、设备签名头（x-todex-device-id/auth-ts/auth-nonce/auth-sig）、Accept/Content-Type、JSON body、返回值。fixture 使用独立的 .invalid 主机和 session；所有请求都被拦截。上述 URLProtocol 阶段没有启动或访问真实 backend，也没有调用真实 provider、Git、PTY、MCP、配对批准、升级或云任务。该阶段 WS 只验证编码、解码与源码支持状态；后续真实协议集成结果见文末。表中“已封装”不代表真实服务实测通过。

复现命令（在允许产生构建文件的包副本中执行）：

```sh
CLANG_MODULE_CACHE_PATH=/tmp/todex-api-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/todex-api-module-cache \
swift test --package-path /path/to/TodexCore-copy \
  --cache-path /tmp/todex-api-spm-cache \
  --config-path /tmp/todex-api-spm-config \
  --security-path /tmp/todex-api-spm-security \
  --disable-sandbox --filter APIClientTests
```

## HTTP 接口

实现：[APIClient.swift](../Packages/TodexCore/Sources/TodexCore/APIClient.swift)。下表各行测试名是 `endpointWire(方法名)` 的参数用例，均已通过；所有操作仍服从后端的认证、归属、信任、运行状态和能力检查。

| HTTP | 路径 | APIClient 方法 | 状态 / 语义 | 本地测试 |
| --- | --- | --- | --- | --- |
| GET | `/health` | `health()` | 已封装；公开；text/plain | `endpointWire(health)` |
| GET | `/v2/version` | `version()` | 已封装；公开 | `endpointWire(version)` |
| GET | `/v2/transport-policy` | `transportPolicy()` | 已封装；公开 | `endpointWire(transportPolicy)` |
| POST | `/v2/device-pairing/create` | `createDevicePairing(clientPublicKey:deviceName:)` | 已封装；公开；不代替本机配对批准 | `endpointWire(createDevicePairing)` |
| POST | `/v2/device-pairing/poll` | `pollDevicePairing(requestId:proof:)` | 已封装；公开；传入 poll proof | `endpointWire(pollDevicePairing)` |
| POST | `/v2/device-pairing/cancel` | `cancelDevicePairing(requestId:proof:)` | 已封装；公开；传入 cancel proof | `endpointWire(cancelDevicePairing)` |
| GET | `/v2/workspaces` | `workspaces()` | 已封装；认证；解包 workspaces | `endpointWire(workspaces)` |
| PUT | `/v2/workspaces` | `replaceWorkspaces(_:)` | 已封装；认证；后端按归属合并 | `endpointWire(replaceWorkspaces)` |
| DELETE | `/v2/workspaces/{workspace_id}` | `deleteWorkspace(id:)` | 已封装；认证 | `endpointWire(deleteWorkspace)` |
| GET | `/v2/workspaces/{workspace_id}/trust` | `workspaceTrust(id:)` | 已封装；认证 | `endpointWire(workspaceTrust)` |
| PUT | `/v2/workspaces/{workspace_id}/trust` | `updateWorkspaceTrust(id:trusted:)` | 已封装；认证 | `endpointWire(updateWorkspaceTrust)` |
| GET | `/v2/workspace/entries` | `workspaceEntries(cwd:query:limit:)` | 已封装；认证 | `endpointWire(workspaceEntries)` |
| GET | `/v2/workspace/directories` | `workspaceDirectories(path:limit:)` | 已封装；认证 | `endpointWire(workspaceDirectories)` |
| GET | `/v2/workspace/file` | `workspaceFile(path:)` | 已封装；认证 | `endpointWire(workspaceFile)` |
| PUT | `/v2/workspace/file` | `saveWorkspaceFile(path:text:expectedText:)` | 已封装；认证；比较原文后保存 | `endpointWire(saveWorkspaceFile)` |
| GET | `/v2/git/scan` | `gitScan(workspacePath:)` | 已封装；认证 | `endpointWire(gitScan)` |
| POST | `/v2/git/run` | `gitRun(_:)` | 已封装；认证；JSONValue 原样发送 | `endpointWire(gitRun)` |
| GET | `/v2/git/workspace` | `gitWorkspace(workspacePath:)` | 已封装；认证 | `endpointWire(gitWorkspace)` |
| GET | `/v2/git/status` | `gitStatus(workspacePath:)` | 已封装；认证 | `endpointWire(gitStatus)` |
| POST | `/v2/git/operation` | `gitOperation(_:)` | 已封装；认证；JSONValue 原样发送 | `endpointWire(gitOperation)` |
| GET | `/v2/git/pull-request` | `gitPullRequest(workspacePath:)` | 已封装；认证 | `endpointWire(gitPullRequest)` |
| GET | `/v2/git/diff` | `gitDiff(workspacePath:path:)` | 已封装；认证 | `endpointWire(gitDiff)` |
| POST | `/v2/browser/fetch` | `browserFetch(url:)` | 已封装；认证 | `endpointWire(browserFetch)` |
| GET | `/v2/providers` | `providers()` | 已封装；认证；解包 providers | `endpointWire(providers)` |
| GET | `/v2/providers/versions` | `providerVersions()` | 已封装；认证 | `endpointWire(providerVersions)` |
| POST | `/v2/providers/{provider}/upgrade` | `upgradeProvider(provider:)` | 已封装；认证；不自动重试 | `endpointWire(upgradeProvider)` |
| GET | `/v2/providers/upgrades/{operation_id}` | `providerUpgradeOperation(id:)` | 已封装；认证 | `endpointWire(providerUpgradeOperation)` |
| GET | `/v2/providers/models` | `providerModels(provider:workspace:)` | 已封装；认证；运行时发现 | `endpointWire(providerModels)` |
| GET | `/v2/providers/image-input` | `providerImageInput(provider:workspace:profile:model:)` | 已封装；认证；运行时能力 | `endpointWire(providerImageInput)` |
| GET | `/v2/providers/commands` | `providerCommands(provider:workspace:)` | 已封装；认证；运行时发现 | `endpointWire(providerCommands)` |
| GET | `/v2/agent-providers` | `agentProviders(agent:)` | 已封装；认证；可选 agent 过滤 | `endpointWire(agentProviders)` |
| PUT | `/v2/agent-providers/{agent}/{id}` | `upsertAgentProvider(agent:id:profile:)` | 已封装；认证；settingsConfig 不透明、掩码写回保留密钥 | `endpointWire(upsertAgentProvider)` |
| DELETE | `/v2/agent-providers/{agent}/{id}` | `deleteAgentProvider(agent:id:)` | 已封装；认证 | `endpointWire(deleteAgentProvider)` |
| POST | `/v2/agent-providers/{agent}/{id}/activate` | `activateAgentProvider(agent:id:modelId:)` | 已封装；认证；modelId 可选 | `endpointWire(activateAgentProvider)` |
| POST | `/v2/agent-providers/{agent}/import-live` | `importLiveAgentProvider(agent:id:name:)` | 已封装；认证；独占型捕获整份 live，叠加型按 id 收编 | `endpointWire(importLiveAgentProvider)` |
| GET | `/v2/agent-providers/{agent}/{id}/models` | `agentProviderModels(agent:id:)` | 已封装；认证；后端代理拉取、密钥不出后端 | `endpointWire(agentProviderModels)` |
| POST | `/v2/agent-providers/{agent}/{id}/models` | — | 未封装；保存前预览拉取，掩码密钥按同 id 档案/live 节点还原 | — |
| GET | `/v2/catalog/skills` | `skills(provider:workspace:)` | 已封装；认证 | `endpointWire(skills)` |
| GET | `/v2/catalog/skills/{resource_id}` | `skillResource(id:provider:workspace:)` | 已封装；认证 | `endpointWire(skillResource)` |
| GET | `/v2/catalog/mcp` | `mcpCatalog(provider:workspace:)` | 已封装；认证 | `endpointWire(mcpCatalog)` |
| GET | `/v2/conversations` | `conversations()` | 已封装；认证；解包 conversations | `endpointWire(conversations)` |
| POST | `/v2/conversations` | `createConversation(workspace:provider:profile:title:)` | 已封装；认证；返回 manifest | `endpointWire(createConversation)` |
| GET | `/v2/conversations/{conversation_id}` | `conversation(id:)` | 已封装；认证；返回 manifest | `endpointWire(conversation)` |
| PATCH | `/v2/conversations/{conversation_id}` | `updateConversation(id:patch:)` | 已封装；认证；返回 manifest | `endpointWire(updateConversation)` |
| DELETE | `/v2/conversations/{conversation_id}` | `deleteConversation(id:)` | 已封装；认证 | `endpointWire(deleteConversation)` |
| GET | `/v2/conversations/{conversation_id}/events` | `events(conversationId:after:limit:)`、`events(conversationId:before:limit:)` | 已封装；认证；保留 replay 外层字段 | `endpointWire(events)` |
| POST | `/v2/conversations/{conversation_id}/prompt` | `promptConversation(id:prompt:)` | 已封装；认证；JSONValue 原样发送 | `endpointWire(promptConversation)` |
| POST | `/v2/conversations/{conversation_id}/cancel` | `cancelConversation(id:)` | 已封装；认证 | `endpointWire(cancelConversation)` |
| POST | `/v2/conversations/{conversation_id}/interrupt` | `interruptConversation(id:)` | 已封装；认证；后端与 cancel 共用处理器 | `endpointWire(interruptConversation)` |
| POST | `/v2/conversations/{conversation_id}/permissions/{permission_id}` | `respondPermission(conversationId:permissionId:decision:)` | 已封装；认证；JSONValue 原样发送 | `endpointWire(respondPermission)` |
| GET | `/v2/kanban/tasks` | `kanbanTasks()` | 已封装；认证；解包 tasks | `endpointWire(kanbanTasks)` |
| PUT | `/v2/kanban/tasks` | `replaceKanbanTasks(_:)` | 已封装；认证；墓碑合并语义由后端负责 | `endpointWire(replaceKanbanTasks)` |

## Wire 与兼容细节

- `WorkspaceRecord` 保留约定的 15 个公开字段。时间为 Unix 毫秒整数，`init(name:path:)` 提供所有 Rust 必需字段；approvalPolicy 为 on-request，sandboxMode 为 workspace-write，model 留空供调用方/提供方决定。后端保存时重算 id/sessionId/tenantId；必须使用服务端返回的记录。threadId 缺省为空；配置可选字段允许缺省或 null。
- `ConversationManifest` 保留约定的公开字段，workspace 是路径字符串，provider/status 是开放字符串，时间保留 RFC 3339 原文。服务端附带的 schemaVersion/ownerId 不进入该公开模型；创建/更新请求使用独立请求体，不直接发送 manifest。
- `ProviderDescriptor.profiles` 是字符串数组；capabilities 和 models 的未知字段通过 JSONValue 保留。静态 WS 支持表不能取代运行时 provider 能力探测。
- `ConversationEvent` 使用整数 schemaVersion/sequence，字符串时间和开放 type/provider，保留 normalizedType/rawType/payload；历史事件缺少可选来源字段仍可解码。JSONValue 内部使用 Double，超过其精确整数范围的数值不额外获得精度保证。
- 创建会话发送 `workspace.path` 字符串和 `providerProfile`；不会发送整个 workspace 对象。nil profile/title 不入请求体。更新支持后端的 title/archived patch，原样保留调用方 JSON；无额外成功语义。
- 回放使用 `afterSequence` 和 `limit`（默认 200），返回完整 replay JSON，保留 nextSequence/hasMore。不会将缺失的列表字段悄悄当作空列表。反向翻页使用 `beforeSequence`（包含式上界）加 `limit`，返回 `sequence <= before` 的最后一页，`hasMore` 表示还有更早事件；下一页游标为本页首条 `sequence - 1`。旧后端忽略该参数时由调用方校验锚点并回退正向回放。
- 文件保存必需 `expectedText`。Git operation 的 wire 为 `{ "workspacePath": "…", "operation": { "action": "create-branch", "branchName": "…" } }`。权限回复 wire 为 `{ "outcome": "allow_once", "optionId": "…" }` 等后端决策结构。
- 复用现有 JSONValue、BackendConnection、HTTPClient，包括 URL 规范化、路径 segment 编码和 JSON 请求/错误处理。只在 APIClient 内处理两个例外：/health 的纯文本，以及查询值含字面量 + 的 GET。后者将 URLQueryItem 留下的 + 改为 %2B，避免被 Axum 的表单查询解析器变为空格；% 字符不重复解码。这两个分支使用同一个 session，并保留大小上限与 HTTP 错误语义，共同文件未修改。
- 默认 session 禁用重定向、缓存和 cookie；公开探测/配对方法不附带设备签名。额外的 `init(connection:session:)` 允许 URLProtocol 注入，调用方负责注入 session 的策略。
- 非 GET 网络失败沿用 HTTPClient 的 unknownOutcome；不重试写操作。401/409/501/302、无效 JSON、缺失必需字段、204 空响应及传输超时均有本地用例。配对封装只发送公钥/设备名或 proof；poll proof 与 cancel proof 的派生域不同，密码学过程不属于本文件封装。

## WebSocket 协议

实现：[ProtocolCatalog.swift](../Packages/TodexCore/Sources/TodexCore/ProtocolCatalog.swift)。`WebSocketCommandEnvelope` 为 Codable/Sendable 的 id/type/payload；可用 `ProtocolCatalog.Command` 构造，也允许未来的字符串 type。缺省 payload 解码为 null，与 V2Command 一致。

`WebSocketEventEnvelope` 处理可选 id/type/payload。原生 server.result/server.error 的 id 用于请求关联；conversation.event 无须 id。旧协议的 event_id、cursor、codex_session_id/thread_id/turn_id、workspace_id/window_id/pane_id 单独保留，不能把 journal event_id 当成请求 id。v2/local/terminal 请求通常使用 camelCase，旧 gateway/cloud/lifecycle 请求部分使用 snake_case；payload 的字段名不自动转换。

下表支持状态来自源码分派逻辑：Supported = 有处理器，Conditional = 还依赖提供方/资源/运行环境，Limited = 存在明确功能限制，Unsupported = 识别但后端明确拒绝或仅报告不支持。它们都不是实测标签。所有行由 `catalogMatchesRecognizedTypesAndHonestSupport` 核对清单，envelope 由 `commandAndEventEnvelopesMatchBothProtocols` 验证。

| WS 命令 | 后端支持状态 | 说明 |
| --- | --- | --- |
| `conversation.subscribe` | Supported | 回放至 high-water sequence，再转发实时事件并补齐缺口。 |
| `conversation.unsubscribe` | Supported | 释放该连接上的订阅槽位并停止转发任务；重复调用幂等。 |
| `conversation.create` | Supported | 已实现处理器；仍检查归属、能力及生命周期。 |
| `conversation.prompt` | Supported | 已实现处理器；仍检查归属、能力及生命周期。 |
| `conversation.followUp` | Supported | 已实现处理器；仍检查归属、能力及生命周期。 |
| `conversation.retry` | Supported | 已实现处理器；仍检查归属、能力及生命周期。 |
| `conversation.resume` | Unsupported | 原生 continuation 未实现；需要显式 followUp。 |
| `conversation.fork` | Conditional | 要求 provider 原生 fork/compact 能力。 |
| `conversation.compact` | Conditional | 要求 provider 原生 fork/compact 能力。 |
| `conversation.control` | Conditional | 需要 expectedTurnId 与 control；取决于 live control probe。 |
| `conversation.cancel` | Supported | 已实现处理器；仍检查归属、能力及生命周期。 |
| `conversation.interrupt` | Supported | 已实现处理器；仍检查归属、能力及生命周期。 |
| `conversation.stop` | Supported | 已实现处理器；仍检查归属、能力及生命周期。 |
| `conversation.permission.respond` | Supported | 已实现处理器；仍检查归属、能力及生命周期。 |
| `mcp.list` | Conditional | 统一 MCP 实现；依赖会话、资源和配置。 |
| `mcp.refresh` | Conditional | 统一 MCP 实现；依赖会话、资源和配置。 |
| `mcp.call` | Conditional | 统一 MCP 实现；依赖会话、资源和配置。 |
| `server.ping` | Supported | server.result 返回 pong=true。 |
| `session.resume` | Supported | 恢复已有 Codex 会话的 cursor 回放，不恢复 provider turn。 |
| `codex.gateway.control` | Limited | 仅 action=control 接受并审计；不执行 provider 操作，其余 action 不支持。 |
| `codex.local.start` | Conditional | 本地 Codex adapter 已实现；依赖 CLI、会话状态及允许的方法。 |
| `codex.local.status` | Conditional | 本地 Codex adapter 已实现；依赖 CLI、会话状态及允许的方法。 |
| `codex.local.stop` | Conditional | 本地 Codex adapter 已实现；依赖 CLI、会话状态及允许的方法。 |
| `codex.local.turn` | Conditional | 本地 Codex adapter 已实现；依赖 CLI、会话状态及允许的方法。 |
| `codex.local.input` | Conditional | 本地 Codex adapter 已实现；依赖 CLI、会话状态及允许的方法。 |
| `codex.local.steer` | Conditional | 本地 Codex adapter 已实现；依赖 CLI、会话状态及允许的方法。 |
| `codex.local.interrupt` | Conditional | 本地 Codex adapter 已实现；依赖 CLI、会话状态及允许的方法。 |
| `codex.local.approval.respond` | Conditional | 本地 Codex adapter 已实现；依赖 CLI、会话状态及允许的方法。 |
| `codex.local.request` | Conditional | 本地 Codex adapter 已实现；依赖 CLI、会话状态及允许的方法。 |
| `codex.local.replay` | Supported | 按 cursor 回放 owned gateway journal。 |
| `codex.local.attach` | Supported | 按 cursor 回放 owned gateway journal。 |
| `codex.local.snapshot` | Limited | 返回空 text，authoritative=false；实际内容需事件回放。 |
| `codex.local.unsupported` | Unsupported | 仅发出 UNSUPPORTED_LOCAL 错误事件。 |
| `terminal.start` | Conditional | 依赖 PTY、归属、信任与终端状态。 |
| `terminal.input` | Conditional | 依赖 PTY、归属、信任与终端状态。 |
| `terminal.stop` | Conditional | 依赖 PTY、归属、信任与终端状态。 |
| `terminal.resize` | Conditional | 依赖 PTY、归属、信任与终端状态。 |
| `terminal.status` | Conditional | 依赖 PTY、归属、信任与终端状态。 |
| `codex.thread.start` | Unsupported | 仅识别 schema，未调用上游 app-server；使用 conversation.* / codex.local.*。 |
| `codex.turn.start` | Unsupported | 仅识别 schema，未调用上游 app-server；使用 conversation.* / codex.local.*。 |
| `codex.turn.steer` | Unsupported | 仅识别 schema，未调用上游 app-server；使用 conversation.* / codex.local.*。 |
| `codex.turn.interrupt` | Unsupported | 仅识别 schema，未调用上游 app-server；使用 conversation.* / codex.local.*。 |
| `codex.mcp.server.listStatus` | Unsupported | 旧 MCP 处理器拒绝；统一 mcp.* 另有实现。 |
| `codex.mcp.resource.read` | Unsupported | 旧 MCP 处理器拒绝；统一 mcp.* 另有实现。 |
| `codex.mcp.tool.call` | Unsupported | 旧 MCP 处理器拒绝；统一 mcp.* 另有实现。 |
| `codex.mcp.server.refresh` | Unsupported | 旧 MCP 处理器拒绝；统一 mcp.* 另有实现。 |
| `codex.mcp.oauth.login` | Unsupported | 旧 MCP 处理器拒绝；统一 mcp.* 另有实现。 |
| `codex.mcp.elicitation.respond` | Unsupported | 旧 MCP 处理器拒绝；统一 mcp.* 另有实现。 |
| `codex.cloudTask.create` | Unsupported | 缺少云 HTTP adapter 调用，处理器拒绝。 |
| `codex.cloudTask.list` | Unsupported | 缺少云 HTTP adapter 调用，处理器拒绝。 |
| `codex.cloudTask.getSummary` | Unsupported | 缺少云 HTTP adapter 调用，处理器拒绝。 |
| `codex.cloudTask.getDiff` | Unsupported | 缺少云 HTTP adapter 调用，处理器拒绝。 |
| `codex.cloudTask.getMessages` | Unsupported | 缺少云 HTTP adapter 调用，处理器拒绝。 |
| `codex.cloudTask.getText` | Unsupported | 缺少云 HTTP adapter 调用，处理器拒绝。 |
| `codex.cloudTask.listSiblingAttempts` | Unsupported | 缺少云 HTTP adapter 调用，处理器拒绝。 |
| `codex.cloudTask.applyPreflight` | Unsupported | 缺少云 HTTP adapter 调用，处理器拒绝。 |
| `codex.cloudTask.apply` | Unsupported | 缺少云 HTTP adapter 调用，处理器拒绝。 |

协议清单还明确区分会话事件的 sequence 与旧 gateway 的 cursor。未知未来 command 的 descriptor 返回 nil；开放 event type/payload 仍可解码。加密协商、socket 连接和重连生命周期不由这两个 envelope 执行。


## 后续隔离真实后端集成

应后续要求新增 [fixture 启停脚本](../scripts/backend_fixture.py)、[可控假 CLI](../scripts/fake_provider.py)、[REST/WS 集成验证器](../scripts/backend_integration.py) 和 [使用说明](../scripts/README.md)。2026-09-10 15:37:50 UTC 在全新临时目录验证通过：**16 组检查、40 次实际 HTTP 请求**，另有真实 WebSocket、PTY 与本地 Git 操作。此阶段使用已有 Rust 可执行文件，SHA-256 为 `2e82c4ca33024574756e7207ec392e3cb1ddae4b78f220b658e03ca69cc01fa7`；不是对所有 43 个 HTTP 接口的全面实测。

| 实际集成范围 | 结果与边界 |
| --- | --- |
| /health、/v2/version、transport-policy | 实际监听、纯文本/JSON 返回通过；未运行包含外部版本查询的 providers/versions |
| HTTP/WS 认证 | 缺少签名与未注册设备签名均被拒绝；已注册设备签名建连成功 |
| workspaces、trust、providers/models | 保存后端规范化记录，确认归属/信任并发现 fake Codex 模型 |
| workspace/file、entries、directories | Unicode、空格及 + 路径通过；保存后读回一致，旧 expectedText 得到 409 且不覆盖文件 |
| git/scan、status、workspace、operation、run | 临时仓库真实扫描、分支创建和提交通过；无 push/PR |
| conversations POST/GET/PATCH、列表、prompt、permissions、cancel、events | 实际创建与元数据、审批往返、取消落盘、分页无缺口通过 |
| WS server.ping、conversation.create/subscribe/prompt/permission.respond/resume | 请求关联、事件流、游标重连回放通过；resume 确认返回 Unsupported |
| Codex / Claude | Rust adapter 启动受控假 CLI；Codex 原生审批/interrupt、Claude stream-json 审批/完成通过；无真实 AI 服务调用 |
| terminal.start/input/resize/stop | 真实 /bin/sh PTY，输出验证避免命令回显误判；测试终端已停止 |
| 错误边界 | 非法 id=400，不存在的合法 UUID=404，工作区外文件=403，未知 patch 字段=422 |

最终保留的本机 fixture：`http://127.0.0.1:49933`，根目录 `/private/tmp/todex-mobile-fixture-ke6n6g8s`。该目录的 `fixture.json` 保存 PID、配置/工作区和会话 ID；`device.txt` 与 `simulator-connection.json` 保存测试设备凭据；`integration-report.json`、`conversation-events.json` 和 `logs/provider-wire.jsonl` 保存证据。设备密钥未写入仓库。旧调试 fixture 已关闭，最终服务继续运行供同机 iOS Simulator 连接。

实际模拟器 UI、Swift APIClient 直连、加密 WS、真实 AI/MCP/云任务、CLI 升级、配对密码学均未在此阶段验证。已完成的 Python 集成不能代替这些检查。启动/停止方法和假 CLI 提示指令见 scripts/README.md。

## 移动端后续验证

Swift Foundation WebSocket、AppSession 竞态、模拟器 UI 和唯一一次真实 Codex 请求的分层结果已汇总到 [validation.md](validation.md)。这些结果不改变上表对后端 Unsupported / Conditional 能力的判断。
