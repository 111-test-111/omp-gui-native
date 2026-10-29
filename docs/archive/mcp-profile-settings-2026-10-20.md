# 活动 profile MCP 设置 — 2026-10-20

本轮在独立 `codex/settings-profile-mcp` worktree 实现，Dev 版本为 0.1.147 / build 148。当前行为见 [OMP 接入](../OMP_INTEGRATION.md#mcp-history-and-context)，实现入口为 [设置页](../../OMPGUI/App/Views/Settings/MCPSettingsPage.swift)、[服务器编辑器](../../OMPGUI/App/Views/Settings/MCPServerEditor.swift)、[配置模型](../../OMPGUI/Core/Models/OMPMCP.swift)及[文件服务](../../OMPGUI/Services/MCP/OMPMCPConfiguration.swift)。

## 交付范围

- 通过原生 `omp config path` 识别活动 profile，仅管理其 `mcp.json`；不扫描项目 MCP，也不在应用启动时读取所有项目配置。
- 支持列表搜索、启停、重命名及确认移除，提供 npx、uvx、自定义命令、远程服务器安装配置入口。
- 可视化编辑覆盖 stdio/HTTP/SSE、argv、工作目录、环境变量/请求头、超时及服务器指令；可切换单服务器 JSON，另有完整配置 JSON 编辑与格式化。
- 保留原生 OAuth、环境引用、`!command` 及未知字段；环境/header 值默认遮掩。原生 profile 覆盖数组遵循 OMP 的 denylist 优先级。
- 保存前核对 profile、执行环境、目录身份和原始字节，拒绝符号链接及冲突，使用 macOS advisory lock、私有临时文件和原子替换。配置限制 2 MiB；可视化数组/映射每组最多 128 项，较大定义继续使用 JSON。

“安装”保存原生服务器定义。OMP 在新会话启动时运行它，npx/uvx 在需要时下载包；GUI 不自行执行安装命令、创建 MCP 连接或管理认证。

## 验证与证据

| 检查 | 结果及边界 |
| --- | --- |
| `make build` | 通过。首次完整构建后，对表单删除绑定、确认移除身份及本地化收尾做增量构建；无 GUI 启动或安装 |
| `make verify AREAS="mcp"` | 54 项通过：覆盖编辑/JSON 往返、原生覆盖、重命名/移除、凭据保留、不执行引用、原始字节冲突、profile/环境变化、锁竞争、符号链接、损坏 JSON 修复及读写大小限制 |
| `make verify TIER=native AREAS="mcp" OMP=…` | OMP 18.11.2 通过；只调用真实 `config path` 并操作全新隔离 profile，核对命名 profile 路径、配置往返及切换保护 |
| `make verify TIER=static AREAS="documentation harness syntax"` | 文档链接、29 项执行器契约及脚本语法通过；末尾文档/原生测试变更只复查对应静态项 |

功能报告：`build.noindex/verification/runs/20261020T131650Z-c59f6737/report.json`。原生通过报告：`build.noindex/verification/runs/20261020T132243Z-ea255a43/report.json`。最初静态报告：`build.noindex/verification/runs/20261020T131546Z-65ad3943/report.json`；语法收尾报告：`build.noindex/verification/runs/20261020T132234Z-54d1e8bd/report.json`。最终构建指纹为 `build.noindex/development/verification-inputs.json`。所有路径均位于该任务 worktree 的生成目录。

原生检查第一次失败来自测试的路径预期：安装的 OMP `getBaseConfigRoot()` 使用 `path.join(HOME, PI_CONFIG_DIR)`，测试却把绝对 `PI_CONFIG_DIR` 当作独立根目录。已对照安装源码，将隔离 fixture 改为 HOME 下的相对配置目录并保留精确路径断言；生产实现始终使用 CLI 返回路径，无需修正。只复跑该失败的原生检查。功能实现的 Core/Services 在通过后未变化，后续仅调整 UI 绑定、确认操作及本地化序列化，因此复用已通过的 54 项证据。

## 未验收项

没有启动 GUI、实际 MCP 服务、npx/uvx 包下载、OAuth 或付费模型请求。真实窗口的中英文、焦点/键盘/VoiceOver、玻璃合成以及安装后连接需另行授权验收。配置的启用状态不等于已连接。当前状态见 [验收边界](../status.md#尚未关闭的验收)。
