# 原生能力阶段实施记录（2026-10-17）

对应[下一阶段功能计划](next-functional-plan-2026-10-17.md)。本记录区分代码与接口交付、合成测量和仍需授权的现场验收；当前使用入口以[聊天工作流](../chat-workflows.md)、[OMP 接入](../OMP_INTEGRATION.md)及[状态](../status.md)为准。

N0–N4 已集成本地 `main`，该批代码提交至 `db7f8bf`，Dev `0.1.60` / build `61`。后续授权的[Q 局部现场验收](native-q-acceptance-2026-10-17.md)包含本地化修正与定向复核；完整 Q 尚未关闭。

## 实施进展

| 工作包 | 本地集成 | 交付与证据 |
| --- | --- | --- |
| N0：增量传输 | `f7d264a` | 协商原生 delta，旧版保留 full；[验收记录](event-projection-acceptance-2026-10-17.md) |
| N1：Fast 与重试 | `2f65544` | 请求/实际 Fast 状态、自动重试 override、停止重试；[验收记录](run-options-acceptance-2026-10-17.md) |
| N2：Goal | `6022490` | 目标、软预算、原生终态、暂停/恢复/放弃；[验收记录](goal-acceptance-2026-10-17.md) |
| N3：旁问 | `f90c874` | 当前主题与追问、取消、未知送达保护、原生 sidecar 退出保存；[验收记录](side-question-acceptance-2026-10-17.md) |
| N4：Slow 与缓存预热 | `db7f8bf` | 原生 scope/支持性、显式 warming 模式与最近事件；[验收记录](resource-options-acceptance-2026-10-17.md) |
| Q：现场验收 | 局部执行 | 已授权的窗口/稳态资源证据及限制见[Q 记录](native-q-acceptance-2026-10-17.md)；实际屏幕 p95 和完整系统矩阵仍开放 |

每包在独立任务 worktree 开发并作为一个本地提交 fast-forward 到 `main`。N0–N4 提交时未启动 GUI；其后仅按 owner 授权执行本任务 Q。没有安装/打包应用、修改已安装 OMP、远端 push 或发布；任务 worktree 与证据按 owner 的清理规则保留。

## 验证与证据边界

自动检查按变化选择，没有默认全套或跨版本重跑。功能 fixture、原生 RPC 与 benchmark 分层执行，具体命令、报告、失败分析及重跑范围在各包记录中。

- N0：`functional:rpc` 及独立 `benchmark:event-projection`；合成 full/delta 的最终文本、工具参数和事件语义一致。
- N1：`functional:run-options/lifecycle/workflows`，隔离 OMP 18.3.2 的 `native:run-options`。
- N2：`functional:goal`，官方 OMP 18.11.2 + 本地确定性 provider 的 `native:goal`。
- N3：最终 `functional:side-question` 47 条；复用仍有效的 `functional:rpc/lifecycle` 和 `native:side-question` 11 条。两处源审竞态在最终构建上补齐确定性交错，未冒称全部旧证据针对最终 binary 重跑。
- N4：`functional:resource-options/run-options/rpc` 32 / 39 / 95 条，官方 OMP 18.11.2 的 `native:resource-options` 13 条通过，模型请求为零；单独执行一次修正语料后的 `benchmark:event-projection`。
- 各包的文档、检查登记和脚本变更执行相应 `static:documentation/harness/syntax`；N0–N4 文档汇总仅做静态链接检查，其后的本地化/手动入口构建及 Q 检查另记在 Q 记录中，不重复原生与 benchmark。

官方 18.11.2 standalone 的路径、来源和 SHA-256 保存在 [Goal 验收](goal-acceptance-2026-10-17.md)。它仅用于隔离检查，本机 npm OMP 18.3.2 的安装未变。旧版/缺失字段的兼容行为由 fixture 与已记录的原生结果分工覆盖；版本号不直接开启功能，运行时仍以当前进程的有效回复或精确 unknown-command 为依据。

原生检查使用本地确定性 HTTP provider，不认证外部账号的模型质量、服务等级或付费缓存预热。合成 event-projection 只比较 NDJSON 字节及 parser/decoder 耗时，不包含真实 OMP stdio、GUI、分配或屏幕 p95，不能据此宣布 Q 性能达标。

N4 修正了 N0 合成 delta 语料遗漏的 `message.role`。修正后 full / delta 为 34,545,220 / 676,141 字节，两者产生相同的 71 条归一化事件；原 N0 测量保留其原始语料范围。此次一次有序测量不等于应用性能提升比例，原始数据及耗时见 N4 记录。

## 原生 UI 与资源边界

目标与旁问使用 SwiftUI sheet，运行选项扩展现有 Usage；共享 Chrome 只为符合约定的紧凑单行动作应用 Liquid Glass。没有新增 WebView、后台轮询、GUI 执行循环、worker 调度或主题历史扫描。新增用户文案均维护 zh-Hans。

目标与旁问单次输入限 128 KiB，目标显示正文限 64 KiB；旁问当前主题的合计显示正文限 64 KiB，最多 16 轮或累计原生问答正文 1 MiB 后停止向该主题追加。提交原文不静默裁剪，完整原生记录归 OMP。未知变更保留身份与草稿，不自动重发；旁问终态不等于 sidecar 已保存。

已删除的收件箱、最近请求、Session records、历史树/分页、独立 fork、工具 inspector/双向定位、MCP 观察与运行时诊断未恢复。计划模式、agent/skill 定义浏览和隔离结果应用仍遵守原计划的公开接口门槛，未以 GUI 仿真替代。

## Q 现场范围与开放项

[AGENTS.md](../../AGENTS.md)要求：`make run`、launching/relaunching GUI 须 owner 明确请求。代码交付后 owner 已授权本任务启动、验收并退出自己的实例；[Q 记录](native-q-acceptance-2026-10-17.md)区分实际完成的局部检查、失败与缺测。以下保留原定门槛，不把 helper 或合成结果当成实际窗口成绩：

| 范围 | 现场核对 |
| --- | --- |
| 新入口交互 | Goal、旁问、Usage 选项的中英窄窗口、键盘、焦点归还、Escape 与审批/问答回归 |
| 系统与可访问性 | 真实输入法组合、VoiceOver、减少透明度/动态效果、睡眠唤醒及最终 Glass 合成 |
| 实际响应 | 输入/菜单 p95 ≤ 100 ms、缓存首屏 ≤ 150 ms、万条消息冷首屏 ≤ 800 ms；普通流式事件到实际屏幕 p95 ≤ 100 ms |
| 并发压力 | 大输出、多 worker、大文档、主回复与旁问并发；输入不饥饿且内存有界，单列刷新分布 |
| 空闲与回收 | 无原生后台工作时 GUI 平均 CPU ≤ 单核 1%；100 次聊天切换、20 次预览开关及新增 sheet 开关后稳定 30 秒，增量 ≤ max(基线 10%, 20 MiB) |
| 归属与对照 | 区分 GUI、OMP/Bun、worker、WebKit、MCP 角色与整体峰值，固定硬件/原生版本/负载并与同负载父提交对比 |

这些是计划目标；实际屏幕 p95 与完整活动期整应用资源尚无通过结论。后续继续选择受影响路径，记录环境与剩余项；选定检查结束即停止，不自动扩张账号/模型矩阵。真实全局 Slow 写入和付费 warming 生命周期未纳入本轮原生证据。
