# Swift API 覆盖与验证

核对日期：2026-09-10；CLI 安装与 Agent 供应商导出/导入于 2026-09-28 补充；Agent 桌面工具（Agent 浏览器、Computer Use）于 2026-10-06 补充。以当前后端源码为准：

- 路由：[routes.rs](../../TodeX_backend/src/server/routes.rs)、[v2.rs](../../TodeX_backend/src/server/v2.rs)、[device_pairing.rs](../../TodeX_backend/src/server/device_pairing.rs)。
- WS 分派及 wire：[websocket.rs](../../TodeX_backend/src/server/websocket.rs)、[protocol.rs](../../TodeX_backend/src/server/protocol.rs)。
- 模型：[workspace_store.rs](../../TodeX_backend/src/workspace_store.rs)、[conversation/model.rs](../../TodeX_backend/src/conversation/model.rs)、[provider/types.rs](../../TodeX_backend/src/provider/types.rs)。共享客户端 [v2.ts](../../TodeX_protocol/src/v2.ts) 仅作交叉参考。

**67/67 个普通 HTTP method + path 已封装，72/72 个 WS 可识别命令已编目（含 2026-10-06 补充的 13 个 `history.*` 命令）。** `GET /v2/ws` 是 WebSocket upgrade，单独列入协议覆盖，不计入 67 个普通 HTTP 接口；`POST /v2/device-pairing/reveal`（配对 v3）与传输隧道 `POST /v2/sealed` 也不计入。

**传输 v2（2026-10-07 起）**：`HTTPClient` 不再有开关，按配置推导：协议与公钥由设备验证批准后一次写入并标记 `transportVerified`（2026-10-08 起，配对 v3 的 transcript 绑定后端传输协议与公钥）；已验证地固定协议与公钥时，所有 REST（含 `/health`、本机回环）都经 `POST /v2/sealed` 封装，WebSocket 用 `tv=2`；未固定公钥的远程后端在发出任何请求前即被拒绝并提示加密配对；已固定但未经验证的公钥（旧版本保存的配置）在任何主机（含本机回环）都被拒绝并提示重新配对，已验证但缺协议或缺公钥的配置按公钥无效拒绝；仅未固定公钥的本机回环后端走明文。配对链接（二维码）只读取 `serverUrl`（版本 1 或 2），分片二维码已删除。配对路由由独立的 bootstrap 客户端直连（不签名、不走隧道）。旧的 `todex.crypto.v1` 帧与配对 v2 已删除，APIClient 也不再封装 v2 配对接口。未添加已移除的 /v1 路由或不存在的 HTTP resume/fork/compact、配对 approve 接口。

## 验证范围

[APIClientTests.swift](../Packages/TodexCore/Tests/TodexCoreTests/APIClientTests.swift) 最近于 2026-09-28 在 Swift 6.4、macOS 上以 `swift test --package-path Packages/TodexCore` 通过：18 个 Swift Testing 测试函数，其中 `endpointWire` 包含 67 个参数用例，`httpErrors` 包含 4 个参数用例，其余 16 个函数分别验证模型、默认值、分页、错误、协议、CLI 安装字段、供应商导出文件与 Agent 桌面工具模型（2026-10-06 起）。依赖使用本机已缓存的 swift-sodium 0.11.0；包副本的 Package.swift 与工作区原文件一致。

这里的通过是 **URLProtocol 拦截 URLSession 实际构造请求后的本地契约测试**：逐项检查 HTTP method、编码后的 path、按后端规则解码的 query、设备签名头（x-todex-device-id/auth-ts/auth-nonce/auth-sig）、Accept/Content-Type、JSON body、返回值。fixture 使用独立的 127.0.0.0/8 主机（未固定公钥的本机配置按传输 v2 规则走明文）和 session；所有请求都被拦截。上述 URLProtocol 阶段没有启动或访问真实 backend，也没有调用真实 provider、Git、PTY、MCP、配对批准、升级或云任务。该阶段 WS 只验证编码、解码与源码支持状态；后续真实协议集成结果见文末。表中“已封装”不代表真实服务实测通过。

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
| GET | `/v2/version` | `version()` | 已封装；已配对时签名（数据目录与工作区根路径仅返回给已认证请求），未配对回退为不签名 | `endpointWire(version)`、`versionIsSignedWhenEnrolledAndFallsBackToUnsignedWhenNot` |
| GET | `/v2/transport-policy` | `transportPolicy()` | 已封装；公开 | `endpointWire(transportPolicy)` |
| POST | `/v2/device-pairing/create` | `DevicePairingSession.begin`（配对 v3，发 `clientCommitment` 与 `transportBinding: 1`；校验响应的 `transportProtocol`/`transportPublicKey`，`none` 仅限本机回环） | 公开；直连、不签名、不走 `/v2/sealed`；不代替本机配对批准 | `PairingTests`、`actualPairingV3EnrollsADeviceThatThenConnects` |
| POST | `/v2/device-pairing/reveal` | `DevicePairingSession.begin`（揭示公钥与 nonce 后才显示随机码） | 同上 | 同上 |
| POST | `/v2/device-pairing/poll` | `DevicePairingSession.poll()`（v3 poll proof；批准密文以完整 v3 transcript 为 AAD，明文的 `deviceId` 与传输协议/公钥须与本机及 create 响应逐字一致，`.approved` 携带待固定的传输） | 同上 | 同上 |
| POST | `/v2/device-pairing/cancel` | `DevicePairingSession.cancel()`（v3 cancel proof） | 同上 | 同上 |
| GET | `/v2/workspaces` | `workspaces()`、`workspaceCatalog()` | 已封装；认证；解包 workspaces；`workspaceCatalog()` 另保留 rejected（目录在后端不可用的已存工作区） | `endpointWire(workspaces)`、`workspaceCatalogKeepsRejectedRecordsApart` |
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
| GET | `/v2/git/log` | `gitLog(workspacePath:skip:limit:)` | 已封装；认证；旧后端 404 时 Git 菜单显示“需更新后端” | `endpointWire(gitLog)` |
| GET | `/v2/git/diff` | `gitDiff(workspacePath:path:)` | 已封装；认证 | `endpointWire(gitDiff)` |
| POST | `/v2/browser/fetch` | `browserFetch(url:)` | 已封装；认证 | `endpointWire(browserFetch)` |
| GET | `/v2/providers` | `providers()` | 已封装；认证；解包 providers | `endpointWire(providers)` |
| GET | `/v2/providers/versions` | `providerVersions()` | 已封装；认证；未安装为 `installed: false`/`status: "notInstalled"` 且无 error；缺少 `installSupported` 视为不可安装（`CLIManagement`） | `endpointWire(providerVersions)` |
| POST | `/v2/providers/{provider}/upgrade` | `upgradeProvider(provider:)` | 已封装；认证；不自动重试 | `endpointWire(upgradeProvider)` |
| POST | `/v2/providers/{provider}/install` | `installProvider(provider:)` | 已封装；设备签名；仅未安装时（否则 409）；返回与升级相同的操作对象，`action: "install"`；不自动重试 | `endpointWire(installProvider)`、`cliInstallFieldsDefaultForOlderBackends` |
| GET | `/v2/providers/upgrades/{operation_id}` | `providerUpgradeOperation(id:)` | 已封装；认证；安装与升级共用；缺少 `action` 视为升级 | `endpointWire(providerUpgradeOperation)` |
| GET | `/v2/providers/models` | `providerModels(provider:workspace:)` | 已封装；认证；运行时发现 | `endpointWire(providerModels)` |
| GET | `/v2/providers/image-input` | `providerImageInput(provider:workspace:profile:model:)` | 已封装；认证；运行时能力 | `endpointWire(providerImageInput)` |
| GET | `/v2/providers/commands` | `providerCommands(provider:workspace:)` | 已封装；认证；运行时发现 | `endpointWire(providerCommands)` |
| GET | `/v2/agent-providers` | `agentProviders(agent:)` | 已封装；认证；可选 agent 过滤 | `endpointWire(agentProviders)` |
| PUT | `/v2/agent-providers/{agent}/{id}` | `upsertAgentProvider(agent:id:profile:)` | 已封装；认证；settingsConfig 不透明、掩码写回保留密钥 | `endpointWire(upsertAgentProvider)` |
| DELETE | `/v2/agent-providers/{agent}/{id}` | `deleteAgentProvider(agent:id:)` | 已封装；认证 | `endpointWire(deleteAgentProvider)` |
| POST | `/v2/agent-providers/{agent}/{id}/activate` | `activateAgentProvider(agent:id:modelId:)` | 已封装；认证；modelId 可选 | `endpointWire(activateAgentProvider)` |
| POST | `/v2/agent-providers/{agent}/import-live` | `importLiveAgentProvider(agent:id:name:)` | 已封装；认证；独占型捕获整份 live，叠加型按 id 收编 | `endpointWire(importLiveAgentProvider)` |
| GET | `/v2/agent-providers/{agent}/export` | `exportAgentProviders(agent:)` | 已封装；设备签名；返回后端原始字节（`todex.agent-providers` v1 文件，密钥为明文） | `endpointWire(exportAgentProviders)`、`agentProviderTransferTravelsVerbatim` |
| POST | `/v2/agent-providers/{agent}/import` | `importAgentProviders(agent:transfer:)` | 已封装；设备签名；文件字节原样作为请求体；按 id upsert，保留文件外的供应商与当前供应商；返回该 Agent 的 bucket；错 agent/格式/版本、重复 id、掩码密钥为 400。上传前 `AgentProviderTransfer.providerCount(in:agent:)` 做轻量校验 | `endpointWire(importAgentProviders)`、`agentProviderTransferEnvelopeIsCheckedBeforeUpload` |
| GET | `/v2/agent-providers/{agent}/{id}/models` | `agentProviderModels(agent:id:)` | 已封装；认证；后端代理拉取、密钥不出后端 | `endpointWire(agentProviderModels)` |
| POST | `/v2/agent-providers/{agent}/{id}/models` | `previewAgentProviderModels(agent:id:settingsConfig:)` | 已封装；认证；保存前按编辑表单预览拉取，掩码密钥按同 id 档案/live 节点还原 | `endpointWire(previewAgentProviderModels)` |
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
| GET | `/v2/agent-desktop` | `agentDesktop()` | 已封装；设备签名；解码为 `AgentDesktopSettings`；HTTP 404 表示后端早于桌面工具，缺少 `computer`/`browser` 表示旧版（桌面端执行）后端 | `endpointWire(agentDesktop)`、`agentDesktopModelsAcceptLegacyDaemonsAndDecodeDataURLs` |
| PUT | `/v2/agent-desktop` | `setAgentDesktop(enabled:computerEnabled:)` | 已封装；设备签名；只发送给出的字段（`enabled` 和/或 `computerEnabled`） | `endpointWire(setAgentDesktop)` |
| POST | `/v2/agent-desktop/computer/permissions` | `requestComputerPermissions()` | 已封装；设备签名；在后端主机上弹出屏幕录制/辅助功能授权 | `endpointWire(requestComputerPermissions)` |
| GET | `/v2/conversations/{conversation_id}/agent-desktop/frame` | `agentDesktopFrame(conversationId:capability:)` | 已封装；设备签名；`.screen`（默认，无 query）为 Computer Use 画面，未控制屏幕时 404；`.browser` 加 `?capability=browser` 为浏览器标签页，无标签页时 404 | `endpointWire(agentDesktopFrame)` |
| DELETE | `/v2/conversations/{conversation_id}/agent-desktop` | `revokeAgentDesktop(conversationId:capability:)` | 已封装；设备签名；`capability` 为 `browser`/`screen`，缺省同时撤销 | `endpointWire(revokeAgentDesktop)` |
| GET | `/v2/conversations/{conversation_id}/agent-shots/{shot_id}` | `agentShot(conversationId:shotId:)` | 已封装；设备签名；`desktop.*.action` 事件记录的截图 | `endpointWire(agentShot)` |
| POST | `/v2/agent-browser/install` | `installAgentBrowser()` | 已封装；设备签名；开始下载固定版本 Chromium，进度见 `browser.chromium` | `endpointWire(installAgentBrowser)` |
| GET | `/v2/agent-browser/profiles` | `agentBrowserProfiles()` | 已封装；设备签名 | `endpointWire(agentBrowserProfiles)` |
| POST | `/v2/agent-browser/profiles` | `createAgentBrowserProfile(name:)` | 已封装；设备签名；返回新档案 | `endpointWire(createAgentBrowserProfile)` |
| PUT | `/v2/agent-browser/profiles/{id}` | `renameAgentBrowserProfile(id:name:)` | 已封装；设备签名；返回全部档案 | `endpointWire(renameAgentBrowserProfile)` |
| DELETE | `/v2/agent-browser/profiles/{id}` | `deleteAgentBrowserProfile(id:)` | 已封装；设备签名；连同 Cookie、存储与缓存删除 | `endpointWire(deleteAgentBrowserProfile)` |
| PUT | `/v2/agent-browser/workspaces` | `assignAgentBrowserProfile(workspace:profileId:)` | 已封装；设备签名；`workspace` 为工作区 id（无 id 时为路径），该工作区已打开的标签页会关闭 | `endpointWire(assignAgentBrowserProfile)` |

## Wire 与兼容细节

- `WorkspaceRecord` 保留约定的 15 个公开字段。时间为 Unix 毫秒整数，`init(name:path:)` 提供所有 Rust 必需字段；approvalPolicy 为 on-request，sandboxMode 为 workspace-write，model 留空供调用方/提供方决定。后端保存时重算 id/sessionId/tenantId；必须使用服务端返回的记录。threadId 缺省为空；配置可选字段允许缺省或 null。
- `ConversationManifest` 保留约定的公开字段，workspace 是路径字符串，provider/status 是开放字符串，时间保留 RFC 3339 原文。服务端附带的 schemaVersion/ownerId 不进入该公开模型；创建/更新请求使用独立请求体，不直接发送 manifest。
- `ProviderDescriptor.profiles` 是字符串数组；capabilities 和 models 的未知字段通过 JSONValue 保留。静态 WS 支持表不能取代运行时 provider 能力探测。
- `ConversationEvent` 使用整数 schemaVersion/sequence，字符串时间和开放 type/provider，保留 normalizedType/rawType/payload；历史事件缺少可选来源字段仍可解码。JSONValue 内部使用 Double，超过其精确整数范围的数值不额外获得精度保证。
- 创建会话发送 `workspace.path` 字符串和 `providerProfile`；不会发送整个 workspace 对象。nil profile/title 不入请求体。更新支持后端的 title/archived patch，原样保留调用方 JSON；无额外成功语义。
- 回放使用 `afterSequence` 和 `limit`（默认 200），返回完整 replay JSON，保留 nextSequence/hasMore。不会将缺失的列表字段悄悄当作空列表。反向翻页使用 `beforeSequence`（包含式上界）加 `limit`，返回 `sequence <= before` 的最后一页，`hasMore` 表示还有更早事件；下一页游标为本页首条 `sequence - 1`。旧后端忽略该参数时由调用方校验锚点并回退正向回放。
- 文件保存必需 `expectedText`。Git operation 的 wire 为 `{ "workspacePath": "…", "operation": { "action": "create-branch", "branchName": "…" } }`。权限回复 wire 为 `{ "outcome": "allow_once", "optionId": "…" }` 等后端决策结构。
- 供应商导出/导入不经 JSONValue 往返：JSONValue 以 Double 存数字且不保留键顺序，而 settingsConfig 是不透明 JSON。导出直接返回响应字节（仅校验为 JSON 对象），导入用 `HTTPClient.request(_:path:jsonData:)` 原样发送并照常签名。
- 复用现有 JSONValue、BackendConnection、HTTPClient，包括 URL 规范化、路径 segment 编码和 JSON 请求/错误处理。只在 APIClient 内处理两个例外：/health 的纯文本，以及查询值含字面量 + 的 GET。后者将 URLQueryItem 留下的 + 改为 %2B，避免被 Axum 的表单查询解析器变为空格；% 字符不重复解码。这两个分支使用同一个 session，并保留大小上限与 HTTP 错误语义，共同文件未修改。
- 默认 session 禁用重定向、缓存和 cookie；公开探测/配对方法不附带设备签名。额外的 `init(connection:session:)` 允许 URLProtocol 注入，调用方负责注入 session 的策略。
- 非 GET 网络失败沿用 HTTPClient 的 unknownOutcome；不重试写操作。401/409/501/302、无效 JSON、缺失必需字段、204 空响应及传输超时均有本地用例。配对封装只发送公钥/设备名或 proof；poll proof 与 cancel proof 的派生域不同，密码学过程不属于本文件封装。

## WebSocket 协议

实现：[ProtocolCatalog.swift](../Packages/TodexCore/Sources/TodexCore/ProtocolCatalog.swift)。`WebSocketCommandEnvelope` 为 Codable/Sendable 的 id/type/payload；可用 `ProtocolCatalog.Command` 构造，也允许未来的字符串 type。缺省 payload 解码为 null，与 V2Command 一致。

`WebSocketEventEnvelope` 处理可选 id/type/payload。原生 server.result/server.error 的 id 用于请求关联；conversation.event 无须 id。旧协议的 event_id、cursor、codex_session_id/thread_id/turn_id、workspace_id/window_id/pane_id 单独保留，不能把 journal event_id 当成请求 id。v2/local/terminal 请求通常使用 camelCase，旧 gateway/cloud/lifecycle 请求部分使用 snake_case；payload 的字段名不自动转换。

下表支持状态来自源码分派逻辑：Supported = 有处理器，Conditional = 还依赖提供方/资源/运行环境，Limited = 存在明确功能限制，Unsupported = 识别但后端明确拒绝或仅报告不支持。它们都不是实测标签。所有行由 `catalogMatchesRecognizedTypesAndHonestSupport` 核对清单，envelope 由 `commandAndEventEnvelopesMatchBothProtocols` 验证。

| WS 命令 | 后端支持状态 | 说明 |
| --- | --- | --- |
| `conversation.subscribe` | Supported | 以 `detail: summary` 回放，最多 `backfillLimit` 条；`hasMore` 时经 HTTP 补齐至 `lastSequence`，再转发实时事件并补齐缺口。 |
| `conversation.unsubscribe` | Supported | 释放该连接上的订阅槽位并停止转发任务；重复调用幂等。客户端本地预算 120（后端上限 128），按最久未用淘汰空闲订阅。 |
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
| `agentBrowser.watch` | Supported | 2026-10-06 补充。开始推送该会话 Agent 浏览器标签页的 `agentBrowser.frame`（base64 JPEG；连接慢时只保留最新帧；`closed: true` 表示无标签页）；每连接最多 8 个。`RealtimeClient` 把帧放入独立的 `browserFrames`（只保留最新 8 帧），不进入 `events` 与事件日志；`AppSession` 重连后重新发送仍在观看的会话。 |
| `agentBrowser.unwatch` | Supported | 停止该会话的帧推送；幂等。 |
| `history.encryption.get` | Conditional | 2026-10-06 补充，会话历史端到端加密（[规格](../../TodeX_backend/docs/history-encryption.md) §7）。返回 `{mode, epoch, recipients[], myRid?, grants[], myAccess?, revokedDevices[]}`，`mode` 恒为 `e2e`；`myAccess=revoked` 时本机停止自动登记并禁用历史操作；`HistoryAPI` 封装，后端尚未实现时客户端静默视为不支持。2026-10-07 起历史强制加密，`history.encryption.enable` / `.disable` 已从后端与客户端删除。写入错误：`HISTORY_KEY_REQUIRED`（409，尚无接收方，客户端重新登记本机密钥）、`HISTORY_READ_ONLY`（409，旧版未加密对话 `legacyPlaintext` 只读）。 |
| `history.recipient.register` / `.revoke`、`history.recovery.set` | Conditional | 登记本机 X-Wing 公钥（连接后自动）、吊销接收方、上传恢复密钥公钥。 |
| `history.grant.request` / `.list` / `.dismiss` / `.fulfill` | Conditional | 旧历史授权：本机在本地解包后为目标 `rid` 重新封装，每批 ≤500，`HistoryGrant` 按页记录进度可续跑；导入恢复密钥时以空 `grantId` 自授权。 |
| `history.keys.list` / `.wraps` | Conditional | 枚举 `kid` 与取回封装；`HistoryDecryptor` 按需取回并以有界 LRU 缓存 DEK。 |
| `history.device.restore` | Conditional | 解除被吊销设备的永久封锁（吊销设备接收方即封锁该 `deviceId`，其历史命令除 `history.encryption.get` 外均返回 `HISTORY_ACCESS_REVOKED`/403）；返回同 get。恢复后该设备以新密钥登记，旧历史需重新授权。 |
| 推送 `history.encryption.updated` | Supported | 全局帧（非 `conversation.event`），不含密钥材料。客户端防抖后重读状态；`grant.progress`/`grant.fulfilled` 且 `rid` 为本机时清空解密器不可用缓存，重新解密已载入的锁定对话（`conversationIds` 或全部）。 |

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
