# N4 原生资源选项条件交付与证据（2026-10-17）

范围为 local `main` `f90c874` 之后的 Slow 与缓存预热接入，保留 N0–N3 的共享集成。Dev `0.1.60` / build `61`。本记录使用 Asia/Hong_Kong 日期，原始运行目录采用 UTC 时间；当前产品入口见[聊天工作流](../chat-workflows.md)，协议边界见[原生接入](../OMP_INTEGRATION.md)。

## 实现与边界

- 在既有 Usage 原生运行选项 disclosure 内增加 SwiftUI 普通布局和共享 Chrome 紧凑动作，没有新 glass 面板、Web UI、轮询、定时器或 GUI 预热调度。
- Slow 写操作要求当前原生 `slowModeSupported=true`、已知 `session/global` 范围与模型。global 文案和动作明确其持久化、其他会话影响，不能套用本会话描述。用户动作先发起新的状态读取，拒绝复用动作前已在途的旧读；范围/模型改变即拒绝本次写。公开原生接口没有原子 expected-model/scope 参数，fresh read 到原生写之间仍存在外部变更窗口。
- 缓存预热只提供明确的 `off/streaming/idle`。协议没有 getter，显示值仅为当前连接已确认的 override；没有猜测继承值或伪造恢复默认。原生拒绝、未知能力、超时和迟到确认沿用同一运行选项请求身份；未知请求保持 pending 与进程保护，不自动重发。
- 只保留最近一条有效原生 warming start/end 事件，不能把它等同于精确当前活动或调度。provider/model 各限 4 KiB，stop reason 限 16 KiB；可选原生非负有限 `usage.cost.total` 标明已包含于总费用，不重复记账、不累计事件列表。
- 明确成功或拒绝后按需读取一次当前状态，替换被运行选项 revision 废弃的 Goal settlement 观察，避免永久阻塞回收；未知 pending 不重发，不引入读取循环。

## 验证

[检入验收摘要](../evaluations/2026-10-17-resource-options/acceptance.json)保存输入与二进制证据、原生资产 hash、每层范围及静态结果。原始产物位于本 worktree `build.noindex/verification/runs/`，生成目录是否保留由 owner 决定。

| 检查 | 结果与证据 |
| --- | --- |
| `make build` | 最终合入 N2/N3 后一次通过；没有启动 GUI |
| `functional:resource-options run-options rpc` | 32 / 39 / 95 项首轮通过，`20261016T171130Z-b9e7e36e/report.json`；包含旧 Slow 读被新 global 状态替代、Fast 明确拒绝与 Goal settlement 挂读交错 |
| `native:resource-options` | 官方 OMP 18.11.2，13 项首轮通过，`20261016T171130Z-a773e64c/report.json`；隔离 profile/session，模型请求为零，配置字节不变 |
| `benchmark:event-projection` | 单次通过，`20261016T171220Z-586464f0/report.json`；见下表和测量边界 |
| `static:documentation harness syntax` | 交付文档写入后选择，最终结果及报告由验收摘要记录 |

原生检查只读复用 N2 已核验官方资产，SHA-256 为 `dfbf52e9ec966e3066e5d8f6df31829dbb4882ca74d82b2fb511b659017f69cc`，194785312 字节，没有系统安装或外部 profile 改写。它确认本地模型的 Slow 不支持/拒绝与关闭 no-op，以及预热 `off → streaming → idle → off` 的真实回显；未用真实账号启用 global Slow，未运行付费预热。四类 warming 终态和 global GUI 范围保护来自隔离 fixture。

## 投影语料精度修正与单次测量

N0 的既有合成 delta 语料省略了整个 `message`，而原生 delta 仍保留 `message.role`。本次只补回该字段，完整消息终态不变；[原 N0 历史测量](event-projection-acceptance-2026-10-17.md)保留原始语料范围，不改写旧结果。这是既有合成语料的小偏差，不是生产 decoder 修复或新的应用性能提升。

[本次对照数据](../evaluations/2026-10-17-resource-options/event-projection-comparison.json)使用相同 133 帧、正文和工具参数各 106,496 UTF-8 字节。两种投影输出 71 条相同归一化事件。

| 指标 | Full | Delta |
| --- | --- | --- |
| 合成 NDJSON 字节 | 34,545,220 | 676,141 |
| JSON 解析总耗时 | 74.583 ms | 2.380 ms |
| decoder 与相同事件收集 | 0.959 ms | 0.675 ms |

这是 full 后 delta 的一次有序观察。未测真实 stdio 传输、内存分配、GUI 资源、屏幕延迟或统计 p95，也没有同负载父提交性能对照；不能关闭 Q。没有检查失败或重复测量。N2/N3 已通过的独立原生与生命周期证据按原范围复用，未扩大为本次全量认证。

没有启动 GUI；键盘、输入法、窄布局、VoiceOver、Liquid Glass 最终合成、真实账号 Slow 与有费用的预热生命周期仍未现场验收。整应用资源与延迟仍按[当前未关闭边界](../status.md#尚未关闭的验收)单独安排。
