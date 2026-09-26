# TodeX for iPhone & iPad

原生 Swift + UIKit 客户端，使用 iOS / iPadOS 27 SDK 构建，最低支持 26.0。界面采用 UIKit Liquid Glass、TodeX 的青绿色强调色与浅灰蓝背景，支持系统深浅色、动态字体和宽屏双栏。

## 构建与运行

打开 `Todex.xcodeproj`，选择 `Todex` scheme 和 iPhone / iPad 模拟器。真机安装需要在 Signing & Capabilities 中选择自己的开发团队。仓库不包含签名证书或访问令牌。

本次使用 `/Applications/Xcode-beta.app` 的 Xcode 27 beta 6（27A5252f），Swift 6.4、iOS 27 SDK。SDK 版本与部署下限分别为 27.0 和 26.0。终端依赖 SwiftTerm 1.20.0，首次构建需要 Xcode 对应的 Metal Toolchain：

Apple 已于 2026-09-09 发布 [Xcode 27 RC（27A266a）](https://developer.apple.com/news/releases/?id=09092026h)。官方 RC 下载入口要求 Apple Developer 登录，本次没有取得该安装包；下面的构建记录指本机已安装的 beta 6，不能等同于 RC 或 App Store 提交验证。

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild -downloadComponent MetalToolchain
xcodebuild -project Todex.xcodeproj -scheme Todex \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
```

SwiftTerm 的固定版本构建插件只生成源代码版本信息。上述命令适用于已核对该依赖的命令行构建；在 Xcode 中也可以直接允许该插件。`project.yml` 是 XcodeGen 项目源，增加源文件或修改目标后运行 `xcodegen generate`。仓库中的 Xcode 项目可直接打开，无须先安装 XcodeGen。

## 使用

1. 打开「连接与设置」，添加后端地址和 Token，或者导入配对 JSON、二维码照片、相机二维码。支持完整二维码与 ML-KEM 分片二维码，也可以申请设备验证并在后端确认随机码。
2. 连接后添加并信任一个后端目录，再选择可用的 Agent 创建对话。首页可搜索、折叠工作区、置顶、重命名、归档、恢复与删除对话。
3. 手机上通过顶部切换「对话 / 操作台」。窗口宽度达到 900pt 且为 regular size class 时同时显示两栏；iPad 分屏和窗口缩放会重新适配。
4. 在操作台打开终端、文件、浏览器和 Git 标签。终端及文件可以引用到聊天输入框；工作台标签可按对话或工作区保存。

## 已实现

| 范围 | 行为 |
| --- | --- |
| 连接 | 多后端配置（首页可查看其他后端缓存的工作区并切换）、Keychain Token、普通/X25519/ML-KEM-768 传输、设备配对；前台无限次退避重连（最长 30 秒），认证或加密配置错误停止重连；每条连接最多 120 个订阅，超出时退订最久未用的空闲对话；未打开的对话也订阅状态，首页实时显示运行、审批与未读 |
| 对话 | REST 历史和 WebSocket 流式事件共用 reducer；连续序号恢复、去重、审批失效防护、待核对消息保留 |
| 输入 | 独立草稿、UTF-8 文本和压缩图片附件（可编辑文本附件；粘贴图片或超过 5 行的文本自动转为附件）、Skills 引用、可搜索的模型选择与默认模型的思考深度、权限/计划模式、候选消息队列（支持后端原生队列的 Agent 直接使用原生队列）、首条消息前更换 Agent、本地 `/plan` `/model` `/permissions` `/copy` `/diff` `/skills` `/mcp` `/approve` 命令、iPad 键盘 ⌘↩ 发送 / ⌘. 停止 |
| 消息 | 离线 Markdown、代码复制、表格、KaTeX 公式、工具卡片（名称、关键参数，参数/输出/错误分栏）与思考折叠、进度旁白单独显示、引用、导出；每轮用量与上下文占用环；按阅读位置跟随输出；已发附件回执可预览（本地 JPEG 缩略图与 ≤100 KB 文本，150 条/2 MB 上限） |
| 审批 | 命令、文件、权限、计划反馈、多问题回答、extension UI、MCP schema 表单与 URL elicitation；多条待审批同时列出；会话级审批跨轮次保留，provider runtime 停止时失效 |
| 控制 | 根据能力启用取消、引导、实时模型配置、原生队列、重试、分叉（首页可直接分叉未打开的对话）和压缩；运行 2 分钟无进展、压缩失败/完成/建议压缩、配置未生效均有提示 |
| 工作台 | SwiftTerm PTY（退出后指数退避自动重启）、多标签、文件树/搜索/语法高亮预览/编辑、原文比较保存、Git 状态/操作/差异与多仓库选择、对话标题栏 Git 摘要、浏览器与后端预览、工作区 HTML 预览与元素检查 |
| 设置 | Agent 供应商账户与模型切换（Codex/Claude Code/Grok Build/Pi/OpenCode，表单/JSON 双模式编辑、保存前预览模型列表）、CLI 版本和升级进度、Skills/MCP/命令目录、跨对话用量统计（每日柱状图与缓存构成）、分类连接诊断、深浅色、工作台共享方式；调试构建可在「关于」导出脱敏调试日志 |

## 协议与限制

`Packages/TodexCore` 提供 47 个 HTTP method/path 封装和全部 57 个已识别 WebSocket 命令的支持表。详细依据和测试映射见 [API coverage](docs/api-coverage.md)。接口存在、后端实现、远程 Agent 可用性和本次实测是不同层次，应用会保留错误与未确认状态。

- **Codex Fast**：当前统一对话的 prompt/configure 接口没有 serviceTier 字段。独立的 `codex.local.*` adapter 也不能定位统一对话的运行进程，因此禁用 Fast。需要后端增加带能力检查和确认响应的统一 API；移动端不会仅修改按钮状态来表示生效。
- **恢复和后台**：iOS 不保证后台长连接。回到前台会立即重连并核对会话历史；断线、后台和应用重启后候选消息队列暂停，需要用户恢复。未确认的发送不自动重试。后端对单个订阅的错误（`EVENT_STREAM_LAGGED`、带 `conversationId` 的转发失败）只重新订阅该对话，不断开整条连接；无法归属的错误仍会断开并把未确认操作标为结果未知。
- **通知**：开启后，当前没有在看的对话完成时发送本地通知（前台显示横幅）。
- **语言**：界面支持简体中文、English、日本語、한국어，跟随系统，或在系统「设置 › TodeX › 语言」单独指定；应用设置里的「语言」行会跳转过去。桌面端是在应用内切换语言。
- **PTY**：后端不提供终端历史重放。应用在内存中为最近 8 个终端各保留至多 256 KB 输出（不落盘），切换对话后重放；离开期间、断线或进入后台时的输出仍可能缺失，会明确提示并查询 PTY 状态。操作台标签关闭与远端 PTY 结束是独立动作。
- **文件与预览**：遵循后端的根目录、类型和大小限制。保存携带 `expectedText`，冲突后需重新核对；后端浏览器抓取仅是 GET 文本快照，不能完整代理交互式站点或二进制资源。
- **尚未实现的后端能力**：原生 resume、旧版 MCP/云任务等返回 Unsupported 的命令保留明确状态，不伪造结果。权限强度由具体 Agent 的 enforcement 决定，应用不会把 agent policy 描述为操作系统沙箱。
- **附件**：最多 6 个、合计 2.5 MB；发送前验证当前模型的图片能力。相册图片缩放至最长 1600px。应用只请求用户选择的照片，不读取整库。
- **数据**：Token 不编码进配置 JSON。草稿、队列与历史缓存写入受保护的 Application Support；设备离线缓存不替代后端权威记录。当前支持单个应用窗口，iPad 的系统分屏/窗口缩放可用。

## 验证

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --package-path Packages/TodexCore
```

核心测试涵盖 Rust 加密互通向量、伪造和重放、设备验证取消竞态、HTTP 线协议、序号缺口、重复/迟到事件、用量的未知值和缓存语义。UI 测试目标为 `TodexUITests`。

[隔离后端脚本](scripts/README.md) 启动实际 Rust daemon、临时工作区、真实 PTY 和 Git 仓库，使用假 Codex/Claude CLI 验证协议。构建、核心测试、会话竞态和模拟器结果见 [验证报告](docs/validation.md)。另有经授权完成的 [一次真实 Codex 请求](docs/real-provider-validation.md)，其临时后端已经停止。

## 依赖

- [SwiftTerm 1.20.0](https://github.com/migueldeicaza/SwiftTerm/tree/1.20.0)：原生终端。
- [swift-sodium 0.11.0](https://github.com/jedisct1/swift-sodium/tree/0.11.0)：libsodium 兼容传输；ML-KEM 使用系统 CryptoKit。
- [markdown-it 14.1.0](https://github.com/markdown-it/markdown-it/tree/14.1.0) 和 [KaTeX 0.16.22](https://github.com/KaTeX/KaTeX/tree/v0.16.22)：随应用本地打包，许可证在 `Todex/Resources/Chat`。Markdown 禁用原始 HTML，公式禁用 trust；消息中的远程图片按链接显示，点击外链才打开浏览器。
- [highlight.js 11.11.1](https://github.com/highlightjs/highlight.js/tree/11.11.1)：离线代码高亮，许可证随应用打包；消息内代码块走 WebView，工作台文件预览复用同一库在 JavaScriptCore 中高亮。
