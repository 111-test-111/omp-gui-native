# 服务商名称、地区密钥入口与首字母标记

日期：2026-10-26。基线 `e523a9d2f`，交付 Dev **0.1.304 / build 305**。按 owner 截图修复 `minimax-cn` 原始名称和密钥表单缺项，检查同类名称回退；OpenRouter 改为大写 O，首字母适当放大。

## 原因与修正

OMP 18.12.5 的公开 `@oh-my-pi/pi-catalog` 模型目录有 `minimax-cn`，其 Anthropic endpoint 为中国站 `api.minimaxi.com`；认证策略和环境变量清单却没有此 ID。原密钥表单只结合环境变量／API Key 登录策略／已存在的 `models.yml`，因此没有预先配置过该 ID 时不能在表单中找到它。配置页没有对应登录名，显示又回退为裸 ID。不能仅凭品牌相同把它重定向到 `minimax` 或 Token Plan。

- 密钥发现补充公共 `getBundledProviders()` 中没有认证策略的模型提供商。已知 OAuth、结构化凭据和原生登录 alias 的限制保持不变；自定义已有项保留。
- `minimax-cn` 显示“MiniMax（中国）”，模型、配置行、密钥表单及图片后端使用同一名称解析。有效实时原生名称优先，缺项采用清单中已核对名称；未知来源不按片段改名。
- 同时补齐 `azure-openai-responses`、Brave、Firecrawl、Jina、TinyFish 等只有原始 ID 的名称。新增 app 文案有 zh-Hans；来自原生策略的品牌名称保留其数据属性。
- 搜索同时查原生 ID、显示名称／本地化名称、原始核对名和原生环境变量名，支持多个词。行内编辑仍按 ID 定位，不通过人类名称推断写入对象。
- 中国站 key 保存为 `providers.minimax-cn.apiKey`，国际站仍为 `providers.minimax.apiKey`，不复制或迁移已有凭据。原生 ModelRegistry 和 key cascade 已按隔离 fixture 验证各自选择。
- OpenRouter 在 `initialOnlyProviders` 明确强制首字母 O，其 SVG 保持原样作为 retained 资源。首字母字号从 20／18 pt 提至 25／22.5 pt，框和点击区域不变。当前为 74 份保留 SVG、72 份活跃标记、96 个图标别名；99 个公开身份中 76 个使用专属标记、OpenRouter 按 owner 选择使用字母、22 个仍为已说明的回退。

## 验证

增量 `make build` 通过。功能区域 `provider-logos provider-usage config models` 及去重依赖全部通过：标记／名称／搜索 411、余额 41、用量／配置投影 55、认证策略 28、配置 128、模型 64 项，报告 `build.noindex/verification/runs/20261026T130644Z-763476e6/report.json`。未放宽既有断言；CoreSVG 通用诊断及 Swift 替身捕获警告保持原验收边界。

隔离原生 **122 项**通过：`build.noindex/verification/runs/20261026T130500Z-cc1dc2a4/report.json`。其中验证表单包含两个独立 MiniMax 地区 ID、保存目标不互换、真实 ModelRegistry 使配置后的中国站可用、`AuthStorage.keys.get` 分别取得各自替身 key、原有 OAuth 不变。无真实服务请求或日常 profile 写入。

静态文档 95 份 Markdown、911 条本地链接通过：`build.noindex/verification/runs/20261026T130848Z-08338f3f/report.json`。此后只补充通过证据文字，没有改变本地链接集合，选定检查通过后停止。

没有启动／重启或安装 GUI，当前运行实例保留；未复制或读取日常密钥。真实窗口字体／首字母合成、键盘／VoiceOver 与实际服务商凭据有效性仍属于现场验收范围。
