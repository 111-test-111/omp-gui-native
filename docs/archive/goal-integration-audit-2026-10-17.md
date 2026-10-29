# 原生 Goal 接入审核（2026-10-17）

范围为 local `main` 当前原生 Goal 接入与 OMP 18.11.2（npm `@oh-my-pi/pi-coding-agent`，含 `src/` TypeScript 源码）的静态核对。方法为两侧源码直读；未运行应用、未改生产代码、未调用外部 provider。OMP 包内路径以其安装目录为根，属机器局部证据，版本变动后需重新核对。功能边界与验收证据见[当前状态](../status.md)及 [N2 记录](goal-acceptance-2026-10-17.md)；本记录不改变任何当前指南。

## OMP 实现要点（审核依据）

- 生命周期核心 `src/goals/runtime.ts`：`active/paused/budget-limited/complete/dropped` 状态机；token 记账口径为新增 input + cacheWrite + output，不含 cacheRead；另有 wall-clock 秒。预算翻转只发生在记账 flush，进行中的请求不被 abort，可超限（软预算）。
- RPC 控制器 `src/modes/rpc/rpc-goal.ts`：op 仅 `get/create/resume/pause/drop`。complete 只能由模型侧 `goal` 工具（`src/goals/tools/goal-tool.ts`，write 层）发起；runtime 另有 `replaceGoal` 与 `onBudgetMutated`，均不暴露于 RPC。
- 续跑由 agent 生命周期事件驱动（非 TUI 的编辑器空闲定时器）。配置 `goal.continuationModes` 默认 `["interactive"]`（`src/goals/settings.ts`），RPC host 须显式加入 `"rpc"`；续跑受无进展 digest 抑制、host abort 的 `hostStopped`、plan mode 及 todo blocked gate 约束；已排定未 admitted 的续跑计入 `isSettled=false`，`session_settled` 与 `get_state.isSettled` 同一谓词。
- 持久化为 session transcript 的 `mode_change("goal"/"goal_paused"/"none")` 与 `goal-completed` 条目；进程恢复时 active 目标一律转 paused。用户 abort 时 active 目标自动暂停并持久化；压缩等内部 abort 不暂停。
- 模型每轮自动注入隐藏 `goal-mode-context`；续跑轮注入隐藏 `goal-continuation`；预算翻转时注入隐藏 steer。

## GUI 接入要点（被审核对象）

- 能力探测纯证据制：[OMPCapabilities](../../OMPGUI/Core/Models/OMPCapabilities.swift) 仅在 `goal` 命令成功且回复可解码时记 supported，仅 "Unknown command" 记 unsupported；[OMPSession+Goal](../../OMPGUI/Services/Providers/OMPSession+Goal.swift) 的只读 `refreshGoal` 是唯一探测请求，不为显示状态启动进程。
- `/goal` 是 GUI 输入模式而非 TUI 命令：[ThreadRuntime+OMPGoal](../../OMPGUI/App/Runtime/ThreadRuntime+OMPGoal.swift)；创建后仅当原生仍 settled、generation 未变且无续跑迹象时，才把正文作为普通首条 prompt 补发一次。
- 快照语义：[OMPGoal](../../OMPGUI/Core/Models/OMPGoal.swift)：null 不证明完成，终态只保留本会话显式观测；revision 防操作前迟到 state read 覆盖；超时保留请求身份、由匹配迟到响应解决、绝不重发；pending 与 settlement 标记阻止进程回收。
- UI：[OMPGoalButton](../../OMPGUI/App/Views/Chat/OMPGoalButton.swift) 顶部胶囊按钮与锚定 popover；仅目标模式或当前目标存在时显示。

## 问题清单

按影响排序；处置建议不改变现状的部分均已按现有文档边界记录。

### P1 Resume 在默认 OMP 配置下不启动任何工作

- 证据：OMP resume 路径经 `#enter` → `#scheduleContinuation`，`#continuationWanted` 首道 gate 即 `goal.continuationModes` 含 `"rpc"`，该配置默认仅 `["interactive"]`。GUI 的 create 路径在原生确认空闲时补发首条 prompt，resume 路径（`changeOMPGoal`）无等价兜底。
- 影响：用户点击「恢复目标」后目标转为 active 但无任何动作，须手动发消息；popover 仅一句配置提示，无引导。
- 处置建议：属产品取舍——接受现状（文档已述续跑由 OMP 配置决定），或 resume 成功后给出明确提示；不建议 GUI 自建续跑循环（违反原生所有权边界）。

### P2 budget-limited 经 RPC 不可解（预算不可改）

- 证据：RPC op 集合不含预算修改；runtime 的 `onBudgetMutated` 仅 TUI `/goal` 调用。
- 影响：budget-limited 目标只能 pause/drop；resume 后下一次记账 flush 又翻回 limited。提高预算只能 drop 重建，丢失 tokensUsed 累计。
- 处置建议：上游 RPC 表面缺口；保持 GUI 不提供伪接口的现状，待 OMP 暴露后再评估。

### P3 停止当前回复会连带暂停目标

- 证据：GUI 停止即 RPC `abort`；OMP 在 abort 时先 `stopForHostAbort`，随后 `onTaskAborted("interrupted")` 把 active 目标转 paused 并持久化。
- 影响：用户中断一次回复的副作用是目标被暂停；叠加 P1，默认配置下恢复后也不自动续跑。[使用说明](../chat-workflows.md)只写了「暂停/放弃不 abort 当前回复」，未写反向耦合。
- 处置建议：在使用说明补一句事实即可；行为本身属原生设计，GUI 不应掩盖。

### P4 严格解码的前向兼容失效模式偏硬

- 证据：[OMPGoal](../../OMPGUI/Core/Models/OMPGoal.swift) 对 status/mode 严格枚举解码，未知值即 markStale 或整体拒绝回复；`timeUsedSeconds` 按整数精确转换，而 wire schema 实为 `number`。
- 影响：OMP 新增状态值后 goal 控件实质不可用直至 GUI 更新；普通聊天不受影响。属本仓库「不猜测」设计的有意取舍。
- 处置建议：保留现状；升级 OMP 时把 goal 状态枚举 diff 列入检查。

### P5 expectedGoalID 栅栏非原子

- 证据：[OMPSession+Goal](../../OMPGUI/Services/Providers/OMPSession+Goal.swift) 注释明示 native 无 expected-id/CAS；模型侧 write 层 `goal` 工具可与 GUI 并发修改同一单例目标。
- 影响：栅栏只防陈旧视图，防不住 check 与 apply 之间的原生变更；最坏后果为错误提示或终态留存顺序差异，不会重发。
- 处置建议：残余风险低，维持现有 pending 栅栏与迟到响应解决。

### P6 `goal.enabled=false` 时的能力灰区

- 证据：OMP 配置禁用时报 "Goal mode is disabled (goal.enabled)."，不匹配 "Unknown command"，能力保持 unknown；composer 的 `/goal` 建议不看 capability。
- 影响：控件不禁用、每次操作弹原始错误；旧版 OMP 上用户提交时才失败。
- 处置建议：轻微 UX 粗糙；可接受。

### P7 完成反馈短暂

- 证据：OMP 完成时 journal 后清状态；GUI 观察到 null 后按钮消失（`showsOMPGoalEntry` 不看 `lastTerminal`），OMP 的 `goal-completed` 条目不在 GUI 历史渲染。
- 影响：完成反馈依赖模型末条消息；用户可能错过状态变化。
- 处置建议：可接受；若 owner 需要再做持久完成标记。

### P8 用量显示非实时

- 证据：OMP 只在有 token 增量的 flush 发 `goal_updated`，纯 wall-clock 增长不持久化也不推送；popover 仅在打开/连接变化时 refresh。
- 影响：显示值在静默期陈旧。
- 处置建议：可接受。

## 已核实不构成问题的点

- 初始 prompt 与原生续跑的重复发送风险：OMP 的 `isSettled`/`session_settled` 谓词包含已排定未 admitted 的续跑，GUI 的补发条件闭合。
- 三种 JSON 形状（RPC 回复 `{goal,state}`、`get_state.goal`、`goal_updated {goal,state?}`）解码路径区分正确；事件过滤传 null，`goal_updated` 全量到达。
- 会话切换与进程恢复：OMP reconcile 将 active 目标恢复为 paused，GUI 在切换时清除旧终态证据，两侧一致。

## 局限

静态调研，未运行 GUI 现场（P1/P3/P7 的实际体感未经屏幕验证）；OMP 侧证据限于 18.11.2 npm 安装包，其他版本或渠道需重新核对；本记录不构成新的兼容性认证。GUI 现场与性能矩阵仍按[未关闭项](../status.md)单独安排。
