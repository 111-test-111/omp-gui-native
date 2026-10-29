# OMP 18.13.3／Bun 1.4.4 升级兼容检查（2026-10-29）

Owner 要求升级日常 OMP 和 Bun、完成 GUI 兼容适配并验证后集成到本地 `main`。任务从本地 `main` 创建 `codex/omp-18-13-3` worktree；本轮不发布、不运行外部付费模型。旧 GUI 及其 OMP host 在隔离检查期间保持原状；owner 随后明确授权隔离浏览器验收，以及通过后保存并正常退出旧实例以完成全局安装切换。

## 版本与生产适配

- OMP 从 18.12.5 升至固定 npm 18.13.3；Bun 从 1.4.2 升至固定 npm 1.4.4，满足新 SDK 的最低版本。候选通过 `npm install --global --prefix <worktree>/build.noindex/omp-runtime` 安装，与日常 npm 全局目录布局一致。
- 逐文件比较原始 OMP SDK 后重建浏览器修复的版本／输入／输出 SHA-256。保留精确 CEF target、原始 CDP 会话恢复、所选 profile 的 Cookie／下载、iframe 截图、后台焦点及 Eval 错误归属；不覆盖上游新增的导航、输入取消和 inline worker 关闭实现。
- 删除 `open-options.ts` 的证书补丁。OMP 18.13.3 已原生返回持有的证书 CDP 会话，worker 关闭时 detach；定向检查验证会话保持及释放。GUI 仍保留显式 `false` 重开和 CEF 主文档证书错误投影。
- `manual_compaction_start`／`manual_compaction_end` 同步活动状态和上下文结果，阻止维护期间回收，隔离旧状态回复，并在结束后使历史缓存失效。原生取消、跳过与成功仍分别呈现，不从结束事件自行推定 settled。
- 旧 SDK 仍通过公开 idle barrier 区分 next-turn 上下文与运行中的队列。18.13.3 将未触发的隐藏 next-turn 上下文排除在 `queuedMessageCount` 外并报告 settled；原生 RPC 检查接受这两种明确语义，继续验证真实失败的 todo 和下一次显式提示消费提醒，不读取私有队列或恢复应用自有调度。
- 同步独立 CEF 原型的 OMP 源码哈希和最小补丁，保留其独立 GUI 验收授权要求。Dev 版本为 0.1.339／build 340。

## 选定验证

所有原生检查明确使用任务 worktree 中的 OMP 18.13.3 和 Bun 1.4.4。它们使用新建隔离 profile、确定性本机 provider 或原生接口替身；不访问现有账号、会话、记忆数据库或外部模型。

| 层级 | 模块 | 本轮结果 |
| --- | --- | --- |
| 构建 | `make build` | Dev 0.1.339／build 340 通过，未启动 |
| 功能 | `browser-bridge queue` | 浏览器守卫及 51 项队列检查通过 |
| 功能 | `workflows rpc` | 156 项工作流、95 项协议／分帧检查通过 |
| 原生 | `browser-sdk` | 真实修复 SDK 导入、frame、profile state、Eval、下载／证书会话与输入哈希通过 |
| 原生 | `rpc approvals workers memory` | 21 项 RPC、5 类审批／10 次响应、21 项 worker 配置及记忆 RPC／21 项 SQLite/FTS 检查通过 |
| 原生 | `config model-configuration request-capture` | 24 项配置、122 项模型／图片／密钥，以及主／子／旁问请求采集、实时上下文和 tokenizer 元数据通过 |
| 静态 | `documentation harness syntax` | 文档链接、33 项执行器契约及脚本语法通过 |
| 现场 | 生产 CEF／OMP `start options tls` | 13＋16＋7，共 36 项真实浏览器断言通过；三个隔离宿主均正常退出 |

[机器可读摘要](../evaluations/2026-10-29-omp-18-13-3/acceptance.json)记录最终通过项、构建指纹和完整报告路径。已通过的项目不因后续无关文档或安装切换重复执行。

首轮浏览器 SDK 检查使用普通本地 npm 依赖布局，依赖提升使隔离 SDK 副本不能找到对应 native addon；修正为上述全局布局后检查通过。新增手动压缩回归首次编译时将可选布尔值当作非可选值，改为显式 `== true`／`== false`。原生配置检查重新加载登录 shell 后误用日常旧 Bun，修正测试 overlay，使它保留执行器选定的 PATH。两者均保留原业务断言，修正后仅重跑失败及未运行范围。

## 日常安装和本地集成

Owner 授权后，对原先运行的 Dev GUI 发出正常应用退出请求，确认其保存／关闭路径完成，旧 GUI 和 OMP host 均已结束。沿用现有 fnm npm prefix 安装固定版本 `@oh-my-pi/pi-coding-agent@18.13.3` 和 `bun@1.4.4`。日常 `omp --version` 返回 `omp/18.13.3`，`bun --version` 返回 `1.4.4`。

安装后 OMP 及依赖共 26,110 个文件／链接、Bun 共 8 个文件／链接的路径和内容摘要与本轮候选逐字节一致，复用其通过证据；没有重复相同原生负载。新 Dev 构建留在任务 worktree，未打包、安装或重新启动日常 GUI。任务保留为一个本地提交并快进集成到 `main`，不推送，保留 worktree 和生成证据。

## 验收边界

本轮使用新的隔离生产 CEF 宿主和 OMP 18.13.3／Bun 1.4.4：`start` 覆盖双标签精确附着、后台输入／拖动／滚轮、兄弟弹窗、Cookie state、跨域 frame、超时恢复及释放后再附着；`options` 覆盖恢复前后的启动选项、viewport、下载目录及真实文件字节；`tls` 覆盖默认拒绝、显式允许、兄弟隔离、恢复保持、显式关闭及释放。frame selector 截图经视觉核对显示输入框的 `child-value`。TLS fixture 的 SSL 握手拒绝日志为预期的无效证书控制，七项产品断言及宿主退出均通过。

未将旧版真实 CEF 结果当作新版证据。未重新启动日常完整 GUI；未验证外网账号、所有网站／浏览器后端、完整 IME／VoiceOver、签名安装包或性能预算。新的 RPC 会话树导航、语音采集等接口不自动成为新增 GUI 功能。[当前开放项](../status.md#尚未关闭的验收)继续保留。
