# P6 交付与验收 / Native workbench delivery

> 历史记录：仅代表原文所列日期、版本及验收范围，不是当前操作指南。 当前已移除的收件箱、会话记录、独立 fork 和诊断入口不因本文的历史描述而恢复为功能。 当前入口见[文档索引](../README.md)和[功能状态与验收边界](../status.md)。

2026-10-16 · P6 集成基线 Dev 0.1.42 / build 43；收件箱移除与等待标签调整于 Dev 0.1.46 / build 47 完成，见[本轮验证](p6-implementation.md#本轮验证--dev-0146--build-47)；Dev 0.1.47 / build 48 已删除会话记录及其全部专用功能；Dev 0.1.48 / build 49 补充双色玻璃等待胶囊与独立审批卡片，见[本轮说明与验证](p6-implementation.md#独立审批卡片--dev-0148--build-49)。开发与检查均在独立任务 worktree 中进行；每个模块一个提交，递增 Dev 版本并记录 Unreleased，依次快进集成本地 `main`。不推送、创建 PR、打包、安装或启动 GUI。各 worktree 和检查产物保留。

运行时诊断、待处理收件箱和会话记录均已移除。批准和问答在未查看会话的侧栏条目右端分别显示琥珀色、紫色液态玻璃等待胶囊；回到原会话，使用只有拒绝/允许两个操作的工具审批卡片或原有问答表单处理。下方首次集成的检查次数及证据保留为当时记录；会话树、工具检查和 MCP 观察的历史证据不表示当前版本仍提供这些功能，也不表示本次重跑了整个 P6。

Dev **0.1.50 / build 51** 重做工具审批信息区，补齐原生工具审批 select 路径，只保留拒绝/允许胶囊；构建及 `functional:interactions` 66 项通过，见[工具审批卡片与本轮证据](p6-implementation.md#工具审批卡片--dev-0150--build-51)。

## 功能与使用入口

| 模块 | 原生入口与状态 | 说明 |
| --- | --- | --- |
| P6.1 会话等待状态 | 未查看会话的侧栏条目右端显示等待批准/回答；回到原会话处理 | [会话草稿、身份与送达边界](p6-implementation.md#p61-会话等待标签--conversation-waiting-labels) |
| P6.2 Hydra 原生任务 | Hydra 标记 | [任务工作台](p6-tasks.md) |
| P6.3–P6.4 会话记录 | 已移除入口、面板及全部专用功能 | 不再交付或验收 |

窄窗口将新增聊天入口收在「对话操作」中。新功能使用 SwiftUI/AppKit 和现有 Chrome/Hydra；Markdown 文件预览继续沿用 WebKit。OMP 负责执行、队列、委派、身份、认证、隔离和结果应用。没有新增 OMP 命令、斜杠命令或终端功能。

## 支持依据与接口边界

能力以当前进程的成功/明确不支持响应为准；旧进程和旧版测试证据不会自动启用新进程的操作。未返回的数据为未知。P5 的两版运行时记录只为原生接口的历史证据，不冒充本次全部 GUI 功能的现场验收。

| 能力 | 本阶段边界 |
| --- | --- |
| 记录检查与诊断 | 会话记录、MCP 观察及专用配置范围采集已移除；运行时诊断、版本/profile 采集和导出也已移除 |
| 原生交互回复 | 确认 pipe 写入才清草稿；原生接口没有逐条响应确认，不等于任务完成 |
| worker stop/steer | 同时要求当前父进程能力与 worker observation 身份；等待原生生命周期确认结果 |
| 消息分支 | 保留消息编辑入口的原生 branch 和原会话保护；记录面板专用的独立 fork 已移除 |
| MCP 配置 | 保留设置中的原生配置编辑；不采集启动连接观察 |
| 隔离结果应用 | 没有经确认的公开接口时仅展示原生报告/产物，应用入口延期 |

## 缓存、订阅与资源预算

各模块的具体预算、取消与失效保护见各自说明。共同规则：不扫描旧会话，不新增持续采样或轮询；只读当前已加载事实；隐去详情后不继续额外读取；正文按 UTF-8 字节限制；合并同一查询；新功能不创建 WebView。

| 模块 | 保留预算 |
| --- | --- |
| 会话交互 | 仅保留所属会话的活跃请求；结束或释放即撤下，无聚合索引或最近请求缓存 |
| 任务 | 未提交输入 128 KiB、32 个文件；每段报告预览 64 KiB；每工作台一个可见 worker 日志 |

P6 的代码预算与 P5 的整应用实际测量分开。此次未运行新的整应用性能负载，不用构建、无窗口回放或静态字节上限宣称 physical footprint、CPU、屏幕延迟已经通过。已有 P5 数据仍见 [P5 验收记录](p5-forward-acceptance-2026-10-16.md#尚未关闭的验收)。

## 验证记录

选择范围遵循 main 新建的 [统一验证入口](../verification.md)：测试统一位于 `tests/`、单一 `tests/catalog.py` 登记，使用共享编译/隔离及 worktree 构建指纹。不执行默认全套、双版本完整矩阵或重复性能负载。通过的检查在相关源和环境未改变时复用。

| 模块 | 新系统证据 |
| --- | --- |
| 会话等待标签 | Dev 0.1.46 / build 47 最终构建；`functional:interactions` 28 项、`lifecycle` 57 项及默认指标 2 项通过。`static:harness` 24 项及 `syntax` 通过。报告见[实施记录](p6-implementation.md#本轮验证--dev-0146--build-47) |
| 原收件箱（已移除，历史证据） | Dev 0.1.38 构建、`functional:inbox` 26 项；`static:harness` 24 项及 `syntax` 通过。报告：inbox worktree `build.noindex/verification/runs/20261016T041509Z-b7449b46/report.json`、`20261016T041509Z-40123d8a/report.json` |
| 任务 | Dev 0.1.39 构建、`functional:workers` 60 项通过。报告：tasks worktree `build.noindex/verification/runs/20261016T041639Z-4a22f7cf/report.json` |
| 会话树（历史，已移除） | Dev 0.1.40 构建、`functional:history` 及 `workflows`（134 项）通过。报告：session-tree worktree `build.noindex/verification/runs/20261016T041935Z-c2a43fdc/report.json` |
| 工具/MCP（历史，已移除） | Dev 0.1.41 构建、`functional:tools`（Swift 34 项、SDK mock、本地化 69 键）通过。报告：tools worktree `build.noindex/verification/runs/20261016T042307Z-04f50abf/report.json` |
| 集成收口 | Dev 0.1.42 / build 43 的 `make build` 与源/二进制指纹通过；`functional:lifecycle` 默认指标 2 项、生命周期 64 项，`workers` 65 项，`workflows` 136 项通过。报告：closeout worktree `build.noindex/verification/runs/20261016T042833Z-52f42e8f/report.json` |
| 最终静态 | `static:harness` 24 项通过；补齐 ChatView 回归后只重验改变的语法输入，`static:syntax` 通过。报告：closeout worktree `build.noindex/verification/runs/20261016T042704Z-c3432421/report.json`、`20261016T042900Z-c2cd8317/report.json`。六份 P6 文档本地链接和本地化 JSON 重复键检查通过 |

上表的 worktree 均为 `/Users/developer/.codex/worktrees/omp-p6-<模块>/omp-gui-native`。P6.0 的原始生命周期/SDK smoke 与 P6.1 的既有 60 项问题表单证据见 [实施记录](p6-implementation.md)；这些历史结果不冒充新执行器的重跑。工具 SDK 的 OMP 18.3.2 隔离 smoke 也复用已通过证据：无模型轮次，不认证当前 MCP 连接或外部模型质量。

首次交付的交叉审查记录（会话树、分页及观察相关实现现已删除）：cached hosting view 隐藏时以 `chatColumnIsShown` 释放 worker 日志 lease；仍可见的另一窗口或独立工作台保留自己的 lease。会话树的 worker 产物预览同时保留原生工作目录和来源身份。上下文首兼末页即使没有下一页 cursor，也通过 `get_entries since` 的当前 leaf 及既有状态 fence 核对快照。诊断字段的 UTF-8 截断保留完整字符，遵守字节上限。

worker 补验直接挂载真实 `HydraHeadTranscript` 和 `ChatView` 离屏宿主，复现 `isHidden` 后更新环境的缓存顺序，覆盖双窗口保留、最后一个读取者释放及重显恢复；主聊天还确认没有触发 `onDisappear`。预置无关命令目录，避免功能检查启动已安装 OMP。末页 fixture 验证无下一页 cursor 时的错误 leaf 被拒绝。未发现需要扩张验证范围的失败；所选检查通过后停止。

## 保留的验收门槛

- 实际窗口中的新入口、表单、键盘、窄布局及中英文呈现。
- 屏幕呈现 p95、同负载父版本对照；空闲 CPU 与重复操作内存预算不能用布局/心跳替代。
- OMP 18.11.1 活跃 WebKit 的完整归属、大输出、多 worker、大文档以及各角色峰值范围。
- 系统睡眠/唤醒、完整 VoiceOver、真实输入法组合和减少动态效果现场矩阵。

这些项目保持开放。按 `AGENTS.md`，GUI 运行需要 owner 明确要求；本轮开发授权和子代理验收授权不扩展为 GUI 启动或系统设置变更。P6.5 仅收口实际证据，不临时扩展功能，也不宣称全面验收通过。

## English handoff

Background conversations show **Awaiting approval** or **Awaiting your answer** at the right of their sidebar rows; open the source conversation to respond. Use Hydra for the native task workbench. The pending inbox, Session records and runtime diagnostics have been removed. Chat persistence, message editing/branching, tool rows, Usage context actions and MCP settings remain available. Narrow windows group the chat actions under **Thread controls**.

All modules use native UI and OMP-owned execution. Capability evidence belongs to the current process. Missing interfaces remain unavailable or unknown: response writes do not prove task completion, and isolated-result application awaits a confirmed public interface. Dedicated tree/detail/page readers, independent forks, tool inspection/navigation and MCP startup observations have been deleted.

Scoped builds and functional checks do not certify GUI performance or system acceptance. Real-window interaction, screen p95 and parent comparison, full resource peaks, sleep/wake, VoiceOver, input-method composition and reduced motion remain open. No GUI was launched, no external profile was changed and nothing was published.

The final Dev 0.1.42 build passed with source/binary evidence. Scoped checks passed: lifecycle 64 plus 2 default-metrics checks, workers 65, workflows 136, runner contracts 24 and tooling syntax. At that integration baseline, unchanged inbox/history/tool evidence was reused; the inbox has since been removed and its request checks renamed to interactions. Headless AppKit checks cover real cached chat/transcript visibility; they do not replace full-window acceptance.

## 会话记录移除 · Dev 0.1.47 / build 48

删除聊天顶部和窄布局中的会话记录按钮、整个面板、历史树和分支来源浏览、按需正文及上下文分页、工具详情与双向定位、独立 fork、MCP 启动观察及其配置目录采集。移除专用模型、缓存/合并读取、事件、SDK 观察模块、无用本地化和 `functional:tools` 检查及配套 fixture；历史导航和分页/fork 的专属断言也一并清理。旧版指南已删除，历史记录由 Git 保留。

正常聊天记录的保存/恢复、消息编辑的原生分支与附件恢复、聊天工具展示、用量面板的上下文管理及 MCP 配置不变。最小验证范围为一次 `make build`、`make verify AREAS="history workflows"` 和测试工具要求的 `make verify TIER=static AREAS="harness syntax"`；不启动 GUI、不运行真实 OMP 或性能负载。实际窗口中的按钮布局仍需 owner 安排目视验收。

验证结果：初次一次 `make build`、`functional:history`、`workflows` 120 项及 `static:harness` 24 项、`syntax` 全部通过。随后本地 `main` 合入 `902e5da`（收件箱移除/等待标签），本任务保留该改动并顺延版本。合并影响了聊天控件、运行时、测试登记和交互 fixture，因此只追加一次增量构建及受影响的 `workflows`、`harness syntax`，全部通过；历史解析的四份输入源码逐一确认未变，复用通过证据，没有重跑 history 或扩张范围。SDK host 的 Node 语法、本地化 JSON（含重复键）和文档本地链接检查也通过。

最终 Dev **0.1.47 / build 48** 的构建日志和源/二进制指纹位于 `remove-session-records` worktree 的 `build.noindex/development/build.log` 与 `verification-inputs.json`。同一 worktree 的验证报告为：

- history：`build.noindex/verification/runs/20261016T055343Z-b51048ba/report.json`（同时记录初次 workflows 120 项）。
- 合并后的 workflows 120 项：`build.noindex/verification/runs/20261016T055714Z-20f024b3/report.json`。
- 合并后的 harness 24 项及 syntax：`build.noindex/verification/runs/20261016T055652Z-bc1459e7/report.json`。

所选检查通过即停止。未启动或重启 GUI，未运行真实 OMP、兼容矩阵或性能负载；按钮布局的目视验收保持待确认，构建和 fixture 结果不代替整应用现场验收。
