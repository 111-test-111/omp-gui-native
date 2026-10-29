# 公式密集聊天布局卡死修复 2026 年 10 月 18 日

Dev 0.1.131 / build 132 修复打开真实公式密集会话时的显示周期死循环。问题在 owner 报告的已完成 helper 会话中可复现；原始聊天和应用数据保持完整。当前实现见[聊天 Markdown](../markdown-rendering.md)。

## 根因

0.1.130 的卡死进程主线程反复进入 `NSHostingView.layout`、约束更新和 `MathParagraphHost.measure`；显示周期保护不断捕获 AppKit 的过多布局异常，无法让界面收敛。公式宿主在 SwiftUI 的候选宽度试算中修改了正在显示的 TextKit 容器、文档 frame、横向滚动条并标记重新布局；原生 `layout()` 又按最终视口改回。完整聊天中的列表、表格等布局探测使这个反馈循环持续发生。

此前的离屏图片和简单宽度检查没有覆盖可见生产聊天的完整显示周期。将该会话的线程文件与 turn 分片只读复制到隔离 capture 库，使用生产 RootView / ThreadRuntime 打开，旧版同样卡死：250 ms 节拍的主线程心跳停在 index 1，12 秒父进程超时后采样并只结束重放 helper。完整真实会话及原始调用栈不提交到仓库。

## 修复

宽度试算现在使用独立的 TextKit storage / layout / container，保留最多 8 个宽度结果；正文或附件几何变化通过 revision 使缓存失效。试算不修改显示文档、文本容器、滚动条和 `needsLayout`。只有原生 `layout()` 按实际分配的视口提交几何，并仅在数值变化时更新 frame 和滚动条。块公式仍按固有宽度居中，超宽公式保留横向范围。

新增的试算隔离断言在旧版先失败，修复后通过；它检查连续不同宽度提案不会修改显示状态。完整 Markdown 宿主还覆盖含行内公式的列表、公式表格和块公式的 760 → 400 → 760 pt 往返。

## 验证

- `make build`、`markdown-hosting`、`markdown-math` 通过；附件的透明背景、数学轴、选中色、倍率、复制、宽度及闲置回收回归保留。
- 同一会话副本的可见生产窗口完成 1320 → 920 → 1320 pt 往返，24 次主线程心跳全部完成，公式队列排空并正常退出。该重放只使用本地历史，没有模型请求或外部 provider。
- 心跳包含首次布局和改宽时的有限停顿；这里只证明该卡死复现已解除，不作为滚动帧率、屏幕延迟或内存性能认证。

证据：[复现及副本散列](../evaluations/2026-10-18-chat-layout-hang/reproduction.json)、[旧版失败断言](../evaluations/2026-10-18-chat-layout-hang/hosting-before-report.json)、[最终宿主回归](../evaluations/2026-10-18-chat-layout-hang/hosting-report.json)、[公式回归](../evaluations/2026-10-18-chat-layout-hang/math-report.json)、[可见窗口重放](../evaluations/2026-10-18-chat-layout-hang/visible-replay.json)与[构建指纹](../evaluations/2026-10-18-chat-layout-hang/build-evidence.json)。

[手动重放 helper](../../tests/acceptance/chat_session_replay.swift)只操作预先隔离的 capture 库和自己的窗口；入口及授权规则见[手动验收](../../tests/acceptance/README.md)。未结束 owner 原来的卡死进程，也未修改或重置真实会话库。
