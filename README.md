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
| 连接 | 多后端配置、Keychain Token、普通/X25519/ML-KEM-768 传输、设备配对、前台重连 |
| 对话 | REST 历史和 WebSocket 流式事件共用 reducer；连续序号恢复、去重、审批失效防护、待核对消息保留 |
| 输入 | 独立草稿、UTF-8 文本和压缩图片附件、Skills 引用、模型/思考深度/权限/计划模式、候选消息队列 |
| 消息 | 离线 Markdown、代码复制、表格、KaTeX 公式、工具与思考折叠、引用、导出；按阅读位置跟随输出；已发附件回执（本地 JPEG 缩略图，150 条/2 MB 上限） |
| 审批 | 命令、文件、权限、计划反馈、多问题回答、extension UI、MCP schema 表单与 URL elicitation |
| 控制 | 根据能力启用取消、引导、实时模型配置、原生队列、重试、分叉和压缩 |
| 工作台 | SwiftTerm PTY、多标签、文件树/搜索/语法高亮预览/编辑、原文比较保存、Git 状态/操作/差异、浏览器与后端预览 |
| 设置 | Agent 供应商账户与模型切换（Codex/Claude Code/Grok Build/Pi/OpenCode）、CLI 版本和升级进度、Skills/MCP/命令目录、统计、深浅色、工作台共享方式 |

## 协议与限制

`Packages/TodexCore` 提供 47 个 HTTP method/path 封装和全部 57 个已识别 WebSocket 命令的支持表。详细依据和测试映射见 [API coverage](docs/api-coverage.md)。接口存在、后端实现、远程 Agent 可用性和本次实测是不同层次，应用会保留错误与未确认状态。

- **Codex Fast**：当前统一对话的 prompt/configure 接口没有 serviceTier 字段。独立的 `codex.local.*` adapter 也不能定位统一对话的运行进程，因此禁用 Fast。需要后端增加带能力检查和确认响应的统一 API；移动端不会仅修改按钮状态来表示生效。
- **恢复和后台**：iOS 不保证后台长连接。回到前台会核对会话历史；断线、后台和应用重启后候选消息队列暂停，需要用户恢复。未确认的发送不自动重试。
- **PTY**：后端不提供终端历史重放。断线或进入后台后会明确提示可能缺失输出，并查询 PTY 状态。操作台标签关闭与远端 PTY 结束是独立动作。
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
