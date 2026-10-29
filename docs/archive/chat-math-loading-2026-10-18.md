# 密集公式聊天加载优化 2026 年 10 月 18 日

Dev 0.1.132 / build 133 保留原生正文和 2× 透明公式附件，降低大量公式的排版及重复打开成本。owner 报告卡死的同一会话副本，本次初始窗口提交 238 个不同渲染键；无缓存队列就绪从 2.30 秒降到 1.87 秒，进程重启后复用磁盘缓存降到 1.10 秒。无缓存的首个可见公式仍约 1.1 秒。

当前机制见[聊天 Markdown](../markdown-rendering.md)，重放入口见[手动验收](../../tests/acceptance/README.md)。原始会话和完整内容不提交到仓库，用户会话库未改写。

## 改动

- 内存缓存目标从 256 项 / 16 MiB 提高到 2,048 项 / 64 MiB，独立保留等待请求并合并重复排版。
- 新增版本化磁盘图片缓存，最多 4,096 项 / 128 MiB，保存 alpha、显式颜色及基线/数学轴，文件名为渲染键 SHA-256。后台原子写入、按使用时间淘汰；读取不被写入队列阻塞。损坏、缺失或协议变化时重新渲染。
- 普通黑色公式使用 Accelerate 提取 alpha 和识别颜色，省去逐像素 Swift 扫描及不需要的彩色缓冲；显式 TeX 颜色保留原路径。图片裁切/蒙版复制移到后台。
- 首批保持最多 8 项，历史批次提高到 64 项并紧凑排列截图，仍优先可见公式、保留 16 MP / 单边 16,384 像素限制及自适应拆批。导航期间准备引擎，最近完成回复最多预取一个完整公式。
- 共享 WebView 闲置保留时间从 20 秒延长到 60 秒，随后仍释放。内存和磁盘命中均不重启已回收的 WebView。

## 真实会话副本

Apple M5 / 24 GiB，macOS 27.2 (26B5101f)，Swift 6.4、Swift 6 模式，未签名 Debug Dev。基线为 `947dd81` 的 Dev 0.1.131。使用生产 RootView、ThreadRuntime、原生 Markdown 和默认历史加载窗口；bootstrap 完成后、选择会话及创建 1320 × 860 pt 窗口前开始计时，不连接 provider。每种配置一个样本，无缓存目录为空；缓存轮次使用新的 helper 进程及前轮缓存副本。

| 配置 | 首个可见公式绘制 | 最后一批已加载公式排空 | MathJax 排版数 | WebView 创建数 |
| --- | ---: | ---: | ---: | ---: |
| 基线，无缓存 | 1,129 ms | 2,299 ms | 238 | 1 |
| 新版，无缓存 | 1,117 ms | 1,866 ms | 238 | 1 |
| 新版，新进程命中磁盘 | 499 ms | 1,100 ms | 0 | 0 |

本次样本无缓存总就绪缩短约 19%，缓存后的首次绘制缩短约 56%、最后一批就绪缩短约 52%。它没有消除无缓存首屏约 1.1 秒的等待。延迟展开历史会在首轮空闲后再次产生工作，因此缓存轮次的 545 ms 首轮空闲不能当作全部就绪；报告取最后一批排空。

计时是原生 cell 绘制回调和 50 ms 主线程采样，包含本次挂载窗口，不强制展开更老历史，不代表整应用启动、GPU 上屏 p95 或所有会话的分布。阶段回调是壁钟时间，也包含调度、回调和重试等待。

对同一副本进行[阶段定位](../evaluations/2026-10-18-chat-math-loading/before-vimage-profile.json)，像素处理从改用 Accelerate 前约 494 ms 降到交付版约 22 ms。该局部定位不代替上述完整路径对照。内存缓存下同进程重建窗口约 316 ms，未再次排版。

证据：[负载、散列及汇总](../evaluations/2026-10-18-chat-math-loading/measurement.json)、[基线](../evaluations/2026-10-18-chat-math-loading/baseline-visible.json)、[新版无缓存](../evaluations/2026-10-18-chat-math-loading/cold-visible.json)、[新进程磁盘复用](../evaluations/2026-10-18-chat-math-loading/disk-visible.json)。

## 资源和验证

这份会话的 238 个缓存文件合计约 3.09 MiB。目标 64 MiB 是缓存像素成本，不是所有活跃附件或进程的硬上限。可见重放 helper 包含第二次窗口重建，采样到的 GUI 物理 footprint 峰值约 147 MiB；加上已由 launchd PID domain 确认的 WebKit 进程，合计样本峰值约 415 MiB。磁盘命中轮次未创建 WebKit，helper 样本峰值约 163 MiB。早期归属不完整的采样保留在账本；求和可能包含共享页面，不是唯一物理占用，也没有基线内存对照用于宣称增减。

资源证据：[无缓存账本](../evaluations/2026-10-18-chat-math-loading/cold-visible-resources.json)、[磁盘命中账本](../evaluations/2026-10-18-chat-math-loading/disk-visible-resources.json)。

- `make build`、`markdown-math`、`markdown-hosting` 通过。新增 320 项等待请求去重、磁盘恢复不启动 WebKit、损坏缓存回退，并逐像素比较普通/彩色/选中及 3× 图片缓存往返；数学轴、透明背景、字号、宽度和闲置回收回归保留。
- 同一真实副本的可见生产窗口完成 1320 → 920 → 1320 pt 往返，24 次心跳、队列排空并退出，未复现显示周期卡死。
- 单独运行 `benchmark:chat-math-cold`：96 项无缓存离屏就绪为 301 / 197 / 186 ms，三轮中位约 197 ms；此前同负载中位约 295 ms。每轮 3 次截图；24 项、16 ms 间隔的主线程提交总计 453 ms。这是资源就绪测量，不是独立输入时钟或真实聊天滚动帧率。

证据：[构建](../evaluations/2026-10-18-chat-math-loading/build-evidence.json)、[功能检查](../evaluations/2026-10-18-chat-math-loading/functional-report.json)、[可见改宽](../evaluations/2026-10-18-chat-math-loading/visible-resize.json)、[离屏测量](../evaluations/2026-10-18-chat-math-loading/cold-benchmark.json)、[测量执行记录](../evaluations/2026-10-18-chat-math-loading/benchmark-report.json)；此前对照见[公式修订记录](chat-math-refinements-2026-10-18.md)。本轮未重跑外部模型流式会话或物理跨屏测试；历史验收范围继续见[接入记录](chat-mathjax-integration-2026-10-18.md)。
