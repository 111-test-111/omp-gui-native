# 模型选择器紧凑布局与 DeepSeek 余额核对（2026-10-26）

基于 `4c68b7f3d`，按 owner 要求缩小左列图标、移除图标下名称、减小右侧字号并柔化两层面板切换。Dev `0.1.295` / build `296`。本轮另回答 DeepSeek 余额查询能力，不启用新的真实账号请求。

## 界面改动

- 服务商列由 88 pt 收窄为 52 pt；图标从 24 pt 改为 20 pt，点击区为 40 pt。服务商名与 Hydra「组合」不再作为列内文字显示，保留悬停说明、辅助功能名称及选中语义。
- 右侧服务商标题与模型名均改用共享 `.ui(.body)` 常规字体，标准字号为 13 pt，继续跟随界面字号偏好。模型 selector、Fast 标记及已知用量语义保留。
- 两层内容各保持 330／620 pt 排版宽度，外层在约 0.28 秒内过渡尺寸，伴随短距离横移和淡入淡出。思考层记录其自然高度，模型层保持 500 pt；过渡范围裁切，减少动态效果或性能模式时直接切换。没有为动画提前挂载第二层或增加额度读取。

## DeepSeek 余额结论

本机 OMP **18.12.5** 的 `DEFAULT_USAGE_PROVIDERS` 无 `deepseek`；同日只读核对的[上游登记表](https://github.com/can1357/oh-my-pi/blob/main/packages/ai/src/usage/registry.ts)也未登记 DeepSeek。支持 DeepSeek 聊天模型不等于实现其余额查询，当前 GUI 因此隐藏该服务商的未知额度。

DeepSeek 的[官方余额接口](https://api-docs.deepseek.com/zh-cn/api/get-user-balance/)为 `GET /user/balance`，使用 API Key，提供 CNY／USD 总可用余额、未过期赠金和充值余额。它是货币余额，不能把它推为套餐百分比或累计 token 消耗。

**可行接入方向**：随 GUI 分发只读 OMP provider 扩展，使用公开 `registerProvider("deepseek", { usage })`，由 OMP 向 `fetchUsage` 传递已解析的凭据、原生 fetch 和取消信号，再通过 `omp usage --json -e <extension>` 返回结果。该公开入口与 CLI 加载行为已从安装源码核对；GUI 无需建立 DeepSeek 认证存储。实施时仍需对官方直连／自定义端点和凭据来源作约束，并将响应币种明确投影到 GUI；当前 OMP `UsageUnit` 没有 CNY，不能把人民币冒充 USD 或 credits。保留十进制金额、缺失隐藏及失败／过期边界，且不覆盖模型定义或原生账号选择。

这次没有编写或安装余额扩展，也没有读取或使用真实 DeepSeek 密钥。真实端点与账号接受情况尚未验证。

## 验证

- `make build` 通过。
- 选择现有 `make verify TIER=functional AREAS="provider-usage"`，30 项通过，含 620 × 500 pt 浅深色离屏布局；报告：`build.noindex/verification/runs/20261026T072706Z-8c68d4d6/report.json`。
- 当前交互与 UI 指南同步后，`make verify TIER=static AREAS="documentation"` 通过；报告：`build.noindex/verification/runs/20261026T072822Z-db2db7c2/report.json`。

没有新加实现镜像测试、启动 GUI 或扩大原生兼容／性能范围。布局边界断言通过，但本次离屏 PNG 存在控件／表面缺绘；对照改动前 `20261026T070624Z-ff47ed25` 产物也有相同现象，因此不把这些捕获当作最终视觉证据，也不为此重复运行通过的功能检查。应用 bundle 图标、真实弹窗尺寸插值、切换动画的观感和 VoiceOver 仍需可见窗口验收。
