# N1 原生运行选项交付（2026-10-17）

基线 `main f7d264a`；任务树 `codex/omp-run-options`。实现[下一阶段计划](next-functional-plan-2026-10-17.md)的 N1，Dev 为 0.1.57 / build 58。

## 行为与边界

Usage 新增原生运行选项展开区，分别显示 Fast 请求/实际状态、已确认的自动重试会话 override，以及原生重试次数、等待和原因。明确的启用/关闭动作不作变更探测；实际 Fast 生效才在当前模型 chip 显示标记。「停止重试」不等同于中断任务。

设置由当前会话的公开 RPC 执行，无 profile 写入、模型请求、GUI 重试循环或额外轮询。缺失实际 Fast 字段保持未知；缺失请求设置的成功回复仍视为无效。失败保留原值，变更超时保留身份与独立回收 blocker；旧读取、旧模型或旧会话回复不能覆盖新状态。打开界面不启动进程。

## 验证

- 应用构建通过。初次编译后，源码审阅发现 Fast 缺实际状态字段不应把已确认的请求设置也视为未知，修正兼容语义后做一次受影响的增量构建；没有启动 GUI。
- 功能 `run-options` 39 项、`lifecycle` 67 项及默认测量关闭 2 项、`workflows` 120 项通过。
- 静态 `documentation harness syntax` 通过；新增本交付记录后只复核文档链接。
- 本机 OMP 18.3.2 的 focused `native:run-options` 12 项通过，使用隔离 profile、本地 provider；未发送模型请求，`config.yml`/`models.yml` 字节未改。只验证原生接口，不认证外部模型的 Fast 可用性。

首次 native 检查误把本地确定性模型当作可启用 Fast 的模型，原生明确拒绝。读取该版 `rpc-mode.ts` / `model-controls.ts` 后确认属于测试预期错误：没有 service-tier family 的模型应拒绝启用；随后改为验证拒绝保持状态、命令能力仍未知，以及禁用的成功回显，只重跑该失败模块。未改变生产逻辑或换模型规避限制。

功能报告：任务树 `build.noindex/verification/runs/20261016T164024Z-38acdb08/report.json`；静态报告 `20261016T164025Z-23fbe33b/report.json`；原生修正后的报告 `20261016T164140Z-05341fcd/report.json`，原失败保留在 `20261016T164036Z-934b25de`。

真实中英窗口、键盘/输入法/VoiceOver、最终 Glass 合成和整应用性能仍属于 Q，不以本次编译或 fixture 成绩关闭。
