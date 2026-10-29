# N0 增量事件传输交付（2026-10-17）

基线：本地 `main 5385b02`；任务树 `codex/omp-delta-transport`。对应[下一阶段计划](next-functional-plan-2026-10-17.md)的 N0。

## 实现

生产 `OMPSession.start` 在协议协商后请求一次 `set_event_filter(events: null, messageUpdates: "delta")`，只根据当前请求的有效回显记录 delta。旧版不回显、未知字段、拒绝或超时保留兼容路径；失败不覆盖上次已确认的投影。所有事件仍开放，不增加读取轮询，不调整重组/backlog 预算。

`OMPEventDecoder` 沿用原有增量处理，完整 `message_end`、工具参数/结果、用量及协议 v2 分块继续工作。无新增 UI 字符串。Dev 前进到 0.1.56 / build 57。

## 已完成的检查

- 一次 `make build` 通过，没有启动应用。
- `make verify AREAS="rpc"` 通过 95 项；新增覆盖 full/delta 一致、完整终态、Unicode/工具参数/用量、混合格式、分块、旧版回显、拒绝/迟到和生产启动请求。
- `make verify TIER=static AREAS="documentation harness syntax"` 通过；新增交付记录及验证说明后只复核受影响的文档检查。
- 一次独立 `make verify TIER=benchmark AREAS="event-projection"` 通过。它不作为功能模块的自动依赖。

构建和功能/测量报告分别保留在任务树 `build.noindex/development`、`build.noindex/verification/runs/20261016T163014Z-904c90e1` 和 `20261016T163114Z-32455e90`。完整环境记录随报告保存，生成目录按 owner 清理决定保留。

## 测量边界与结果

[单次合成对照数据](../evaluations/2026-10-17-event-projection/comparison.json)使用相同生产 JSON parser/decoder、133 帧、正文与工具参数各 106,496 UTF-8 字节；full 与 delta 输出的 71 条归一化事件一致。

| 指标 | Full | Delta |
| --- | --- | --- |
| 合成 NDJSON 字节 | 34,545,220 | 672,142 |
| JSON 解析总耗时 | 72.153 ms | 2.189 ms |
| decoder 与相同事件收集 | 0.840 ms | 0.654 ms |

这只说明累计快照对该固定语料产生了大量重复数据；耗时是 full 后 delta 的一次有序观察，不是统计 p95、父提交对照或机器无关阈值。未运行真实 OMP、GUI、stdio 或分配测量，也未认证实际窗口性能。N2/N3 的支持版本原生验证与 Q 的现场验收仍按计划分别进行。
