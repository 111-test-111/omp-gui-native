# 历史记录索引

本目录保存特定日期、版本、任务和机器的计划、研究及验收事实。当前操作从[文档索引](../README.md)开始，功能范围及未关闭门槛见[当前状态](../status.md)。

记录里的 owner 授权只属于原任务，不授权新任务启动/退出应用、修改 profile、打包或发布。旧检查名称、产物路径和次数是历史证据，不表示本轮重跑；已清理的构建目录也不保证还能取得原始产物。已检入的数据在[评估目录](../evaluations)。

首次公开前的机器用户名路径已匿名化；部分本地提交不会出现在整理后的公开历史中。保留原测量和当时的验证边界，不把匿名路径当作原产物哈希的新认证，详见[源码发布说明](../source-release.md)。

## 计划与实施

- [独立任务记忆读取与侧栏纯文本操作（2026-10-23）](global-memory-task-startup-2026-10-23.md)。

- [侧栏历史活动、项目分页与设置宽度（2026-10-23）](sidebar-activity-pagination-2026-10-23.md)。

- [主窗口设置、原生 MCP 快捷登录与完成卡片修复（2026-10-23）](embedded-settings-mcp-cards-2026-10-23.md)。

| 记录 | 内容 |
| --- | --- |
| [浏览器恢复配置与下载、证书验收（2026-10-29）](browser-recovery-state-2026-10-29.md) | 下载目录恢复、启动选项、CEF context、证书会话与导航错误，36 项定向现场断言 |
| [浏览器自动化修复（2026-10-28）](browser-automation-repairs-2026-10-28.md) | GUI／OMP 责任边界、受守卫兼容修复、隔离回归与待授权的真实 CEF 验收 |
| [N0–N4 实施与 Q 开放项（2026-10-17）](native-stage-implementation-2026-10-17.md) | 五个本地功能提交、分层证据、资源边界与 Q 进展 |
| [下一阶段功能计划（2026-10-17）](next-functional-plan-2026-10-17.md) | 增量传输、原生运行选项、目标执行、旁问及性能关卡；排除已移除能力 |
| [P0–P5 计划](native-development-plan.md) | 当时缺口、阶段范围和性能目标 |
| [P0 基线](p0-runtime-baseline.md) | 能力、生命周期、分段历史及资源测量 |
| [P1/P2 工作流](p1-p2-native-workflows.md) | 原生队列、历史编辑、上下文；部分浏览能力已删除 |
| [P3 原生入口](p3-native-entrypoints.md) | 配置、登录、扩展 UI 与插件 |
| [P4 Hydra/文件上下文](p4-hydra-file-context.md) | 观察身份、按需日志及 host tools |
| [P6 方案](p6-native-workbench-plan.md) | 当时的计划和修订范围 |
| [P6 实施](p6-implementation.md) | 原交互、等待标签及后来审批卡片的局部证据 |
| [P6 任务工作台](p6-tasks.md) | 初次工作台交付及定向验证 |

## 验收与集成

- [OMP 18.13.3／Bun 1.4.4 升级兼容检查（2026-10-29）](omp-18-13-3-compatibility-2026-10-29.md)：浏览器 SDK 迁移、原生证书会话、手动压缩事件与隔离接入验证。

- [工具圆标放大、glob 与文本菜单图标（2026-10-28）](tool-symbol-refinements-2026-10-28.md)：find/glob 的大号右上圆标、read 的 text.menu 与 analyze_files 的右下圆标，及四项浅深色对照。

- [自定义 find SF 符号与工具图标核对（2026-10-28）](tool-symbol-audit-2026-10-28.md)：右上角放大镜文件夹、浅深色原生预览、八项工具候选及定向离屏检查。

- [Chrome 扩展一次性 Cookie 导入（2026-10-28）](chrome-cookie-import-2026-10-28.md)：真实扩展站点授权／拒绝、临时权限撤销、中文生产设置导入、手动重名拒绝与自动编号，以及重启后的服务端登录及 Cookie 字段核对。

- [Chrome profile 与登录态迁移评估（2026-10-27）](chrome-profile-migration-2026-10-27.md)：目录复用／复制的限制、Chrome 156 → CEF 154 的公开接口 Cookie 迁移、进程重启及独立写盘诊断；未添加设置。

- [浏览器共享 profile 与登录持久化（2026-10-27）](browser-shared-profiles-2026-10-27.md)：本机 HTTP 表单登录、五次真实 CEF 启动的 75 项断言，以及中文设置页 CUA 新增／选择操作。

- [浏览器面板关闭主窗口修复（2026-10-27）](browser-window-close-2026-10-27.md)：生产面板的 sandbox 开启、跨窗口保留、关闭和进程重启，共 32 项隔离验收。

- [CEF iframe 截图与 CDP 对话框修复（2026-10-27）](cef-browser-repairs-2026-10-27.md)：隔离依赖补丁、六种截图像素组合、弹窗及取消／关闭恢复、带弹窗正常退出。

- [CEF 页面的 OMP Browser 扩展能力（2026-10-27）](cef-browser-capabilities-2026-10-27.md)：13 组通过、iframe 部分通过、对话框阻塞，保留错误图及截图绕行方法。

- [CefWebView + OMP CDP 原型（2026-10-27）](cef-browser-prototype-2026-10-27.md)：独立可见宿主、真实 OMP 浏览器接口、21 项检查与生命周期恢复边界。

- [服务商名称、地区密钥入口与首字母标记（2026-10-26）](provider-names-key-editor-2026-10-26.md)。

- [服务商品牌与全量原生身份核对（2026-10-26）](provider-brand-alias-audit-2026-10-26.md)。

- [模型勾选、品牌图标与原生登录别名（2026-10-26）](provider-picker-identity-2026-10-26.md)。

- [服务商品牌图标、DeepSeek 余额与关键用量设置（2026-10-26）](provider-logos-deepseek-coverage-2026-10-26.md)：含 OMP 22 个内置用量来源和额外官方 API 核对表。

- [模型选择器紧凑布局与 DeepSeek 余额核对（2026-10-26）](model-picker-compact-and-deepseek-2026-10-26.md)。

- [模型选择器套餐用量与听写设置集中管理（2026-10-26）](model-picker-usage-dictation-settings-2026-10-26.md)。

- [本地听写与原生套餐／语音／优化评估（2026-10-26）](upstream-functional-stage2-2026-10-26.md)。

- [Droppy Code 首批视觉移植（2026-10-26）](upstream-visual-design-2026-10-26.md)。

- [上游任务组织、恢复与长会话移植（2026-10-23）](upstream-task-organization-2026-10-23.md)。

| 记录 | 内容 |
| --- | --- |
| [OMP 18.12.5 升级兼容检查（2026-10-22）](omp-18-12-5-compatibility-2026-10-22.md) | 审批单次授权修复、Hydra/记忆的隔离原生检查与日常安装切换 |
| [Goal 问题复核与修复（2026-10-17）](goal-audit-fixes-2026-10-17.md) | 8 项问题逐项结论、原生边界、恢复单次启动与定向验证 |
| [Goal 模式与实际 OMP 升级（2026-10-17）](goal-mode-acceptance-2026-10-17.md) | `/goal` 正文提交、按钮锚定弹层、18.3.2 → 18.11.2 npm 升级及定向兼容验证 |
| [N0 增量传输交付（2026-10-17）](event-projection-acceptance-2026-10-17.md) | 当前进程投影协商、旧版回退与一次合成对照；未认证整应用性能 |
| [N1 运行选项交付（2026-10-17）](run-options-acceptance-2026-10-17.md) | Fast、自动重试和停止重试；隔离的 18.3.2 原生接口验证 |
| [N2 原生目标交付（2026-10-17）](goal-acceptance-2026-10-17.md) | 31 条功能行为、官方 18.11.2 本地 provider 的 10 条原生语义；未运行 GUI/Q |
| [N3 原生旁问交付（2026-10-17）](side-question-acceptance-2026-10-17.md) | 47 条功能行为、官方 18.11.2 的 11 条原生语义及 EOF 保存边界；未运行 GUI/Q |
| [N4 原生资源选项交付（2026-10-17）](resource-options-acceptance-2026-10-17.md) | Slow 范围保护、预热 override/最近事件；32 条资源功能与 13 条无模型请求原生检查，投影语料精度修正；未运行 GUI/Q |
| [Q 局部现场验收（2026-10-17）](native-q-acceptance-2026-10-17.md) | 授权后的真实控件、稳态资源证据、人工标记超时与尚未关闭的屏幕/系统范围 |
| [P1/P2 验收](p1-p2-acceptance-2026-10-16.md) | 18.3.2 与当时真实模型的局部流程 |
| [P3/P4 验收](p3-p4-acceptance-2026-10-16.md) | 原生能力、合成登录及实际 worker |
| [main 集成检查](main-integration-audit-2026-10-16.md) | 当时有关分支树的集成，不是后续任务的通用合并方案 |
| [P5 向前兼容](p5-forward-acceptance-2026-10-16.md) | 固定 18.3.2 / 18.11.1 矩阵、性能数据及开放门槛 |
| [P6 交付](p6-acceptance-2026-10-16.md) | 集成和功能删除时的证据，非当前审批外观指南 |
| [Markdown 文件预览](markdown-preview-acceptance-2026-10-16.md) | 论文/语料、离屏布局与资源结果 |
| [文档核对](documentation-audit-2026-10-17.md) | 本轮清理、来源核对、系统入口及剩余工程限制 |
| [Goal 接入审核](goal-integration-audit-2026-10-17.md) | OMP 18.11.2 与当前接入的静态源码核对、8 项潜在问题分级；未运行 GUI/OMP |

## 研究与来源

| 记录 | 当前解释 |
| --- | --- |
| [会话记录面板与 OMP 数据调查（2026-10-24）](session-history-research-2026-10-24.md) | 18.12.5 原生字段与读取限制、pi-app 采集／检查器实现、只读面板及后续请求诊断方案；面板仍为占位 |
| [OMP 初次接入研究](omp-integration-research-2026-10-12.md) | 接入选择与早期验证；当前参考是 [OMP integration](../OMP_INTEGRATION.md) |
| [eval / todo 审计](EVAL_AUDIT.md) | 特定 OMP 18.3.2 的持久化与展示事实 |
| [聊天 Markdown 初次实现](chat-markdown-implementation-2026-10-13.md) | 选型、实现及外部实验仓的当时信息 |
| [SwiftMath/Temml 研究](swiftmath-temml-evaluation.md) | 独立研究负载；产品聊天仍是 SwiftMath |
| [Tivano Kimi 适配](tivano-kimi-code.md) | 已退休的 runtime 及图标来源，不能据此启用 Kimi CLI |
| [Tivano 历史迁移](tivano-repository-history.md) | 导入来源的历史事件，不重写本 fork 历史 |
| [Tivano 公共发布](tivano-public-release.md) | 退休流程；发布脚本已禁用，相关辅助脚本部分已删除 |
| [Tivano 镜像运维](tivano-aliyun-update-mirror.md) | 旧服务部署记录；不是 OMP GUI 的服务器或更新源 |

归档不覆盖原文的局部结论，也不补造当时未做的验证。阅读时保留版本和范围，新增结论写当前指南或新的日期记录，不把历史「已通过」扩张为全系统认证。
