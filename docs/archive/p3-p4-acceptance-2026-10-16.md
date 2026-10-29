# P3 / P4 验收记录

> 历史记录：仅代表原文所列日期、版本及验收范围，不是当前操作指南。 当前已移除的收件箱、会话记录、独立 fork 和诊断入口不因本文的历史描述而恢复为功能。 当前入口见[文档索引](../README.md)和[功能状态与验收边界](../status.md)。

2026-10-16，Dev **0.1.24 / build 25**，本机 **OMP 18.3.2**，真实模型 **kimi-code/k3**。P3、P4 在本机公开接口支持的范围内验收通过，相关计划树集成本地 main。P0 剩余验收仍暂缓；没有将跨版本、完整 VoiceOver/减少动态效果矩阵或真实外部账号重新授权计作已通过。

## 实际运行与隔离

`tests/acceptance/capabilities.py` 启动本任务构建的独立 Dev 实例，使用全新 GUI defaults/library、临时 Git checkout 和 linked worktree。P3 的原生 profile、插件 registry 和合成凭据也在本任务 `build.noindex/omp-capability-live/` 中；P4 由 OMP 读取既有模型认证，使用只读测试任务和独立 native worktree 根目录。没有修改 owner 的实际 profile 配置或账号，也未停止、安装或替换原有运行中的 GUI。

合成 provider 是仓库内自编的本地插件，经过真实 OMP 插件 CLI 加载。OAuth 回调只接收 `ACCEPTANCE_OK`，没有外部账户、网络授权或真实 token。另一个无法连接任何服务的 bootstrap provider 满足 OMP 非交互进程必须先有可认证模型的启动要求；扩展命令不调用它。测试回调经过生产 `OMPNativeLogin`、真实 RPC 和 `OMPLoginSheet`，不是预先录制的 RPC 回放。

原生运行记录汇总见 [JSON](../evaluations/2026-10-16-p3-p4/native-gui.json)。P3 使用运行 `20261016-051453-20a3d757`，P4 最终通过运行 `20261016-052219-8681bf2c`。前者完成 P3 后，P4 首个 host tool 检查因验收器只匹配直接 toolName 而失败；原生实际使用 `write → xd://<工具名>`。校正验收器后单独复验 P4，没有把这一失败隐藏为一次全绿运行。中间 P4 运行还确认本机不支持子代理 control RPC；验收按真实能力核对不可用状态。

## P3

真实原生服务检查 23 项、中文窗口检查 12 项通过，覆盖：

- 本地插件安装、清单与 user scope、原生 doctor 诊断、卸载；设置页点击重新载入后显示实际插件，诊断输出可见。
- 新 profile 无法列出登录 provider 时仍有终端登录入口；安装的合成 provider 在登录前未认证，GUI 输入回调后由 OMP 持久化到隔离 profile。
- 富选项说明、原生多行预填，编辑后逐字保留中文、emoji、前导空格和末尾换行；状态文字及 above/belowEditor 文本组件。
- 用户正在输入时 prepared editor text 不覆盖草稿；明确应用后原草稿保留为未提交记录；真实原生超时及取消清理对应问题。
- 命令来源为 extension；原生角色写入、`-1` 递归深度、未知配置字段保留，外部改写后拒绝陈旧保存并能重新载入。
- 角色、子代理模型覆盖和禁用代理表单首开即显示已有值；实际从角色表单保存 `plan: @smol`，default、smol、未知 future role 和外部字段均保留。
- MCP 配置修改保留未知字段；界面分别显示“已配置禁用”和“连接状态未知”，没有启动测试 server 或把启用配置称为已连接。

本次修复两处实跑问题：没有已认证模型时登录 RPC 提前退出导致入口消失；SwiftUI 布尔弹窗捕获旧初始值导致表单首开空白。后者改用包含配置快照的 presentation item，并在保存时保护 profile 范围。补齐相关 zh-Hans 文案。

## P4

真实模型/原生检查 10 项、中文窗口检查 6 项通过：

- K3 经 OMP 挂载的 host tool 读取明确加入的 Unicode 选区，输出其绝对路径、行号及源 worktree；打开 linked worktree 的源文件第 2 行。清除明确上下文后，生产 callback 拒绝再次读取。
- 原生 `task` 创建 project 来源的隔离 worker，保留 observation、父子 session file 和创建它的 tool call；后台 worker 尚未结束时父会话不可回收。
- 本机 `steer_subagent` 与 `cancel_subagent` 的真实响应均为 Unknown command，GUI 对应控件保持不可用。支持这些命令的后续运行时路径由定向协议回归覆盖，没有声称本机完成了子代理 steering。
- 隐藏详情后重新打开，按原生文件游标补读到完整工具步骤及 `P4_CHILD_FINAL`；界面可再次打开这些步骤和报告。主会话 `P4_HOST_OK` 与下一轮 `P4_PARENT_FINAL` 同时保持可读。
- 实际模型 `kimi-code/k3`、思考级别 off、来源 project、父子身份及 native worktree 目录正确。异步结果没有给出 isolation/application 布尔值和 output artifact，界面显示“OMP 尚未报告”，没有推断变更已应用。

本次修复会话工作目录读取：OMP 原生日志在 session header 之前可能写 title record。读取改为只检查本 GUI 存储内的有限前置记录，支持这两种头部格式；不扩大任意文件读取范围，也不扫描完整子代理历史。

## 构建与回归

下表入口使用当前名称；次数与结果是当时记录，测试系统迁移没有重跑这些验收。

| 验证 | 结果 |
| --- | --- |
| `make build` | 通过，独立 Dev 构建，无签名安装 |
| `make verify AREAS="config"` | 32 项通过 |
| `make verify TIER=native AREAS="config" OMP=/absolute/path/to/omp` | 14 项真实原生 CLI 检查通过 |
| `make verify AREAS="workers"` | 47 项通过，含新增标题前置头部、读取边界及外部日志拒绝 |
| `make verify AREAS="timeline"` | 100 项通过 |
| `make verify AREAS="workflows"` | 68 项通过 |
| `make verify TIER=native AREAS="fast-write" OMP=/absolute/path/to/omp` | GUI 3、原生 snapshot 52、GUI decoder 255 项通过 |
| `make verify AREAS="markdown-layout"` | 30 个 Unicode/字体/CJK 情形通过 |

原有 P1/P2 的真实模型 22 项验收记录继续保留；本次在合并候选上验证上述相关回归。未重复 P0 资源门槛测量。没有独立 Xcode test target，没有远端推送、PR、发布或打包。

## 原生边界与后续

本机公开 RPC 没有子代理控制命令或 MCP live 连接状态；扩展任意 TUI 工厂等能力继续使用原生终端入口。首次真实外部 OAuth、secret prompt、跨版本矩阵和完整辅助功能矩阵未在此合成账号流程中验证，后续 P5 收口时单独记录，不能用协议 fixture 代替。

分支、所有工作区及近期 reflog 对象的遗漏检查见 [main 集成检查](main-integration-audit-2026-10-16.md)。
