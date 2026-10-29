# 手动系统验收

[CefWebView + OMP CDP 最小原型](cef_browser/README.md)提供独立可见宿主，以及输入、截图、标签隔离、取消、关闭恢复和扩展 Browser 能力矩阵；只有 owner 明确授权时运行，不注册到自动检查入口。

这些驱动会启动本 worktree 的 Dev GUI，部分路径使用真实模型、系统权限或当前 OMP 认证。它们不属于 `make verify` 的任何层级，只有 owner 明确要求启动/退出对应实例后才能执行。一次聚焦所需路径，记录机器、runtime、负载、结果和未完成项。

`python3 tests/acceptance/chrome_profile/run.py` 准备独立探针和固定 CEF，不构建主应用、不启动浏览器；owner 明确要求迁移研究／测试后加 `--run`，使用安装的 Google Chrome、全新用户数据根和本机 HTTP fixture，比较目录单例锁、关闭后复制和公开接口的 Cookie／简单站点存储迁移。`--skip-build --case transfer` 只执行迁移及目标重启；`--skip-build --case database --inspect-run <本 worktree 已有运行目录>` 只核对保留的目标数据库，不启动浏览器。每个 CEF 探针最多 60 秒，控制器最多 240 秒并清理自己进程组。数据和日志只在 `build.noindex/chrome-profile/`；不接受个人 profile 路径、不读取 Keychain 密钥、不加入自动检查。结论及限制见 [Chrome 迁移评估](../../docs/archive/chrome-profile-migration-2026-10-27.md)。

`python3 tests/acceptance/workspace_browser.py` 只编译和准备链接本 worktree Dev 模块的隔离浏览器宿主；明确授权后加 `--run`，显示生产浏览器面板，检查首次 profile 创建、兄弟标签保留、跨窗口移动、关闭单页不关闭主窗口、创建期间关闭、CEF 退出及第二进程恢复。数据与报告在本 worktree 的 `build.noindex/browser-acceptance/`，不运行 OMP、不读写日常应用库、不退出已运行的 GUI。它不替代完整 OMP 自动化、签名分发或网页兼容性验收。

追加 `--presentation` 只检查新空白页的标题、加载状态和无重复导航，并保留一个中文面板供 CUA／人工查看标签与菜单。`presentation-ready` 表示可操作；完成后在该运行目录创建 `presentation-finish`，宿主随后检查有序退出并保存结果。可操作阶段最多 60 秒，不重复完整生命周期或第二进程恢复验收。

`python3 tests/acceptance/workspace_browser.py --run --profiles` 单独验证共享 profile。它启动本机 HTTP 登录站点和五次隔离生产面板进程，实际提交表单、接收 HttpOnly 持久／会话 Cookie，核对服务端认证、localStorage 和 IndexedDB 的跨会话共享、关闭全部标签后恢复、跨进程持久化、新配置空白隔离及切回后的账号保留。更改设置后的新会话仍须使用本次启动配置，重启才切换。它不接触真实账号，不认证外部网站 OAuth、签名 Keychain 或完整聊天应用现场重启；不与使用同一 capture 偏好 suite 的其他验收同时执行。

`--run --profile-settings` 单独显示中文生产浏览器设置供 CUA／人工操作，核对新增空白配置、原生选择器及重启提示。`settings-ready` 表示可操作，创建同目录 `settings-finish` 后退出并写入 `settings.json`，最多等待 75 秒。这三个可见界面 scope 与 `--profiles` 均互斥。

Chrome Cookie 导入已改为原生读取，原扩展／JSON 驱动已退休并从当前树移除，其[历史验收](../../docs/archive/chrome-cookie-import-2026-10-28.md)不代表新流程已完成现场验证。当前自动检查只使用合成 SQLite/WAL 和注入密钥，不申请系统权限。另行授权现场验收时，需覆盖已签名应用的文件访问／Keychain 允许、拒绝与取消，真实 Chrome schema／分区、生产设置中的来源选择，以及目标 CEF 完整属性和重启后的服务端登录；禁止用个人凭据做自动验证。capture 模式的默认 Chrome 根固定在自身输出目录，且禁止真实 Keychain 读取。

先在本 worktree `make build`，再按授权范围选择：

```sh
python3 tests/acceptance/runtime.py --p5-forward --language zh-Hans --omp /absolute/path/to/omp
python3 tests/acceptance/workflows.py --omp /absolute/path/to/omp --model provider/model
python3 tests/acceptance/capabilities.py --omp /absolute/path/to/omp --model provider/model
python3 tests/acceptance/native_controls.py --omp /absolute/path/to/omp --language zh-Hans --width 860
python3 tests/acceptance/native_controls.py --omp /absolute/path/to/omp --chat-math
```

`runtime.py` 验证隔离新会话、历史/预览负载和资源归属；`workflows.py` 验证队列、分支和上下文；`capabilities.py` 验证配置、扩展和 Hydra。历史阶段参数保留用于既有应用内部验收钩子，不作为新测试命名规则。驱动打印本次输出目录和继续/结束方式；只操作自己这次启动的实例，不停止或改写其他 worktree 的应用。

`native_controls.py` 是独立的 DEBUG 人工复核入口，不重复历史/预览资源负载，也不登记为自动检查。它只读复用 `tests/native/rpc_provider.Provider` 的本地确定性 HTTP 服务，清除继承的 `PI_`/`OMP_` 覆盖变量，并在 native wrapper 再次固定全新的 HOME/profile。使用明确的真实 OMP 路径；不读取外部账号，只有本地 provider 请求。GUI 库位于本次唯一 `build.noindex/native-controls-live/` 目录；capture defaults suite 每次重置，不能并发另一个 capture 实例。

窗口标题为 `OMP Native Controls Acceptance`。`--language en|zh-Hans` 通过启动参数选择语言，不在 UI 改全局语言；`--width` 不得小于生产最小内容宽度 860 pt。普通 lead 仅自动提交一条 `Q_BOOTSTRAP` 建立真实 `OMPSession`，收到本地回答后写 `phase=ready` 及 GUI/OMP PID。之后没有自动产品动作、原生状态轮询或资源负载；操作者复核普通状态隐藏 Goal、`/goal` 进入模式及正文提交、Goal/旁问按钮锚定弹出面板与 Usage。需要重复开关时记录实际 UI 操作次数。将截图、循环计数及结果写入该输出目录，不能把结束标记当作自动视觉断言。

在 `ready` 后 **600 秒内**创建该目录的 `finish` 文件完成；`abort` 或超时记为失败。驱动与 hook 只退出本次明确启动的实例。退出沿用生产显式停止语义，报告保留停止前的旁问持久化状态；进程退出不伪造原生 sidecar 保存 ACK。报告不认证屏幕 p95、整应用资源预算或任意外部模型行为。

只附加已有进程进行资源采样时，明确提供已验证的 PID：

```sh
python3 tests/support/resource_ledger.py --pid GUI_PID --omp-pid OMP_PID --seconds 60 --output build.noindex/resources.json
```

模拟算法属于 `make verify AREAS="resources"`，实际采样不代替算法检查，也不因算法改动而默认执行。完整授权和停止规则见[测试规范](../../docs/verification.md)。

`--chat-math` 是单独选择的真实聊天公式验收：复用同一隔离启动器，用[固定速率 SSE provider](chat_math_provider.py)先建立含公式的长历史，再通过生产 ThreadRuntime 发送新回复。驱动检查上滚期间的原生滚动偏移、主题不重复排版、字号和窄窗口、选中色及闲置 60 秒的 WebView 释放，保存本进程窗口的 WindowServer PNG、`math-checks.json` 与按 launchd GUI PID-domain 验证的 WebKit 资源账本。只退出自己启动的实例。绘制回调和主线程心跳不等于屏幕呈现 p95，物理显示器倍率切换及 VoiceOver 仍需分别验收。此模式在 `needs-user-scroll` 时等待真实滚轮上滚及 `math-scrolled` 标记，在 `needs-sidebar-width-check` 时等待侧栏开合复核及 `math-sidebar-checked` 标记，各等候最多 120 秒。剩余定向检查完成后自动写入 finish；普通 native-controls 模式仍由操作者结束。

仅重查可见原生选区时使用 `--chat-math --selection-only`，自动捕获并退出；不重跑流式/宽度/资源负载。该入口用视口内真实坐标定位文本视图，不能以 `visibleRect` 非空替代屏幕可见性。

`chat_session_replay.swift` 是不连接 provider 的可见聊天布局重放 helper，链接本工作树最新 Dev 模块。先在 `build.noindex/` 内的独立 capture 目录只读复制所选历史会话的 `library.json`、线程文件和 turn 分片；library 只保留目标及必要父项，路径重写到该副本，不能指向真实库。以 `--website-captures <该目录>`、`--resources <本工作树 MarkdownPreview>`、`--thread-id <副本中的 UUID>` 运行 helper；它显示生产 RootView/ThreadRuntime，按 1320 → 920 → 1320 pt 改宽，记录 24 次主线程心跳后关闭自己的窗口，输出 `replay.json`。操作者应在父进程施加超时，卡死时先采样再只结束该 helper；不要操作另一个实例。不得提交真实聊天内容。此路径仍需明确的 GUI 运行授权，不注册到自动功能检查。

附加 `--performance` 时固定 1320 pt，以 50 ms 心跳记录首次可见公式绘制、首轮空闲和最后一批排空，等待 0.5 秒稳定后重建同进程窗口，核对内存缓存复用；`renderer_stages` 分别记录导航、MathJax/字体/布局、截图、像素处理和清理。首次空闲可能早于延迟展开的历史页，不能替代最后一批就绪时间。跨进程缓存测量需另开 helper，将前一轮 `math-cache` 复制到新的隔离目录；无缓存对照从空目录开始。绘制回调不等于 GPU 上屏，`cold_ms` 包含稳定等候，同进程重建也不等于完整应用重启。

组合 `--performance --preparation-check` 时，另记录生产时间线的 `preparation` 状态：首次进入、内容字号加 1、恢复原字号及缓存窗口重开。只改 helper 进程内的 TypeScale，结束恢复原值，不写真实应用偏好。该模式等到重开时间线不再被等待态隐藏后才结束；`reopen_typeset` 仅统计重开阶段。它验证真实附件队列与等待状态接线，不是 GPU 呈现时序、完整外观/辅助功能或外部模型流式验收。

`--performance --switch-check --other-id <副本中的普通会话 UUID>` 增加切走 80 ms 后切回的记录，随后用真实 AppKit 事件循环等待手动/CUA 上下滚动。出现 `needs-scroll` 文件后开始输入，写入同目录 `scroll-finish` 结束，最多等 45 秒；父进程应留出其他阶段时间。`--history-change` 仅允许修改该 capture 的 `storage/` 内已复制原生日志，以追加无消息 ID 的 title 元数据触发一次真实重建。所有被选线程及原生日志都必须解析 JSON 后重写路径到副本，不能用纯文本替换绕过 JSON 中的斜杠转义。`frames`、`wheel_events` 和 `preparation-live.json` 保存数字状态检查点，不保存聊天正文；只有 CUA/真实用户输入能作为可见滚动证据，心跳和离屏布局不能替代。普通 async main 不能替代 `NSApplication.run()` 的事件分发。

## 生产浏览器自动化

`workspace_browser.py --automation` 只编译／准备生产面板验收宿主。它复用本 worktree 已通过的 Dev 构建，不启动 GUI。owner 明确授权后执行：

```sh
python3 tests/acceptance/workspace_browser.py --automation --run --omp /absolute/path/to/omp
```

仅使用独立 capture profile、临时 OMP 配置、loopback 合成网页和指定 npm SDK 的受守卫副本；真实 Browser/Eval 由 OMP 执行，不发模型请求。驱动验证双标签精确附着、兄弟弹窗、隐藏面板输入／拖动／滚轮、Cookie state 回读、跨域 frame 字符串／selector 截图、超时恢复及全部句柄释放后的再附着。页面抽样由生产宿主独立读取，避免以 `fill` 返回成功代替页面值变化。`PI_CONFIG_DIR` 按 OMP 的 home-relative 语义设置，并在加载会话前核对实际配置根目录。

某阶段失败后先定位生产或夹具原因；只需继续剩余阶段时使用 `--automation-from state|frames|recovery`，仍会创建新的隔离宿主和必要的双标签连接。复用此前通过的证据时，记录对应目录、当时的失败项及后续修改没有影响这些通过项的依据，不能把部分运行记为整轮通过。

恢复配置及相邻边界另选 `--automation-from options|downloads|tls`，每次只执行所选 scope。`options` 核对模态超时前后的下载真实路径／字节、User-Agent、启动脚本、viewport、白名单及显式重开更换目录；`downloads` 核对两个标签交替下载、原生同名替换语义、等待超时、兄弟释放及全部释放后人工下载的默认位置；`tls` 用 `/usr/bin/openssl` 在本次输出内生成一天有效的自签名证书，启动 loopback TLS 服务，核对默认拒绝、显式允许、兄弟隔离、关闭、恢复与释放，并保存 CDP 事件及 CEF 原生加载错误。它不修改系统信任／Keychain；TLS 握手在独立请求线程进行，避免浏览器预连接阻塞 fixture。`status` 控制仅收集本宿主的加载错误，不读日常 GUI。

结果写在本次 `build.noindex/browser-acceptance/<timestamp>/automation-result.json`，保留 host／SDK 日志；失败即停止本轮。退出只作用于本次启动的验收进程，日常 GUI 不受影响。单次宿主上限 240 秒，SDK 驱动上限 180 秒。它不认证外网登录、真实 Cookie、系统权限或完整应用启动流程。
