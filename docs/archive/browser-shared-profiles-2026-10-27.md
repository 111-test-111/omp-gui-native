# 浏览器共享 profile 与登录持久化验收（2026-10-27）

owner 要求把每个会话独立的浏览器站点存储改为全 GUI 共用所选 profile，设置支持选择／新建空白 profile，切换在应用重启后生效，并实际验证登录态持久化。本次仅启动和退出任务 worktree 内的隔离验收宿主；没有重启日常应用、使用真实账号或改写系统 Chrome、OMP 配置及日常 GUI 数据。

## 实现

- [配置模型](../../OMPGUI/Core/Models/BrowserProfiles.swift)保存固定默认身份、命名 profile 列表及下次启动的选择，恢复时校验数据与身份。在第一次读取应用设置时固定本次运行的选择，包括尚未启动 Chromium 的情况。
- [运行时](../../OMPGUI/Services/Browser/EmbeddedBrowserRuntime.swift)持有唯一 `CefProfile`，所有会话的页面共用它；所有页面退出后才释放 profile 并 shutdown CEF。标签、导航和下载仍保留会话归属。
- [浏览器设置](../../OMPGUI/App/Views/Settings/BrowserSettingsPage.swift)复用原生 Picker、共享 Chrome 输入弹层及玻璃按钮。创建空白 profile 自动选中，切换未生效时显示当前配置及重启提示，新增文案提供 zh-Hans。
- 数据使用 `browser/profiles/Profile-Shared-<profile UUID>`，旧会话目录保留且不自动迁移。新共享默认 profile 首次使用需要登录；切回已用 profile 保留其站点数据。

## 执行与结果

环境：Apple Silicon、macOS 27.2、Swift 6.4，Dev 0.1.322 / build 323，固定 CEF 154.0.34 / Chromium 154.0.8037.98，sandbox 开启。构建和 fixture 数据均在本任务 worktree 的 `build.noindex/`。

- 一次 `make build` 通过。
- `make verify AREAS="workspace-browser settings"`：浏览器功能 127 项、设置 34 项通过；不启动 CEF。原始报告：`build.noindex/verification/runs/20261027T150436Z-2241afc7/report.json`。
- `python3 tests/acceptance/workspace_browser.py --run --profiles`：链接实际生产模块与浏览器面板，本机 HTTP 服务器实际接收表单提交并设置 HttpOnly 的有到期时间 Cookie 和无到期时间会话 Cookie。使用生产页面的精确 CDP target 读取服务端认证结果和真实站点存储，没有直接向数据库写入 Cookie。五次进程启动共 **75 项断言通过**，原始目录：`build.noindex/browser-acceptance/20261027-230621-460834/`。

| 启动 | 生效 profile | 认证与存储结果 |
| --- | --- | --- |
| first | 默认 | 初始完全空白；表单登录 account-a；其他会话立即共享；设置变更及关闭全部标签均不丢失／混用登录 |
| persisted | 默认 | 重启恢复 account-a 的两类 Cookie、localStorage、IndexedDB；选择另一 profile 仅影响下次启动 |
| blank | 新建 | 没有 account-a 的任何 Cookie 或站点存储；实际登录 account-b |
| restored | 默认 | 切回后恢复 account-a 的两类 Cookie 和站点存储 |
| blank-restored | 新建 | 再切回后恢复 account-b，两份 profile 各自保留账号 |

- `--run --profile-settings`：CUA 操作实际中文设置页，验证空名称时“创建配置”禁用，填写“工作账号”后创建成功、自动选中并显示“当前配置：默认配置。重启 OMP GUI 后切换。”；原生选择器切回默认时提示消失，再选“工作账号”时提示恢复。退出前记录的 `settings.json` 确认保存选择与本次生效身份不同。原始目录：`build.noindex/browser-acceptance/20261027-230659-640746/`。

已检入[结构化结果](../evaluations/2026-10-27-browser-profiles/summary.json)，包括五阶段断言、CUA 最终配置及功能检查结果。

## 失败分析与边界

验收驱动首次编译误把项目的 `JSONValue` 当成 `Decodable`，改用已有 `JSONValue.parse`。首次 CDP 就绪探测发送了二进制 WebSocket 帧，页面已经加载但没有有效协议回复；改为 CDP 的 JSON 文本帧后五阶段通过。两者均为验收驱动缺陷，没有修改生产行为或放宽登录断言。设置页的离屏 bitmap 呈黑色，不作为视觉证据；布局与交互由 CUA 的实际窗口截图和操作核对。

本次证明本机 HTTP 登录、真实 Cookie／站点存储及隔离生产面板进程重启的行为。外部站点的 OAuth、反自动化策略、服务端到期／撤销、Release Keychain、Developer ID 包、VoiceOver／IME、完整聊天应用现场重启及能耗仍需各自验收；不从本机 fixture 推断这些路径已通过。
