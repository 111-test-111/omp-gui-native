# P6.2 原生任务工作台 / Native task workbench

> 历史记录：仅代表原文所列日期、版本及验收范围，不是当前操作指南。 当前已移除的收件箱、会话记录、独立 fork 和诊断入口不因本文的历史描述而恢复为功能。 当前入口见[文档索引](../README.md)和[功能状态与验收边界](../status.md)。

2026-10-16 · OMP GUI Dev 0.1.39 (40)

## 使用说明

点击聊天顶部的 Hydra 标记打开原生任务工作台。首次使用仍保留 Hydra 介绍。列表仅呈现当前父会话已观测到的原生 worker，支持搜索以及全部、运行中、已结束筛选；不会扫描或导入历史会话。清除浮动面板中的已结束 head 不会删除工作台里的任务记录。

选择任务可查看父会话、原生 worker ID、observation 身份、创建工具调用、实际模型与思考级别、原生工作目录、隔离与应用状态、进度、报告以及文件/产物。未知字段显示“OMP 未报告”。打开父会话可对照原始 task 工具调用；原生工具调用 ID 和父/子会话文件保留在详情中。文件和产物可通过已有文件预览打开，产物还可在访达中显示；相对文件缺少原生工作目录时不猜测其位置。

“原生日志与追加指令”复用 Hydra 时间线和 Composer，展示原生持久化日志中的用户输入、工具调用及报告。只有显示此日志页时才补读该 worker；切回详情或关闭页面会释放本视图的读取租约，其他可见 Hydra 面板不受影响。旧 observation 不能控制复用相同 ID 的新 worker。当前父进程无法提供旧日志时显示限制，先前已加载的内容仍可阅读。

“新任务”分别填写完整任务简报、文件上下文、预期结果。可以选择文件路径，或明确加入此前共享的源文件/选区上下文；选择路径本身不触发 GUI 读取文件全文。简报和预期结果为必填项。表单把全部内容作为一个原生输入提交至父会话：空闲时使用 prompt，忙碌/后台工作期间使用原生 follow-up。OMP 独占执行、调度、委派、模型选择和隔离；表单不创建 GUI worker，不保证产生一个或多个子任务。

任务表单独立于主聊天输入；确认接收后仅清除与已提交内容完全一致的任务草稿。编辑中的新内容、提交失败和送达未知均保留。送达未知时禁止再次提交，使用父会话已有投递记录检查/处理。应用打开期间关闭工作台、切换聊天再打开可继续编辑；尚未提交的表单不跨应用重启持久化。已提交的完整输入通过现有原生投递/会话保存路径保留。

停止与追加指令同时要求当前原生能力和相同 observation。停止请求的接收结果单独显示，最终状态等待 OMP 生命周期；追加指令沿用现有确认后清草稿和原生消费合并机制。原生执行结束不推断变更已应用。没有已确认的公开结果应用接口，因此不新增应用、合并或 GUI 隔离入口。

## 预算与能力

| 路径 | 预算或约束 |
| --- | --- |
| 任务表单 | UTF-8 总计最多 128 KiB，最多 32 个文件路径；超出预算禁止提交，不截断用户输入 |
| 任务/原生报告预览 | 每段最多 64 KiB，UTF-8 安全截断；复制按钮保留原始全文 |
| 列表与详情事实 | 读取现有 Hydra 观察记录，不建立第二份正文缓存或额外订阅 |
| 原生日志 | 每个工作台最多一个可见 worker 日志；复用进程级 progress 订阅、180 ms 合并和原生 fromByte/nextByte 游标 |
| 隐藏视图 | 停止本视图额外读取；重开从原生水位补读；不启动周期轮询 |
| 活跃后台工作 | 沿用原生 work/activity 与运行中 worker 的回收保护；未提交任务草稿也保留其 runtime |

prompt/follow-up 使用现有父会话发送接口，不增加探测命令。worker stop/steer 以当前进程实际响应确认的能力为准；18.3.2 的已有证据为不可用，18.11.1 的既有原生证据见 P5 记录，本次未重复运行版本矩阵。模型、effort、目录、隔离和应用布尔值只展示 OMP 实际提供的字段。

## 验证与限制

当前检查登记在 `tests/catalog.py` 的 `functional:workers`，源码为 `tests/functional/omp/workers_tests.swift`；使用 `make build` 和 `make verify AREAS="workers"`。复用原 worker fixture 对隐藏读取、游标、重建、ID 复用、原生控制及 host tools 的覆盖，并在同一 fixture 中增加任务输入/预算、原生投递复用、失败与未知保留、主草稿保护和无 GUI worker 分配检查。此 fixture 使用隔离目录和无模型协议 peer，不是实际模型或 GUI 验收。

按新规范集成后的验证：在 `main=1cf6dcc`（保留验证工具重构和 P6.1）上 rebase 后，Dev 0.1.39 / build 40 的一次 `make build` 通过，生成 `build.noindex/development/verification-inputs.json` 的源码与二进制指纹；只选择 `functional:workers`，`make verify AREAS="workers"` 通过，共 60 项断言。报告为 `build.noindex/verification/runs/20261016T041639Z-4a22f7cf/report.json`，详情日志为同目录的 `functional/workers/checks.log`。该轮验证覆盖实际组合后的源码和重定位后的 fixture，没有运行其他功能模块、原生版本矩阵或性能负载；静态工具检查由最终集成统一执行。

重构前的历史验证结果：`make build` 通过，产物为此 worktree 的 `build.noindex/development/Build/Products/Debug/OMP GUI Dev.app`，完整构建记录为 `build.noindex/development/build.log`。`make verify AREAS="workers"` 通过，输出 `PASS P4: 60 selection, native metadata, visibility/cursor, reused-id and host-tool checks`。首次 fixture 编译因新增两处 `ompSubmission` 调用遗漏标签失败；核对生产事件声明后修正 fixture，仅重跑失败的 workers 检查。随后交叉审查发现释放会话直接把原生投递行改为未知时，任务表单投影可能仍停留在提交中；已同步该行的状态/原因并补断连断言，仅对这处源码做必要增量构建、重跑 workers，最终 60 项通过。

本次不运行 GUI、不安装、不打包、不修改外部 OMP profile。真实屏幕、VoiceOver、输入法、睡眠/唤醒和减少动态效果仍待 owner 安排；P5 屏幕 p95、父版本对照、WebKit 覆盖与多 worker/大输出峰值门槛保持开放。结果应用因缺少已确认公开接口延期。

## English guide

Open the workbench from the chat's Hydra mark. It shows observed native workers belonging to the current parent conversation, with search and running/finished filters. It does not scan, migrate or import old conversations. Finished workers remain inspectable after clearing their floating panels.

Task details retain native worker and observation IDs, parent/child session files, spawning tool-call identity, progress, reports, actual model and effort, native working directory, workspace/application facts, files and artifacts. Missing facts stay unknown. Open the parent conversation to inspect its original task call; use file preview or Finder for reported artifacts. Relative files without a native directory are not resolved against a guessed workspace.

The log tab reuses Hydra's native timeline and additional-instruction composer. Only a visible log acquires a transcript lease; closing it preserves other visible consumers. Reopening uses the native byte cursor. Previously loaded entries remain readable if the original parent process can no longer supply that observation's journal.

New tasks require a complete brief and expected result, with optional explicit file paths, source selections and context. The complete form goes through the parent's existing native prompt or follow-up path. OMP owns execution, delegation, model selection and isolation. No GUI worker, concurrency queue, scheduler or result-application mechanism is introduced.

The independent task draft survives workbench dismissal and chat changes while the app stays open. Native acceptance clears only an unchanged matching task form; failure, unknown delivery and subsequent edits retain their text. Unknown delivery blocks duplicate submission. The parent composer remains untouched. Submitted input follows existing native admission and conversation persistence; unsubmitted form state is not persisted across app restarts.

Stop and steering require both current native support and matching observation identity. Stop acceptance is separate from native lifecycle completion, and execution completion does not imply applied changes. Result application remains deferred until a public OMP interface is confirmed.

Budgets are 128 KiB of UTF-8 task input, 32 context-file paths and 64 KiB per secondary report preview. Logs reuse the existing 180 ms coalescing, shared progress subscription and native cursor without a new body cache or hidden polling. Before the verification-tool migration, validation passed with the initial build, one affected incremental build after correcting the disconnect admission projection, and 60 scoped workers checks. Two initial fixture argument labels were corrected before its first passing run; native version matrices, GUI/system acceptance and P5 performance gates are not claimed as newly passed.

After rebasing on the verification-tool migration and P6.1 (`main=1cf6dcc`), Dev 0.1.39 / build 40 passed one build with `verification-inputs.json` source/binary fingerprints and the single selected `functional:workers` check (60 assertions). Evidence is in `build.noindex/verification/runs/20261016T041639Z-4a22f7cf/report.json` and its `functional/workers/checks.log`. No other functional, native or benchmark area ran in this integration pass; static tooling checks are reserved for final integration.
