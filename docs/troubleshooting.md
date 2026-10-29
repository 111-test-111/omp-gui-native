# 故障排查

先确定失败属于构建、GUI 数据、OMP 发现/原生接口，还是手动系统验收。只处理当前任务与确切实例；源码入口见[架构地图](architecture.md)。

## 构建与工具

| 现象 | 核对与处理 |
| --- | --- |
| `xcodebuild`找不到 SDK/工具链 | 核对完整 Xcode、`xcode-select -p`及项目 macOS 26/arm64 要求；Command Line Tools 单独安装不等于完整 Xcode |
| `make build`失败 | 阅读 `build.noindex/development/build.log`末尾的实际错误，再定位源码或依赖；不要先清空所有缓存反复重建 |
| 拒绝覆盖正在运行的 app | 确认是否为本 worktree 的 Dev；未获退出授权时保留现状，不杀其他实例 |
| App-linked 检查提示 missing/stale build | 核对当前 worktree 的 `verification-inputs.json`；编译源码变更后做一次增量构建 |
| static 检查缺少工具 | 按计划补齐 Python 3、Node、bash、Xcode 工具链等声明依赖；缺失是环境失败，不是通过 |
| 签名打包提示 team 不一致 | 阅读[打包前置条件](packaging.md#signing-preflight-and-current-limitation)；当前 Dev 未设置 team，unsigned build 不解决它 |
| XcodeGen 生成后缺依赖/资源 | `project.yml`尚不完整；按[工程文件说明](local-development.md#project-files-and-dependencies)核对变更，不覆盖未提交工作 |

检查失败时先读相关生产和测试代码，区分实现错误、过时预期和环境问题；修正后只复跑受影响项。完整停止规则见[验证规范](verification.md)。

## 找不到 OMP 或模型

1. 在 Settings 核对 OMP binary path。留空才自动发现；自定义路径不存在时不会静默退回另一份安装。
2. 核对终端的 `command -v omp`和 `omp --version`，确认与 GUI 所选可执行文件一致。GUI 使用登录 shell，而不是项目的 Node 版本猜测。
3. 登录 shell 探测预算为 15 秒。shell 启动文件若阻塞/过多输出，修正后 Refresh Providers；失败期间使用标准 PATH 回退。具体实现是 [LoginEnvironment](../OMPGUI/Core/Support/Shell.swift)和 [ProviderRegistry](../OMPGUI/Services/Providers/ProviderRegistry.swift)。
4. 模型目录来自原生认证与配置。执行原生 `omp login`或使用 GUI 原生登录入口后重新载入；不要把 key 存到 GUI 自建配置。
5. OMP 18.3.2 在没有任何认证模型时可能提前退出 RPC 枚举。终端登录入口仍可用，不能把空 provider 目录视为 GUI 已管理账号。

活动 profile 受 OMP 环境及配置规则影响；两版 GUI 使用同一外部 profile。只在本次任务的隔离环境执行原生测试，不用真实 profile 试写配置。

## 可选控制不可用或配置不生效

| 现象 | 含义与下一步 |
| --- | --- |
| 旁问/目标报 `Unknown command: btw` / `goal` | 所选 OMP 没有对应公开 RPC；核对实际 binary path/version，升级原安装后重启 GUI。18.3.2 不支持这两个接口；18.11.2 的独立验收不能替代当前进程证据。升级不自动替换活动连接 |
| worker 停止/追加指令禁用 | 当前进程未证实支持，或 worker observation 已过期；查看报告不等于可重新控制旧 worker |
| 队列无法逐条撤回 | 要求匹配的 npm SDK、Bun、原生队列接口及握手；standalone 保持普通聊天，不通过重发模拟撤回 |
| 配置保存被拒绝 | 外部字节、profile 或 executable/environment 已改变；先重新载入，保留未提交修改，不强行覆盖 |
| MCP 显示已启用却无连接结论 | 配置状态不是连接状态；使用同 profile/项目的 OMP 原生 `/mcp`终端入口检查 |
| MCP 或附加提示编辑未作用于当前聊天 | 原生进程可能尚未重新发现文件；按[接入指南](OMP_INTEGRATION.md)确认下次会话启动的生效范围 |
| 上下文动作长时间未知 | 可能已执行；保留待确认记录，等待匹配回复或进程终止，不把 settled 状态当作可重复提交 |
| 没有 plan 开关、历史树或独立 fork | 当前不提供这些 GUI 入口，详见[状态](status.md)；不要按旧阶段文档恢复适配器 |
| todo 清空后仍显示已完成清单 | 这是完成记录的显示投影，未回填 OMP 活动清单；新非空清单会替换它 |

上游特定版本问题需带版本描述。例如 eval 内 `xd://todo`持久化缺口是 [18.3.2 的历史审计](archive/EVAL_AUDIT.md)，不能未经验证推广到全部版本。

## Codex 模型通道的运行中消息拒绝

`unsupported_native_inflight_message` 是 OMP 的 `openai-codex` 模型通道收到的原生服务端错误：该次实验性 native lane 拒绝在响应进行中接收有状态消息。它不能证明所有 Codex 通道都不支持插话，也不代表子代理最终没有完成。公开 Responses API 的 [steering 文档](https://developers.openai.com/api/docs/guides/steering)说明了支持场景，但不能代替当前 Codex native lane 的能力证据。

OMP 拥有父子消息投递、运行中 steering、队列、重试及降级。GUI 保留原始错误、原始时间和所属失败轮次，并展示之后真实发生的回复；不自行重发、切换模型通道或改写 OMP 安装/profile。诊断需向 OMP 提供确切版本、错误码、追加消息与后续完成的时间关系。当前安装中的降级代码存在，不等于本次失败已无损恢复；没有原生消费/结果证据时保留未知。

GUI 的私有会话覆盖固定设置 `providers.openaiLiveSteering: false`，让 OMP 在工具边界消费追加消息，保留普通 WebSocket 流式传输；子代理从 OMP 的父设置继承。此配置随新进程启动生效，并在 Hydra 偏好更新时保留。不要为这项 GUI 降级执行全局 `omp config set`，也不要把已有运行进程当成新配置的验证结果。[原生 worker 检查](verification.md)覆盖已安装 SDK 的配置继承及本地确定性流中的一次消费，不认证真实 Codex 服务端行为。

## 草稿、文件与数据

未知投递不等于失败，不自动重发。审批/问答响应写管道成功也不证明模型任务完成。切回源会话检查活跃请求与投递记录，保留请求实例身份。

库打不开时先核对 edition、磁盘空间、权限、目录是否被 symlink，以及确切持锁进程。租约仍有继承命名；不要删除持锁文件。读取失败的会话不能用空文件覆盖，恢复前保留完整库及原生日志，见[数据指南](shared-library.md)。

预览缺失、二进制、超限或不支持编码会给出原因及重试/外部打开。worker worktree 已删除时不回退到主 checkout 的同名文件。检查来源 worktree、路径及[预览预算](file-preview.md)，不以「修复」为由放宽目录边界或远程资源限制。

## 交付问题所需证据

记录应用 edition/版本、macOS、所选 OMP 路径/版本、项目执行目录的必要关系、复现操作、原始错误和本次验证报告路径。构建、fixture、真实 OMP、离屏渲染和完整 GUI 结果分别说明。

使用[问题模板](../.github/ISSUE_TEMPLATE/bug_report.md)整理可复现材料。分享前移除 token、认证响应、私有聊天及文件内容；不要为了诊断提交整份 profile 或真实库。当前没有 GUI 运行时诊断/导出页，使用现有构建与验证证据即可。
