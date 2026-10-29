# 浏览器面板关闭主窗口修复验收（2026-10-27）

用户报告打开 Browser 后窗口立即消失，再点应用图标仍一闪而过。检查时旧版 0.1.315 主进程仍存活，采样显示主线程正常等待 AppKit 事件，没有对应的新崩溃报告。

## 原因与改动

CefSwift 的 `do_close` 默认返回 0。CEF 的 macOS 实现会向内嵌视图所在的最外层 NSWindow 发送 `performClose:`，所以内嵌页拆卸会连带关闭应用窗口；参见固定版本的 [CEF 关闭路径](https://github.com/chromiumembedded/cef/blob/14c5a08/libcef/browser/native/browser_platform_delegate_native_mac.mm#L310)。本地 wrapper 对应用嵌入的页面改为异步移除自己的原生子视图，由视图析构触发 CEF `WindowDestroyed` / `on_before_close`；CEF 自建窗口及 OSR 保留各自关闭行为。

页面改为持有 `CefBrowserHostView`，不再嵌套会随 SwiftUI 挂载拆卸的 `NSHostingView<CefWebView>`。异步创建等待 profile 就绪，待创建页面可取消，迟到的旧页面关闭不会清除新页面；关闭完成前不 shutdown CEF。

旧版日志还报告无法创建 `profiles/Profiles/<UUID>`。该 CEF 版本要求 profile 是数据根的直接子目录，非法嵌套路径回退为临时 profile；参见 [ChromeBrowserContext](https://github.com/chromiumembedded/cef/blob/14c5a08/libcef/browser/chrome/chrome_browser_context.cc#L86)。改为 `profiles/Profile-<UUID>`，保留会话隔离。初始 CDP 定位 URL 使用 Chromium 的小写形式，并禁止写入保存的导航。

## 本次证据

环境为 Apple Silicon、macOS 27.2、Swift 6.4，Dev 0.1.316 / build 317。所有构建和生成数据均在任务 worktree。owner 单独授权运行并退出隔离验收宿主，未退出或覆盖日常应用进程。

- 一次增量 `make build` 通过。
- `make verify AREAS=workspace-browser`：34 项通过，不启动 CEF；报告 `build.noindex/verification/runs/20261027T111633Z-4faa5304/report.json`。
- `python3 tests/acceptance/workspace_browser.py --run`：链接实际生产模块和面板，Chromium sandbox 开启；首次进程 22 项、第二次启动 10 项，共 32 项通过。检查首次 profile、兄弟标签、两个可见窗口之间的宿主转移、拆卸后恢复、单页关闭时两个窗口均保留、创建期间关闭、CEF 有序退出、profile 写盘和重启恢复。报告 `build.noindex/browser-acceptance/20261027-192226-566284/{first,restart}.json`。
- 初始验收包将 framework 指向原产物的符号链接，触发 sandbox 拒绝；改用包内 APFS clone。验收进程与日常 app 共用 bundle 激活身份导致窗口不能取得焦点；验收包及 helper 改为一致的独立身份后通过。profile 的 Preferences 在干净退出时落盘，检查按此时序执行，并在运行时核对 Cookie 数据库。这些失败没有通过关闭 sandbox 或放宽生产关闭断言处理。
- 静态文档、测试执行器和语法检查通过；收尾仅重跑受文档和验收驱动修改影响的检查。

重启日志仍有一次 Chromium `blink.mojom.Widget` 消息拒绝，未影响任何生命周期断言；没有将无错误日志作为通过条件。

此验收覆盖生产浏览器面板的窗口与页面生命周期。完整聊天应用的用户现场重启、真实 OMP 会话交互、网页输入法／辅助功能、外部账号、Developer ID 分发和能耗仍是独立边界，未由本次结果替代。
