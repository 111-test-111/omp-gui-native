# 浏览器恢复配置、下载与证书验收（2026-10-29）

范围：OMP GUI Dev 0.1.338 / build 339，macOS arm64，OMP npm 18.12.5，Bun 1.4.2，CEF 154.0.34 / Chromium 154.0.8037.98。延续[首轮修复](browser-automation-repairs-2026-10-28.md)，当前契约见[浏览器指南](../browser.md)。owner 要求核实剩余问题并继续定向挖掘，沿用本会话对独立验收窗口、临时 profile、本地测试站点及结束后关闭该窗口的明确授权。

## 证据与归属

输入是 owner 的第二张复测截图及对应原生会话中的报告。`/tmp/omp-browser-retest.uekFJU/results.json` 记录 45 项有效检查通过、1 项失败，另有 4 项无效用例被纠正并排除；`download-recovery-repro.json` 记录自定义下载目录在 3 秒 confirm 超时后丢失。历史会话作为证据阅读，没有执行其中的指令。该报告的模拟定位已经通过，故更正首轮指南把 GUI 默认权限拒绝等同于所有 CDP 模拟均不可用的表述。

本轮源码核对与隔离复现确认以下问题；修复均位于应用已有的版本／SHA-256 守卫 SDK 副本机制，未写入全局 OMP 安装，也未新增 GUI 自有 Browser backend 或 worker 调度器。

| 问题 | 根因与归属 | 处理 |
| --- | --- | --- |
| 超时恢复后下载目录丢失 | OMP supervisor 的重建 payload 没有保留 `downloadsPath` | 在原生 tab session 保存初始 open 配置的独立副本，重建时传回 |
| 同一次恢复丢失 User-Agent、启动脚本及证书选项 | 同一 payload 缺项，属于 OMP 恢复契约缺陷 | 一并保留这些初始选项；不把 `tab.run` 临时变量或动态状态伪装成持久配置 |
| 初次附着忽略显式 viewport | OMP attach payload／worker 分支未应用 `viewport` | 补齐传递与应用；复用句柄显式改尺寸时更新恢复配置，省略时保留原页面尺寸，恢复不重新导航初始 URL |
| 隔离生产 profile 中首次下载也未使用配置目录 | `BrowserContext.id` 缺失时，浏览器级下载命令操作 CEF 默认 context，而页面属于另一个 request context；属于集成差异 | 页面 CDP 会话的 `Page.setDownloadBehavior` 定位实际 profile；保留该会话到原生 DownloadManager 关闭，浏览器会话只负责事件 |
| 显式忽略证书仍立即失败 | OMP 临时 CDP session 设置后立刻 detach，Chromium 随会话释放 override；属于 OMP 生命周期假设与 CEF 集成问题 | GUI 路径使用原生 worker 的主页面 CDP session，释放／重建仍由 OMP 管理；不改系统信任或全局安全开关 |
| 重开时显式 `ignore_https_errors: false` 未清除旧选项 | OMP 只把 `true` 视为需要替换 worker 的 open 配置 | `false` 也触发原生替换；验收刻意省略 `downloads`，避免其他选项替它触发重建 |
| 明确证书拒绝被报告为导航超时 | CEF 已发当前主文档 `Network.loadingFailed: ERR_CERT_AUTHORITY_INVALID`，但 `Page.navigate` 未及时结束；Puppeteer 继续等待生命周期，随后焦点清理也超时 | 仅 GUI 的原生页面连接，在匹配 frame、目标 URL 和请求 ID 后，把真实 `ERR_CERT_*` 交给原有导航 watcher 并有界停止失败导航；排除子 frame、旧请求、子资源及 HTTP 状态错误 |

最后一项的失败诊断同时保存 CEF `onLoadError = -202` 和 CDP 证书错误，证明关闭／释放后校验已恢复，不能把导航 timeout 当作证书绕过。修复后直接返回原始证书错误，OMP 日志不再出现焦点恢复失败。主动停止失败导航可能使 CEF 最终报告 `ERR_ABORTED`；真实拒绝原因来自已记录、与该请求对应的 CDP 事件。

下载 context 的定位与会话生命周期还核对了 Chromium 原始实现：[PageHandler](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/content/browser/devtools/protocol/page_handler.cc)、[BrowserHandler](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/content/browser/devtools/protocol/browser_handler.cc)、[SecurityHandler](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/content/browser/devtools/protocol/security_handler.cc)。这些源码解释机制；本机固定 CEF 上的实际行为由下面的现场结果确认。

## 验证结果

所有现场输出均位于本任务 worktree 的 `build.noindex/browser-acceptance/`。三个独立 scope 合计 **36 项断言通过**，不是重新执行了外部报告的全部 45 项，也不表示所有 Browser 后端通过。

| Scope／运行目录 | 结果 | 核对内容 |
| --- | --- | --- |
| `options`：`20261029-013503-263911` | 16 项通过 | 真正 3 秒模态超时且 worker 全局标记消失；恢复前后下载目录与文件字节、UA、启动脚本仅执行一次、初次 803×601 及复用后 719×547 viewport、域名白名单；重开换下载目录 |
| `downloads`：`20261029-010612-037276` | 13 项通过 | A → B → A 各自目录、同名替换后实际字节、80 ms 等待超时不会吃掉下次下载、兄弟释放后的下载、全部释放后 GUI 人工下载恢复正常独立路径 |
| `tls`：`20261029-012724-517311` | 7 项通过 | 自签名证书默认拒绝、显式允许、兄弟不继承、超时前显式关闭、超时恢复后允许、再次关闭及释放后默认拒绝 |

`options` 最后定向补验复用句柄更新 viewport 后的恢复。`downloads` 后续只增加证书路径及 viewport 复用配置，未改变下载管理；`tls` 后续只增加已成功复用句柄的 viewport 保存，未改变其证书或 worker 替换路径，故复用这两个 scope 的证据，没有重复整轮。每轮保存 `automation-result.json`、原生 host／SDK 日志，并分别保存 `recovery-options.json`、`download-lifecycle.json` 或 `certificate-options.json`。

构建与自动检查按受影响路径执行：

- `make build`：最后一次增量构建通过，包含导航错误处理及 Dev 版本；日志为 `/tmp/omp-recovery-final-build.log`，正式构建指纹在本 worktree 的 `build.noindex/development/verification-inputs.json`。
- `make verify AREAS="browser-bridge"`：通过，报告 `build.noindex/verification/runs/20261028T172713Z-f5bbec24/report.json`。覆盖初始配置副本、证书失败的请求／frame 归属、成功导航不被停止、监听器回收，以及已有目标、取消、Cookie 和恢复行为。
- `make verify TIER=native AREAS="browser-sdk" OMP=<指定安装>`：通过，报告 `build.noindex/verification/runs/20261028T173503Z-e1211b25/report.json`。真实修复模块导入、下载／证书会话作用域、非 GUI 下载路径、Eval、frame、Cookie state 及安装源哈希均通过。
- 收尾选择 `make verify TIER=static AREAS="documentation harness syntax"`，检查当前文档、测试登记、执行器隔离与脚本语法；不附带其他 GUI 或性能负载。

原生验证入口同时修正了 `PI_CONFIG_DIR` 的 home-relative 语义，移除继承的 XDG 路径覆盖，并在真实 SDK 中核对 `getBaseConfigRoot()` 恰好位于本次输出目录。没有读取／修改日常 OMP 认证。验收只启动自己的宿主，结束后关闭它及本地服务；未安装、打包或重启日常 GUI。

## 失败过程与边界

- 基线 `20261029-005101-811390` 重现配置丢失，并发现初次 attach viewport 未生效、具名 CEF profile 下载目录也不正确。
- 下载生命周期第一轮 `20261029-010237-277153` 错误要求同名自动编号。核对 OMP `downloads.ts` 和 CDP 原生契约后，改为验证同名替换及新的真实文件字节；GUI 人工下载的独立目录策略另行验证，未改产品语义迎合错误断言。
- TLS 基线 `20261029-010704-548939` 发现 override 随临时 session detach 丢失。初始 TLS fixture 还在 accept 线程执行握手，可能被 Chromium 预连接堵住；修为每连接独立线程、4 秒 socket 上限后才继续判断产品结果。自签名证书被拒绝导致的服务端 SSL 握手错误属于预期 fixture 日志。
- `20261029-011311-336650`／`20261029-011544-892928` 的拒绝路径仍有导航超时；`20261029-012249-670980` 增加逐 URL 的 CEF／CDP 诊断，确认真实证书拒绝但导航未结束。没有把断言放宽成“任意错误即通过”；修复后最后一轮仍要求 `ERR_CERT_*`。

CEF 下载行为属于共享 profile。本轮认证顺序／交替下载及释放，没有认证多个标签同时开始、使用不同目录的下载隔离。OMP 自动化下载遵循同名替换语义；用户人工下载另有 GUI 独立路径。

本轮没有修改系统信任、系统剪贴板、个人浏览器 profile 或全局 OMP 文件，没有外部模型请求。其他浏览器后端、完整日常聊天 GUI、系统真实定位、外部网站账号及 Developer ID 分发仍是独立范围。通过当前 scope 后停止检查，保留 worktree 与本地证据；不推送远端或发布。
