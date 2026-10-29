# OMP 18.12.5 升级兼容检查（2026-10-22）

Owner 要求将日常 OMP 从 18.11.2 升级到 18.12.5，并检查、修复 GUI 的审批、Hydra 和记忆接入。工作在从本地 `main` 创建的独立 task worktree 完成；不启动或重启 GUI，不运行外部付费模型，也不改活动 profile。

## 审批修复

18.11.3 起原生审批可以提供会话授权；18.12.3 又增加文件、目录和跨会话缓存授权。RPC 仍使用公开 `select`，但菜单不再固定为 `Approve` / `Deny`。旧 GUI 将扩展菜单投影成普通问答，原生答复入口也只允许固定字符串。

现在以原生标题及已知选项识别工具审批，保留请求 instance、时限、完整详情及取消行为。审批卡片和全部允许仍只返回本次调用的原始选项：无缓存授权时是 `Approve`，有缓存授权时是 `Approve Once`。原生 URL 目标菜单中的 `Approve` 本身可能是缓存授权，已在投影、会话答复防护和实际原生解释三处覆盖。GUI 不添加会话/持久授权入口；未知或损坏的菜单继续使用普通原生选择题。

## 选定验证

固定官方 npm 包 18.12.5 先安装在本 worktree 的 `build.noindex/omp-runtime`，不替换仍被当前 GUI 加载的全局目录。所有本轮原生检查明确指定该路径；不是旧版本或 standalone 的历史证据。

| 层级 | 模块 | 本轮结果 |
| --- | --- | --- |
| 构建 | `make build` | 最终集成 Dev 0.1.177 / build 178 通过，未启动 |
| 功能 | `interactions` | 98 条；新旧审批、缓存 URL 单次授权、送达/取消/时限及请求身份 |
| 功能 | `workers` | 98 条；元数据、可见日志、游标、ID 复用、追加指令和结果边界 |
| 功能 | `memory` | 仓库/worktree/符号链接身份、全局文件缓存、有界预览和 EOF 排空通过 |
| 原生 | `approvals` | 5 类真实 SDK 菜单，10 次生产响应往返，结果始终为 `once` / `deny` |
| 原生 | `workers` | 21 条；主/子/孙配置继承、普通 WebSocket 保留及工具边界追加消息恰好一次 |
| 原生 | `memory` | 生产 SDK host/RPC/EOF 排空及 21 条真实 SQLite/FTS 检查通过 |
| 原生 | `rpc` | 22 条；真实 task worker 启动、steer、取消、父子日志身份、恢复/队列及协议分帧通过 |

Hydra 的原生 worker 由本地确定性 HTTP provider 驱动，另用注入流检查队列；不替代真实 Codex 服务端 live steering 认证。记忆覆盖同仓库 worktree 共用、不同项目隔离、全局召回、原生提示词与 `memory_recall` 持久快照、预览不改召回、关闭/恢复及 retention cursor；关闭 embeddings 与 LLM。Hydra 和 Mnemopi 无需新增生产适配。

构建预编译期间发现会话答复入口也需要保留原生单次标签，主动中止首轮构建后修正；最终构建通过。首次新增审批回归误用未绑定会话的 `ThreadRuntime.resolve`，被现有身份保护拒绝；依据生产与测试接线确认是测试搭建问题，改用该检查已持有的真实会话答复入口，保留送达与权限范围断言。随后功能及原生所选模块均通过，不重复已通过范围。

静态 `documentation harness syntax` 全部通过，包含 29 条执行器契约检查。机器可读摘要及原始报告路径见[本轮证据](../evaluations/2026-10-22-omp-18-12-5/acceptance.json)。

合入前本地 `main` 新增独立的服务商退出提交 `af2f8e7`。在任务 worktree rebase，保留双方 changelog，Dev 版本顺延至 0.1.177 / build 178，并完成最终增量构建。审批、Hydra、记忆、SDK host、所选测试及执行器源码与已验证候选保持一致，复用原功能/原生证据，不因无关服务商设置改动重跑等价负载。摘要分别保留原检查的构建身份和最终集成构建身份。

## 日常安装切换

Owner 明确许可保存并退出当前 Dev GUI 后，向该实例请求正常退出，确认应用及所属 OMP host 均已结束。沿用现有 fnm 的 npm prefix 执行固定版本 `npm install --global --prefix <existing-prefix> @oh-my-pi/pi-coding-agent@18.12.5`。日常 `omp --version` 返回 `omp/18.12.5`；安装包及依赖共 26,049 个文件的路径/内容摘要与本轮验证候选逐字节一致，复用其原生通过证据，不重跑等价负载。所检查的外部原生配置文件哈希保持不变。未重启 GUI，未导入或修改既有会话、账号和记忆数据库。

## 验收边界

未验证完整 GUI 的审批弹层、中英文/键盘/VoiceOver 或玻璃合成；未访问既有会话和记忆数据库，未认证外部服务商、真实账号、embedding/长期记忆质量或性能预算。[当前开放项](../status.md#尚未关闭的验收)继续保留。不会因为版本号更高而为新进程假定 RPC 能力，也没有添加 worker 调度器或 GUI 续跑循环。
