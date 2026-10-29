# Goal 输入模式、原生弹层与实际 OMP 升级（2026-10-17）

Owner 报告当前应用旁问与目标分别返回 `Unknown command: btw` / `goal`，要求按钮锚定的弹出面板与更少解释文案；随后明确要求 `/goal` 激活目标模式、发送正文即目标，普通状态隐藏顶部入口。

## 原因与环境修改

实际 GUI 连接加载的是登录 PATH 中 fnm npm 全局安装的 OMP 18.3.2，经 Bun SDK host 启动；该安装的公开 RPC 没有这两个命令。此前 [Q 局部验收](native-q-acceptance-2026-10-17.md)的 18.11.2 standalone 在隔离目录，并未替换用户的日常安装。接口接法正确，旧安装不能通过 GUI 模拟出新能力。

Owner 明确授权当前工作可结束、退出当前 Dev GUI 并升级现有全局安装，随后补充「直接升级，检查兼容即可」。退出获准实例及其原生进程后，沿用现有 fnm npm prefix，执行固定版本 `npm install --global @oh-my-pi/pi-coding-agent@18.11.2`；实际命令明确传入原 prefix，未另建并行 runtime。`omp --version` 返回 `omp/18.11.2`。未修改 OMP 活动 profile、账号或项目配置，未启动新版 GUI。

## 最终行为

- `/goal` 是本地输入模式，以公开 Goal RPC 创建目标；它不是把 TUI 命令字符串转发给 RPC。命令建议可直接选择，也支持 `/goal 正文`。仅选择模式不启动运行时；发送正文才允许启动或恢复连接。
- 普通状态隐藏顶部 Goal。选择输入模式、存在当前目标或等待创建确认时才显示入口。正文只在主输入框编辑；弹出面板保留可选预算、原生状态与用量、暂停/恢复/放弃。
- 创建后的初次普通消息只在原生明确空闲、目标/连接/运行代次仍匹配时发送一次。原生已排定、正在运行或完成过首次轮次时不补发；未知结果不重发，不创建 GUI 续跑循环。确认只清匹配草稿；冷创建及未知结果保存原生恢复身份。
- 旁问为按钮处的 420 × 440 pt 原生弹层，Goal 为 460 × 360 pt；正文和长错误有界滚动，操作留在滚动区外。不支持时缩为简短升级提示。两者复用现有 Chrome/Badge popover，关闭后释放 hosting content，保留 runtime 中的草稿与有界原生状态。
- 输入 placeholder 的 Goal 判断留在原本绑定草稿的文字列内，不让整个 composer 因正文每次按键重算。新增文案有 zh-Hans；Dev 为 0.1.62 / build 63。

## 选定验证

初次 `make build` 通过。功能层 `goal workflows questions interactions` 依次通过 43 / 120 / 71 / 68 条行为检查。Goal 增补裸命令/内联正文、无启动模式选择、冷提交、原生排定和已完成轮次的双发抑制等边界。

首次真实 npm RPC 检查在启动阶段失败（0 条行为），后续 Goal/旁问未执行。单次无模型诊断捕获到 `installNativeAskDialog` 向原生只读 getter 赋值的 TypeError。18.11.2 的 getter 在 `set_ask_dialog` 启用前返回 undefined；原兼容桥误判其缺失。修正为检查属性存在性，保留原生实现，旧版缺少属性时仍使用 SDK input 桥；没有换回 standalone 或忽略失败。

同时核对原生 Ask parser：空 customInput 会被 trim 为 undefined，note 被忽略。只对直接原生 `ask` 的跳过改为明确、非空的未回答文本，不选择选项、不取消工具；旧桥保持原语义。增加真实只读 getter 与真实 native Ask/RPC 检查，修复后只增量构建并执行受影响检查，不重跑已通过的 Goal/工作流/审批行为。

修复后的增量构建通过；实际 npm 18.11.2 的 RPC / Goal / 旁问分别通过 22 / 10 / 11 条，问答序列化通过 78 条，真实 AskTool + SDK/RPC 通过 42 条，包含只读 getter、原生 opt-in 与跳过不取消的实际往返。

原生层与静态检查结果见[检入摘要](../evaluations/2026-10-17-goal-mode/acceptance.json)。原生检查使用此次升级的 npm 可执行文件、隔离 profile 与本地确定性 HTTP provider；不使用旧 standalone、外部账号或付费模型。

本次没有启动新版 GUI，不声称弹层的实际合成、输入法、完整键盘导航、VoiceOver、屏幕 p95 或资源预算通过。既有 [Q 开放项](../status.md#尚未关闭的验收)继续保留；源审、离屏布局与原生协议检查不代替现场窗口验收。所选检查通过即停止，不重放历史/预览负载或扩张版本矩阵。
