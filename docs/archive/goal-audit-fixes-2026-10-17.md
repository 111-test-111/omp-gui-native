# Goal 问题复核与修复（2026-10-17）

范围为 local `main` `cb80f65` 后的 Goal 修复，Dev `0.1.112` / build `113`。按 owner 要求复核此前静态审核的 8 项问题；原审核记录及其索引属于 primary checkout 的既有未提交文件，本任务保留原文。当前操作见[聊天工作流](../chat-workflows.md#原生目标)，接口边界见[原生接入](../OMP_INTEGRATION.md#native-goals)。

## 逐项结论

| 项目 | 复核结果与处置 |
| --- | --- |
| P1 恢复后不启动 | 真实缺口。默认 OMP continuation modes 仅 interactive，RPC resume 自身只恢复状态。新增明确恢复的单次普通 prompt，与创建使用相同的前后 settled、run generation、连接及目标身份保护；已排定、运行过或正在运行的原生工作均优先，未知/迟到确认绝不补发。实际运行时路径覆盖恰好一次投递。 |
| P2 预算不可改 | 真实原生接口限制，不能在 GUI 伪造预算修改或保留累计的新目标。禁止恢复已耗尽预算的 paused 目标，面板说明放弃后设新预算重建、用量归零。没有修改外部 OMP 安装或 profile。 |
| P3 Stop 暂停目标 | 真实原生设计。公开 abort 触发 host stop 和 interrupted accounting，把 active 目标持久化为 paused；GUI 保留该行为，在 Stop help、目标面板和使用说明中明确提示。pause/drop 仍不 abort 当前回复。 |
| P4 严格解码 | 小数秒拒绝为真实协议类型缺陷，改为有限非负 Double。新增状态/模式可保留原始值、身份和用量并提示升级，所有变更禁用；损坏字段、整数 token 约束及字节上限不放宽，也不推断终态。 |
| P5 非原子身份校验 | 真实原生限制。操作前重新 get 并核对 expected ID；结果若指向另一 ID，采用真实观测、报错并不重发。合成对端覆盖静默替换和读取后替换。读取到应用之间仍无原生 CAS，特别是 null 的 drop 回复不能证明被操作的 ID；这一残余风险未宣称消除。 |
| P6 禁用状态灰区 | 真实体验缺口。精确识别原生 `goal.enabled` 拒绝，独立于 supported/unsupported 证据保留禁用状态；空 get 成功不清除它。保留正文、隐藏建议、禁止重复提交并显示启用/重连说明。旧版 unknown-command 仍只禁用 Goal。 |
| P7 完成反馈短暂 | 真实可见性缺口。显式 complete 后即使原生清成 null，保留「目标已完成」按钮及最后一次目标/用量；新目标或原生会话切换清除。null 不推断完成，drop 不显示完成标记；没有添加另一套持久化历史。 |
| P8 用量非实时 | 原记录「只有 token 增量才推送」不成立：`GoalRuntime.#flushUsageLocked` 有仅 wall-clock 增量也调用 `#commitState` 的路径，其默认 emit 为 true，只有持久化受 token/persistWallClock 限制。静默期没有周期刷新仍属原生快照语义。面板标明最近一次原生报告并显示报告用时；不自行累加、假造实时计数或新增轮询。 |

## 原生依据

本次直接读取选定 npm 安装的 `@oh-my-pi/pi-coding-agent` 源码，版本 18.11.2：

- `src/modes/rpc/rpc-goal.ts`：公开 op、disabled 拒绝、continuation modes、scheduled settlement、completion journal 和 host abort。
- `src/goals/runtime.ts`：budget mutation 仅内部方法、resume/pause、interrupted 持久化、wall-clock flush/emit。
- `src/goals/settings.ts`：默认 continuation modes。
- `src/modes/rpc/wire/state.ts`：`timeUsedSeconds: number`、整数 token 和当前枚举。

这些是机器局部、版本特定的证据；后续 OMP 升级需重新核对。GUI 变更在 [Goal 模型](../../OMPGUI/Core/Models/OMPGoal.swift)、[接口](../../OMPGUI/Services/Providers/OMPSession+Goal.swift)、[运行时](../../OMPGUI/App/Runtime/ThreadRuntime+OMPGoal.swift)及[按钮/面板](../../OMPGUI/App/Views/Chat/OMPGoalButton.swift)。

## 验证

本任务预先选择 `make build`、`functional:goal`、单版本 `native:goal` 和 `static:documentation`。原生层只用新生成的隔离 profile、会话及回环确定性 HTTP provider，不连接外部模型，不改日常 OMP 配置，不启动 GUI。[检入摘要](../evaluations/2026-10-17-goal-audit-fixes/acceptance.json)保留构建及检查输入 hash、选定运行时版本/源码 hash、原生断言和边界。

| 范围 | 结果与原始证据 |
| --- | --- |
| 最终 `make build` | 通过；工作树 `build.noindex/development/verification-inputs.json` 对应功能/原生报告的同一二进制 hash |
| `functional:goal` | 64 条通过；`20261017T082355Z-e2af735f/report.json`，合成公开 RPC 对端，无原生 OMP 或模型调用 |
| `native:goal` | 日常 npm 安装 OMP 18.11.2 的 15 条通过；`20261017T082407Z-8130a494/report.json`，仅新生成 profile 和本地 provider |
| 文档链接/导航 | 收尾选择 `make verify TIER=static AREAS="documentation"`；报告保存于本任务 worktree 的 `build.noindex/verification/runs/` |

首轮构建及 61 条功能检查通过后，自查发现控制前查询会复用点击前已发出的面板查询。改为等待旧读取后发起新的身份查询，并补上确定性的查询并发回归；同时阻止 active 状态搭配未知 mode 时发送 fallback prompt，修正新建模式的完成图标。对这些后续源码修改进行增量重建，仅复跑受影响的 Goal 功能检查，最终为上述 64 条；功能和原生层均未失败，没有扩张兼容矩阵，原生层只执行一次。首次文档检查发现摘要缺失：汇总时遗漏 `CaptureRun.storageRoot` 的 `storage/` 子目录，导致摘要生成中断。修正读取路径、生成摘要后，只重跑文档检查。原始报告留在本 worktree 的生成目录，后续按 owner 要求清理后不保证原路径仍可访问。

界面中英文、键盘、窄布局和最终 Liquid Glass 合成未做现场认证，仍列于[当前状态](../status.md#尚未关闭的验收)。P2 的原预算原地修改及 P5 的原子身份校验需 OMP 新增公开接口；当前处置不冒充原生支持。
