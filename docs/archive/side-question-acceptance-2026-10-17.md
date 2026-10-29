# N3 原生旁问交付与证据（2026-10-17）

范围为 local `main` `6022490` 之后的原生 BTW 旁问接入，Dev `0.1.59` / build `60`。本记录使用 Asia/Hong_Kong 日期；运行目录采用 UTC 时间。当前入口见[聊天工作流](../chat-workflows.md#旁问)，协议与排空边界见[原生接入](../OMP_INTEGRATION.md#side-questions-and-disposal)。

## 实现范围

- 主输入框旁的 SwiftUI 原生 sheet，复用当前 OMP lead 连接；一项主题、追问和取消独立于主回复、队列、Hydra 与主会话费用投影。关闭 sheet 释放正文布局，当前有界状态与独立草稿由所属 runtime 共享。
- 使用公开 `btw`、`btw_cancel`、`btw_record`、`btw_delta` 和 `btw-history` notice。GUI 不请求完整旁问历史、不直接读取或复制原生 sidecar，也不提供主题历史浏览或跨连接恢复。
- 原文输入最多 128 KiB，仅判空与原生匹配时 trim；主题达到 16 轮或原生累计正文 1 MiB 后禁止追加。GUI 问答及逐轮错误合计最多显示 64 KiB，按 UTF-8 边界省略旧正文；增量显示合并到 50 ms，独立错误有界保留。
- 未知 admission/cancellation 保留请求身份、草稿与回收保护，匹配迟到结果后解除。明确原生拒绝可重试，传输超时与缺帧不自动重发。原生 `started` record 可早于 RPC 成功回包，旧 record 不覆盖已观测终态或较新增量。
- 原生回答终态早于 sidecar 保存，协议没有保存成功 ACK。自动回收先关闭 stdin，继续读取输出并等待真实退出；排空期间拒绝新输入和普通连接替换，不设自动强杀。已知保存失败阻止自动排空，EOF 期间的保存 notice 即使伴随 exit 0 也保留错误；显式停止仍沿用原有终止语义。

## 实际验证

检入的[验收摘要](../evaluations/2026-10-17-side-question/acceptance.json)保存版本、生产输入 hash、原生资产 hash、检查范围和证据复用说明。原始报告留在本 worktree 的 `build.noindex/verification/runs/`；该目录可按 owner 要求清理，原始路径不保证永久可用。

| 检查 | 结果与证据 |
| --- | --- |
| `make build` | 首次构建及两次源审修复后的增量构建均通过；未启动应用 |
| `functional:side-question` | 最终 47 条通过，`20261016T170307Z-aa3533dc/report.json`；含有界投影、草稿身份、未知回包、取消、EOF 与 Goal settlement 交错 |
| `functional:rpc lifecycle` | 95 条 RPC、67 条生命周期及 2 条默认 metrics 检查通过，`20261016T165845Z-6b9377a8/report.json`；与首次旁问检查同次选择 |
| `native:side-question` | 官方 standalone OMP 18.11.2，11 条通过，`20261016T165944Z-43bcf8f1/report.json`；独立 profile、新会话与回环 HTTP 确定性 provider |
| `static:documentation harness syntax` | 交付前重新选择并通过；文档链接、29 条登记/执行器契约与脚本/Swift 语法。首轮静态报告为 `20261016T165845Z-51dab195/report.json`，最终报告保存在同一运行目录 |

原生检查证明：真实主 prompt 仍运行时可执行旁问；同主题原生追问、独立取消及主费用不重复记账；EOF 后原生输出和进程均结束，再检查该次隔离 session 的原生 sidecar，确认同一主题、两项 follow-up 及最终 cancelled turn 已保存。测试读取隔离产物用于验收，产品不读 sidecar。资产由 N2 获取并校验，本任务只读使用其 `build.noindex/native-runtime/omp-darwin-arm64`，194785312 字节，SHA-256 为 `dfbf52e9ec966e3066e5d8f6df31829dbb4882ca74d82b2fb511b659017f69cc`；没有替换系统安装或使用外部付费 provider。

## 源审修复与证据复用

检查均一次通过，没有通过重复执行掩盖失败。源审随后发现并修复两项确定交错：第一，成功 admission 等待 record 投影或解析时连接已 reset，身份不符必须直接取消，不能向新 snapshot 写入未知错误；第二，旁问未改变主配置或会话，不能递增全局 state revision，否则会废弃 Goal 操作后唯一 settlement 回包，导致后台连接永久无法进入 EOF 排空。最终 47 条旁问检查覆盖这两项真实交错，并在最终构建上通过。

此前 RPC、生命周期与原生检查的生产覆盖路径未被上述局部修复改变，按输入范围复用通过证据；原生使用的 dylib 原始 SHA-256 与最终构建证据分别保留，不把原生结果冒称为最终二进制全量复验。最终修改的 Swift/Python fixture 与文档一并通过交付静态检查。

未运行 GUI、键盘/输入法/VoiceOver/窄布局现场验收、Liquid Glass 最终合成、Q 整应用资源/延迟负载，也未重跑 Goal、旧 native RPC 矩阵或使用外部付费模型。原生 EOF 退出仅提供此公开协议可观测到的排空边界，不补造持久化 ACK；任意存储故障及模型回答质量不在本次认证范围。其余验收继续按[当前边界](../status.md#尚未关闭的验收)单独安排。
