# N2 原生目标交付与证据（2026-10-17）

范围为 local `main` `2f65544` 之后的原生 Goal 接入，Dev `0.1.58` / build `59`。本记录使用 Asia/Hong_Kong 日期；运行目录采用 UTC 时间。当前入口见[聊天工作流](../chat-workflows.md#原生目标)，接口及数据归属见[原生接入](../OMP_INTEGRATION.md#native-goals)。

## 实现范围

- 顶部原生目标 sheet：目标、可选 token 预算、原生状态/用量、暂停/恢复/放弃。复用同一 OMP lead 进程，不为显示状态启动进程。
- 只使用公开 Goal RPC。OMP 管理工具集、持久化及续跑；GUI 不循环 prompt、不设置计时调度、不提供预算修改或手动完成的伪接口。
- 预算为原生收尾/续跑限制，不是进行中请求的硬性限额；暂停/放弃不 abort 当前模型轮次。`null` 不证明完成，仅保留本次连接明确观测到的终态。
- 原文提交上限 128 KiB，正文显示 64 KiB，错误保留 16 KiB，原生目标 ID 最多 1 KiB；未知变更保留请求身份和回收保护。未提交草稿阻止 runtime 被当作纯持久状态驱逐。

## 实际验证

检入的[验收摘要](../evaluations/2026-10-17-goal/acceptance.json)保存版本、运行时资产 hash、生产输入 hash、检查范围和两次测试预期修正。原始报告留在此 worktree 的 `build.noindex/verification/runs/`，该目录可按 owner 要求清理，不能把原始路径可用性视为永久保证。

| 检查 | 结果与证据 |
| --- | --- |
| `make build` | 初次构建通过；随后分别补草稿回收 guard、sheet 错误状态修正，各做一次受影响的增量构建通过。未启动应用 |
| `functional:goal` | 31 条通过，`20261016T164835Z-479c13aa/report.json`；验证 schema、空值/终态、原文/字节预算、操作前 state 晚回、pause/drop、超时与迟到确认、旧版拒绝。没有模型调用 |
| `native:goal` | 官方 standalone OMP 18.11.2，10 条通过，`20261016T165152Z-c122bd81/report.json`；独立 profile、全新会话、回环 HTTP 确定性 provider |
| `static:documentation harness syntax` | 通过，`20261016T165206Z-ebb1ebf2/report.json`；登记与执行器契约 29 条、文档链接及脚本/Swift 语法 |

功能检查之后的生产修改限于 `holdsOnlyPersistedState` 的目标草稿 guard 和 sheet 错误状态，不触及已通过的 Goal API/fixture；其 31 条证据按相关输入未变复用。原生检查使用草稿 guard 后的增量构建。末次 sheet 修正仅让未确认变更的错误跟随原生 snapshot 清除，避免匹配迟到确认后本地 `@State` 继续显示旧错误；只读刷新成功也清除过期本地错误。该 UI 局部修正做一次增量构建，复用不涉及 UI 的 31 条功能及 10 条原生证据。新增本记录和索引、随后局部更新本段后，仅选择 `static:documentation` 复核链接。

原生资产保存在本 worktree 的 `build.noindex/native-runtime/omp-darwin-arm64`，194785312 字节，SHA-256 为 `dfbf52e9ec966e3066e5d8f6df31829dbb4882ca74d82b2fb511b659017f69cc`；没有替换系统安装或写入外部 OMP profile。

原生验收证明公开操作、真实 complete 工具事件、软预算、恢复进程后暂停，以及配置允许 RPC continuation 时由 OMP 自行启动一轮并在无工具进展时抑制下一轮。它不认证任意模型的任务完成质量或跨 provider 行为。

## 失败分析与边界

首次 native 失败来自测试 provider 用整串相等匹配输入，漏掉 18.11.2 附加的 system-reminder 文本前缀。读取请求记录后修正 marker 匹配，未改生产逻辑。第二次失败来自测试在 settled 后立即断言本地目标已清空，早于异步 state 回包；原生日志已有同 ID 的 complete、`mode:none` 与 `goal-completed`。增加明确只读查询后保留原断言，仅重跑失败的 `native:goal`，最终通过。

未运行 GUI、键盘/输入法/VoiceOver/窄布局现场验收、Liquid Glass 最终合成、Q 全应用延迟和资源负载，也未重跑旧 RPC 矩阵或调用外部付费 provider。这些仍按[当前边界](../status.md#尚未关闭的验收)单独安排。
