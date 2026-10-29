# 服务商图标、DeepSeek 余额与关键用量设置

日期：2026-10-26。产品范围：OMP GUI，OMP 原生运行时。检查对象为本机安装的 OMP **18.12.5** 公共源码／SDK；这不是全部真实账号的服务可用性矩阵。任务最初基于 `27bf87b83`，集成前合入本地 `main` 的 `5cfef3acc`，保留期间独立交付的聊天错误、数学渲染和听写设置变更。交付版本 Dev **0.1.299 / build 300**。

## 最终界面范围

- 接入 Lobe Icons 固定离线子集：59 个模板图标、72 个原生 provider ID，共用于模型左列、服务商已配置／登录行和 API Key 编辑器。精确映射未知时使用通用标记，不恢复其他运行时。
- 按 owner 的后续调整，将全部账户套餐／余额展示从模型选择器移至“设置 → 服务商 → 已配置”。已配置列表结合 OMP 的可用模型、已认证登录来源及已确认额度账户，包含 DeepSeek 等 API Key 服务商；保留原生浏览器登录能力边界。
- 每行只显示关键额度和有效重置／补充时间，或可用总余额。隐藏重复标题、进度条、更新时间、赠金和充值明细；多账户时保留原生返回的身份标签。不从明细补算缺失总额。
- 模型列表不持有用量读取。列表缩为 **540 × 420 pt**；52 pt 左列、20 pt 图标与常规字体不变。右侧宽度受视口约束，局部原生滚动锁关闭横向滚动条、弹性及横向偏移，保留纵向位置并在拆卸后恢复自己的容器状态。
- 原切换的退出淡出会让旧思考页和玻璃／Canvas 色条在尺寸变化期间继续保留。现在思考页退出立即卸载，只给进入的模型页短淡入／横移，尺寸过渡约 0.22 秒；减少动态效果或性能模式下直接切换。首次打开按较大页面所需空间选择弹出方向，保持同一按钮锚点，减少居中新会话处的翻边。AppKit 仍负责最终屏幕边缘避让。

当前使用入口由[交互指南](../chat-workflows.md#聊天模型选择与套餐用量)维护，不能用此前“模型选择器展示用量”的历史记录判断当前行为。

## 图标来源与依赖

来源为 [`@lobehub/icons-static-svg` 1.101.0](https://www.npmjs.com/package/@lobehub/icons-static-svg/v/1.101.0)，[源码 revision `aea0ecb0fe1439467219197c52ffaeb579dfe33f`](https://github.com/lobehub/lobe-icons/tree/aea0ecb0fe1439467219197c52ffaeb579dfe33f)，MIT © 2023 LobeHub。公开包 tarball SHA-1 为 `58ee9c600e3ca19c82da8364d07e0b9145dfb953`。

[图标清单](../../design/icons/provider-logos.json)保存原始／规范化 SVG 的 SHA-256 和每个别名；[原始 MIT](../../design/icons/lobe-icons-LICENSE.txt)及完整[第三方声明](../../THIRD_PARTY_NOTICES.md)随仓库与应用保留。只规范化 `currentColor`、将 `1em` 根尺寸表达为 viewBox 单位，并移除浏览器专用根 flex 样式，原路径不变。Xcode 编译为原生矢量模板，没有 npm／Swift 新运行时依赖、CDN 或运行时 SVG 解析器。已批准的应用／上游服务商／Hydra 原图保持不变。

## DeepSeek 余额实现

[官方 `GET /user/balance`](https://api-docs.deepseek.com/zh-cn/api/get-user-balance/)已实现，只对官方 HTTPS `api.deepseek.com` 直连生效。完整行为见[OMP 接入边界](../OMP_INTEGRATION.md#subscription-usage-and-voice-boundaries)。

1. npm SDK＋Bun 可用时，由现有本机配置辅助进程加载 OMP 公共 `Settings`、`ModelRegistry`、provider 扩展，并通过 `AuthStorage.keys.get("deepseek")` 取得 OMP 实际选择的密钥。先加载原生扩展，再核对端点归属，最后解析密钥；不绕过 owner 配置的 relay／key 覆盖。密钥不交给 Swift，不写 GUI 偏好、参数或日志。
2. 发现 OMP 18.12.5 原生 usage collector 没有一致纳入仅在 `models.yml` 定义的 key，且其存储凭据候选可能与模型配置优先级不同。SDK 路径沿用完整原生 cascade 解决此缺口。无匹配 SDK 时，使用 OMP 公开 `--extension` 加载随应用附带的只读 usage provider；该回退只支持原生 collector 实际提供的凭据，不能承诺 config-only key。
3. 固定官方地址，不跟随跳转；超时 10 秒、响应最多 64 KiB、严格 UTF-8，失败或未知响应不显示，不将响应正文作为错误日志。自定义中转不触发官方查询，避免把其凭据发送给另一端点。
4. 只接受官方明确返回的 CNY／USD、有效十进制字符串和无冲突币种行。保留精度、零值和真实负余额，不转 Double、不相加／换汇。内部可保留官方赠金／充值字段，最终精简 UI 只显示可用总余额。
5. 余额与套餐共用来源时间、十分钟新鲜度、profile／可执行文件／环境／目录变化保护和内存缓存。仅可见服务商设置读取，成功缓存 60 秒、失败重试节流 10 秒，离开最后一个视图取消；本地显示时钟只隐藏过期项，没有后台联网轮询。不发起模型请求、不安装全局扩展、不修改 OMP 配置／凭据。

## OMP 内置覆盖

本机安装源码登记了 **22 个 provider ID**，包括 Ollama 的别名，不能解读为 22 家独立公司或真实账号全部通过。完整 ID、源文件和 SHA-256 保存在[核对数据](../evaluations/2026-10-26-provider-usage/native-coverage.json)，registry SHA-256：`4378c3101a0cb136870e49938d546ad7df69c75caad994c1510b979f3a317a9e`。[上游公开 registry](https://github.com/can1357/oh-my-pi/blob/main/packages/ai/src/usage/registry.ts)仅作入口参考，以上述固定安装证据为本次结论。

| 内置 ID | 可返回的关键数值及边界 |
| --- | --- |
| `openai-codex` | 多窗口／模型 tier、用量比例、重置与原生 saved reset；不是普通 OpenAI API 钱包。 |
| `anthropic` | 5 小时／7 天和模型窗口、额外 USD 用量及 saved reset；不能据此猜测统一零售套餐。 |
| `github-copilot`、`cursor` | Copilot 月度 premium requests／AI credits；Cursor 的月度／API／auto／按量 USD 桶。 |
| `google-gemini-cli`、`google-antigravity` | 原生模型配额桶、剩余额度与重置；与 Google Cloud 统一账单不同。 |
| `kimi-code`、`minimax-code`、`muse-code` | 各自编程套餐的原生窗口／余量；Kimi Code 不等于 Moonshot API 余额。 |
| `zai`、`commandcode`、`opencode-go` | Z.ai 的 tokens／requests／credits、Command Code 额度／credits、OpenCode Go 百分比窗口。 |
| `alibaba-token-plan`、`factory-droid`、`cline-pass` | 各自计划窗口；Factory 也可带额外 USD 余额。 |
| `ollama`、`ollama-cloud`、`synthetic`、`umans`、`xai-oauth`、`devin`、`charm-hyper` | 各自原生额度、消费／余额或窗口；Charm 为 credits，`xai-oauth` 是 Grok 账号路径，不等于 xAI API Management。 |

每个 adapter 的 `supports`、认证类型、端点及服务端响应决定该账号是否有报告。GUI 仅显示真实返回且当前有效的已知数值；未支持、未认证、失败或缓存过期都不是零余额。本轮未消费 saved reset，也没有仅为刷新而发送模型请求。

## OMP 尚无对应内置来源、官方已有公开接口的候选

除 DeepSeek 外，下表只完成接口／认证／单位核对，未实现额外读取。普通推理 key、管理 key、OIDC、订阅 OAuth 的权限不能相互假定。

| 服务商与官方来源 | 已确认接口／口径 | 依赖与建议方案 |
| --- | --- | --- |
| [DeepSeek](https://api-docs.deepseek.com/zh-cn/api/get-user-balance/) | `GET /user/balance`；CNY／USD 的可用、赠金、充值十进制字段。 | 本轮已接入，只显示可用总额。 |
| [Moonshot / Kimi API](https://platform.kimi.ai/docs/api/balance) | `GET https://api.moonshot.ai/v1/users/me/balance`；国际文档为 USD，含 available／voucher／cash，cash 可负。 | 可复用推理 Bearer key；与 `kimi-code` 区分。国内／国际凭据和端点应独立核对后映射，不猜测币种。 |
| [SiliconFlow CN](https://github.com/siliconflow/siliconcloud/blob/main/openapi.yaml)／[用户信息文档](https://siliconflow.readme.io/reference/user-info) | `GET https://api.siliconflow.cn/v1/user/info`；balance／chargeBalance／totalBalance 字符串。 | 先限定已核实的 CN 官方区域；国际区域 API／币种需要独立验证，不能复制地址就假定兼容。 |
| [OpenRouter 当前 key](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-key)／[账户 credits](https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits) | `GET /api/v1/key` 的 `limit_remaining` 是 key 预算；`GET /api/v1/credits` 的 total_credits／total_usage 是账户 credits。 | key 预算适合先做。账户 credits 文档要求 management key；不能默认使用普通推理／OAuth key，也不能把 key 预算称为账户余额。 |
| [Novita](https://docs.novita.ai/api-reference/basic-get-user-balance) | `GET https://api.novita.ai/openapi/v1/billing/balance/detail`；availableBalance／cashBalance／creditLimit 等字符串。 | 普通 API key；单位是 **1/10000 USD**，后续须精确十进制缩放，不能直接当美元显示。 |
| [Vercel AI Gateway](https://ai-sdk.dev/providers/ai-sdk-providers/ai-gateway#credit-usage) | 公共 `gateway.getCredits()` 返回团队 balance／total_used。 | 支持 Gateway API key 或 OIDC；可用于推理的 Vercel personal/app access token 不自动支持这些管理 helper。沿用公共 API 接入，不猜旧 HTTP 地址。 |
| [NanoGPT 余额](https://docs.nano-gpt.com/api-reference/endpoint/check-balance)／[订阅用量](https://docs.nano-gpt.com/api-reference/endpoint/subscription-usage) | `POST /api/check-balance` 返回独立 usd_balance／nano_balance；`GET /api/subscription/v1/usage` 返回订阅 tokens／images、比例和毫秒重置时间。 | 推理 key 可读取普通订阅用量；management usage-only token 是另一路径。保留不同币种，不推测汇率，比例可以超额。 |
| [xAI Management billing](https://docs.x.ai/developers/rest-api-reference/management/billing)／[认证指南](https://docs.x.ai/developers/management-api-guide) | `GET /v1/billing/teams/{team_id}/prepaid/balance`，`management-api.x.ai`，金额为 USD cents。 | 需要独立 management key 与 team ID；和内置 `xai-oauth` 无可假定共享关系。新增管理凭据应先明确原生配置归属和最小权限。 |
| [Groq rate-limit headers](https://console.groq.com/docs/rate-limits#rate-limit-headers) | 响应头的 remaining-requests 是 RPD，remaining-tokens 是 TPM，带各自 reset。 | 是实际响应的速率额度观察，不是钱包或独立余额 GET。可后续观察 OMP 已有响应；不能为读额度额外发模型请求。 |

优先级属于本轮设计判断：后续可先评估 Moonshot、Novita、Vercel 和 NanoGPT 的现有 key／公共 helper；SiliconFlow 先完成区域核对；OpenRouter 先 key 预算，账户 credits 与 xAI 管理余额待原生管理凭据边界明确后再接。Groq 应作为响应观测功能单独设计。

本次没有核实到接口的其他服务商保持“未知”，不据此断言其官方没有任何查询 API。Cerebras 公开限流说明本身也不足以证明有独立钱包余额接口。

## 验证与剩余验收

首次实现阶段：

- 原生隔离 SDK 检查 9 项通过：`build.noindex/verification/runs/20261026T081348Z-b9cca843/report.json`。存储／环境／模型配置 key 优先级、命令引用和原生扩展端点覆盖使用假 fetch；没有读日常账号或发送远程请求。
- 图标检查 239 项通过：`build.noindex/verification/runs/20261026T082219Z-dc05cd4a/report.json`，包括 59 个图标的原生可见像素和透明画布。这些资源在后续设置／模型布局调整中未变化，复用通过证据。
- 初次 Swift 构建修复了可选 profile directory 未解包；原生 fixture 原先在同一进程写配置后未使 OMP `ModelsConfigFile` 单例缓存失效，与生产每次新进程读取不同，修正 fixture 后原断言通过。像素检查揭示 SVG `1em` 被 Xcode 编为 1×1，规范化根尺寸后全部图标通过；仍有通用 CoreSVG 非阻塞诊断，没有放宽可见性断言。

最终设置迁移／紧凑布局调整：增量 `make build` 通过；余额 41、套餐／设置投影／弹出方向／模型读取隔离 45、设置导航 29 项通过，报告：`build.noindex/verification/runs/20261026T114027Z-1c9af71d/report.json`。静态文档检查（92 份 Markdown、899 条本地链接）、29 项 harness 与语法检查通过：`build.noindex/verification/runs/20261026T114235Z-6bb92fd3/report.json`。

离屏结果核对又发现 `containerRelativeFrame` 在独立 hosting 容器中可能按外层窗口而非右侧视口定宽，导致模型行撑宽并裁切左列／末尾标记。改为用实际右侧视口宽度约束内容，并增加原生滚动容器边界及文档宽度检查。按 [SwiftUI 的定义](https://developer.apple.com/documentation/swiftui/view/popover(ispresented:attachmentanchor:arrowedge:content:))，`arrowEdge` 使用 attachment anchor 的边，方向映射也据此核对。最终增量构建、41 项余额和 49 项用量／布局检查通过：`build.noindex/verification/runs/20261026T114943Z-218a639a/report.json`。主分支的独立听写变更只做集成构建，复用未变化的原生凭据／图标／设置导航通过证据；文档后续仅补充证据文字，未改变已核对的本地链接集合。测试宿主与应用主 bundle 不同，离屏模型截图不作为品牌标记真实窗口合成验收，品牌资源按应用 bundle 单独核验。

未启动／重启 GUI，未打包、安装、推送或发布，未修改日常 OMP profile。真实 DeepSeek／其他服务商接口、系统窗口中的颜色条合成、屏幕边缘／新会话居中及停靠位置切换、中英文键盘／VoiceOver 和多窗口仍待 owner 授权后的现场验收。构建、离屏窗口和确定性替身不代替真实账号及可见系统合成验收。
