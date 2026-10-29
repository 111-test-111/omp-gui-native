# Droppy Code 首批视觉移植（2026-10-26）

来源固定为 Droppy Code [e7dd8dcb](https://gitlab.com/droppyformac1/droppy-code/-/commit/e7dd8dcb3ac0c605473afb0243052a94c116e19d)，即 2026-10-09 的视觉改动；本地起点为 `00bc139`，集成时保留已前移的 `main`（`a7007e473`）及其原生上下文检查器。本轮 owner 授权移植步骤树、居中输入和设置细节，并允许谨慎放宽悬浮玻璃范围。

## 实现范围

- 现有 OMP `TimelineGroup` 的连续步骤、阶段文本、独立 Hydra 派遣、通知、警告和计划的分组与排序不变。只将每个步骤组替换为摘要／前置箭头／细线连接的树；当前组默认展开，用户选择独立保留，长组全部可读，思考和工具详情继续有界滚动。整轮状态保留 Card / Line 偏好，完成过程和文件审阅保留。
- 主会话空白输入框居中，首条消息后将同一原生编辑器停靠到底部；实际测量包括草稿、附件、审批及 OMP 扩展。历史加载、交接和子代理保持原有布局，切换会话直接落位，减少动态效果与性能模式不播放停靠动画。
- 设置采用页面正文标题和更清晰的导航行，搜索匹配本地化标题。14 个页面及原分组、缓存、读取取消、返回和已有功能不变。
- 玻璃范围明确扩展到聊天编辑器、队列及改动标签，以共享 Chrome 表面和局部合成容器实现。没有扩大到步骤树、设置卡片、普通面板或整个窗口。原生玻璃不垫不透明填色，性能模式／减少透明度使用实色，前景保持不透明。
- Dev `0.1.280` / build `281`。来源署名、批准图标、独立数据域和 OMP 原生所有权保留。

## 验证

最终 Dev `make build` 通过。选定的检查如下：

- `functional:timeline`：169 项通过；包括原生多组顺序、最终回复／文件卡片、65 条思考完整展开、编辑器停靠／身份／草稿和短窄布局。进度条限定到当前轮次；主分支前移及面板合成修订后仅补跑此受影响区域，最终报告在本 worktree 的 `build.noindex/verification/runs/<run>/report.json`（`functional:timeline`）。
- `functional:settings`：29 项通过，报告为 `build.noindex/verification/runs/20261026T023043Z-979be9b0/report.json`；设置导航、页面缓存和返回代码及相关运行环境此后未改，复用该证据。
- `static:documentation`：本地链接、锚点及入口可达性检查；命令为 `make verify TIER=static AREAS="documentation"`。

证据保存在任务 worktree `/Users/developer/.codex/worktrees/upstream-visual-design/omp-gui-native`。离屏图像包括 `activity-tree.png`、`new-chat-centred.png`、`chat-editor-docked.png` 和 `new-chat-narrow.png`，位于时间线报告同级目录。独立检查进程的应用图标／资源不代表正式应用的资产显示，图像主要用于核对布局；最终桌面玻璃合成仍属于现场范围。

离屏检查验证步骤归属、65 条完整思考、独立组折叠、原生编辑器身份／草稿保留、首次消息后的停靠、切换空白会话和短窄窗口可达性。此范围不启动主应用、OMP 或模型请求。

真实窗口中的动画、输入法、键盘／VoiceOver、长附件及原生扩展、玻璃桌面合成仍待现场验收；见[当前边界](../status.md#尚未关闭的验收)。
