# 独立任务记忆读取与侧栏纯文本操作（2026-10-23）

基线 `ca533a3`；Dev 为 `0.1.196`／build `197`。任务在 `codex/global-memory-sidebar-link` worktree 实施，已 fetch 只读 upstream。当前行为见[记忆数据说明](../shared-library.md#长期记忆)、[侧栏交互](../chat-workflows.md)及 [UI 约定](../ui-guidelines.md)。

## 原因与修复

独立任务只在首次发送前创建工作目录；记忆页通过当前会话的原生连接读取全局库，提前启动 OMP 时，该任务的 `workspace` 目录尚不存在，因此启动失败。全局文件的原生 bank 和文件元数据本来就不依赖任务是否属于项目，错误发生在读取之前。

- 原生连接的公共启动路径准备独立任务目录，记忆发现和冷启动预览都能在首次发送前继续执行；首次发送仍在持久化第一轮边界之前准备目录，两处复用同一实现。项目目录仍由用户管理，不自动重建。
- 保留当前 OMP RPC／SDK 记忆接口、全局过滤、元数据缓存、预览限额及请求身份检查，没有新建另一套记忆读取器、数据库或项目记录，也不会发送输入或清除草稿。
- 「显示更多」改为淡灰纯文本，移除玻璃底框和图标；分页、点击与辅助功能提示沿用原行为。按本次 owner 的明确要求，将这一视觉例外写入工作规则与 UI 约定；复用已有双语文案，无新增本地化 key。

## 验证

`make build` 一次通过。`make verify AREAS="memory"` 通过文件身份／来源／限额、原生只读预览、缓存／迟到结果、目录准备、原生 SDK 能力门禁、草稿／轮次保留、用户项目边界、EOF 排空和仓库身份检查。功能报告为 `20261022T195304Z-6f6a477e/report.json`。

新增回归通过 AppModel 的实际记忆发现与 ThreadRuntime 的冷预览入口执行，使用 `/usr/bin/false` 替身停在 SDK 能力门禁，断言目录已在原生启动前准备完成；不调用已安装 OMP、真实 SDK 或全局数据库。既有 Node 检查覆盖仓库共享／独立克隆和预览的 Unicode／字节预算。新目录准备与现有原生全局 bank 读取的实际组合仍需真实应用验收。

静态收尾选择 `make verify TIER=static AREAS="documentation"`。构建日志与所有检查产物保留在任务 worktree `/Users/developer/.codex/worktrees/global-memory-sidebar-link/omp-gui-native` 的 `build.noindex/` 下；验证报告位于 `verification/runs/<run>/`。没有启动、退出或重启主应用，也未修改外部 OMP 配置、打包或发布。

现场验收仍包括独立任务首次发送前打开记忆页并查看／刷新真实全局文件，以及淡灰文字在亮暗主题、键盘和 VoiceOver 下的可见性与操作。
