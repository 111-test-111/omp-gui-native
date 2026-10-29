# 侧栏历史活动、项目分页与设置宽度（2026-10-23）

基线 `4d59694`；Dev 为 `0.1.195`／build `196`。本任务在 `codex/sidebar-activity-pagination` worktree 实施，已 fetch 只读 upstream，参考仍为 Tivano `d31e093b356846ff538dd8ba0dc22d62598e4427`。当前行为说明见[会话组织](../chat-workflows.md#新对话默认值与选区操作)前的侧栏段落与 [UI 约定](../ui-guidelines.md)。

## 行为

- 恢复原活动视图：跨项目与独立任务，按待处理、置顶、日期及 Settle 分组，包含更早会话；父会话下保留 helper/head。恢复铃铛入口及菜单／快捷键文案，沿用 `sidebarActivityView` 偏好及快捷键身份，不新增偏好迁移。
- 每个项目默认最多 5 个主会话，每次「显示更多」增加 5 个，显示完后移除按钮。子代理随父会话显示，不另计名额。分页保存在 AppModel 的临时状态中，折叠该项目后重置；其他项目不受影响。项目拖动时仅临时隐藏子行，不修改分页。
- 列表、键盘导航和拖动同组都使用当前项目页。搜索、命令面板及活动视图保留全部记录。Settle 的折叠会话不占显示名额；展开后与普通会话共用页数，保留完整折叠计数，避免只增加隐藏行的无效按钮。
- 复用现有 Core 活动排序和 SidebarItemCache，分页进入缓存键；日期标题的缓存只在跨日时失效。未增加另一套排序、运行时、代理调度器或 MCP 管理。
- 设置内容区宽度上限从 680 pt 增至 800 pt；窄主窗口继续随可用空间收缩，导航栏宽度保持原值。新按钮复用 Chrome 紧凑玻璃控件，两个新增文案有手工 zh-Hans 翻译。

## 验证与边界

`make build` 一次通过。随后执行 `make verify AREAS="organization settings"`，最终通过 51 项组织行为断言及 18 项主窗口设置断言，功能报告为 `20261022T192856Z-896f5f9b/report.json`。覆盖历史日期、父子归属、5 → 10 → 余数、独立项目页数、折叠／重开重置、结束分组及键盘范围；设置检查覆盖导航、窗口数量、runtime／草稿保留、900 × 600 尺寸跟随及 Command-W。

首轮组织检查的夹具未展开默认折叠的父会话，却要求子代理出现在键盘列表。核对 `ChatThread.expandsHelpers` 默认值及生产可见性逻辑后，补齐显式展开和折叠状态断言，保留对展开后子代理的原要求；生产代码和构建输入未变，复用构建，只重跑失败区域及尚未执行的 settings。首轮报告为 `20261022T192803Z-c605a7bd/report.json`。

静态收尾选择 `make verify TIER=static AREAS="documentation harness syntax"`，分别检查文档本地链接／导航、登记表及执行器契约、工具语法。所有报告与日志保留在任务 worktree `/Users/developer/.codex/worktrees/sidebar-activity-pagination/omp-gui-native` 的 `build.noindex/verification/runs/<run>/`；构建日志在 `build.noindex/development/build.log`。

检查只使用隔离资料库、偏好与离屏窗口，没有启动／退出主应用、执行 OMP、修改外部配置、打包或发布。可见侧栏的点击／拖动、长项目名、日期切换、VoiceOver，以及更宽设置内容在实际窗口和不同语言下的排版仍需现场验收；离屏 900 × 600 检查不替代这些结论。
