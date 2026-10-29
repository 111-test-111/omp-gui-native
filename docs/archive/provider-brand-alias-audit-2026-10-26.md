# 服务商品牌与全量原生身份核对

日期：2026-10-26。初始基线 `62ddbdce5`，集成前合入本地 `main` 的 `d73146896`，保留独立的模型面板尺寸／间距修订。交付 Dev **0.1.302 / build 303**。按 owner 截图检查 Z.ai 在 API Key、套餐和登录行的标记不一致，并核对其他服务商。

## 原因与范围

此前按精确 ID 查找，但人工表只覆盖部分模型提供商，遗漏认证别名和地区／套餐身份；同时 Swift 字典与设计清单重复保存名单。`zai` 被识别，`zai-coding-plan` 和 `zhipu-coding-plan` 则回退为首字母。没有增加模糊匹配规则，而是将所有界面收敛到[一份随应用打包的清单](../../OMPGUI/Resources/ProviderLogos.json)，逐项明确原生 ID。原[设计路径](../../design/icons/provider-logos.json)为相对符号链接，保持历史入链且不复制数据。

公开源码核对对象为本机安装的 OMP **18.12.5**：模型目录 79 个 provider，加上 provider entries 与认证 policies 的身份共 99 个。没有读取账号／凭据或发起提供商请求。[核对数据](../evaluations/2026-10-26-provider-brand-audit/native-identities.json)保留公开名称、原生来源类型、环境变量名、声明 URL、预期品牌或首字母回退理由，以及原始公开目录的 SHA-256。

## 已核对的修订

| 身份／家族 | 显示品牌 |
| --- | --- |
| `zai`、`zai-coding-plan`、`zhipu-coding-plan` | 同一 Z.ai 标记 |
| `xiaomi`、欧洲／中国／新加坡 Token Plan | MiMo |
| `azure` 及既有 Azure OpenAI 变体 | Azure |
| `opencode-go`、`opencode-zen` 及已有 `opencode` | OpenCode |
| `fireworks`、`firepass` | Fireworks |
| Alibaba Coding Plan／Token Plan | Alibaba Cloud；不根据模型名称误选 Qwen |
| `qwen-portal` | Qwen |
| `qianfan` | Baidu Cloud |
| `kilo`、`cline-pass`、`lm-studio` | Kilo Code、Cline、LM Studio 各自专属标记 |

另补齐 AIML API、Apple、Exa、Kagi、Meta、Sakana、StepFun、Tavily、vLLM、Wafer、ZenMux 等已核实的专属标记。共新增 15 个 SVG，仍来自固定 `@lobehub/icons-static-svg` **1.101.0**；公开 tarball SHA-1 再次核对为 `58ee9c600e3ca19c82da8364d07e0b9145dfb953`。沿用既有规范化、MIT 与商标声明，原路径不变，没有新包或运行时依赖。批准的原始图标不修改。

现在保留 74 份 SVG、73 份活跃标记、97 个显式品牌／登录别名。99 个本机原生身份中 77 个有已确认标记；其余 22 个保留首字母，其中 `local`／`web` 是类别，其他为固定版中尚无已确认对应标记的来源。相似名称或相同下游模型／协议不证明同品牌，例如不把未核实的 Muse Code 套到库里同名 Muse 图案。

## 运行边界与验证

清单在首次使用时只读并缓存，大小上限 128 KiB；无效或冲突清单安全回退为首字母。只做大小写规范化后的完整 ID 查找，不以名称、模型、端点、前后缀或凭据命名空间推断品牌。图标映射不改变服务商 ID、认证、余额、native `storeAs` 分组或中转配置。

选择增量 `make build`、`functional:provider-logos` 和静态 `documentation harness syntax`，全部通过后停止。图标 **405 项**通过：`build.noindex/verification/runs/20261026T123534Z-5b905859/report.json`；覆盖新增资源的原生打包／可见像素与透明度、唯一清单确实随包且与源码相同、全部 99 个身份的核对结果、Z.ai 三入口一致性和私有 relay 不误配。CoreSVG 的既有通用诊断不阻断检查，所有像素断言保持有效。

静态文档（94 份 Markdown、910 条本地链接）、29 项 harness 和语法检查通过：`build.noindex/verification/runs/20261026T123534Z-bcdbb63c/report.json`。后续只补充证据文字及独立尺寸修订的现有说明，没有改变链接集合或测试工具。合入主分支的独立布局源代码后补做一次集成构建；图标来源、别名清单和解析未变化，复用上述通过证据。

未启动／重启 GUI，未改运行中的主 checkout 构建或日常 OMP profile，保留真实窗口合成及辅助功能的现场验收边界。
