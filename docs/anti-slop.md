# 简洁回复指导

OMP GUI 的 **Settings › General › Conversation › Concise AI replies** 默认开启。它提供一段内置指导，要求先给结果、保留必要细节、减少套话和重复读取、只写有用注释，并遵循项目组件及验证要求。用户请求和项目规则始终优先。

## 当前 OMP 路径

[AntiSlopPolicy](../OMPGUI/Core/Models/AntiSlopPolicy.swift)保存开启/关闭两种文本；关闭文本要求忽略之前的应用指导，不改写原有聊天。源码中的 `[Tivano anti-slop guidance]`是保留的指导标记，不代表另一个运行时或数据来源。

[OMPSystemPrompt](../OMPGUI/Services/Providers/OMPSystemPrompt.swift)通过原生扩展的 `before_agent_start`把指导追加到现有 system blocks，保留 OMP 自己的 `APPEND_SYSTEM.md`发现、项目优先级、工具和上下文。不使用会覆盖原生发现的 `--append-system-prompt`。

[ThreadRuntime](../OMPGUI/App/Runtime/ThreadRuntime.swift)把开关纳入 session signature，下次发送时使用对应配置；正在进行的消息不会被重新写入。文本要求委派任务也遵守，但实际 worker prompt 与执行仍由 OMP 决定，GUI 不为每个 head 再建发送器。

## 来源及边界

这是继承自 Tivano 的简短改编文本，不安装或运行上游 wizard、外部脚本、审计器。它不承诺固定 token 节省比例或强制控制模型输出。

灵感来源：[miqdadbadjuber/anti-slop](https://github.com/miqdadbadjuber/anti-slop/tree/743735248fbaefd76bb56619615687dfa8b3bc1e)，固定 revision `743735248fbaefd76bb56619615687dfa8b3bc1e`，MIT，Copyright 2026 Miqdad Badjuber。完整声明继续保留于[第三方声明](../THIRD_PARTY_NOTICES.md)。

历史提示文件及原生请求准备检查见[早期接入记录](archive/omp-integration-research-2026-10-12.md)。当前原生接入和配置范围见[OMP integration](OMP_INTEGRATION.md)。
