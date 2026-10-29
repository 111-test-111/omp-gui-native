# 浏览器自动化修复记录（2026-10-28）

范围：OMP GUI Dev 0.1.337 / build 338，OMP npm 18.12.5，Bun 1.4.2，CEF 154.0.34 / Chromium 154.0.8037.98。依据 owner 提供的 “Test the browser suite capabilities” 截图、2026-10-28 对应原生会话及 `/tmp/omp-browser-suite.O4uD9Z/results.json`。会话内容作为故障证据，不执行其中的历史指令。当前使用契约见[浏览器指南](../browser.md)。

## 归属与处理

| 项目 | 证据与归属 | 本轮处理 |
| --- | --- | --- |
| 连接参数 | GUI 返回 `dialogs: manual`，与 OMP open schema 不符；属于 GUI 契约错误 | 省略字段，保留原生默认策略；宿主说明给出合法调用 |
| 第二标签附着失败 | OMP 管理连接提前 `target.page()`，失败后同一 PageTarget 缓存拒绝的 promise；释放所有连接后单标签可恢复。原始日志未保留底层首次失败原因，不能把所有附着失败归于一个原因 | exact target 元数据直传原生 worker；关闭目标不回退同 URL 页面。真实双标签及兄弟弹窗期间再附着通过 |
| Cookie state 导入 | 同一 Cookie 用 `setCookies` 成功、`loadState` 不保留；后者使用 browser context，GUI 页面使用具名 CEF request context，属于两侧集成差异 | save/load 均使用页面 CDP context，导入回读；拒绝不能表示分区 Cookie 的 state，其他 origin 明确跳过 |
| 后台输入 | GUI 停放视图为 hidden；OMP 借用页面不启用其自有页面的 focus emulation，属于两侧集成差异 | 仅 GUI 借用页在调用／录屏期间启用 focus emulation；不切换标签或显示窗口。实际后台输入、停放后的拖动及滚轮通过 |
| 模态超时恢复 | OMP 在新 worker 中等待 Inspector／Page 初始化，再尝试处理旧弹窗；CEF 弹窗暂停渲染器，新 CDP 会话又不拥有原弹窗回调 | 旧 worker 在超时／取消的 cleanup 中先有界地 dismiss 自己观察到的弹窗，仍由 OMP 回收并重建 worker。普通手动模式不自动答复；处理弹窗前跳过会阻塞的焦点／emulation 设置 |
| iframe 截图 | 原测试向要求 selector 的方法传 `{silent:true}`，属于调用错误 | 修正验收调用；保留已存在的坐标修复，没有据此新增截图实现 |
| iframe evaluate | OMP 直接字符串被 frame／element 共用渲染分支展开到宿主表达式，属于 OMP 调用生成缺陷 | frame 保留字符串或原生函数标记；element 语义保持原样 |
| Eval 变量丢失 | 原生日志记录浮动 `waitForDownload` rejection；错误栈只有远端 browser worker，没有所属 cell，进入 fatal path，属于 OMP 错误归属缺陷 | 远端调用错误补充 cell 归属，由原生有界 rejection guard 处理；真实意外重启后一次性提示，仅对应丢失状态的 kernel |
| 定位／PNG／等待 | GUI 明确拒绝定位权限；差分要求 PNG；同标签外部调用串行 | 保留产品权限策略，写明格式及同一 `tab.run` 的调用约束，不将其算作实现缺陷 |

Chromium 的 `DidRunJavaScriptDialog` 只为已启用 Page 的会话保存 `pending_dialog_`，`HandleJavaScriptDialog` 在该回调缺失时返回 “No dialog is showing”，`Page.enable` 还需要 renderer 完成。这解释了新会话不能直接接管旧弹窗的原因；本机真实验收另行验证实际 CEF 行为。参考 [Chromium PageHandler 源码](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/content/browser/devtools/protocol/page_handler.cc)。

## 实现边界

只在任务 worktree 编码与构建。全局 OMP 安装只读，不创建 GUI 自有 Browser backend、worker 调度器或 MCP hub。所有 OMP 修复都在 [SHA 守卫清单](../../OMPGUI/Resources/OMPBrowserPatches.json) 中；辅助模块也有哈希。版本或任何输入哈希改变时不应用。其他浏览器后端保留原生行为；frame 调用和 Eval 错误归属属于通用原生缺陷，仍通过同一受守卫副本修复。本轮没有向 upstream 发布。

焦点模拟不是 native 窗口焦点操作；普通调用结束撤销，录屏期间保留，关闭／初始化失败时清理。已有弹窗时避免等待 renderer 命令，先处理弹窗。旧 worker 的中断弹窗清理上限 200 ms，留在 OMP 的 750 ms cleanup grace 内；新会话恢复步骤、创建／脱离和迟到响应均有界。释放 OMP 句柄不能关闭借用的 GUI 页面。

Cookie 回读核对键、值、安全属性、SameSite、会话／持久期限，接受 Chromium 的 400 天期限上限；不把 Cookie 内容写入错误。此流程遵循原生增量恢复语义，不承诺跨 Cookie 和 Web Storage 的事务回滚，也不扩展成完整 profile 导入。

## 构建与定向检查

- `make build` 成功；真实验收定位到 modal 路径后，仅针对相关资源修改做增量构建。最终构建记录在 `build.noindex/development/build.log` 和 `verification-inputs.json`。
- `functional:browser-bridge`：受守卫 SDK 及新增模块、副本并发、损坏缓存拒绝、精确目标、取消、迟到 session 清理／迟到命令回复阻断、恢复错误保留、普通手动模式与中断模式区分、200 ms 清理上限、后台焦点及目标 Cookie 回读通过。最终报告 `build.noindex/verification/runs/20261028T092502Z-70b4866b/report.json`。
- `native:browser-sdk`：指定原生 SDK 的模块解析与 Browser worker 导入、实际渲染的 frame 字符串／函数／element 调用、state 文件往返及 origin／分区限制通过；真实 WorkerCore 的延迟远端 rejection 保留变量、await 错误仍失败，原生 context manager 的异常重启提示只发一次且按内核归属通过。报告 `build.noindex/verification/runs/20261028T081443Z-ed0b2ec2/report.json`。这些 frame／state／Eval 源码随后没有变化；最终 worker 修改由下面的实际 CEF 运行验证，不重复运行相同内核检查。
- `functional:workspace-browser` 144 项、`functional:workers` 118 项通过，前者不启动 CEF，后者使用宿主工具 fixture。报告 `build.noindex/verification/runs/20261028T080446Z-f0d22dfd/report.json`。
- 文档链接、验证注册表和工具语法另选 `documentation harness syntax`，不并入 GUI 或性能负载。

第一轮原生 Eval 检查因夹具只安装额外的 process 监听器、没有使用生产的 postmortem 拦截入口而失败；错误栈已正确携带 cell。按生产入口修正夹具后通过，没有放宽断言。进一步审阅将重启提示从 owner 级改为 kernel 级，补充同 owner 不同 kernel 检查后通过。

## 授权后的真实 CEF＋OMP 验收

owner 明确授权启动并关闭本任务的独立验收窗口。驱动使用生产 `BrowserWorkspaceStore`／面板、两个同 URL／title 的页面、临时 CEF profile、本地 HTTP 页面和真实 OMP Browser/Eval，不发送模型请求。输入结果由 GUI 宿主的独立 CDP 抽样确认，不能以工具返回成功代替页面内容变化。入口为 [workspace_browser.py](../../tests/acceptance/workspace_browser.py) 的 `--automation --run --omp ...`。

按失败阶段修复并继续，保留此前有效证据；没有把失败的部分运行标记为整轮通过。各目录均位于本任务 `build.noindex/browser-acceptance/`，内有 `automation-result.json`、host／SDK 日志和隔离 profile：

| 运行目录 | 已通过范围 | 本次停止原因及处理 |
| --- | --- | --- |
| `20261028-170202-276750` | 双标签、后台 B 输入、兄弟弹窗时 B 再附着 | A 的 `handleDialog` 被调用前的 focus 设置挡住；修复 pending-dialog 分支，先由原生 API 答复 |
| `20261028-170639-259478` | 上述范围、答复弹窗、停放输入及可信拖动 | 滚轮派发后立即采样得到 0；读取原生实现确认它只等待排队／有限 ack。夹具改为同一 `tab.run` 内有界等待实际 scrollY 变化，保留非零断言 |
| `20261028-171121-162565` | 连接参数、同址双标签身份隔离、后台可信输入、兄弟弹窗、停放输入／拖动／滚轮、窗口保持隐藏且选中页不变，共 7 项 | Cookie 夹具误把数组传给变参 `setCookies`；改为单个 Cookie 对象，从 state 阶段继续 |
| `20261028-171325-321711` | Cookie save/load 目标 profile 往返、跨域 frame 字符串、selector 截图，另 3 项 | 模态超时后重建失败；原生日志为新 worker 初始化超时。按原会话拥有回调的机制修复旧 worker cleanup |
| `20261028-172517-480342` | 模态超时后真实输入／点击、释放全部句柄后双标签重连、关闭目标拒绝且兄弟页面不变，另 3 项 | recovery 阶段全部通过；预期的 timeout 与 stale-target 错误均被断言为失败，其余调用成功 |

合计 13 项不同检查通过。最终修改只影响中断 cleanup 与其后的恢复步骤，正常调用／state／frame 路径未改变；普通未中断手动模式的无操作行为另有定向检查。因此复用前两阶段证据，没有重跑整个套件。

同时修正了验收脚本的 `PI_CONFIG_DIR`：OMP 将其与 home 拼接，绝对路径会形成重复前缀；改为 home-relative 并在加载会话前核对实际根目录。先前本任务生成的独立日志已移到 `build.noindex/relocated-native-state`，没有读取或覆盖日常 OMP 配置。最终验收正常退出并关闭其窗口，日常 GUI 保留。

## 保留的验收边界

本轮覆盖上述定向故障，不重新宣称原报告全部 18 类能力在所有后端通过。定位仍按 GUI 权限策略拒绝；分区 Cookie state 明确拒绝，非当前 origin 的 Web Storage 明确跳过。强制杀进程、renderer 崩溃及外部调试器抢占不等同于本次模态超时，未用这一结果保证可无损恢复。

完整日常 GUI 的安装／重启、外部网站 OAuth、真实账号 Cookie、系统权限、其他浏览器后端和签名打包属于另外的验收范围。原始首次附着失败缺少底层 CDP 日志的限制仍保留。
