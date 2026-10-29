# OMP GUI tests

从任务 worktree 根目录使用 `make verify` 列出模块，使用 `make verify-plan AREAS="..."` 查看计划，再运行所选范围。没有默认全量测试，也不自动构建应用。

目录、功能归属、原生/性能选择、失败处理和新增测试要求见[测试与验证规范](../docs/verification.md)。`catalog.py` 是唯一自动检查登记表，`support/` 共用编译和隔离；`scripts/` 不再存放测试入口。

修改测试工具时运行 `make verify TIER=static AREAS="harness syntax"`。GUI/现场验收见 [acceptance/README.md](acceptance/README.md)，不能附加到普通功能检查。

旁问分别选择 `make verify AREAS="side-question"` 和 `make verify TIER=native AREAS="side-question" OMP=/absolute/path/to/omp`。前者使用确定性协议 fixture 覆盖先到记录、未知送达、取消、累计字节预算及 EOF 保存错误；后者复用本地 loopback provider 核对指定 OMP 的公开接口、主回复并发、原生主题/取消和真实 sidecar 排空。两层不互相替代，也不启动 GUI 或调用外部账号。

`rpc` 包含 full/delta 投影的同输出、完整末消息、分块、混合形状，以及当前进程有效回显/旧版回退/迟到回复检查。独立选择 `make verify TIER=benchmark AREAS="event-projection"`，对同一份长正文与工具参数语料仅做一次 full/delta 对照，输出 `comparison.json`。它记录合成 NDJSON 字节、生产 JSON 解析与 decoder 耗时，不调用已安装 OMP、模型或 GUI，不测内存分配、实际传输或屏幕延迟；单次顺序测量不能认证性能 p95。编译所需的本 worktree Dev 构建证据由执行器统一核对。

共享投影语料保留真实 delta 的 `message: {role}`。最初语料完全省略这个字段，旧测量只描述当时的合成输入；修正后的新结果不得覆盖旧报告或被解读为新一轮产品性能改进。

`resource-options` 用确定性 fixture 验证 Slow 的原生支持/会话与全局范围保护、预热的明确模式回显、超时与迟到响应及有界最近事件。`native:resource-options` 只在隔离 profile 中验证选定运行时的公开命令、本地模型的原生 Slow 拒绝/关闭，以及预热策略回显；不发送模型请求，不验证真实账号的全局写入或付费预热生命周期。

文档链接与导航变更选择 `make verify TIER=static AREAS="documentation"`；修改该检查器时合并选择 `documentation harness syntax`，只执行一次。项目入口见[文档索引](../docs/README.md)。
