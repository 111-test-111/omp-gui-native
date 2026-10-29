# 仓库来源与集成

OMP GUI 是从 Tivano 派生的独立项目。Tivano 基于 Droppy Code；Droppy Code 的 T3 Code 来源及第三方署名继续保留。它是明确标记的修改版，不代表任一上游作者背书。

公开 `main` 保留 Tivano 1.1.7 的公开基线及其上游历史，随后以实际整理日期提交首次公开集成快照。本地开发记录中的 `3294f65`（2026-10-12，OMP 唯一运行时）和 `b3b38fa`（`OMPGUI` 工程及 make 入口）是公开前的提交引用，并非公开快照中的可重现对象。原本地仓库、作者信息和工作树未被重写；公开历史与隐私整理范围见[源码发布说明](source-release.md)。

## 当前工作流

- 主分支为本地 `main`；`upstream`指向 Tivano，只用于读取来源，不作发布目的地。
- 任务从本地 `main`分出 `codex/`分支，在独立 worktree 开发，形成一个任务提交后快进集成。
- 保留其他任务的 worktree 与运行应用；仅按 owner 要求清理已完成 worktree。
- 无远端 push、PR 或发布的默认授权；继承的发布脚本禁用。

具体命令、验证和版本处理以 [AGENTS.md](../AGENTS.md)、[本地开发](local-development.md)和[打包契约](packaging.md)为准。

## 上游历史的含义

旧文档曾记录 Tivano 于 2026-10-08 的历史迁移及公开发布准备，现保存在[上游历史记录](archive/tivano-repository-history.md)。那是导入来源的历史事件，不是本 fork 要执行的历史重写流程，也不授权合并旧任务树、迁移数据或公开仓库。

[Changelog](../CHANGELOG.md)中已发布版本属于继承记录，OMP GUI 的本地变更位于 Unreleased。继承的 provider 枚举、图标和署名可用于档案兼容，不能据此恢复执行适配器。

保留 [LICENSE](../LICENSE)、[Droppy 商标政策](../TRADEMARK.md)、[第三方声明](../THIRD_PARTY_NOTICES.md)。其中原始许可条款继续适用；整理文档不会改变许可或商标授权。
