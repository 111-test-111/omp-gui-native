# 当前会话工具快照与设置工具区（2026-10-21）

本记录的会话检查实现对应 `f49c840`。随后按 owner 要求改为[全局静态工具目录](../OMP_TOOLS.md#global-tool-catalogue)，移除了会话读取、刷新、状态与参数弹窗；下面保留当时的快照和验证证据。

## 真实 GUI 会话读取

对象是已运行的 OMP GUI Dev 中选中的「Adapt latex-document skill for OMP」，安装的 OMP 为 18.11.2。原生连接已回收，先通过现有上下文刷新恢复保存的会话，再执行原生 `/dump`；没有向模型发送普通提示词，也没有启动或重启 GUI。

原生 LLM request 快照包含 13 个直接工具：`read`、`bash`、`edit`、`ask`、`eval`、`glob`、`grep`、`find`、`task`、`wait`、`todo`、`web_search`、`write`。

模型提示词目录及 MCP routes 包含 12 个挂载工具：`ast_edit`、`debug`、`lsp`、`generate_image`、`retain`、`recall`、`reflect`、`memory_edit`、`gui_read_selected_context`、`gui_open_file_location`、`mcp__context_7_query_docs`、`mcp__context_7_resolve_library_id`。

`eval` 的实际描述声明 `py` / `js`，预置能力为 `browser`、`archive`。共享入口包括 `display`、`print`、`log`、`phase`、`read`、`write`、`env`、`output`、`tool`、`wait`、`judge`、`judge_batch`、`completion`、`budget`、`agent`、`workpool`。描述同时包含安装、加载和自定义函数辅助用法。`computer`、`ratchet` 未出现在此快照的已公布预置能力中。

这里的记忆工具来自 GUI 会话的 Mnemopi 开关，不能用外部 CLI 的 `memory.backend=off` 覆盖这一事实。MCP routes 是这个原生会话实际公布的工具；配置文件存在与否不用于推断连接或可用状态。

只提取工具元数据的 JSON 保存在任务 worktree 的 `build.noindex/inspection/selected-session-tools.json`，不检入完整聊天或系统提示词。直接工具含完整描述/Schema；旧版 `/dump` 的挂载目录仅含原生摘要，完整挂载 Schema 由本次新增的 SDK 读取入口提供。

## 实现与边界

`f49c840` 中的 `OMPGUI/App/Views/Settings/ToolsSettingsPage.swift`展示按能力分组的完整身份目录及动态条目，支持搜索、只看可用、原生描述/Schema/预置指导的只读详情。可用状态来自本会话的公开 SDK；已有连接可自动读取，冷连接由刷新操作恢复，未建会话不创建替身。

当时的 `OMPGUI/Resources/OMPToolInspection.js` 只读桥接不执行工具、不加载 eval 内核、不启动浏览器/MCP，也不改原生配置或工具选择。只把同时启用且已向模型公布的预置能力标为可用。旧版/standalone 只报告直接工具时，其余状态为未知。已知但未注册的普通工具在完整目录中显示未启用，四个上下文动作设备保留未知。

结果按请求 ID、原生 session ID、会话文件和运行时 epoch 校验。并发读取合并，切换会话时立即丢弃前一页状态；分支取消旧读取但保留同一连接的检查能力。失败刷新保留最近一次成功快照，显示错误和快照时间。

## 验证

验证全部通过：

- `make build`：Dev 0.1.157 / build 158。首次构建通过后，仅收敛本地化目录的序列化差异并增量重建，保留原目录格式；没有重复运行等价功能覆盖。
- `make verify AREAS="tools tool-bridge"`：35 项 Swift/协议检查及 Node 桥接检查。报告：`build.noindex/verification/runs/20261021T060305Z-fffd88e0/report.json`。
- `make verify TIER=native AREAS="tools" OMP=/absolute/path/to/omp`：实际安装 OMP 18.11.2 的 15 项隔离 SDK 检查。报告：`build.noindex/verification/runs/20261021T060235Z-8dafc650/report.json`。
- `make verify TIER=static AREAS="documentation harness syntax"`：文档链接、29 项执行器契约及语法检查通过。报告：`build.noindex/verification/runs/20261021T060040Z-7c295158/report.json`。

不执行其他兼容矩阵、GUI 或性能负载。

未进行新工具页的可见窗口验收：中英文、键盘/VoiceOver、原生玻璃合成、长描述/Schema 实际滚动及刷新/切换交互仍需单独运行新构建确认。只读旧窗口快照不代表新页面的整应用验收。
