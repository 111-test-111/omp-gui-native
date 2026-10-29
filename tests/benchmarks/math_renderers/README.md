# SwiftMath 与 Temml 实测脚本

只在明确需要渲染器对比时，在任务 worktree 中执行。使用 74 个合成样例、从 fd7776e 冻结的 `SwiftMathBaseline.swift` 与当前 `MarkdownMath.swift`，以及独立 Release CLI；不需要额外构建应用。WebKit 使用隐藏窗口和非持久化数据存储。数学字号为 15 pt；快照固定为每点 2 像素。执行与停止规则见[测试规范](../../../docs/verification.md)。

依赖为 macOS 26 或更新版本、Xcode/Swift、Python 3.9 或更新版本。测试本身只需要 Python 标准库；汇总图需要 Pillow 和 matplotlib，PDF 检查需要 pypdf 和 Poppler。初次准备需要访问 SwiftMath Git 仓库和 npm registry。

```sh
make verify-plan TIER=benchmark AREAS="math-renderers"
make verify TIER=benchmark AREAS="math-renderers"
```

统一入口调用 `setup.sh` 准备固定的 SwiftMath 1.7.3、Temml 0.14.0，并验证 npm 发布包 SHA-512。字体保留原始许可；浏览器脚本与样式均从本地加载。下载、编译、日志、快照和 PDF 位于本次 `build.noindex/verification/runs/<run>/benchmark/math-renderers/`。

性能测量先做兼容性检查，只使用双方通过的 28 个核心样例，加上不同数值产生新缓存键。阶段按顺序运行，采集时避免同时构建或运行其他浏览器测试。先分析失败原因；确需复跑失败阶段时，把 `OMP_GUI_VERIFICATION_OUTPUT` 指向该次目录，再调用 `run.py --phase compat|perf|memory|visual`，不重复已通过且输入未变的组。

PDF 子集字体检查和图片预览可使用下列脚本，再运行汇总程序。检查 PDF 的字体与图像资源，也应查看 Poppler 输出的三个预览，确认根号、分数线和基线未被裁切。

```sh
# 指向需要分析的那一次结果；以下两条读取已生成数据，不重复测量。
export OMP_GUI_VERIFICATION_OUTPUT=/absolute/path/to/run/benchmark/math-renderers
python3 tests/benchmarks/math_renderers/validate_pdf.py
python3 tests/benchmarks/math_renderers/summarize.py
```

汇总默认生成该次目录的 `published/`，包含 CSV、完整样本 gzip JSON、概要、图表和排版样图；`--output <目录>` 可指定其他保存位置。未指定环境目录的底层研究工具仍兼容旧的 `build.noindex/math-renderer-evaluation/`。历史仓库快照位于 `docs/evaluations/2026-10-13-swiftmath-temml`。

冷启动为九次新进程，系统文件缓存已经预热；暖批次各 21 次，缓存/重排各 41 次，原生附件缓存命中另测 101 次，共享图像/PDF/批量 PDF 桥接各 11 次。WebKit `performance.now()` 约有 1 ms 量化，小公式显示 0 表示低于计时分辨率；对外结论优先使用 Swift 的单调时钟计时。

内存每组启动三个新进程，每次就绪后取七个样本。用 `proc_pid_rusage(RUSAGE_INFO_V2)` 获取 physical footprint 与累计 CPU 时间；Mach tick 按 `mach_timebase_info` 转换为秒。同时保留 `ps` RSS 和进程身份。WebKit XPC 的父 PID 通常是 1，所以按测试前后新增的 WebContent、GPU、Networking PID 计入，排除既有服务。发生其他程序同时创建 WebKit 服务时应重测该组。

缓存比较衡量为已知内容重新建立显示内容：原生复用矢量几何，Temml 复用 MathML 字符串后重建 DOM。保留现有视图且内容未变时，双方都可以跳过更新。截图测量包含离屏绘制/跨进程回传；它不等同于整应用滚动帧率。共享 PNG/PDF 桥接包含逐公式转换、布局、导出，PDF 另含 `NSImage` 解码，均不包含产品中的异步附件装配。批量 PDF 测试导出一页并让每个可见附件按区域裁切绘制同一页，包含重复解释 PDF 内容流的成本；同时保存屏幕与 PDF 裁切预览。

`make clean` 可清除这组生成文件和构建缓存；已保存的报告快照不在生成目录中。
