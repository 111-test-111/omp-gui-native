# 模型详情接入与验收记录 — 2026-10-18

## 实现范围

- 模型名称区域旁打开只读详情，复用已加载的 OMP 目录；声明的输入类型、上下文窗口、最大输出和输入／输出／缓存读写基础价格均保留独立字段。
- 免费、套餐内含、价格浮动及价格未知按原生状态区分；不从全零价格推断免费。缺失或非法字段保持未知，小额缓存费率保留有效数字。
- 会话 RPC 更新保留 CLI 已解析的基础价格；长上下文／分时价格只作来源限定，不复制 OMP 计费引擎。
- 可见模型显示睁眼，隐藏后显示闭眼，移除可见的「已隐藏」文字；隐藏和参数按钮独立于详情入口。

## 自动化证据

工作树：`/Users/developer/.codex/worktrees/model-picker-visibility/omp-gui-native`，分支 `codex/model-details`。以下路径相对于该工作树，均不属于发布产物。

| 范围 | 结果与证据 |
| --- | --- |
| Dev 编译 | `make build` 通过；`build.noindex/development/build.log` 和 `verification-inputs.json` |
| 元数据、价格及可见性 | `make verify AREAS="models"` 通过，共 52 项断言；`build.noindex/verification/runs/20261018T105123Z-e42e1bce/report.json` |
| 文档、登记表／执行器和语法 | 三项静态模块通过；`build.noindex/verification/runs/20261018T104521Z-34f2e4e5/report.json` |
| 测试预览背景调整后的语法 | `static:syntax` 通过；`build.noindex/verification/runs/20261018T105123Z-a74f9c83/report.json` |
| 本地化 | 20 个详情字符串的 zh-Hans、占位符及全目录重复键检查通过 |

详情检查覆盖付费、免费、套餐内含及未知状态的 400 × 420 离屏尺寸。原位图使用透明背景，随后只给测试宿主补充白色背景，保留应用源码及构建证据，仅复跑受影响的 `models` 和 `syntax`。位图文件已生成，但当前查看结果未得到可读的外观预览；这些 PNG 不作为文字清晰度、内容完整性或 Liquid Glass 外观证据，不能把尺寸检查表述为完整视觉验收。

## 剩余验收

本轮未启动 GUI 主程序、运行已安装 OMP、请求外部模型或改动原生配置。真实窗口中英文、行锚定、隐藏／参数按钮与详情的点击隔离、眼睛状态、窄布局、滚动、Escape／焦点返回及 VoiceOver 仍待现场验收。当前行为说明见[聊天工作流](../chat-workflows.md)，边界见[当前状态](../status.md)。
