# 模型勾选、品牌图标与原生登录别名

日期：2026-10-26。基线 `d7a8affd8`；目标版本 Dev **0.1.300 / build 301**。按 owner 提供的真实窗口截图修订展示。后续澄清为“大写首字母，和专属 logo 差不多大”，未采用放大字母的设计。

## 实现

- 当前模型只保留勾号和辅助功能选择状态，移除持久底色及边框，选中行悬停也不重加填充。其他模型行的短时悬停反馈及左列服务商选择状态保留。
- ChatGPT Codex 原先使用 Lobe Icons 的实心终端结形款；截图与该 SVG 一致，没有取得品牌识别度足够的效果。现在 `openai-codex` 和 `openai-codex-device` 共用既有 OpenAI 结形图标。原 Codex SVG、路径与校验和保持不变，作为 retained 资产保留。
- 59 份固定版 SVG 保留，当前 58 份活跃品牌映射覆盖 73 个 provider/login ID；[清单](../../design/icons/provider-logos.json)明确区分 retained 与活跃别名。未映射服务商使用显示名的大写首字母，字号与标记框同为 20 pt（密钥编辑器 18 pt），保留 Unicode 首字。无有效首字时用 `?`，不按名称片段猜品牌。
- 原生策略读取只增加 `credentialProviderID` 元数据，由公开认证 policy 的 `storeAs` 或自身 ID 得到；不访问凭据内容。配置页按这个明确的共享来源合并行，优先保留 canonical browser action，只有 alias 时仍使用其真实原生 action ID。模型、usage 和账户报告不改身份、不删除。
- 缺少公开策略证据的身份继续独立；同名来源不合并，多个原生账户用量仍保留各自报告。All providers 中未登录的浏览器／设备码入口仍是原生登录方法，未删除支持。

## 两条 Codex 项的原因

本次核对本机 OMP **18.12.5** 的公开安装源码，未读取日常 token 或修改账号：

1. `@oh-my-pi/pi-catalog/src/compat/rules/auth/openai-codex.kdl` 定义普通 OAuth-code 登录。
2. `.../openai-codex-device.kdl` 定义设备码 custom hook，并明确 `store-as "openai-codex"`。
3. `pi-coding-agent/src/modes/rpc/rpc-mode.ts` 的 `get_login_providers` 按 `keys.source(provider.storeCredentialsAs ?? provider.id)` 判定每个登录方法是否 authenticated。因此同一来源存在凭据时，两条登录方法都显示已登录。

原 GUI 把登录方法直接投影成两家已配置服务商，才出现截图中的重复行。这两行不证明有两份不同的订阅或凭据；实际账号数量由 OMP 原生存储管理。本轮只修正展示，未删除、迁移、重新登录或退出任何账号。

## 验证边界

一次增量 `make build` 通过，选定检查全部通过后停止：

| 范围 | 结果与报告 |
| --- | --- |
| `provider-logos provider-usage config` 及去重依赖 | 图标 242、余额 41、用量／模型及别名投影 53、认证策略 27、配置 128 项；`build.noindex/verification/runs/20261026T121227Z-85efe344/report.json` |
| `native:model-configuration` | 117 项；`build.noindex/verification/runs/20261026T121227Z-5d9242ab/report.json` |
| `static:documentation` | 93 份 Markdown、901 条本地链接；`build.noindex/verification/runs/20261026T121351Z-352b3220/report.json` |

别名策略检查覆盖共享来源、同名独立来源、alias-only action、profile 身份及 OMP 实际公开 policy；原生检查使用隔离 profile，认证发现禁止联网。图标检查验证全部保留资产的可见像素、模板／透明度、映射及首字母回退。沿用的通用 CoreSVG 诊断和 Swift 替身 `hold` 捕获警告不阻断检查，未放宽任何断言。后续文档仅补充上述结果，链接集合不变。

没有启动／重启／安装 GUI，未影响当前从主 checkout 构建运行的实例，也未改日常 OMP profile。未显示的窗口及资源像素核对不代替可见系统合成、键盘或 VoiceOver 验收；原生完整凭据查询和删除不在本轮范围。
