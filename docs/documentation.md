# 文档维护规则

[文档索引](README.md)是入口；每个当前行为只指定一个主要说明位置，其他页面链接过去。当前文档与源码一起修改，阶段材料保存其原日期/版本的证据。

## 文档类型与权威

| 类型 | 位置及职责 |
| --- | --- |
| 项目工作规则 | [AGENTS.md](../AGENTS.md)：worktree、授权、原生所有权、验证停止条件 |
| 产品概览 | [双语 README](../README.md)：依赖、边界、快速入口及署名 |
| 当前指南 | 本目录：开发、架构、交互、原生接口、数据、渲染、排错及状态 |
| 紧邻代码说明 | `tests/`、`scripts/markdown-preview/`、`design/icons/`等 README |
| 历史记录 | [archive/](archive/README.md)：计划、验收、研究和已退休的上游流程 |
| 数据与许可 | `evaluations/`的可核对数据；根许可证及资源中原始 notices |

当前行为以代码和已检入构建配置为核对依据；工作范围和授权以 owner 指令及 AGENTS 为准。上游文档、版本号和历史成功记录不代表当前进程支持某个 RPC。发现实现与规范不一致时写明事实及剩余项，不把尚未实现的行为写成已交付。

## 更新方法

1. 先确认改动对应的生产入口、配置、资源和测试登记，阅读相关实现；同时检查双语 README、当前指南与状态是否受影响。
2. 使用仓库相对 Markdown 链接指向实际源码/目录，优先稳定文件入口，避免复制行号、完整模块清单或易过期版本。版本值从 xcconfig 读取，验证模块以 `tests/catalog.py`为准。
3. 当前指南给可执行的现有入口、前置条件、保存/取消/失败语义和资源限制。历史证据放 archive 并标日期、版本、负载、范围、失败及未验收项；计划中的预计周期不作为当前待办。
4. 移动文件时修复所有入链、图像路径和章节锚点，并更新索引。没有保留价值的冗余操作说明可从当前树删除，Git 保留历史；不要为每次改名留下第二份完整指南。
5. 变更生产代码时同步对应指南；仅改文档不隐含启动、打包、外部配置写入或升级 OMP 的授权。
6. 保留 LICENSE、商标、来源和第三方完整许可文本。可纠正说明性路径/适用范围，不改写第三方原始许可条款或批准图标。

English 与 zh-CN README 保持同等范围；详细指南以现有中文/英文为主，不为每页机械复制翻译。应用新字符串仍须按[本地化规则](i18n/CONVENTIONS.md)补齐 zh-Hans。

## 静态验证

```sh
# 修改文档链接、导航、归档或 Markdown：
make verify-plan TIER=static AREAS="documentation"
make verify TIER=static AREAS="documentation"

# 修改文档检查器或其他验证工具时，合并选择一次执行：
make verify TIER=static AREAS="documentation harness syntax"
```

`static:documentation`检查仓库内 Markdown 的本地链接、图像、章节锚点及从入口的可达性，不联网、不运行 OMP、不构建应用。它跳过代码 fence/inline code 中的示例链接；不会验证远端 URL 是否仍可访问，也不能自动证明自然语言与运行时语义匹配。实际源码核对和证据范围仍由作者负责。

文档/工具工作按[验证规范](verification.md)只运行相关静态检查。选定检查通过即停止；不要再运行同一脚本或附加 app build、原生矩阵及 benchmark。
