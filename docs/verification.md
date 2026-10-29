# 测试与验证规范

选择能覆盖改动的最小集合，所选检查通过即停止。[AGENTS.md](../AGENTS.md#verification-scope-and-stopping-rules) 规定工作树、授权及停止条件。仓库没有 Xcode test target；功能检查编译实际生产源码或链接本 worktree 的 Dev 模块。

## 唯一入口与分层

```sh
make verify                                  # 只列出功能模块，不运行
make verify-plan AREAS="rpc questions rpc"   # rpc 只出现一次
make verify AREAS="rpc questions"            # 按顺序执行，失败即停
make verify TIER=static                       # 列出静态检查
make verify TIER=native                       # 列出原生集成
make verify TIER=benchmark                    # 列出性能测量
```

`AREAS` 必须显式填写。空选择只列清单；拼错任何模块会在执行前拒绝整次请求。计划预览不检查本机依赖、不写运行目录、不编译或执行检查。执行时先验证整个计划的输入、工具和构建前置条件；共享前置检查只执行一次。不自动构建应用、重试或追加模块，也不要接着直接运行同一底层文件。

| 层级 | 用途 | 外部依赖及边界 |
| --- | --- | --- |
| `static` | 文档链接/导航、执行器契约、登记表、脚本语法 | 不编译应用，不执行生产 Swift 检查或 OMP |
| `functional`（默认） | 确定性功能、协议 fixture、离屏渲染 | 不调用已安装 OMP、外部模型或实际资源采样；聊天公式检查使用本工作树构建的模块及离线资源 |
| `native` | 指定 OMP 的 CLI、SDK、真实协议 | 明确 OMP 绝对路径；隔离 profile、新生成数据；不启动 GUI、不验证外部模型质量 |
| `benchmark` | 固定负载的性能及资源测量 | 变化路径需要测量或 owner 明确要求时才运行；不得附在普通功能检查后 |
| 手动验收 | 完整 GUI、系统交互、真实账号/模型 | 位于 `tests/acceptance/`，不注册到自动入口；启动/退出 GUI 仍须 owner 明确授权 |

`functional` 的原生渲染指 AppKit/WebKit，`native` 专指已安装 OMP。离屏检查可能在检查进程内初始化 AppKit；Markdown 文档检查使用不显示的 WebKit 窗口。这些结果不代替整应用交互验收。

从 GUI 发起的工具进程可能把 `com.apple.quarantine` 自动附加到本机编译产物，导致有效的本地签名也被 Gatekeeper 拦截。[共用本地构建策略](../tests/support/local_build.py)只处理当前 worktree 的 `build.noindex` 内受控产物：测试助手须刚完成编译或通过源码／二进制指纹核对；SwiftPM 使用受控编译器入口，在执行临时 manifest 或插件前处理其成功编译的输出，并把临时目录留在本 worktree；Dev app 只在构建成功后处理。不会递归清理整个仓库、下载源文件、已安装 OMP 或外部应用，不关闭系统安全保护，也不替换签名。元数据处理失败会在启动产物前停止，不要求 owner 点击系统放行。

`popovers` 另核对子代理步骤的首次内容高度、批量选择的固定视口、追加日志后的内部滚动及重开时的高度上限；可见卡片的实际打开动画仍属于现场验收。

## 目录和命名

```text
tests/
  run.py                     # 命令行、计划和退出码
  catalog.py                 # 唯一登记表：职责、输入、工具和前置关系
  functional/{omp,chat,preview,markdown,git}/
  native/                    # 真实 OMP CLI/SDK/协议
  benchmarks/                # 性能负载与独立渲染器对比
  acceptance/                # 单独安排的 GUI/现场验收
  fixtures/omp/              # 合成协议对端、MCP 和扩展素材
  support/                   # 共用编译、隔离、资源账本、源码片段提取
  tooling/                   # 执行器自身的回归测试
```

测试采用说明职责的 `snake_case_tests.swift|mjs|py`；执行器回归测试采用 unittest 的 `test_*.py`。fixture、测量驱动按职责命名，不使用 P0/P3/P4/P5 等项目阶段编号。`scripts/` 保留开发、资源生成和打包工具，不新增 `check_*` 包装器或第二份模块清单。

## 按改动选择

文档、注释、开发工具、测试工具及版本号改动只做相关静态/语法检查。编译源码或资源改动先做一次增量 `make build`，再选受影响模块。不因同处一行就运行全部模块；下表不代表自动推导出的完整覆盖。

| 变化行为 | 功能模块 | 链接 Dev 模块 |
| --- | --- | --- |
| 外观等宽字体名匹配、默认回退、同字号切换及字形保留 | `fonts`；预览字体路径另选 `preview-renderers` / `markdown-preview` | 否 |
| 高斯壁纸在默认／不透明设置及内容表面后的宽轮廓保留、柔和度归零清晰与逐渐柔化、透明度、填充裁切、深色对比和性能／减少透明度回退 | `wallpaper` | 是；隔离偏好与离屏 SwiftUI 图片，不启动 GUI；桌面材质合成需可见窗口验收 |
| 工具行系统／自定义 SF Symbols 的打包可用性、透明字形与精确身份/回退；站点图标单色识别、透明镂空、原生附件与共享菜单亮暗切换、彩色保留及原生图片附件的小数基线位置一致性 | `icons` | 是；离屏 AppKit/SwiftUI，不启动 GUI 或访问网络 |
| 启动会话选择恢复、会话生命周期、发现缓存、查询合并、指标边界 | `lifecycle` | 是 |
| 分帧、RPC 匹配/取消/超时、损坏的新会话 | `rpc` | 是 |
| Mnemopi 仓库/worktree 身份、全局文件列表缓存/失效、独立任务首次发送前目录准备、有界只读预览、关闭默认值和 EOF 保存排空 | `memory` | 是；离屏 SwiftUI/AppKit、隔离进程与 Git 仓库 |
| 原生发送队列标识和移除 | `queue` | 否，Node |
| 原生消息身份、活动路径和分支前历史解析 | `history` | 否 |
| 会话记录／请求分页、轮次树与平铺切换、祖先保留筛选、工具关联、详情模式恢复、顶栏等待期间外观保留、完整 JSON 复制及取消、参数全部展开／收起及迟到结果隔离、多分支原地展开、长文本滚动保留、连接线几何、文件变化、sidecar 缓存、读取生命周期与离屏分栏 | `session-records` | 是 |
| 新请求回调保真、并发关联、脱敏、会话级健康标记、失败边界、私有存储与保留边界 | `request-capture` | 否，Node |
| 上下文原生 tokenizer 分类、精确来源匹配、独立累计统计、分支捕获选择、未知值、可见读取生命周期与窄／宽原生面板 | `context-inspection`（含 `context-bridge`） | 是；隔离归档日志、请求摘要及离屏 SwiftUI，不启动 GUI 或 OMP |
| 提交/消费竞态、分支、压缩、handoff | `workflows` | 是 |
| 本地听写权限、按需语言资源、草稿身份、投递门禁、取消排空与全局麦克风归属 | `dictation` | 是；替换录音／识别边界，不申请权限、下载资源或打开麦克风；实际系统语音与窗口交互另行验收 |
| 原生额度／精确余额的隐藏规则、设置已配置服务商及关键数值投影、活动 profile 身份、可见共享缓存／取消、无用量读取的紧凑模型列表、首次进入空目录后的加载、预选弹出方向及纵向滚动锁的通知重入／原生居中约束 | `provider-usage`（含 `provider-balances`） | 是；隔离 CLI／fetch 替身与离屏 SwiftUI，不运行已安装 OMP、访问账号端点或启动 GUI |
| 唯一打包品牌清单、地区／模型／密钥／登录 ID 的标记与可读名称、多词与本地化名称搜索、OpenRouter 首字母约定、原始资源校验和、模板打包、可见笔画与透明画布 | `provider-logos` | 是；读取本 worktree Dev 资源包和固定原生身份快照，不联网、不启动 GUI |
| 原生目标身份、预算、终态与控制确认 | `goal` | 是 |
| 原生旁问、累计正文预算、草稿身份、sidecar EOF 排空与保存失败 | `side-question` | 是 |
| 配置、工具开关／入口归属／共享控制和依赖状态提示、扩展 UI、能力发现、全局技能来源过滤与 SKILL.md 读取；服务商登录自动打开、去重、原生输入／完成／取消和浏览器失败恢复；退出的多凭据／别名移除、外部认证保留、部分失败与并发保护 | `config` | 是；工具配置、登录及退出使用隔离 CLI/RPC 替身，不打开浏览器或运行 OMP |
| 活动 profile MCP 表单、跨页即显缓存／后台身份核对、完整预设工具名与弹窗关闭滚动位置、系统 JSON 文件入口、文件监听自动刷新、默认空参数/环境变量/请求头及保存保真、输入框占位与离屏边界、启停覆盖、重命名/移除、原子写入、冲突/符号链接保护及项目排除 | `mcp` | 是；隔离 CLI 替身及离屏 AppKit/SwiftUI，不运行服务器或解析密钥引用 |
| OMP 用量范围／年度边界、缓存加权与未知值、主／子代理及重复历史归属、revision／旧格式读取、实时快照替换、读取预算、原生日期轴柱体命中／范围边缘／夏令时及宽窄图表布局 | `usage` | 是；隔离资料库及离屏 Swift Charts，不启动 GUI、OMP 或扫描外部历史 |
| 主窗口设置导航、保留会话／草稿、应用窗口数量、Command-W 返回及尺寸跟随；跨页返回时保留已加载技能列表、离页取消未完成读取 | `settings` | 是；隔离资料库、CLI 替身与离屏窗口，不启动主应用或 OMP |
| MCP OAuth 委托、原生凭据边界、取消、失败及配置冲突 | `mcp-login` | 否；Node 原生 API 替身，不联网、不写真实凭据 |
| 模型详情元数据、价格状态／精度、旧档案解码、离屏详情，以及选择器隐藏／恢复和提供商批量操作 | `models` | 是；隔离 GUI 偏好与离屏 SwiftUI，不启动 GUI 或 OMP |
| 原生 Fast、重试控制及设置请求身份 | `run-options` | 是 |
| 原生 Slow 范围保护、缓存预热回显及有界最近事件 | `resource-options` | 是 |
| Hydra 元数据、worker 历史、父代理追加指令和完成通知／日志补读竞态 | `workers` | 是 |
| 会话等待状态、审批卡片、请求身份、草稿与原生取消/时限 | `interactions` | 是 |
| 问题表单、答案、分页布局、草稿 | `questions` | 是 |
| 弹窗原生标准磨砂与完整效果覆盖、主窗口透明度设置独立性与性能偏好实时更新、原生遮罩／前景隔离与实色回退、测量环境继承、固定视口、消息编辑按内容增减高度／上限和滚动条、技能预览／源码切换后的滚动位置，以及记忆开关前后的上下文控件 | `popovers` | 是；离屏 SwiftUI/AppKit 及始终透明隐藏的真实弹层容器，不显示可见界面、不启动主程序或 OMP；可见弹层的系统材质合成及箭头需现场验收 |
| 附件图片弹窗的无副作用测量、加载与实际图片绘制、关闭／切换／重开、迟到结果及失败重试 | `attachment-previews` | 是；隔离图片与离屏 SwiftUI/AppKit，不显示窗口或启动 GUI/OMP |
| 进程归属算法 | `resources` | 否，模拟进程账本 |
| 文件读取、监听、编码和目录边界 | `files` | 否 |
| 预览 store、缓存、宿主路由、混合侧栏页签／审阅路由、按会话全屏持久化及迟到恢复保护、40 个独立文件页签及完整恢复、有界打开并发、旧状态迁移及隐藏读取取消 | `preview-store` | 否 |
| Git 单文件预览 Diff／源码／Markdown 模式、暂存及未暂存合并、新增／忽略／未变化文件、字面路径、无首次提交、worktree 隔离、补丁上限、只读索引、可见元数据监听及迟到结果保护 | `preview-diff`；持久模式／源选区和行导航另选 `preview-store` | 是；隔离 Git 仓库，不启动 GUI 或 OMP |
| Git 侧栏的真实父子拓扑／多父泳道／分页延续、固定提交起点、内部引用排除、父提交比较、暂存／工作区／重命名／冲突差异、只读索引、失效 worktree、迟到读取及可见文件监听 | `git-browser`；混合页签状态另选 `preview-store` | 是；隔离 Git 仓库和 260／360／480 pt 未显示的生产窗口，不启动 GUI、OMP 或网络操作；可见窗口键盘／玻璃／拖动仍需现场验收 |
| Git 文件级／批量暂存与取消暂存、只提交固定暂存内容、首次提交／linked worktree、外部索引锁／分支变化、原生 hook 拒绝及已提交后退出、草稿／生成迟到保护及单行提交顶栏 | `git-commit`；宿主入口另选 `preview-store`，图谱及浏览回归另选 `git-browser` | 是；隔离 Git 仓库与未显示的 260／360／480 pt 生产窗口，不运行 OMP 或网络；真实签名、键盘、输入法及玻璃仍需现场验收 |
| 文件树页签往返的嵌套展开、隐藏文件选项、原生滚动容器／精确位置、预览刷新、关闭释放、会话隔离及重启后的原生全屏布局 | `preview-browser` | 是；隔离目录与未显示的原生窗口，不启动 GUI 或 OMP |
| Chromium profile 列表／下次启动选择、手动重名拒绝、配置删除／持久清理／默认及活跃保护／符号链接边界、会话标签归属、恢复及资源上限 | `workspace-browser`；设置导航及 Chrome 导入提示的中英文宽窄离屏布局另选 `settings` | 是；隔离偏好和目录，不启动 CEF 或 OMP；离屏布局不替代真实窗口交互 |
| 原生 Chrome 配置发现、一致性 SQLite/WAL 快照、密钥派生／严格域名哈希、分区及安全属性保留、单条跳过／明确拒收拆分／验证子集清理／合并计数、整体故障／权限／取消失败边界、新 profile 命名／偏好恢复与扩展资源移除 | `browser-cookie-import`；相邻配置及设置导航另选 `workspace-browser settings` | 是；合成 SQLite、独立密码学向量和注入密钥，不读个人 Chrome／Keychain，不启动 CEF 或 OMP；真实系统授权、目标 CEF 及进程重启属于现场验收 |
| GUI 下载的显式隔离、持久化标记、字节保真、无关文件隔离及缺失文件错误 | `browser-downloads` | 否；真实文件元数据，不访问网络或执行下载；应用／子进程默认隔离策略另做进程级验收 |
| 侧栏／底栏终端的独立会话／选择／开关、同时挂载、显式双向迁移与来源关闭、目标已有会话保留、迁移后重启／关闭及会话清理、输出与原生视图保留、拆卸和背景／主题适配 | `terminal` | 是；隔离 capture 与未显示的原生窗口，不启动 shell、GUI 或 OMP；真实 PTY／桌面合成需现场验收 |
| 调试运行／停点迁移、已读栈／变量／寄存器持久化、帧与运行隔离、历史选择固定及顶栏选择器、存储预算、旧日志批量精确补读、源文件跳转、历史详情准备／缓存及离屏渲染、列表滚动保留、开始信号自动展开、语义状态、只读查询白名单、停点与变量引用失效、取消、worker 隔离、历史持久化及原生进程回收保护 | `debug`（自动包含 `debug-bridge`） | 是；隔离模型及 Node 桥接替身，不启动 OMP 或 GUI。单独的 `make verify TIER=native AREAS="debug"` 使用已安装 OMP SDK 与本地 DAP 替身，验证同进程原生工具钩子、栈与变量；不执行用户程序或模型请求。真实调试器、键盘／VoiceOver 和完整窗口交互仍需现场验收 |
| OMP 文件引用和打开入口 | `preview-entrypoints` | 否 |
| 预览渲染、动画、打开流程、浮动控件及 PDF 浅深色页间／边缘／回弹留白像素 | `preview-renderers` | 否 |
| 聊天 Markdown 解析、布局（含网页图标两侧可见等距）、公式、高亮及流式文字颜色 | `markdown-parser`、`markdown-layout`、`markdown-math`、`markdown-hosting`、`highlighting` | `markdown-math`、`markdown-hosting` 是；离屏原生附件、完整 Markdown 宿主及共享 MathJax |
| 聊天表格的原生单元格、列宽与横向滚动 | `markdown-tables` | 是；离屏 SwiftUI/AppKit |
| 密集公式会话等待、快速/少量抑制、超时及会话隔离 | `markdown-preparation` | 是；受控时钟与原生附件，不运行 WebKit |
| WebKit Markdown 文件预览 | `markdown-preview` | 否 |
| Diff、时间线答案及错误／重试警告合并计数和历史恢复、todo、eval | `diff`、`timeline`、`todo`、`eval` | 仅 `timeline`、`eval` 是 |
| 命令文件归属、审阅轮次筛选、同期合入提交、同文件后续写入、跨 worktree 编辑与旧汇总重算/持久化 | `file-attribution`；原生后台命令另选 `workflows` | 是；隔离 Git 仓库，不运行 OMP |

真实写入 hook 的 `fast-write` 移到 `native`。`preview-renderers` 不再执行大文件 wrap 计时阈值，该负载独立选择 `benchmark:preview-wrap`。`lifecycle` 不附带资源采样和大语料重复压力；分帧正确性归属 `rpc`，资源账本算法归属 `resources`。

`highlighting` 同时核对扩展语言的实际 token、无扩展名／别名识别、注释与字面量边界、Unicode 及复制保真；`preview-renderers` 核对实际原生宿主的 Makefile、TeX 与 Markdown 源码着色，`markdown-preview` 核对打包后的扩展围栏语法及纯文本／超限回退。`highlighting` 的离屏原生文本检查覆盖可选代码主题的缓存亮暗颜色、渐显回调与文本视图外观不一致、渐显中切换主题、链接/行内代码颜色、原有透明度、选区和临时颜色清理；`preview-renderers` 另核对未变化源码即时着色时的文本、选区及滚动保留，`markdown-preview` 比对同一主题在原生与 WebKit 的实际前景色，并核对样式切换不重建 DOM、不丢失选区或滚动位置。均不启动 GUI，也不替代真实窗口的主题菜单或流式会话验收。

`markdown-hosting` 验证普通长正文的宽度试算保持显示容器、文本和选区不变，内容/字体变化后重新测量；同时验证 SwiftUI 试算不修改正在显示的公式文档、容器宽度及滚动条，并用含列表、公式表格、块公式的完整 Markdown 在 760 → 400 → 760 pt 往返中检查布局收敛。它使用不显示的窗口；可见窗口的显示周期卡死需单独的[手动会话重放](../tests/acceptance/README.md)。

`markdown-math` 另覆盖超过旧缓存容量的 320 个公式、等待请求去重、磁盘恢复时不启动 WebKit、缓存损坏时重新排版，并逐像素比较透明/彩色/选中及 3× 缓存往返。它使用隔离 capture 缓存，不访问用户系统缓存目录。

`markdown-preparation` 使用受控时钟核对延迟出现、最短显示、历史分页/几何就绪、再次失效及超时后不反复遮挡，并核对绑定/转移/分离原生附件时仅统计当前时间线的工作；控制器检查覆盖缓存列切回、真实历史重建及第一拍滚轮/tracking 对旧定位的取消。`markdown-hosting` 另核对跨含公式段落/列表的连续原生选择及宿主数量预算。可见行为另用手动重放，不把 GUI 或性能负载挂入功能检查。

文档链接、归档和导航改动选择 `make verify TIER=static AREAS="documentation"`，检查本地文件/图片、章节锚点与文档可达性，不访问远端 URL，不自动证明语义一致。检查器及维护范围见[文档维护](documentation.md)。修改文档检查工具时合并选择 `make verify TIER=static AREAS="documentation harness syntax"`，不另跑底层脚本。

测试框架改动选择 `make verify TIER=static AREAS="harness syntax"`。`harness` 用临时仓库和进程替身覆盖去重、依赖边界、预检、失败停止、超时清理、隔离、报告、构建指纹和编译缓存，并检查测试文件登记、源码提取锚点和路径；macOS 另用实际文件元数据核对本地构建产物的 quarantine 处理、外部／符号链接越界保护及失败编译不放行旧产物，不执行带隔离标记的文件。`syntax` 解析 `tests/`、`scripts/` 中的 Python、shell、JavaScript、Swift，不导入 fixture、不执行负载、不下载依赖。未改变内容的 TypeScript fixture 在对应原生集成时由其工具链加载。

独立任务、默认模型／位置、项目排序／分页与折叠重置、完整活动日期分组及归档批量范围选择 `organization`；损坏索引、上次启动副本、重复身份、格式备份和待写轮次合并选择 `recovery`；消息归属、选区快照、分段引用与 Unicode 渐显选择 `selection`。三者均链接当前 worktree 的 Dev 模块，使用隔离 capture 资料库与偏好，不运行 OMP 或显示 GUI。选区检查只读取系统剪贴板变更计数，不执行复制。

`config` 自动依赖 `provider-authentication`：Node 替身检查原生认证类型、返回 Key 的真实 OAuth、API Key 入口保留、原生 `storeAs` 凭据归属及需要终端前置输入／未知 hook 的排除；Swift RPC 替身检查归属元数据的 profile 边界、未确认的流程不会启动登录、完成／取消／失败会释放等待状态。图片后端及 Codex 浏览器／设备码共享凭据与真实安装策略的对应关系由独立的 `native:model-configuration` 检查，读取公共策略时不联网、不发起登录、不刷新 token，也不修改真实凭据。

## 原生集成和性能测量

`native:provider-usage` 仅在余额／原生凭据路径改变时选择：`make verify TIER=native AREAS="provider-usage" OMP=/absolute/path/to/omp`。使用隔离 profile 与指定 npm SDK，验证存储、环境、模型配置密钥优先级及原生扩展的端点覆盖；fetch 为本地确定性替身，不访问实际账号或发起模型请求。它不作为普通功能检查的依赖。

```sh
# 仅选择受影响的原生适配路径。
make verify-plan TIER=native AREAS="questions"
make verify TIER=native AREAS="questions" OMP=/absolute/path/to/omp
make verify TIER=native AREAS="approvals" OMP=/absolute/path/to/omp
make verify TIER=native AREAS="config" OMP=/absolute/path/to/omp
make verify TIER=native AREAS="model-configuration" OMP=/absolute/path/to/omp
make verify TIER=native AREAS="rpc" OMP=/absolute/path/to/omp
make verify TIER=native AREAS="side-question" OMP=/absolute/path/to/omp
make verify TIER=native AREAS="run-options" OMP=/absolute/path/to/omp
make verify TIER=native AREAS="workers" OMP=/absolute/path/to/omp

make verify TIER=native AREAS="goal" OMP=/absolute/path/to/omp
make verify TIER=native AREAS="resource-options" OMP=/absolute/path/to/omp
make verify TIER=native AREAS="fast-write" OMP=/absolute/path/to/omp

# 仅在需要该性能证据时选择。
make verify TIER=benchmark AREAS="lifecycle"
make verify TIER=benchmark AREAS="event-projection"
make verify TIER=benchmark AREAS="preview-wrap"
make verify TIER=benchmark AREAS="markdown-preview" PAPER=/absolute/path/to/paper.md
make verify TIER=benchmark AREAS="math-renderers"
make verify TIER=benchmark AREAS="mathjax-attachments"
make verify TIER=benchmark AREAS="chat-math-cold"
```

`native:memory` 使用隔离 profile、真实原生 SDK 与 Mnemopi SQLite/FTS，检查 worktree 项目共享、全局可见性、独立项目隔离、文件路径/预览身份保护、提示词召回快照不变和关闭状态。关闭 embeddings 和 LLM，不访问外部模型、不启动 GUI。

`native:questions` 消费本次 `functional:questions` 生成的序列化答案，前置检查只运行一次，不提前另跑。问答和 fast-write 需要 Bun 及保留 `src/index.ts` 的 OMP SDK 安装。`native:config` 使用真实配置 CLI；`native:rpc` 使用本地确定性 provider 和全新会话。

`native:approvals` 使用指定 npm SDK 的公开 `requestApproval` 生成实际选项，将它们交给生产 Swift 审批投影和响应序列化，再由同一原生接口解释结果。覆盖普通、会话授权、缓存文件/目录/URL 菜单，确认 GUI 始终只返回单次允许或拒绝，尤其区分目标授权 `Approve` 和单次 `Approve Once`。不执行工具或写入授权缓存，不调用模型或启动 GUI；真实管道送达/请求身份由 `functional:interactions` 覆盖。

`native:config` 另以同一隔离 profile 检查公开 `skill list --json`：全局技能可见、项目技能不进入设置列表、聊天 overlay 不影响全局清单，原生配置字节不变。

`native:mcp` 只通过安装的 OMP `config path` 核对显式隔离的命名 profile、MCP 原生文件保存及切换身份保护，不启动会话、服务器、包管理器或 OAuth。选择 `make verify TIER=native AREAS="mcp" OMP=/absolute/path/to/omp`；实际 npm/uvx 下载、连接和双语 GUI 表单交互属于另行授权的手动验收。

`native:mcp-login` 单独选择 `make verify TIER=native AREAS="mcp-login" OMP=/absolute/path/to/omp`。它使用指定 npm SDK 与 Bun，在临时命名 profile 中验证原生 OAuth 发现、动态注册、PKCE、回调及凭据保存；测试授权服务和回调均为本机 loopback，不打开浏览器，不接触外部账号，不运行 MCP 工具、包下载或模型。它不认证目录中每个外部服务的授权条件。设置隐藏时的读取暂停与预览恢复选择 `preview-store`；完成卡片归属、折叠后保留、分段去重及多报告布局选择 `timeline`。

`native:model-configuration` 单独验证 API Key 编辑器和图片后端目录：使用安装的 OMP SDK、原生 provider 清单、YAML schema 和凭据优先级，以及隔离配置目录，覆盖 OAuth 共存、清空覆盖、未知字段、冲突、私有权限、符号链接及旧格式；图片检查覆盖未登录后端、自定义图片/纯聊天模型、共享 OAuth/密钥、无需凭据的端点，以及只返回元数据且不执行密钥命令、不刷新 token、不请求模型。`functional:config` 补充图片目录解码、未知选择器及图片角色修改/清除保留其他角色。不改真实 profile、不启动 GUI，眼睛按钮和实际图片服务需单独手动验收。

该原生检查也验证仅在模型目录中的 `minimax-cn` 能进入密钥表单，按中国／国际原生 ID 独立保存，真实 ModelRegistry 可用性与 `AuthStorage.keys.get` 分别解析各自覆盖。此处使用隔离的替身密钥，不改写地区身份、不测试真实服务端，也不按品牌图标合并凭据。

`native:image-tools` 通过安装的 SDK 创建隔离会话，验证仅配置图片角色仍不启用工具、原生开关实时注册/移除 `generate_image`、`tools.xdev` 开关下的设备/顶层呈现，以及模型实际系统提示中的工具可见性；不发送提示词或模型/图片请求。`native:config` 另验证生产设置读取器区分 profile 默认值与聊天 overlay，并通过原生 CLI 保存图片工具开关、保留模型角色。

`native:run-options` 复用隔离的本地 provider 环境，只验证运行选项命令、原生拒绝和 profile 不变，不发送模型请求，不自动运行整个 `native:rpc` 负载。

`native:workers` 要求 Bun 和包含 `src/index.ts` 的指定 OMP 安装。它读取生产导出的 GUI 会话覆盖，通过真实 Settings、原生子代理设置工厂及 agent loop 检查主/子/孙代理继承、普通 WebSocket 偏好保留、工具边界追加消息恰好消费一次及隔离 profile 字节不变。模型流使用注入的确定性替身，不连接模型服务、不启动 GUI，也不认证 Codex 服务端是否支持运行中 steering；`functional:workers` 仍保持无已安装 OMP 依赖。

`functional:goal` 使用合成公开 RPC 对端，覆盖空值/终态与完成入口留存、预算非硬限及耗尽恢复保护、未知状态/小数秒、身份变化、禁用策略、迟到确认、旧版拒绝，以及明确恢复时单次 prompt 与原生续跑去重。`native:goal` 复用隔离的本地确定性 HTTP provider，但只运行 Goal helper；检查公开 Goal 操作、原生 complete 工具、停止造成的暂停、预算、进程恢复、禁用策略及原生 RPC continuation，不执行通用 RPC 兼容矩阵或外部付费模型。
`native:resource-options` 同样不发送模型请求：验证本地模型的 Slow 拒绝/关闭语义、预热模式的公开回显及隔离 profile 不变。全局 Slow 的真实账号写入、付费预热的 hit/miss/error/aborted 生命周期不在此范围；确定性的 GUI 范围保护与事件投影由 `functional:resource-options` 覆盖，不代替现场验收。

明确需要兼容矩阵时才指定必要版本：`python3 tests/run.py --tier native --omp /path/to/omp-a --omp /path/to/omp-b rpc`。其他 native 模块一次选一个 runtime，不自动展开矩阵。

`benchmark:lifecycle` 保留固定重复负载和资源测量；`preview-wrap` 保留大文件布局断言和计时阈值。SwiftMath/Temml 是独立研究负载，首次下载固定依赖，见[测量说明](../tests/benchmarks/math_renderers/README.md)。测量须记录同负载基线、候选、机器及边界，不用单次耗时宣称整应用响应达标。

`benchmark:event-projection` 用一份合成正文/工具参数语料比较 full/delta NDJSON 字节和生产 JSON parser/decoder 耗时，不运行 OMP、GUI 或 stdio，不测内存分配及屏幕延迟；它依赖本工作树构建证据，需单独显式选择。

`benchmark:chat-prose-layout` 链接本工作树 Dev 模块，对同一份含标题、列表、中文和行内代码的长正文，在固定的 400/760/520/760 pt 宽度间比较原有显示容器单宽度测量与独立多宽度缓存。预热后每组 48 次试算，记录三组原始耗时至 `prose-layout.json`，逐次核对高度一致；不包含解析、富文本构造、绘制或整应用滚动，不作为帧率验收。单独选择 `make verify TIER=benchmark AREAS="chat-prose-layout"`。

`benchmark:sidebar-layout` 链接本工作树 Dev 模块，在不显示的窗口中用同一份长 Markdown 和原生输入框，比较逐帧调整聊天宿主宽度与固定目标宽度的原生裁切视口。940 ↔ 660 pt 每个方向各 28 帧，分别记录三组耗时及实际 TextKit 容器宽度数量，包含切换到目标宽度的一次排版，输出 `sidebar-layout.json`。不测绘制、GPU 呈现或完整 GUI 交互，不作为屏幕帧率验收；单独选择 `make verify TIER=benchmark AREAS="sidebar-layout"`。

`benchmark:chat-math-cold` 链接本工作树 Dev 模块，使用实际共享队列、缓存及 MathJax 图片路径。三个重建 WebView 的轮次各处理 96 个不同公式，随后以 16 ms 间隔提交 24 个新公式，输出 `cold.json`；各轮第一批及全部就绪时间描述离屏资源就绪，不是整应用帧率、可见优先调度验收或唯一物理内存。首轮与后续重建共享进程环境，应分开解释。

`benchmark:mathjax-attachments` 是[共享 MathJax 原型](../tests/benchmarks/mathjax_attachments/README.md)：复用生产离线 CHTML/NewCM 与原生 Markdown/TextKit 正文，比较冻结的 SwiftMath 基线、批量 PDF 矢量附件和 2× 图片附件，包含流式回放及明确归属的 WebKit 资源账本。不改变产品聊天路径，不启动 GUI 或 OMP，不需要应用构建；完整聊天滚动、选中色和功耗另行验收。

## 隔离、缓存和证据

- 每次生成 `build.noindex/verification/runs/<run>/<tier>/<area>/`，不复用上次 fixture、profile 或结果。子进程清除外部 OMP/PI 覆盖变量，使用本次隔离 profile 和临时目录。
- `report.json` 记录顺序、通过/失败/未运行状态、耗时、实际命令、声明输入指纹、工具路径、系统及 Python 信息；链接应用时记录构建证据；真实 OMP 记录路径、版本、可执行文件及可用 SDK 源码指纹。各模块保留 `checks.log` 和原有 JSON/PNG 语义结果。
- 共用 Swift 6 编译及 worktree 模块缓存。辅助程序仅在源码内容、生成片段、生产模块/二进制或编译器标识变化时重编译；这是编译缓存，不是自动复用上次测试结论。历史 SwiftMath 研究使用增量 SwiftPM 缓存。
- `make build` 核对构建前后的源码/资源指纹，成功后写入 `build.noindex/development/verification-inputs.json`。应用模块检查拒绝缺失、过期或替换过的构建，不凭 dylib 文件存在认定它最新。旧 worktree 首次使用新系统时做一次增量构建；文档、测试工具改动不使有效的应用构建失效。
- 每个命令有时限。失败、超时、中断均不自动重试；超时/中断终止本命令拥有的进程组。未执行项保留 `not-run`，不能视为通过。`make clean` 清除 worktree 生成产物，需保留报告先移出生成目录；不删除应用数据和外部 OMP 配置。

复用通过证据前，确认相关源码、fixture、runtime、环境未变。不要重复同一行为的不同包装器或多版本运行。协议 fixture、已安装 OMP、离屏渲染和整应用验收的结论必须分别说明。

## 新增测试规范

1. 先明确生产行为、真实失败情形及最小层级。优先扩充已有职责模块；可逆、低影响改动不添加复刻实现的测试。
2. 直接编译/调用生产实现，只 stub 无关边界。片段提取须明确锚点，锚点变化必须失败，不悄悄改用复制实现。合成协议不得冒充原生集成。
3. 在 `catalog.py` 登记职责、源码、额外输入、工具、时限和真正共享的前置检查。`harness` 拒绝无效路径、未登记文件、循环依赖及越层引入重项。通用编译和隔离改 `support/`，不新增单模块编译包装器。
4. 查看计划后执行最小集合。修复后只复跑受影响失败项，保留仍有效证据。测试框架改动补充契约验证，并更新本规范中的选择和边界。

## 失败分析与停止条件

先阅读生产源码和测试，明确是实现缺陷、过时/不合理的预期还是环境问题，再修正对应部分。不能用重跑、扩张范围或削弱有效断言代替分析。缺失工具/构建属于环境失败，不是通过或静默跳过。

所选检查通过即停止。测量或手动验收无法完成时记录限制和剩余项，不为取得有利结果不断重复。交付至少说明改动、所选层级/模块、结果和证据路径，以及未完成的必要验收边界。

## 旧入口迁移

已移除收件箱后的会话请求检查由 `inbox` 改名为 `interactions`，不再包含最近请求缓存。历史报告中的旧名称保留当时含义。

旧 `check_*.sh`、`scripts/verify.py` 已删除，不保留重复包装器。`lifecycle/rpc/config/workers` 接替 P0/P5/P3/P4 功能脚本；原生 P3/P5 使用 `TIER=native AREAS="config"` / `"rpc"`；原生问答使用 `"questions"`；生命周期的 `--benchmark` 使用 `TIER=benchmark AREAS="lifecycle"`。历史验收文档的次数和数据保留当时证据，不表示新执行器已重跑这些负载。

`native:request-capture` 使用隔离 OMP SDK 与本机 loopback HTTP/SSE 服务，检查主／子代理并发和旁问的扩展最终载荷、会话／分支身份、响应元数据、上下文及输出。它不访问外部模型、日常 profile 或 GUI；选择 `make verify TIER=native AREAS="request-capture" OMP=/absolute/path/to/omp`。

该原生检查同时验证流式主请求期间 `/omp-gui-context` 通过公开扩展命令立即返回原生分项与 tokenizer 组成、不增加消息或 leaf，并核对主／子请求的组成与服务商计数持久化到摘要。它不验证真实服务商 tokenizer 的计费规则或整应用的可见交互。
