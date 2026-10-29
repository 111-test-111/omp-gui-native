# 模型选择器套餐用量与听写设置（2026-10-26）

起点为本地 `main` 的 `b0540824a`，延续[本地听写与原生能力评估](upstream-functional-stage2-2026-10-26.md)。本轮按 owner 新要求集中听写设置、改造第二层模型列表，并接入只读 OMP 套餐用量；补充约束是未知或不支持的值全部隐藏，只显示可确认的准确数值。Dev `0.1.294` / build `295`。

## 交付行为

- 设置 → 听写集中选择系统支持语言、显式安装系统资源、申请麦克风权限，以及在已拒绝时打开系统权限设置。使用现有系统框架，不增加包、命令行工具或外部语音账号依赖。
- 输入框麦克风在条件具备后直接录音；缺权限或资源时只显示前往设置的提示。不再打开配置 popover，也不显示资源检查文字行。继续保留全应用录音／安装归属、取消排空、五分钟上限、草稿身份恢复和发送门禁。
- 第一层思考强度面板保持原样；第二层为 620 × 500 pt 服务商／模型弹窗。左列来自 OMP 原生可用模型目录，右侧搜索及模型行保留名称、selector、选择态和 Fast 标记；Hydra 组合独立列出并保留自定义名下的模型说明。旧档案的跨运行时历史切换仍被禁用，原生服务商图标不成为旧运行时入口。
- 套餐用量来自公开 `omp usage --json`，有有效数据才出现在相应服务商的模型列表上方。没有收藏入口，也没有在设置中增加套餐额度；原有设置用量页继续统计本 edition 保存的轮次。

## 原生数据与准确性

[原生投影](../../OMPGUI/Core/Models/OMPProviderUsage.swift)只保留公开报告的显示字段。报告按原生 provider／账户保留，`fetchedAt` 是来源时间，不能用 GUI 读取成功时间冒充刚联网取得。比例优先级遵循 OMP `resolveUsedFraction`；原生零值与超额保留，绘图限幅不改变文本。credits、USD 等绝对余额不推成百分比，`tick`／`regen` 表示滚动补充，不能称为完整重置。

下列项隐藏，不显示零值、未知占位或空进度条：缺少可解释的有效数值、未知或未识别状态、明确估算／OMP-observed 来源、缺失来源时间、时间明显在未来、报告超过十分钟，以及已过重置时间的窗口。绝对数量缺少已知单位时不显示，原生归一化比例仍可使用。未提供的套餐／账户／重置字段不猜测；未识别的重置语义不显示。读取失败也不生成用量区。时间变化只使现有快照失效，不在后台发起请求。

[读取与缓存](../../OMPGUI/Services/Providers/OMPProviderUsageReader.swift)仅在第二层列表可见时工作，多个列表共享一次读取。成功缓存 60 秒，失败重试节流十秒；入口／刷新前核对 `omp config path`，读取后再次核对活动 profile，同时约束 executable、environment 和目录 revision。关闭最后一个列表取消用量进程，迟到或旧 profile 结果不发布。没有禁用原生扩展，也没有 GUI 自有 HTTP、账号或凭据读取。OMP 仍可按其自身逻辑更新认证、用量缓存和历史。

原生输出限制为 3 MiB／45 秒，最多投影 128 份报告、每份 128 条和总共 1,024 条额度，文本字段最多 256 字符。GUI 不保存原始响应、账户凭据或套餐快照；只有内存缓存。接口依据为上一轮固定核对的 OMP 18.12.5 及其公开 usage 类型，本轮另核对 `UsageStatus`、`resolveUsedFraction` 与 `resetLabel` 的实际安装源码；未重新读取真实账号用量或扩大服务商验收矩阵。

## 验证记录

- `make build` 最终通过。首次构建暴露 catch 变量遮蔽属性及 switch 表达式位置两处实现错误，已修正；差异审阅后补充未知状态／滚动补充语义及原有模型列表保护，再对受影响源码增量构建。
- 原始定向选择 `make verify TIER=functional AREAS="dictation provider-usage models settings"` 全部通过：听写 22、套餐用量 29、模型 64、设置 29 项。报告为 `build.noindex/verification/runs/20261026T064000Z-cced1f4a/report.json`。未改变的听写、模型可见性与设置导航复用该证据。
- 额度语义修正后仅重跑 `provider-usage`，30 项通过；报告为 `build.noindex/verification/runs/20261026T070318Z-24e8d0aa/report.json`。覆盖未知／过期隐藏、明确零值、超额、绝对余额、滚动补充、profile 切换、共用读取、最后消费者关闭、迟到结果、原生目录失效、CLI JSON／参数和第二层列表浅深色离屏布局。
- 最终模型行呈现与历史保护调整后再选择一次 `provider-usage`，30 项通过；最终报告为 `build.noindex/verification/runs/20261026T070624Z-ff47ed25/report.json`。
- 文档、登记与脚本语法选 `make verify TIER=static AREAS="documentation harness syntax"`，三项通过后停止；报告为 `build.noindex/verification/runs/20261026T070703Z-1ddacb4f/report.json`。

功能检查使用隔离偏好／资料库、CLI 替身及未显示的 AppKit／SwiftUI 容器，不调用已安装 OMP、不访问账号端点、不启动主 GUI、不申请麦克风权限或安装语言资源。浅深色布局图位于各 `provider-usage` 报告目录，捕获 helper 不等同于应用 bundle 的图标资源或可见玻璃合成验收。

## 剩余现场验收

真实麦克风授权及撤销、语言安装／取消、中文及其他语言转写质量、输入设备异常、五分钟停止、草稿／会话／设置切换和多窗口；真实账号套餐的 native 缓存、外部 profile 变更与网络失败；模型弹窗和设置页的中英文、键盘／VoiceOver、浅深色、窄屏与 Liquid Glass 合成均留待对应 GUI 运行授权后验收。实时语音维持评估结论，未接通通话。没有安装、启动／重启 GUI、打包、远端 push 或发布。
