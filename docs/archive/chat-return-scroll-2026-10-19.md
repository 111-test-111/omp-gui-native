# 会话切回与滚动修订 2026 年 10 月 19 日

Dev 0.1.134 / build 135 处理公式密集会话切回后回复消失、等待态前空白及第一个滚动输入被抵消的问题，并减少原生正文的布局和绘制开销。文案继续为「正在等待会话加载」，保留原生正文及透明 MathJax 图片。当前机制见[聊天 Markdown](../markdown-rendering.md)和[worker 历史](../chat-workflows.md)。

## 原因与修改

1. 原生 worker 每次重新显示详情都读日志，并在主线程清空消息后分段重放。即使日志未变化，也会销毁已有回复与排版；原等待态没有观察 `nativeAgentHistoryLoading`。现在后台对完整日志行计算摘要，未变化时跳过解码/重放，保留原有消息对象。摘要绑定会话路径，未完成尾行不触发刷新，真正变化才重建；原有大小、路径和取消边界保留。
2. 原等待态先隐藏内容、再延迟显示 spinner，密集原生树构建也会占用第一帧。现在已知密集的新入口或真实历史重建立即提示，第一次挂载原生树前让提示先提交一帧。已完成的缓存列保留就绪状态；后续图片失效仍有 180 ms 防闪烁延迟，少量公式不显示。最短显示、有界退出和流式排除保留。
3. 底部校正在触控板 tracking 阶段或无 phase 的第一拍滚轮时仍可能执行；横向公式宿主的实际文档高度还会让输入探针误判路由。现在 tracking 和滚轮输入立即取消旧定位并阻止校正，纯 offset 回弹不触发底部吸附，公式宿主将纵向输入交给外层滚动视图。等待结束也要求时间线几何稳定。
4. `isProseOnly` 仍沿用旧渲染器限制，排除了所有行内公式。现在相邻含公式段落、标题和可合并列表共享连续 TextKit 正文；引用保留边线，列表标记沿用主题色，块公式/表格/代码保持独立。超宽公式几何按布局失效及宽度缓存，滚动不再逐次枚举全文附件。

## 验证

使用 owner 截图中的 Hank worker 隔离副本，保留 3 个已存轮次、4 条助手消息及默认历史窗口；原生日志也复制进独立 capture store。生产 RootView / ThreadRuntime，1320 × 860 pt，不连接 provider，不写真实会话库，不重启 owner 实例。

| 路径 | 结果 |
| --- | --- |
| 基线快速切回 | 79 次采样中助手数量在 3 / 4 之间变化，spinner 为 0；采到一帧部分内容未被覆盖 |
| 修复后快速切回 | 80 次采样始终 4 条助手回复，不隐藏、不重新显示 spinner |
| 强制真实历史刷新 | 缓存公式仍需重放时立即等待；所有采到的部分内容状态均被覆盖，最终完整显示 |
| 首次挂载 | 首次记录约 136 ms 已有 1 个指示器、尚无可见原生文本宿主；不是 GPU 首帧延迟测量 |
| 首个原生滚轮及连续上下滚动 | CUA 对独立验收窗口输入；第一拍无 phase 的上滚改变可见内容并出现 Jump to latest，继续上下滚动后回到底部 |
| 24 段行内公式对照 | 原生文本宿主由逐块路径的 24 个降为连续路径的 1 个；跨段落/列表选择和 TeX 导出仍通过 |

证据：[汇总及限制](../evaluations/2026-10-19-chat-return-scroll/measurement.json)、[基线切回](../evaluations/2026-10-19-chat-return-scroll/baseline-return.json)、[最终数字状态](../evaluations/2026-10-19-chat-return-scroll/visible-trace.json)、[构建散列](../evaluations/2026-10-19-chat-return-scroll/build-evidence.json)。不提交原始聊天、日志或截图。

`make build` 通过。[功能检查](../evaluations/2026-10-19-chat-return-scroll/functional-report.json)覆盖 workers、markdown-preparation、markdown-hosting、markdown-math 和 markdown-parser，包括未变化历史对象复用、相同 ID 内容变化失效、tracking/滚轮优先、透明/选中及超宽图片；其后只修订引用/列表样式，相关[渲染回归](../evaluations/2026-10-19-chat-return-scroll/render-report.json)通过。新增的原生视图预算验证见[宿主检查](../evaluations/2026-10-19-chat-return-scroll/view-budget-report.json)。其余相关源路径未变，复用本轮通过证据。

验收工具同时改用 `NSApplication.run()`，原 async-main 窗口可绘制但不足以验证真实输入。探索运行曾因手动等待过长触及外层 120 秒时限，后续把手动等待限制为 45 秒并保存检查点；最终运行完成。完成运行中，隐藏滚动条使原 viewport 选择条件没有取到 offset，故不报告数字滚动距离；工具已修正供后续使用，实际输入结果由 CUA 的可见状态验证。

这是局部行为和原生宿主数量证据，不是 FPS、上屏 p95 或所有复杂会话的性能分布。未做物理触控板回弹、跨屏、完整 VoiceOver、外部模型流式或进程资源对照；不将回归/单次输入扩大为完整系统验收。
