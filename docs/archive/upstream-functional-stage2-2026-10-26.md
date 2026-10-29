# 上游第二阶段：本地听写与原生能力评估（2026-10-26）

来源为 Droppy Code [e7dd8dcb](https://gitlab.com/droppyformac1/droppy-code/-/commit/e7dd8dcb3ac0c605473afb0243052a94c116e19d)（2026-10-09）。本地起点 `80409a2a8` 已包含首批视觉移植及后续步骤、上下文和服务商登录修订。本轮只实现本地听写；实时语音、套餐额度及其他优化作评估，不启用入口。集成时保留主分支前移的 `6dc66cc69`（Context 导出菜单及图标修订）。Dev `0.1.293` / build `294`。

## 本地听写与依赖

[听写服务](../../OMPGUI/Services/Dictation/LocalDictationService.swift)使用 macOS 26 系统的 AVFoundation / Speech（`SpeechTranscriber`、`SpeechAnalyzer`、`AssetInventory`）。没有额外 Swift package、OMP 模型角色、API Key、Bun、ffmpeg 或 Whisper 依赖。设备／语言支持取自系统，不把 macOS 版本相符理解为所有语言都支持；不支持时要求明确选择，不静默改用英语。

麦克风设置弹窗可选择系统声明支持的语言，并按需安装对应资源。系统负责下载、缓存和更新，资源可被其他应用共享；不随 GUI 资料库复制，也不由 `make clean` 删除。安装有进度和取消，安装完成后仍需用户点击麦克风。设置选择只保存在当前 edition 的 GUI 偏好中。系统资源达到保留限制或安装失败会保留草稿并提供重试入口。依据：[SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)、[AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)。

[控制器](../../OMPGUI/App/Runtime/ComposerDictation.swift)与[输入框控件](../../OMPGUI/App/Views/Composer/ComposerDictationViews.swift)提供：

- 首次麦克风授权后再次点击才录音；迟到的权限／资源响应不会在后台开始录音。
- 全应用一次录音／转写／安装操作；同一会话的编辑器共享状态，其他编辑器不能抢占。
- 最长五分钟、16 kHz 单声道临时录音；私有目录权限为 `0700`，成功、失败和取消均清理。取消先立即停止录音，再排空异步识别，迟到结果不得追加。
- 转写只追加到同一身份的草稿，保留录音期间的编辑、附件、引用和命令。相同文字的新草稿也属于另一条输入，结果转入可复制的恢复区；正文上限为 128 KiB。
- 录音／转写期间拦截普通发送、steering、follow-up 和停止后发送，菜单与按钮同步禁用；已有任务的停止仍可用。隐藏聊天、离开输入框及丢弃运行时会取消听写。
- 新增音频输入 hardened-runtime entitlement、麦克风用途说明及其中英文 `InfoPlist.strings`；项目文件与 `project.yml` 同步声明。没有削弱签名或 hardened runtime。

本机识别使用系统管理的模型；首次安装需要网络，录音与转写不调用语音云服务。未在本轮下载系统语言资源、申请麦克风权限或录制真实音频。实际权限归属、语言准确率、断网安装／取消、真实输入法与窗口切换仍属现场验收。

## OMP 套餐、额度及账户核实

固定核对本机 npm **OMP 18.12.5** 的 CLI、RPC 类型和 SDK 源码；没有把 GitHub `main` 当作该安装的能力证明。[能力清单](../evaluations/2026-10-26-upstream-functional-stage2/omp-capabilities.json)记录源码 SHA-256、全部内置 usage provider 及脱敏后的实际 CLI 结构。公共源码入口：[usage 类型](https://github.com/can1357/oh-my-pi/blob/main/packages/ai/src/usage.ts)、[provider 登记](https://github.com/can1357/oh-my-pi/blob/main/packages/ai/src/usage/registry.ts)、[CLI](https://github.com/can1357/oh-my-pi/blob/main/packages/coding-agent/src/cli/usage-cli.ts)。

### 公开入口与数据语义

| 范围 | 原生支持与限制 |
| --- | --- |
| 当前额度 | `omp usage --json` 返回 `generatedAt`、`reports`、`accountsWithoutUsage`、`disabledCredentials`、`capacity`。实际执行一次 `--json --redact` 成功，取得一个 `openai-codex` 报告，包含 `limits`、`metadata`、`resetCredits`。未保存账号标识、token、原始 payload 或具体用量数字。 |
| 报告内容 | `provider`、`fetchedAt`、`limits[]`，以及可选 `metadata`、`notes`、`resetCredits`。套餐常在自由形状的 metadata 中，不存在每家都必填的统一 `planName`。CLI 删除较重的 `raw`。 |
| 额度窗口 | `scope` 可区分账号／组织／项目／模型／tier／共享池；`window` 可给时长和毫秒级重置时间；`amount` 支持已用、上限、剩余、已用比例和剩余比例。单位包含 percent、tokens、requests、credits、usd、minutes、bytes、unknown，不能全部当百分比。 |
| 百分比与未知值 | 原生优先已用比例，其次 used/limit、percent 单位的 used，最后从 remainingFraction 反推。缺字段保持未知；比例可超过 1 表示超额。绘图可以限幅，原始值和超额事实应保留。 |
| 账户与切换 | 多个 OAuth 账户和用量排序／保留策略由 OMP auth storage / broker 管理。`omp usage accounts` 提供原生身份键；GUI 不需要创建 Codex／Claude HOME 或另一套凭据库。 |
| 历史与客户端 | `omp usage --history --days N --json` 为原生额度快照；`omp usage clients --days N --json` 是 broker 记录的客户端消耗，依赖已收集数据。两者与 GUI 当前保存轮次的 token／费用统计口径不同。 |
| 额度重置 | Codex 与 Claude 的 saved reset 有原生只读状态和单独的 `omp usage reset` 动作。读取与消费必须分开；本轮未消费额度重置。 |
| RPC | 安装的 RPC command union 没有通用 `get_plan_limits`。会话的 usage/context、usage-limit 事件不等于完整账户额度清单；应使用公开 usage CLI 或 SDK `authStorage.usage.reports()`。 |
| 扩展与请求范围 | 原生扩展可注册 usage provider。上游 `--no-extensions` 会漏掉这些来源，不宜作为完整清单。该版 `--provider` 在取得报告后过滤输出，不能据此承诺只访问一家服务。 |
| 缓存与失败 | 使用每份报告的 `fetchedAt`；CLI 成功不等于所有报告均为刚联网取得。无额度接口、未取得报告、过期缓存、失败和实际为零必须分别处理。`accountsWithoutUsage` 不应消失。 |

### 内置服务商覆盖

登记表共有 **22 个内置 usage provider**；具体凭据类型和服务端可用性仍受每个 adapter 的 `supports` / fetch 结果约束，清单不是 22 家真实账号的验收矩阵。

| 来源 | 已核实的报告能力／套餐边界 |
| --- | --- |
| `openai-codex` | 多窗口／模型 tier、账号身份、`metadata.planType`、额度拒绝状态及 saved reset；部分报告也可由请求限额 header 形成，未必包含完整身份和套餐。 |
| `anthropic` | 5 小时／7 天及模型 tier 窗口、额外 USD 用量、账号／组织和 saved reset；不能从窗口结构可靠推断统一的零售套餐名称。 |
| `github-copilot` | 月度 premium requests 或 AI credits，报告可带 `metadata.plan` 及账户信息。 |
| `cursor` | 月度 plan/API/auto/按量等 USD 桶及身份；不是统一的套餐名称接口。 |
| `google-gemini-cli`、`google-antigravity` | 原生模型／配额桶、剩余额度与重置信息；报告随账户和模型形态变化，不保证零售套餐名。 |
| `kimi-code`、`minimax-code`、`muse-code` | 各自原生窗口和余量；Muse 在服务端给出时携带 subscription tier，不能据此给其他提供商补套餐名。 |
| `zai`、`commandcode`、`opencode-go` | Z.ai 的 tokens／requests／credits 及可选等级；Command Code 的额度、credits 和可选 planType；OpenCode Go 的原生百分比窗口及其套餐标记。 |
| `alibaba-token-plan`、`factory-droid`、`cline-pass` | 原生计划窗口；Factory 还可带额外 USD 余额。保留各自窗口标签与来源。 |
| `ollama`、`ollama-cloud`、`synthetic`、`umans`、`xai-oauth`、`devin`、`charm-hyper` | 各自原生配额、消费／余额或窗口报告；Umans 可带套餐 display name，Charm 为 credits 余额。单位、身份和未知值应按实际报告呈现。 |

### 当前 GUI 与下一步

当前 [ProviderRegistry](../../OMPGUI/Services/Providers/ProviderRegistry.swift) 保留的 `planLimits/credits` 是兼容展示类型，[PlanLimitsReader](../../OMPGUI/Services/Providers/PlanLimits.swift) 的入口明确返回 false/nil；没有真实套餐查询。现有设置用量页统计当前 GUI edition 的已保存 OMP 轮次，不代表订阅剩余额度。

有必要在下一阶段接入**只读原生额度**。建议按原生 provider＋账户保留报告，跨服务商页／上下文弹窗共享一次有界读取和缓存，仅可见时刷新，显示原始采集时间、单位、来源与缺失原因。暂不把报告压扁到单个 `.omp` 百分比，也不移植上游账户目录、自动切换或更新其他 CLI。本轮没有新增套餐／额度／账户切换 UI。

## 实时语音：可经 OMP 接入，暂不实现

先前只查看 Droppy Code 时，其语音界面通过 Codex app-server；本轮核对到 OMP 18.12.5 已有自己的公开接口，不能继续概括为“OMP 没有支持”。安装源码与 [rpc-live](https://github.com/can1357/oh-my-pi/blob/main/packages/coding-agent/src/modes/rpc/rpc-live.ts)声明：

- 控制为 `live_start { voice?, instructions? }`、`live_stop`、`live_mute { muted? }`；start 在后台接入，stop 可取消尚未接通的会话。
- 输出 `live_phase`、最多每 100 ms 的 `live_levels { input, output }`、按 role＋turn 合并的 `live_transcript { text, final }`，以及一次终态 `live_end { error? }`。语音帧独立于普通会话事件筛选。
- OMP 的 `RpcLiveBridge` 绑定当前原生 AgentSession，语音委派仍由 OMP 执行；原生负责音频、WebRTC、认证和停止，不需要恢复 Codex runtime adapter。
- 其底层 `CodexLiveTransport` 使用 OMP 的 `openai-codex` OAuth 与 Codex realtime 服务、原生 `AudioCapture/LiveWebRtcPeer`，并有平台／设备证明路径。不是任意模型提供商或普通 API Key 都能通话。

可借鉴球体状态、字幕、静音和显式结束按钮；实现前仍需：当前进程的能力确认、原生音频模块可用性、真实账号服务接受、麦克风权限的进程归属、连接取消／断线、旁问与工具审批共存、进程回收 lease，以及隐藏舞台与结束通话的明确区别。GUI 目前的 idle recycling 不能直接用于仍在通话的原生进程。

按 owner 范围，本轮没有创建语音界面、调用 `live_start`、测试音频设备或建立真实 realtime 会话。结论为**已有原生接入基础，值得后续单独设计和验收**，并非已证实真实通话可用。

## 其余优化逐项判断

| 上游变化 | 当前实现与本轮结论 |
| --- | --- |
| 未闭合 Markdown 的流式修复 | 当前 `StreamMend` 已具备，并加了数学保护、半截代码／强调闭合处理。保留当前实现，不覆盖成更简单的上游版本。 |
| 小块低延迟刷新 | 当前 `ThreadRuntime.flushDelay` 已为 16/45/90 ms，并在滚动时放缓到至少 160 ms，另有多 worker 的共享刷新预算。无需重复移植。 |
| 渐显提高到 30–60 fps | 当前为 18 fps，并在滚动期间冻结不必要重绘。高帧率可能改善短段视觉连续性，也会增加正文更新；没有同负载可见测量，暂不更改。后续只在明确的流式观感问题下比较成本与收益。 |
| 长聊天视口挂载／远距离到底部 | 当前已有 MountedWindow、测量高度 spacer、远跳及返回底部按钮归属修订，保留现有方案。 |
| 顶部渐隐交给原生图层 | 当前已经有 `TimelineTopFade`、原生滚动层遮罩、可调风格和作用域，主会话启用、浮动面板关闭。无需第二次叠加。 |
| 步骤树、居中停靠、设置导航、局部玻璃 | 第一阶段及后续 owner 修订已经覆盖。保留当前思考默认折叠、首行预览、完整步骤和布局约定。 |
| 其他 checkout 中命令的文件归属 | 当前有 `watchForeignCommand`、原生文件 snapshot 及 worktree 归属修订，不恢复上游应用层结果合并。 |
| 全窗口玻璃改 behind-window blur | 当前无壁纸分支仍使用窗口大小的 glass，确有潜在 GPU 优化空间；但另有 Gaussian 壁纸、透明度、主题和辅助功能契约。值得作为独立候选，对同一可见负载测量后再决定；本轮不替换背景。 |
| 多账户、CLI 自动更新 | 当前 OMP 原生管理账户／认证；GUI 无需另建账户 HOME。更新入口应围绕 OMP 自身的公共命令另行设计，不能复活其他运行时的更新器。 |
| Intel 双架构包 | 当前工程明确仅 arm64，用户本轮未要求扩大平台；不移植其发布／安装流程。 |

本轮选定的改动只有听写及其依赖与边界保护；未为评估运行性能负载或扩展原生兼容矩阵。

## 验证与剩余验收

- `make build` 最终通过。初次失败为下载进度回调缺少 Swift 6 要求的显式 self 捕获，修正后增量构建；检查了实际 Dev bundle 的麦克风用途字段及 en／zh-Hans 本地化资源，音频 entitlement 保留于签名配置。
- `make verify TIER=functional AREAS="dictation workflows"`：听写 20 项、原有原生工作流 150 项通过。首次听写检查的 fixture 在历史未加载时激活，被生产门禁正确拒绝；改为等待 `ensureLoaded()` 后执行原断言，没有放宽生产门禁。
- 最终功能报告：`build.noindex/verification/runs/20261026T053705Z-5a9773d1/report.json`。测试使用可替换的 capture / speech 边界，不打开麦克风、不下载资源、不启动 OMP 或 GUI。
- 主分支前移仅修改 Context 导出菜单与版本／changelog；听写、投递源码、fixture 和运行环境未变，复用上述功能通过证据，并对最终合并树增量构建。
- 文档／登记表／测试语法选择 `make verify TIER=static AREAS="documentation harness syntax"`，通过后即停止。
- `omp usage --json --redact` 为一次实际原生只读使用查询；OMP 可以按自身逻辑更新认证和用量缓存。输出只保留结构性证据，不认证未登录服务商或全部网络失败路径。

真实窗口的麦克风授权、首次语言安装及取消、支持语言的实际转写质量、录音输入设备异常、五分钟停止、会话／设置切换、多窗口、输入法、键盘／VoiceOver、窄窗口与最终玻璃合成仍待 owner 授权现场验收。没有安装／启动新 GUI、打包或发布。
