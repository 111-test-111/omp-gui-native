# P6 实施记录 / Native workbench implementation

> 历史记录：仅代表原文所列日期、版本及验收范围，不是当前操作指南。 当前已移除的收件箱、会话记录、独立 fork 和诊断入口不因本文的历史描述而恢复为功能。 当前入口见[文档索引](../README.md)和[功能状态与验收边界](../status.md)。

完整阶段入口、支持边界及最终验证见 [P6 交付与验收](p6-acceptance-2026-10-16.md)。任务见 [Hydra 工作台](p6-tasks.md)。会话记录及其专用浏览、工具/MCP 检查功能已在 Dev 0.1.47 / build 48 删除。

For phase entry points, support boundaries and final evidence, see [P6 delivery and acceptance](p6-acceptance-2026-10-16.md), with a separate guide for the task workbench. Session records and its dedicated history/tool/MCP inspection features were removed in Dev 0.1.47 / build 48.

## P6.0 已移除 / Removed

按 owner 最新要求，运行时诊断的入口、面板、摘要/导出、专用刷新及版本/profile 采集已移除。能力判断仍是原生操作的内部保护。会话记录及其专用加载、缓存、独立 fork、工具定位和 MCP 观察也已删除；原生聊天、消息编辑/分支、用量面板的上下文操作及 MCP 设置保留。

Runtime diagnostics, its snapshot/export and dedicated refresh have been removed. Internal capability guards remain. Session records, its dedicated readers/caches, independent forks, tool navigation and MCP observations have also been removed. Chat, message editing/branching, context actions in Usage and MCP settings remain available.

## P6.1 会话等待标签 / Conversation waiting labels

待处理收件箱功能已移除，包括侧栏入口、聊天顶部托盘按钮、聚合面板和最近请求缓存。当批准或提问来自当前未查看的会话时，侧栏该条目右端显示「等待批准」或「等待回答」。项目、活动、搜索及子会话列表使用同样的标签；悬停后仍能使用原有操作。打开来源会话后隐藏标签，在独立审批卡片或问题徽章中处理；原生请求结束时立即撤下等待状态。同时存在两类请求时优先显示批准。

The pending inbox, sidebar entry, chat tray button, aggregate panel and recent-request cache have been removed. A background conversation shows **Awaiting approval** or **Awaiting your answer** at the right of its sidebar row, including project, activity, search and helper rows. Existing hover actions remain available. Opening the conversation hides its label; respond through its dedicated approval card or question badge. Native resolution removes the waiting status. Approval takes precedence when both kinds are pending.

活跃请求及问答草稿只由所属 `ThreadRuntime` 保存，同一会话的窗口共享输入。身份仍包含 GUI 会话、进程 generation、原生会话、原生请求 ID 和实例 UUID。启动阶段只在当前 generation 首次绑定原生身份；换进程、复用 ID、旧回调和旧时限不能改写新表单。提交仍检查身份与时限，保留多选、自定义输入、跳过和多行编辑语义。

Live requests and drafts belong to their conversation's runtime. Windows showing that conversation share the same input. Request identities remain fenced by GUI thread, process generation, native session, native ID and instance UUID. Startup identity binding, stale callbacks, reused IDs, native deadlines and the existing answer semantics retain their guards.

确认 transport 管道写入后才清草稿；原生协议没有逐条接收确认，写入不表示任务完成。未知送达保留当前会话输入且不自动重发。取消、超时、退出或会话释放会撤下表单并释放运行时索引；已经打开的表单引用只读。没有跨会话请求档案或后台缓存，不写磁盘、不扫描旧会话、不轮询，也不增加订阅或调度。等待批准使用琥珀色、等待回答使用紫色的液态玻璃胶囊。这是侧栏等待标签的明确样式例外；胶囊不带交互效果，性能模式及减少透明度使用轻量回退。审批卡片正文沿用普通原生卡片，仅紧凑操作按钮使用玻璃。

Only a confirmed transport write clears submitted input; the native protocol has no per-response acknowledgement or task-completion guarantee. Uncertain delivery retains the live input without retries. Cancellation, timeout, exit and release withdraw the form and runtime entry; any already-held form reference becomes read-only. There is no cross-session archive, disk draft, history scan, polling, new subscription or scheduler. Approval waits use amber Liquid Glass capsules, and answer waits use purple capsules. These noninteractive badges are an explicit styling exception, with lightweight performance and reduced-transparency fallbacks. Approval card content remains plain native UI; only compact action buttons use glass.

### 工具审批卡片 · Dev 0.1.50 / build 51

卡片以原生工具图标和名称为标题，来源和原因分层呈现。Bash 命令使用 shell 高亮；write 显示独立路径及按扩展名高亮的内容；其他工具详情原样放入等宽信息区。复用聊天工具的 `ToolCodeBlockView`，不增加复制、展开或发送控件。正文最多 200 pt 滚动，页脚只显示「拒绝」「允许」两个液态玻璃胶囊按钮，操作始终可见；原生取消、超时和断开仍会撤下请求。

查阅当前已安装 OMP 的公开 SDK 源码后，补齐真正的工具审批路径：`formatApprovalPrompt` 生成以 `Allow tool: ` 开头的提示，wrapper 和 eval prelude 使用原生 `select` 及精确的 `["Approve", "Deny"]` 选项。仅同时匹配该方法、选项与非空工具标识时呈现工具审批；一般 select/input 保持原有问答语义，不根据按钮文字猜测。允许/拒绝仍返回原始 `value: "Approve"` / `"Deny"`；普通 confirm 返回 `confirmed: true` / `false`。GUI 不决定审批策略或执行工具。元数据只拆分已知前缀；命令、文件内容、未知详情及原生附加安全提示保留原文，中文、空白和换行不被改写。

Tool approvals now show a native tool icon/name, separate reason and origin, syntax-highlighted commands or file content, and exactly two capsule decisions: Deny and Allow. Native Approve/Deny select prompts retain their original response values; ordinary confirmations retain booleans. Only the known native prompt shape is recognized, and unrecognized details remain verbatim. Native cancellation/deadlines and process/request identity guards remain authoritative.

本轮一次增量 `make build` 通过；只选择 `make verify AREAS="interactions"`，66 项通过。新增测试数据初次编译误用了只读 `JSONValue` 下标，修正为字典构造后仅补跑该模块，没有重建应用或扩展检查范围。验证覆盖真实生产 dialog/transport 的原生 select 与 confirm 回复、精确选项与方法识别、来源/原因/正文分离、中文及 CRLF 内容保留、200 pt 滚动上限及 320/760 pt 卡片布局。未新增测试入口或脚本包装。

证据位于本聊天的 `sidebar-waiting-labels` worktree：构建日志 `build.noindex/development/build.log`；通过报告 `build.noindex/verification/runs/20261016T062830Z-906234dc/report.json`；同一运行的 `functional/interactions/storage/` 保存窄卡片、文件及长内容 PNG。本地化 JSON、中文标签和文档链接已核对。只阅读当前 OMP 的公开 SDK 源码，没有运行已安装 OMP、性能负载或完整 GUI；离屏 PNG 不能证明 Liquid Glass 的最终窗口合成效果，实际中英文外观与键盘交互仍待现场验收。通过后停止所选检查。

### 独立审批卡片 · Dev 0.1.48 / build 49

以下是该版本的历史记录；当前卡片已改为上方的工具信息布局和两个决策按钮。

OMP 的原生 `confirm` 请求进入 `ApprovalRequest`，在输入框上方显示独立审批卡片；不再作为普通问题打开问答表单，也不通过文案猜测请求类型。卡片分开显示原生标题与说明，长内容最多 200 pt 滚动，操作区保持可见。批准、拒绝、取消直接回复；依次保留原生 `confirmed: true`、`confirmed: false`、`cancelled: true`，没有新增审批策略。原生请求实例与时限原样保留，提交前再次检查时限；同一请求不能重复发送，取消/超时/断开沿用既有生命周期。仅第一张卡片拥有批准快捷键。

Native `confirm` requests now project to dedicated approval cards above the composer rather than question forms. Cards retain separate native titles and details, bounded scrolling and always-visible actions. Approve, Decline and Cancel keep the native true/false/cancellation response shapes. Native identity, deadlines and single-submission guards remain authoritative; only the first card owns the approval shortcut.

本轮最终 Dev 构建通过；`make verify AREAS="interactions questions config"` 通过：交互 50 项、问答 60 项、配置 32 项。自审统一无回调审批入口的取消语义、以实例身份重置审批卡片后，只增量构建并补验 `interactions`（50 项），复用未受影响的问答/配置证据。`make verify TIER=static AREAS="syntax"` 通过；后续 Swift 测试分支由最终功能编译覆盖。本地化 JSON 和文档链接通过静态核对。

证据位于本聊天的 `sidebar-waiting-labels` worktree：最终构建日志 `build.noindex/development/build.log`；三模块报告 `build.noindex/verification/runs/20261016T060553Z-c6f85a08/report.json`；最终交互报告及窄/宽卡片 PNG `build.noindex/verification/runs/20261016T060837Z-963caf29/`；语法报告 `build.noindex/verification/runs/20261016T060515Z-84f68966/report.json`。离屏检查覆盖原生确认回复值、取消、时限、ID 归属、320/760 pt 布局、正文滚动上限和无问答编辑器；离屏 PNG 不代表 Liquid Glass 的窗口合成外观。未启动 GUI、原生 OMP 或性能负载；中英文、玻璃效果及实际键盘交互仍待真实窗口验收。

### 本轮验证 · Dev 0.1.46 / build 47

最终 `make build` 通过。期间本地 `main` 合入会话记录样式变更，接入后只做必要的增量构建，再运行 `make verify AREAS="interactions lifecycle"`：会话交互 28 项、生命周期 57 项及默认指标 2 项通过。改名后的登记与工具语法通过 `make verify TIER=static AREAS="harness syntax"`：执行器契约 24 项和语法检查通过；测试辅助程序的一处参数名修正由最终 Swift 编译与功能检查覆盖，无应用源码改动或重新构建。标签复用既有本地化键，简体中文为「等待批准」和「等待回答」；本地化 JSON、旧入口移除和文档链接已核对。

证据保留在 `sidebar-waiting-labels` worktree 的 `build.noindex/development/build.log`、功能报告 `build.noindex/verification/runs/20261016T054634Z-ece1950c/report.json` 和静态报告 `build.noindex/verification/runs/20261016T054408Z-3c4e0bcf/report.json`。所选检查通过后停止；未运行原生 OMP、兼容矩阵或性能负载，未启动/重启 GUI。中英文、窄侧栏及悬停的真实窗口呈现仍需目视确认。

The final Dev build and scoped interaction/lifecycle checks passed (28, 57 plus 2 default-metrics checks). Registry contracts (24) and tooling syntax passed. No GUI was launched; actual window appearance, narrow layouts and hover presentation remain manual acceptance items.

### 历史验证 / Historical checks

以下为已移除收件箱的当时记录，不代表当前功能。原 `inbox` 检查已改为 `interactions`，保留会话身份、草稿、送达与原生取消/时限覆盖，删除已移除缓存的断言，并验证会话等待状态。

验证范围：一次 `make build` 和 `make verify AREAS="inbox questions"`。收件箱检查覆盖跨会话同 ID、共享草稿、双窗口提交、未知送达、失效 generation、真实生产 transport 回调及 ID 复用竞态、原生取消/时限、退出和缓存预算；问题检查继续覆盖现有表单模型和原生控件布局。Dev 0.1.38 / build 39 构建通过；收件箱检查最终 26 项、问答检查 60 项通过。自审补齐显式释放会话撤下操作及未知送达继续占据待处理区，只补跑受影响的 `inbox` 检查；交叉审查补齐启动早期请求的首次身份绑定及失效多页表单的逐题只读查看，再只补跑 `inbox`；此前问题模型/布局证据复用。新增文案 JSON/翻译及脚本语法检查通过。未启动 GUI。

测试入口同步至 main 的新 `tests/` 规范：`functional:inbox` 登记于 `tests/catalog.py`，直接使用共享编译/隔离与 rpc fixture，不保留旧 shell 包装。历史检查次数保留当时证据。新系统的 worktree 增量构建及指纹已确认，`functional:inbox` 26 项通过；`static:harness` 24 项、`static:syntax` 通过。报告保留在本任务 `build.noindex/verification/runs/20261016T041509Z-b7449b46/report.json` 和 `20261016T041509Z-40123d8a/report.json`。
