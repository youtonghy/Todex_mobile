# TodeX 移动端验证记录

验证日期：2026-09-10 至 2026-09-11，Asia/Taipei。代码位于 `Todex_mobile`；后端和桌面端作为协议参考，未修改。

## 构建与设备

- 原生 Swift 6 + UIKit，使用 Xcode 27 beta 6（27A5252f）、Swift 6.4、iOS 27 SDK 构建；部署下限为 iOS / iPadOS 26.0。
- 应用及 `TodexUITests` 的 `build-for-testing` 成功，SwiftTerm 的 Metal Toolchain 已安装。此处为模拟器构建，未配置用户的签名团队，未验证真机安装或 App Store 提交。
- iPhone 17 Pro / iOS 27：聊天、原生审批、草稿保留、窄屏切换，以及富文本、文件保存、真实 PTY、浏览器后端预览和 Git 共 3 项 UI 测试通过。
- iPhone 17 Pro / iOS 26.5：4/4 UI 测试通过，含最大辅助字体与深色模式；同一 SDK 27 构建可以在已安装的 26.5 runtime 运行。未单独安装 26.0 runtime。
- iPad Pro 11-inch (M5) / iPadOS 27：6/6 UI 测试通过，包括横屏双栏、深色最大辅助字体、富文本、工作台完整流程、后端持久化重启回归，以及 Composer `/` 命令与 `@` 文件提及的内联建议（`testComposerInlineSuggestions`）。
- 默认测试与视觉验证设备为 iPad Pro 11-inch (M5) / iPadOS 27 模拟器（UDID `C7B85E55-DB33-47BE-B4F9-1F9214F9185C`）。

两组 4 项测试分别在 2026-09-11 00:29:39 与 00:32:23（Asia/Taipei）通过。浏览器同时验证了后端 loopback 文本预览和设备 WKWebView 直接加载。UI 测试发现并修正了隐藏面板的键盘焦点、超大字体的首页头部高度、工作台标签对比度与终端按键换行。

最后将超大字体下较长的工作区名称改为单行中间截断，重新构建并单独回归辅助字体测试，00:33:38 通过；其它操作流程没有再修改。

本机原始结果：

- [iOS 26.5 · 4 项通过](/private/tmp/todex-mobile-fixture-ke6n6g8s/ui-3E414370-B1F2-4ADF-B17E-93B4368202FA-1789057667.xcresult)
- [iPadOS 27 · 4 项通过](/private/tmp/todex-mobile-fixture-ke6n6g8s/ui-C7B85E55-DB33-47BE-B4F9-1F9214F9185C-1789057824.xcresult)
- [iPadOS 27 · 6 项通过](/private/tmp/todex-mobile-fixture-spdhta6q/ui-C7B85E55-DB33-47BE-B4F9-1F9214F9185C-1789148709.xcresult)

已查看并保留的原始模拟器截图：[iPad 双栏](screenshots/ipad-conversation-workbench.png)、[离线公式与代码](screenshots/ipad-markdown-math.png)、[iPhone 对话](screenshots/iphone-conversation.png)、[原生审批](screenshots/iphone-approval.png)、[深色辅助字体](screenshots/iphone-dark-large-text.png)、[真实 PTY](screenshots/iphone-terminal.png)。

Apple 发布的最新 [Xcode 27 RC（27A266a）](https://developer.apple.com/news/releases/?id=09092026h) 需要登录下载，本机未取得该安装包。本次 beta 6 的结果不代表 RC 已通过。

## 核心与竞态

| 验证层 | 结果 | 主要覆盖 |
| --- | --- | --- |
| TodexCore | Swift Testing 报告 80 tests / 7 suites 通过；其中 2 个可选 live test 在普通运行中跳过 | API 线协议、Rust 加密向量、nonce/伪造/重放、配对取消竞态、HTTP 错误与超时、事件序号缺口和缓存边界 |
| Foundation WebSocket → 真实 Rust | 2 个测试 / 3 个参数场景通过 | 缺失/错误认证、ping、回放、Codex 和 Claude 的发送→审批→完成及重连 |
| AppSession / LocalStore | 14/14 独立场景通过 | connect/replay 单次并发执行、HTTP 与实时事件交错、分页、迟到响应隔离、切换后端、草稿保护、原子待发送记录、磁盘失败、后台暂停、流溢出、fixture 环境不覆盖真实后端目录 |
| 离线 Markdown / TeX | 全部断言通过 | 6 种公式分隔形式、5 个代码/转义/不完整公式案例、表格、HTML/危险链接、公式长度上限 |

核心测试源码在 [TodexCoreTests](../Packages/TodexCore/Tests/TodexCoreTests)，渲染检查在 [test_renderer.cjs](../scripts/test_renderer.cjs)。[AppSession runner](../scripts/run_session_tests.sh) 使用真实的 AppSession/LocalStore 源码，替换 HTTP、Socket 和 Keychain，独立于 XCTest 计数；从全新临时构建目录重跑的 13 个场景同样全部通过，源码已保存在仓库。

## 隔离真实后端

真实 Rust 二进制 SHA-256：`2e82c4ca33024574756e7207ec392e3cb1ddae4b78f220b658e03ca69cc01fa7`，版本 `DEV0.0.0`。已有二进制可能与源码 checkout 不同，以上 hash 是实际运行对象。

[backend_integration.py](../scripts/backend_integration.py) 完成 **16 组检查、40 次 HTTP 请求**，另有 WebSocket、真实 `/bin/sh` PTY 与临时 Git 仓库。验证了保存读回、`expectedText` 冲突不覆盖、审批决定传至假 CLI、取消后持久化完成、分页和重连无序号缺口。详细接口分层及 41 HTTP / 56 WS 支持表见 [api-coverage.md](api-coverage.md)。

最终假 CLI fixture 保持运行于 `http://127.0.0.1:49933`，目录 `/private/tmp/todex-mobile-fixture-ke6n6g8s`。配置、数据、Token、工作区和 CLI HOME 全部隔离；Token 没有写入仓库。模拟器连接同机 loopback；真机需要填写它能够访问的后端地址。

## 唯一一次真实 Provider 请求

[完整记录](real-provider-validation.md)：HTTP 请求没有指定模型，真实 Codex 确认使用 `gpt-6-astra`，权限为 `ask` / `workspace-write`。只提交一次，未重试，输出精确为 `TODEX_MOBILE_LIVE_OK`；用户消息持久化序号 2，完成事件序号 24，时间为 `2026-09-10T16:07:07.985576Z`。

没有工具或子代理调用。16,207 input / 11 output tokens，金额未知。这个请求由集成 harness 发起，不计为移动端 UI 的真实模型测试。临时真实后端已停止，授权的认证符号链接已移除；没有第二次真实模型请求。

## 尚未实测及后端限制

- 加密帧有 Rust 互通向量和传输单元测试，未进行实际加密 WebSocket 的端到端测试。相机二维码、完整设备配对和真机后台行为仍需设备验收。
- 未执行实际 CLI 升级、Git push/PR、云任务或外部 MCP 调用。按当前后端能力保留明确不可用状态。
- Codex Fast 缺少统一会话的后端 API，UI 明确禁用；原生 resume 等 Unsupported 操作不伪造成功。
- 长时间后台运行、系统回收、网络故障下的 iOS 生命周期无法仅由这些测试穷尽。应用保留未确认发送并暂停队列，不自动重发可能已经执行的操作。

## 复现

构建、fixture 启停、Swift 测试及模拟器命令见 [README](../README.md) 和 [scripts/README.md](../scripts/README.md)。临时日志和 `.xcresult` 为本机证据，可能被系统清理；测试源码与本报告保留在仓库。
