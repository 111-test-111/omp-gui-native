# 密集公式会话等待态 2026 年 10 月 18 日

Dev 0.1.133 / build 134 在公式密集会话进入、启动恢复和较慢的再次排版期间，显示 3×3 波纹指示器和 owner 指定文案「正在等待会话加载」。正文仍由原生 TextKit 排版，附件保持透明图片路径。当前行为及阈值见[聊天 Markdown](../markdown-rendering.md)。

## 实现边界

- 时间线隐藏时保持原生视图挂载，让图片和布局继续完成；标题、导航及输入框可用。没有为整块聊天加入玻璃或大范围淡入合成。
- 初次密集判定只采样最近 4 条完成回复，每条最多 32,768 字符，至少 16 个完整公式。后续至少 16 项当前时间线的待处理附件可再次触发。流式中的新回复不触发遮罩。
- 工作持续 180 ms 才出现 spinner，出现后从实际挂载开始至少显示 280 ms。无公式、少量公式和快速完成不显示。初始历史窗口的加载也计入等待，避免图片队列分段空闲时留下空白。
- 就绪需要当前绑定附件结束、初始历史窗口完成，以及附件几何稳定 120 ms。等待约 4 秒后放行已有内容；若 spinner 刚挂载则先满足最短显示时间。该批工作结束前不反复遮挡。
- 共享渲染器的其他会话不阻塞本会话。已预建的隐藏列不运行轮询，原生弱引用解绑后不留下陈旧等待。图标沿用主题色及现有 Core Animation 波纹，性能模式/减少动态效果回退为静态。

## 定向验证

使用前次卡死报告的同一真实会话隔离副本，生产 RootView / ThreadRuntime、默认历史窗口、1320 × 860 pt，首次挂载提交 238 个不同渲染键。不连接 provider，不改写真实会话库，不重启 owner 正在使用的实例。驱动为[手动重放](../../tests/acceptance/README.md)的 `--performance --preparation-check`，每 50 ms 读取实际原生文本视图所属的准备状态。

| 路径 | 观测 |
| --- | --- |
| 无缓存首次进入 | 238 项排版；先隐藏正文并显示等待，完成后显示内容，最终队列排空 |
| 新字号缓存缺失 | 同一挂载时间线再次显示等待，结束后正常恢复 |
| 恢复已缓存字号 | 不显示 spinner，正文保持可见 |
| 新进程读取磁盘缓存 | 238 项命中、零 MathJax 排版；历史页持续准备时显示等待，结束后恢复 |
| 同进程重建缓存窗口 | 零新增排版；需要等待历史窗口时显示提示，最终内容可见 |

无缓存入口首次观测内容已显示约 2.05 秒，磁盘命中入口约 1.32 秒。它们是本轮单次主线程采样下的状态转换，包含原生历史窗口准备，不是 GPU 上屏、首帧分位数或新的性能优化对照。未保存真实聊天文本或截图。最初重放暴露了“队列短暂空闲而历史仍在准备时没有提示”的边界，修正为同一次初始等待，并只重跑受影响检查。

证据：[汇总及范围](../evaluations/2026-10-18-chat-math-loading-state/measurement.json)、[无缓存状态采样](../evaluations/2026-10-18-chat-math-loading-state/cold-visible.json)、[磁盘缓存状态采样](../evaluations/2026-10-18-chat-math-loading-state/cached-visible.json)、[构建散列](../evaluations/2026-10-18-chat-math-loading-state/build-evidence.json)。

`make build` 通过。`markdown-preparation` 用受控时钟覆盖快/少量抑制、延迟分页、最短显示、再失效、超时和原生附件会话隔离；[最终检查报告](../evaluations/2026-10-18-chat-math-loading-state/functional-preparation-report.json)通过。`markdown-hosting`、`markdown-math` 的[本轮集成回归](../evaluations/2026-10-18-chat-math-loading-state/functional-integration-report.json)通过，其后只改变文案及初始等待策略，未改原生图片/布局路径，沿用该证据。

本轮未重跑外部模型流式、资源基准、物理跨屏或完整 VoiceOver/外观矩阵。流式排除依据现有整条 streaming 回复的 `markdownVeiled` 环境；原有滚动、数学轴、透明背景及宽度验收范围见[接入记录](chat-mathjax-integration-2026-10-18.md)和[布局修复](chat-layout-hang-2026-10-18.md)。可见状态采样不代替上述系统验收。
