# 文档与代码核对记录

2026-10-17。核对起点为本地 `main=53d8be0`，整理期间纳入 `5d4b3df`的问答 popover 锚点修复。本文记录文档维护范围；不替代应用构建、原生协议或系统验收。

## 范围和方法

盘点原有 **45 份 Markdown**（含隐藏的 GitHub 模板）以及 LICENSE 和 **6 份原始字体/库 notice 文本**。核对工程、开发/打包脚本、配置、各层主要入口及测试登记；原始许可证按保留要求检查，不改写许可条款，也不改图标或评估数据。

当前指南分别链接实际生产入口；本地文档、源码和资产链接纳入统一静态检查。阶段报告保留原日期、版本、次数与局部结论，移至 archive；旧授权不延伸到新任务。远端站点及本轮未执行的运行时行为没有冒充已复验。

## 原有文档的处理

| 原位置或分组 | 核对来源 | 处理 |
| --- | --- | --- |
| README.md、README.zh-CN.md | OMP session、AppInfo、Makefile、工程及当前 UI | 重写为对齐的产品入口，移除「P6 下一阶段」、旧面板与一致生成工程的误导 |
| AGENTS.md | owner 工作规则、现有目录/验证入口 | 保留全部约束，只加入索引、架构和文档维护导航 |
| CHANGELOG.md | 当前 main、本地/继承历史 | 保留历史条目，新增本地文档整理记录，不将旧版本当当前功能表 |
| THIRD_PARTY_NOTICES.md、TRADEMARK.md、LICENSE 及 6 份 notice 文本 | 资源、依赖锁及打包资源声明 | 纠正第三方说明中的当前/历史路径和退休功能范围；原始许可、商标及署名保留 |
| docs/OMP_INTEGRATION.md、OMP_TOOLS.md | OMPSession/RPC/SDK、CLI、原生配置、工具枚举及 symbols | 分离初次研究与当前接入参考；修正 progress 订阅及源码入口；工具表保持精确身份和版本范围 |
| docs/local-development.md、packaging.md、shared-library.md | develop/package/install 脚本、xcconfig、Storage/AppInfo/lease | 清除 Tivano bundle/Keychain 路径与不存在的 separation 流程；准确区分 build、run、package、install |
| docs/anti-slop.md、thread-reminders.md、i18n/CONVENTIONS.md | system hook、session signature、活动/未读状态、当前请求 UI及catalog | 更新唯一 OMP 路径、等待 capsule、deferred context、草稿/取消及翻译维护要求 |
| docs/file-preview.md、markdown-rendering.md | Files、Preview、聊天 parser/math、离线资源 | 分开聊天/文件两条渲染链，将实验和测量迁入历史记录，保留当前预算及验证边界 |
| docs/verification.md、tests/README.md、tests/acceptance/README.md | Makefile、catalog、runner/recipes、验收驱动 | 保留分层及最小范围，新增静态 documentation 模块及维护说明；手动 GUI 授权边界不变 |
| scripts/markdown-preview/README.md、tests/benchmarks/math_renderers/README.md | 对应构建源、lockfile、recipe和固定研究负载 | 保留适用的离线重建/研究说明，作为邻近源码说明纳入索引 |
| design/icons/README.md、release/dmg/README.md | 当前资产目录、实际打包脚本 | 修正 OMPGUI 路径，明确批准图标与继承 DMG 素材；删除不存在 package_dmg 的现行操作步骤 |
| .github 的两个 issue 模板及 PR 模板 | 当前错误/验证信息需求、AGENTS 授权 | 保留问题模板；PR 模板补范围化验证、指南同步和本地发布边界 |
| native-development-plan、P0、P1/P2 工作流/验收、P3 入口、P4 文件上下文、P3/P4 验收、main 集成检查 | 各自日期/版本及当前源码剩余范围 | 移至 archive，加历史标记并修复入链；不保留为当前 setup/待办 |
| P5、P6 方案/实施/任务/验收 | 当前功能删除及后续审批/问答代码 | 移至 archive；当前入口汇总到使用指南和状态页，未关闭验收不丢失 |
| EVAL_AUDIT、swiftmath-temml-evaluation | 特定原生版本和独立研究数据 | 归档，保留明确版本、样本与局部结论；不触发重跑 |
| kimi-code、public-release、operations/aliyun-update-mirror、旧 repository-history | 唯一 OMP registry、禁用 publisher、fork 历史 | 归档为 Tivano 历史，明确不适用于本 fork；当前来源另写 repository-history |

完整历史文件逐项见[归档索引](README.md)。新增当前入口包括[架构](../architecture.md)、[交互](../chat-workflows.md)、[状态](../status.md)、[UI](../ui-guidelines.md)、[排错](../troubleshooting.md)及[文档维护](../documentation.md)。

## 确认并保留的工程限制

1. `project.yml`缺少已检入 Xcode 工程中的 SwiftMath 及显式文件夹资源配置，不能声称两者完全一致。正常构建入口继续是 Xcode 工程。
2. package_local.sh 要求 Dev/Release 各自显式设置相同 team，但 Dev xcconfig 未设置，打包 preflight 会拒绝。此次只修正文档，不修改签名配置。
3. GUI 独立库/state/偏好和 GitHub Keychain service 已更名；启动 lease 仍使用 Tivano 命名。保留真实互斥行为，不把命名误述成旧数据导入。
4. 收件箱、Session records、独立 fork、工具/MCP 观察和运行时诊断已删除；正常聊天、消息编辑 branch、Usage 上下文和原生 MCP 配置保留。
5. 真实窗口、屏幕 p95/父版本比较、完整资源峰值与系统现场矩阵保持开放，见[状态](../status.md)。

## 本轮验证范围

只选择 `make verify TIER=static AREAS="documentation harness syntax"`：本地链接/锚点/导航、检查器与 runner 契约、工具语法。每次执行的实际状态、输入指纹及日志位于本任务 worktree 的 `build.noindex/verification/runs/<run>/report.json`。修正后只复跑受影响的失败项，仍有效的通过证据复用。

不构建、不启动或退出 GUI，不运行已安装 OMP、外部模型、性能负载或兼容矩阵，不修改真实 profile，不打包安装或发布。文档检查不联网验证外部 URL，也不能自动证明自然语言与全部运行时行为一致。
