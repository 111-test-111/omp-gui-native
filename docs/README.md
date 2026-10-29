# OMP GUI 文档索引

这里是人和 agent 的共同入口。当前指南描述本地 `main` 的实现；[历史记录](archive/README.md)保存特定版本的计划、实验和验收，不能用来判断当前入口或授权。

## 按任务阅读

| 要做的事 | 先读 | 接着定位 |
| --- | --- | --- |
| 第一次了解项目 | [项目介绍](../README.zh-CN.md)、[当前状态](status.md) | [架构与源码地图](architecture.md) |
| 查看本阶段计划与实施 | [N0–N4 实施及 Q 开放项](archive/native-stage-implementation-2026-10-17.md) | [原计划](archive/next-functional-plan-2026-10-17.md)、[当前边界](status.md) |
| 开始修改、构建和集成 | [AGENTS.md](../AGENTS.md)、[开发工作流](local-development.md) | [验证规范](verification.md) |
| 使用聊天、审批、队列和 Hydra | [使用与交互](chat-workflows.md) | [侧栏提醒](thread-reminders.md)、[文件预览](file-preview.md) |
| 修改原生接入、模型或配置 | [OMP 接入](OMP_INTEGRATION.md) | [工具身份表](OMP_TOOLS.md)、[数据归属](shared-library.md) |
| 修改 UI 或文案 | [UI 约定](ui-guidelines.md) | [本地化约定](i18n/CONVENTIONS.md)、[聊天 Markdown](markdown-rendering.md) |
| 定位故障或数据问题 | [故障排查](troubleshooting.md) | [数据与配置](shared-library.md)、[能力及验收边界](status.md) |
| 按 owner 要求打包安装 | [打包契约](packaging.md) | [开发与授权规则](../AGENTS.md) |
| 整理文档或交接 | [文档维护规则](documentation.md) | [本轮核对记录](archive/documentation-audit-2026-10-17.md) |

## 当前指南

- 工程：[架构与源码地图](architecture.md)、[本地开发](local-development.md)、[验证](verification.md)、[文档维护](documentation.md)。
- 产品：[聊天工作流](chat-workflows.md)、[侧栏提醒](thread-reminders.md)、[文件预览](file-preview.md)、[工作区浏览器](browser.md)、[当前状态与验收边界](status.md)。
- 原生边界：[OMP 接入](OMP_INTEGRATION.md)、[工具与图标](OMP_TOOLS.md)、[数据与配置](shared-library.md)、[简洁回复指导](anti-slop.md)。
- 界面：[UI 约定](ui-guidelines.md)、[本地化](i18n/CONVENTIONS.md)、[聊天 Markdown](markdown-rendering.md)。
- 运维：[故障排查](troubleshooting.md)、[本地打包](packaging.md)、[源码发布说明](source-release.md)、[仓库来源](repository-history.md)。

## 随代码维护的说明

| 位置 | 用途 |
| --- | --- |
| [tests/README.md](../tests/README.md) | 测试入口导航，登记表在 `tests/catalog.py` |
| [手动验收](../tests/acceptance/README.md) | 需明确 GUI 运行授权的驱动 |
| [数学渲染实验](../tests/benchmarks/math_renderers/README.md) | 单独选择的研究负载 |
| [Markdown 资源构建](../scripts/markdown-preview/README.md) | 固定版本、离线资源及许可证 |
| [图标来源](../design/icons/README.md) | 已批准的上游图标与 Dev 派生资产 |
| [继承的 DMG 资产](../release/dmg/README.md) | 历史素材，当前没有 DMG 发布入口 |
| [问题报告](../.github/ISSUE_TEMPLATE/bug_report.md)、[功能请求](../.github/ISSUE_TEMPLATE/feature_request.md)、[PR 模板](../.github/PULL_REQUEST_TEMPLATE.md) | 保留的贡献模板；模板不授权远端发布 |

## 记录与许可

[Changelog](../CHANGELOG.md)记录本地 Unreleased 变更及继承的历史版本；[历史目录](archive/README.md)按计划、验收、研究和上游记录分类；[评估数据目录](evaluations)保留已检入的 JSON、CSV 和图像。

[LICENSE](../LICENSE)、[商标政策](../TRADEMARK.md)和[第三方声明](../THIRD_PARTY_NOTICES.md)随应用保留。第三方原始许可证不按产品功能重写，已移除功能的署名也继续保留。
