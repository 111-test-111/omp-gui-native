# P3 原生能力入口

> 历史记录：仅代表原文所列日期、版本及验收范围，不是当前操作指南。 当前已移除的收件箱、会话记录、独立 fork 和诊断入口不因本文的历史描述而恢复为功能。 当前入口见[文档索引](../README.md)和[功能状态与验收边界](../status.md)。

2026-10-16，基于本机 OMP 18.3.2 的公开实现核对，不将新版文档或命令名称视为连接状态证据。

## 命令目录与扩展 UI

`get_available_commands` / `available_commands_update` 的 `source`、`aliases`、`input.hint`、`subcommands` 都进入 GUI 命令模型。内置、技能、扩展、自定义、MCP prompt 和文件命令分别标注；别名可搜索，子命令可选择。GUI 只提交原生命令，技能仍由 OMP 展开和执行。目录只描述当前会话可调用命令，不充当插件安装清单。

扩展 `select` 的 `optionDetails` 按位置匹配说明；`editor` 使用原生多行编辑器并保留 `prefill`、换行与空白，允许提交空文本。`input` 保留原生占位文字。原生毫秒超时在 GUI 同步计时，过期发送 `cancelled/timedOut` 并关闭对应请求；OMP 的取消事件只移除指定请求。进程退出和会话分支清除旧请求与计时器。

`setStatus` / 文本数组 `setWidget` 用 SwiftUI 文本显示，保留组件键与 above/belowEditor 位置。最多保留 16 个状态、8 个组件、每组件 64 行、每行 2,048 字符；单组件可视高度不超过 120 点。终端控制符不会成为 GUI 控制指令。刷新合并到最多每 100 ms 一次，交互请求不等待这层合并。

`set_editor_text` 交给运行时处理；用户正在输入时提供“使用准备好的文本”入口。明确应用替换前保留原草稿，避免丢失用户文字。登录 URL 仅接受 HTTP(S)，页面显示实际 provider 主机，用户点击后才打开；原生提供的短 loopback `launchUrl` 优先用于复制，避免 OAuth 参数被截断。任意远程替代地址不覆盖 provider URL。

OMP 18.3.2 的 RPC 不提供任意 TUI 工厂、定制 header/footer/editor、同步 `getEditorText` 或自定义终端组件。这些能力不在 GUI 仿制，保留 OMP 终端入口。

## 配置、认证与插件

模型角色使用字段表单，包含常用聊天角色以及 vision、commit、memory、task、advisor 和原生媒体角色。子代理设置包括并发数、隔离、结果应用、递归深度、模型覆盖及禁用代理名称。CLI 对负数参数使用合法 JSON 前导空白，兼容 18.3.2 的参数解析。原生的 `0` 并发上限、`-1` 递归深度等值按实际语义显示。选择器仍是原生字符串，接受 `provider/model` 或 `@role`。表单只修改显示的字段，保留未知原生字段和未来非字符串值。

`omp config path` 确定外部活动 profile；CLI 查询在项目之外执行，并从设置专用读写环境中移除 `PI_CONFIG_FILES`，避免将聊天进程的覆盖值复制进 profile；聊天环境保持原样。表单清楚标注写入活动 profile，项目、环境和进程覆盖可能使对话中的生效值不同。GUI 不切换 OMP profile。保存通过 `omp config set`；保存前重新核对 profile 路径、可执行文件与环境身份、配置文件 SHA-256 指纹与原生返回值；读取返回后、写入前再次核对身份与指纹。公开 CLI 没有 compare-and-swap 接口，因此这不构成跨进程原子保存保证。外部 CLI 已修改配置时拒绝覆盖并要求重新载入。窗口重新激活或点击重新载入会刷新 CLI 数据。指纹只保留摘要，不保留配置文件中的凭据。

账号登录使用公开 `login` RPC，OMP 自己管理认证监听器、OAuth、API key 与持久化。登录后原生 input 回调由 SwiftUI 表单回答；不支持 RPC 的 secret/交互认证路径保留“在 OMP 终端中继续”。用户取消会停止该临时无会话 RPC 进程。未登录时不会自动发起认证。

18.3.2 在没有任何已认证模型时会提前退出非交互进程，此时无法通过 RPC 枚举登录 provider。设置页仍显示 `omp login` 原生终端入口，登录后可重新载入。角色、模型覆盖和禁用代理表单通过携带配置快照的 presentation item 打开，首次打开就保留既有值；保存仍核对原配置及 profile，避免把空初始状态当成用户编辑。

插件清单来自 `omp plugin list --json`，区分 npm 与 marketplace 原生条目和实际 scope；诊断调用 `omp plugin doctor --json`，不自动修复。安装、卸载调用原生 CLI 的公开操作，保留原生 registry、依赖和存储规则。项目 scope 只适用于 marketplace 插件，npm 包与本地链接仍由 OMP 放在用户插件目录。部分 marketplace 写操作即使带 `--json` 仍输出文本，成功退出码视为原生接收证据，避免把成功安装误报失败。只有用户点击安装或确认卸载时才执行写操作。

## MCP 状态边界

设置页读取并编辑 OMP 原生 profile / 项目 `mcp.json`，保留未知字段与外部修改冲突检查。配置是否启用单独显示；OMP 18.3.2 的公开 RPC `get_state` 没有 MCP 连接状态，因此 GUI 标注连接未知，不能用“已启用”或命令目录中的 MCP prompt 推断“已连接”。各配置文件提供对应工作目录与活动 profile 的 OMP `/mcp` 终端入口，连接、OAuth 和 live 管理由原生 TUI 负责。

## 核验

新增 `make verify AREAS="config"` 核验命令元数据、别名/子命令、富选项说明、多行预填、毫秒超时、取消隔离、刷新合并、组件边界、登录 URL、未知字段保留、配置指纹及原生插件 scope。脚本只使用独立 build.noindex 目录，不修改真实 profile、不进行真实认证或安装。

`make verify TIER=native AREAS="config" OMP=/absolute/path/to/omp` 使用本次 `build.noindex/verification/runs/<run>/native/config/agent` 运行生产配置服务及本机真实 OMP 配置 CLI：验证 profile 角色编辑、未知全局字段保留、`PI_CONFIG_FILES` 不污染 profile、负数递归深度、外部文件修改拒绝与重载。包装器仅将配置命令转给真实 OMP，额外模型/认证目录探测使用离线响应，不发起模型调用或改写真实活动 profile。

静态协议及状态检查不能替代真实 provider 认证、插件安装/卸载或 VoiceOver、窄窗口等整应用交互验收；最终构建、检查数和运行时结论由本任务整体验收记录给出。

后续真实原生验收已完成：自编本地插件经真实 OMP 安装、诊断及卸载，合成 provider 经真实登录 RPC 和 GUI 输入完成回调，扩展选项/编辑器/超时/取消、草稿保护以及配置表单在中文窗口验证。未使用真实外部账号执行重新授权。具体范围见 [P3/P4 验收记录](p3-p4-acceptance-2026-10-16.md)。

## 本机公开接口依据

安装包：`@oh-my-pi/pi-coding-agent` 18.3.2。

- `src/slash-commands/available-commands.ts`：目录来源、别名、参数与子命令。
- `src/modes/rpc/rpc-types.ts`、`rpc-mode.ts`：扩展文本/UI、超时、登录与 `get_state` 的实际字段。
- `src/cli/config-cli.ts`：配置路径、读取和全局写入语义。
- `src/task/settings.ts`、`src/config/model-roles.ts`：角色、递归深度、并发和子代理原生字段。
- `src/cli/plugin-cli.ts`：插件 inventory、doctor、安装/卸载、scope 与输出格式。
