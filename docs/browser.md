# 工作区浏览器

在工作区侧栏的“＋”中选择 **Browser / 浏览器**，打开内嵌 Chromium 面板。地址栏接受 HTTP、HTTPS 和带端口的 localhost 地址；裸域名使用 HTTPS。本地文件继续使用 Files 面板。

## 使用与生命周期

面板支持独立网页标签、前进／后退、刷新／停止、地址复制、页内查找、缩放、下载列表、默认浏览器打开和开发者工具。网页的用户手势新窗口链接进入本会话的新标签；自动弹出窗口会被拦截。原生 CEF 提供文本编辑、文件选择与页面上下文菜单。页面请求的摄像头、麦克风、定位权限默认拒绝，并提示使用默认浏览器；人工浏览默认拒绝无效证书。OMP 的显式自动化选项见下文。

网页标签栏沿用终端标签栏的胶囊选中态、文字大小、间距与悬停关闭按钮；没有网页标签时隐藏整行，仅保留空状态中单层外框的新建按钮。标签栏的新建按钮与地址栏右侧的“更多”按钮上下对齐，地址输入框与周围按钮等高，地址栏上下留白一致；“更多”操作使用普通菜单列表行。

新标签保持“新建浏览器标签页”标题，画布中央只显示小型 OMP 标识和搜索输入框。标识复用现有的 OMP π 图案，右下角附加小型地球图标，整体为 56 pt；不替换应用图标。欢迎内容是原生覆盖层，不导航到外部首页，不影响保留的 CEF 页面及 CDP 身份。内部 CDP 定位过程不显示加载控件，也不会额外跳转一次空白页。

## 应用内网页链接

**设置 → 浏览器 → 网页链接打开方式** 可选“内置浏览器”（默认）或“系统默认浏览器”，保存后即时生效。它统一会话文字／右键“打开链接”、文本／Markdown／PDF 预览、终端输出和应用内普通网页链接。内置模式在点击链接的窗口所属会话中新建并选中网页标签；没有会话时创建独立任务承载浏览器。来自设置页的网页链接会返回工作区显示结果。达到标签上限或浏览器启动失败时在面板报告错误，不自动改用外部浏览器。

设置严格限定于完整的 HTTP／HTTPS 目标。会话和 Markdown 的裸域名识别先将 `github.com/xxx` 这类网页网址补为完整 URL，再交给打开方式设置；路由本身不按文件名外观猜测网址。明确的文件链接、目录、相对路径、`file://`、带行号引用，以及邮件／自定义协议保留既有处理。内置浏览器中的正常网页导航、显式“使用默认浏览器打开”和登录授权流程沿用各自原有行为。

## 界面语言

**设置 → 浏览器 → 浏览器界面语言** 提供“跟随应用语言”（默认）、English 和简体中文。跟随应用时使用当前应用实际显示的语言；独立选择只影响浏览器面板文案和 Chromium 原生菜单，不改变其他应用界面。修改后重启 OMP GUI 生效，当前运行中的面板和 CEF 保持同一语言；应用不会自动重启。

英语和简体中文的应用文案与 CEF `locale.pak` 均随应用打包，**无需另行下载语言包**。CEF 使用 `en-US`／`zh-CN` 对应已内置的 `en.lproj`／`zh_CN.lproj` 资源。网页正文的语言由站点决定，这个选项不翻译网页，也不改写站点语言偏好。

## 网页搜索

在空白标签页输入关键词后按 Return，或点击输入框右侧箭头，在当前标签打开搜索结果；输入框提示当前引擎。各标签保留自己的未提交搜索文字，空输入不会导航。地址栏继续只接受本页开头所述的网页地址。

**设置 → 浏览器 → 搜索引擎** 提供 Google、Bing／必应、DuckDuckGo、Baidu／百度，默认 Google。选择即时生效，并保存到当前 Dev／Release edition 的本地偏好；现有标签不会因切换引擎自动导航。搜索使用引擎的公开 HTTPS 网址，保留中文、空格、`C++` 及查询分隔符；不提供搜索建议、输入时联网或额外的搜索历史库。仅提交时把关键词交给所选引擎。

## 标签与会话状态

浏览器获得焦点时，⌘L 聚焦地址栏，⌘T 新建网页标签，⌘W 关闭当前网页，⌘R 刷新，⌘F 显示页内查找。工作区外层仍使用原有页签切换快捷键。页面的 alert、confirm、prompt 和 beforeunload 显示在对应标签内；切到其他标签仍可继续操作。人工答复与 OMP CDP 使用同一个 CEF 回调；CDP 已完成的弹窗会同步消失。

每个会话拥有自己的标签状态，所有会话及窗口共用本次启动选中的 CEF profile。同一会话在不同窗口使用同一组页面；原生宿主移动到当前展示窗口。切换会话、侧栏页签、全屏、收起或隐藏窗口只转移／停放宿主，不销毁页面。标签显式关闭会等待 beforeunload；关闭整个 Browser 面板、删除会话和退出应用会强制释放其页面。后台页面可以继续网络请求与 OMP 操作，因此隐藏面板不表示暂停网页。

每个会话最多 16 个网页标签，应用最多 64 个已创建的原生页面；超过上限显示错误，不淘汰正在使用的页面。重启只恢复 URL、标题及选中标签，页面按需创建，原生导航历史和旧 CDP 句柄不恢复。状态文件读取上限为 1 MiB，每个标签下载列表保留最近 50 项。

数据位于当前 edition 的 Application Support 库中：`browser-tabs.json` 保存导航元数据，`browser/profiles/Profile-Shared-<profile UUID>` 保存 CEF 站点数据，`browser/downloads/<conversation UUID>` 保存下载，列表可在 Finder 中定位文件。profile 必须是 Chromium 数据根的直接子目录；旧版嵌套目录被 Chromium 回退为临时 profile，没有可迁移的持久站点状态。下载使用独立子目录避免覆盖同名文件。Dev 与 Release 不共享该目录。Chrome Cookie 仅通过下述明确的导出／导入流程复制，不共用系统 Chrome 的目录；Tivano 和 Droppy 的 profile 不导入。

GUI 下载列表中完成的文件会显式标记为 macOS 网页下载隔离，不修改文件内容；标记失败时显示错误，不提供 Finder 定位操作。主应用不再把本地终端、包管理器和构建生成的所有文件自动标记为下载，CEF helper 仍保留自动隔离。该调整不关闭 Gatekeeper、代码签名校验或 Chromium sandbox，须更新并重新启动应用后生效；不会批量移除既有文件的隔离标记。

## 浏览器配置与登录态

**设置 → 浏览器 → 浏览器配置** 可选择现有 profile，或通过“添加配置…”输入名称并创建空白 profile。新建后自动选中，**重启 OMP GUI 后生效**。本次运行的 profile 在应用读取设置时固定，包括尚未打开浏览器的情况；更改设置后，新开的会话、标签和窗口仍使用原来的 profile，界面提示当前生效的配置。所有会话共享该 profile 中的 Cookie、localStorage、IndexedDB 及站点登录态，标签导航和下载归属仍按会话保留。

默认 profile 有固定身份；自建 profile 使用独立 UUID。手动名称去除首尾空白后比较，不区分大小写，禁止与现有配置（包括默认配置及导入配置）重名；输入框就地提示并禁用创建。旧版已存在的重名记录保留各自身份。新建空白 profile 不复制 Cookie 或账号。切换后再切回来会复用原来的站点数据；关闭标签、关闭面板或删除会话不会清除 profile。旧版按会话保存的 `Profile-<conversation UUID>` 保留在原位置，不自动合并或选用，首次使用共享 profile 时需重新登录。

**设置 → 浏览器 → 删除所选配置** 可删除选择器中的非默认 profile。点击“删除配置…”后确认名称；取消不改变数据。确认后将该 UUID 从配置列表移除，若它是所选项则改选默认配置，并持久记录待清理身份；当前进程仍沿用启动时固定的 profile，不在使用期间删除文件。**下次启动 OMP GUI 时**在后台清理其 Cookie 和其他站点数据。默认配置不可删除，导入 Cookie 期间禁用删除操作；其他配置及外部 Chrome 数据不在删除范围。

待清理列表与配置共同保存，兼容没有此字段的旧偏好。清理仅针对本 edition 库 `browser/profiles/Profile-Shared-<UUID>`；保留当前启动 profile、默认及仍列出的 profile，拒绝沿库／浏览器／profiles 根符号链接向外遍历。最终 profile 符号链接只移除链接本身，失败或中断的清理保留待办供后续启动重试。重启前不能以同一 UUID 重新导入已移除配置。

CEF 开启 `persistSessionCookies`，持久 Cookie 以及没有到期时间的会话 Cookie 均可跨正常退出／重启保留；网站主动退出、过期及服务端撤销仍按网站规则执行。localStorage 和 IndexedDB 使用同一个磁盘 profile。安全存储沿用 wrapper 的自动策略：Debug 使用 mock keychain，Release 使用 macOS Keychain；Dev 与正式版保持各自的 profile 列表和选择。

页面使用保留的 AppKit 宿主，移动窗口或停放时不拆卸 SwiftUI 网页树。关闭回调仅移除 Chromium 子视图，由 CEF 完成页面释放；不得向 OMP GUI 主窗口发送 `performClose:`。新 profile 使用异步创建，关闭尚在创建中的页面也会在创建完成后释放。内部空白定位 URL 不写入导航状态。

## 从 Chrome 一次性导入 Cookie

**设置 → 浏览器 → 从 Chrome 导入** 原生读取本机 Google Chrome 配置，不需要扩展或导出文件。

导入弹窗根据当前字号及提示文字测量紧凑宽度，最多 640 pt，并受所在屏幕可用区域约束。说明及范围提示尽量单行，长权限错误按两行安排宽度，避免整条红色文字撑宽弹窗。窄屏时仍完整换行，不使用省略号；权限错误支持选择和复制。设置页的导入结果、当前配置及删除提示同样保留完整文字。

1. 点击“从 Chrome 导入…”，从列表选择 Chrome 配置。列表读取 `Local State` 中的名称并附带目录名，不读取 Cookie 值或钥匙串；支持 `Network/Cookies` 和旧位置 `Cookies`，前者优先。
2. 确认“导入到新配置”。应用只读打开所选源数据库，通过 SQLite 备份 API 将一个包含已提交 WAL 数据的一致性快照复制到内存。源读取事务在快照完成后释放，不在系统授权期间持有 Chrome 的数据库锁。
3. 有加密 Cookie 时，通过原生 Security API 请求 `Chrome Safe Storage` 钥匙串项目。允许或拒绝由 macOS 管理，不使用外部 `security` 命令，不保存密钥。若 macOS 阻止文件访问，错误旁的“打开隐私设置”可打开完全磁盘访问权限页面，允许当前 OMP GUI 应用后重试；应用不自行修改系统权限。
4. 应用逐条解密并校验，再分批写入全新 UUID profile。过期、损坏或不支持的单条 Cookie 会跳过；浏览器明确拒收的批次会拆分以保留其余条目。目标回读逐项确认，只将属性完整保留的子集发布为新配置；若目标留下被改写的条目，只清空这个尚未发布的新 profile 并重写已确认的子集。没有任何可用 Cookie 时不添加配置。
5. 成功信息显示导入数、配置名称及重启提示；存在跳过项时仅追加“跳过 xx 个”，不列原因。**重启 OMP GUI 后生效**，当前运行中的所有页面仍使用原配置；应用不会自行重启。导入期间可取消，退出会取消并排空操作；已出现的系统钥匙串授权窗口仍需在 macOS 中完成或取消。

导入名称为 `Chrome 来源名称 [Chrome]`；发生碰撞时自动使用 `Chrome 来源名称 (2) [Chrome]`、`(3)` 等。每次导入均创建独立配置，不合并到已有配置。此自动命名路径允许重复来源，手动创建仍禁止重名。

当前支持 macOS Chrome 的数据库 schema 23／24 及 `v10` 加密。schema 24 的每个加密值必须通过完整 SHA-256 域名绑定校验；schema 23 按其旧格式处理，不猜测或盲目剥离前缀。未知加密前缀、枚举、域名哈希不符或不能完整保留的单条数据计入跳过数，不放宽校验。数据库 schema、快照或查询失败、Keychain 拒绝／不可用、总量超限、目标连接或未知协议错误仍终止整次导入。保留 host-only／domain、路径、HttpOnly、Secure、SameSite、session／有效期、priority、source scheme／port，以及分区 Cookie 的 `topLevelSite` 和 `hasCrossSiteAncestor`；同名 Cookie 的不同分区不会合并，分区信息也不会降级为普通 Cookie。目标回读逐项核对，不依赖写入命令成功作为唯一证据。

读取有明确上限：源数据库／WAL 各不超过 128 MiB，快照页总量不超过 128 MiB，最多 50,000 条记录，Cookie 值、域名、名称、路径及分区站点合计不超过 32 MiB；快照最多 5 秒，查询有取消和执行预算。拒绝符号链接的源 profile／数据库／WAL／SHM。快照和解密数据只在内存中处理，不生成 JSON、临时数据库、偏好或诊断中的明文 Cookie。目标数据由 CEF 按本 edition 的安全存储策略写入自己的 profile。

这是已保存 Cookie 的一次性副本，快照不包含 Chrome 尚未提交到磁盘的内存数据。密码、历史、扩展、localStorage、IndexedDB、Chrome 登录和同步状态不会迁移；依赖其他存储、设备绑定或服务端校验的站点可能要求重新登录。Chrome 之后的登录／退出不会持续同步到 OMP GUI。原扩展和 Cookie 文件导入已移除，旧 `[Chrome]` 配置及其来源标记继续保留。失败或取消不会改变配置列表／选中项；未发布的目标目录只在浏览器排空后清理。

## OMP 的页面归属

GUI 通过现有 `set_host_tools` 一并注册 `gui_browser`、文件上下文和文件定位工具。`gui_browser` 支持 `list`、`open`、`attach`、`select`、`close`，只查找请求来源会话的标签 UUID，不跟随此刻 UI 选中的其他会话。它返回原生 Browser 的 `open` 参数；OMP 用 `browser.open(result.open)` 附着后，继续用自身 Browser/Eval 完成观察、截图、输入、网络和取消。GUI 不实现另一个 Browser backend、MCP hub 或 worker 调度器。

CEF 在首次打开页面时启动，CDP 仅绑定 loopback 随机端口。新页面先使用随机空白 URL，GUI 通过 `/json/list` 获得真实 target ID，再开始用户请求的导航。OMP 的兼容修复按该 ID 精确匹配；同 URL／标题页面不混用，目标关闭后报错，不转向另一个标签。原生页面重建后返回带新 target ID 的句柄名；调用方必须重新 attach，不能复用旧句柄。

端口属于整个应用进程。会话路由不构成本机 CDP 客户端之间的权限隔离，任何有本机访问能力的其他客户端仍可能连接该端口。不同会话中的网页也有意共用当前 profile 的站点登录态。页面内容同样不能作为宿主权限或 agent 指令。

已审查的 SDK 为 npm OMP **18.13.3**，需要 **Bun 1.4.4 或更新版本**。应用把它复制到自己的 `browser/sdk-compat` 后应用逐文件 SHA-256 校验的修复；新增兼容辅助模块也校验哈希。全局安装保持只读。版本／源码不匹配时继续普通聊天和人工浏览，`gui_browser` 返回明确的兼容性错误，不尝试猜测性补丁。独立二进制仍使用其原生 RPC；没有 SDK 时不宣称具有这条自动化连接。

兼容层按 GUI 返回的 target ID 查询元数据，只由原生 tab worker 初始化页面，避免管理连接先行初始化并缓存失败的 Page。GUI 页面始终是借用对象，释放 OMP 句柄不关闭原生页面。隐藏页面在原生调用及录屏期间启用焦点模拟，结束后恢复；不选择标签或提升窗口。弹窗暂停渲染器时跳过焦点命令，先让原生 dialog API 处理答复。调用超时／取消时，旧 worker 在原有 CDP 会话中有界地 dismiss 弹窗，再由 OMP 重建 worker、停止导航及清理拦截；新会话不能接管已打开弹窗的回调。CDP 错误保留原因，原生 worker 继续拥有取消、回收和重试。其他浏览器后端不启用这些 CEF 专用行为。

`saveState`／`loadState` 的 Cookie 使用目标页面的 CDP 会话，避免落入 CEF 默认 context 的另一份 Cookie jar；导入后回读确认，未保留则失败。Web Storage 只恢复当前 origin，其他 origin 通过原生 `skippedOrigins` 返回，即使请求 `allowOtherOrigins` 也不在错误的 context 新建页面。OMP 18.13.3 的 state 格式仍不能保留分区 Cookie：GUI 路径拒绝此类导入／导出，不能用它替代上面的完整 Chrome Cookie 迁移。普通 Cookie 状态文件仍包含站点登录信息，按原生 OMP 文件语义保管。

原生 worker 恢复保留 `browser.open` 的下载目录、启动脚本、User-Agent、显式 viewport 和证书选项，并保留原生已有的域名白名单；恢复不重新导航初始 URL。附着时的显式 viewport 立即生效，省略时沿用页面原尺寸；复用已有句柄并显式更改 viewport 后，恢复采用新尺寸。`tab.run` 内临时变量、动态 emulation／路由等仍遵循 OMP 的 worker 重建语义，不能当成持久启动配置。

GUI 下载通过目标页面选择实际 CEF profile，下载事件仍由原生 OMP 处理。`waitForDownload` 会重新应用该标签配置的目录；重开并指定 `downloads` 可切换目录。OMP 自动化下载遵循原生同名文件替换语义，人工下载仍使用 GUI 的独立子目录；释放所有 OMP 下载句柄后恢复人工下载位置。CEF 的下载行为属于共享 profile，未认证多标签同时下载时不同目标目录的隔离。

证书忽略会话现在由 OMP 原生创建、保留并在关闭时 detach；GUI 不再修补 `open-options.ts`。仅显式 `ignore_https_errors: true` 才启用该标签的证书忽略，会话存续期间及 worker 恢复后有效；重开时传 `false` 或释放后按默认选项重开会恢复校验，兄弟标签不继承。兼容层持有原生页面会话，不修改系统信任或 CEF 全局开关。CEF 已报告当前主文档的 `ERR_CERT_*`、但尚未完成 `Page.navigate` 时，按请求／frame 身份把原始证书错误交给 Puppeteer，并有界停止失败导航，避免把拒绝伪装成导航超时；其他请求及子 frame 不触发此处理。

原生 iframe 修复保留截图坐标校正，并让直接字符串 `frame.evaluate` 在 frame 内执行。Eval 的远端工具错误保留所属 cell，延迟浮动 rejection 交给原生拦截器报告；真正的工作进程意外退出后，下次使用同一内核提示变量已丢失。此提示跟随应用语言，不把显式 reset 或取消当成崩溃。

调用约束：`browser.open` 的 `dialogs` 仅接受 `accept`／`dismiss`，GUI 默认省略；`setDialogs(null)` 恢复原生默认策略，confirm／prompt 等待答复，alert／beforeunload 可自动处理。需要先等待、再触发的下载以及手动弹窗流程应放在同一个 `tab.run`，不要跨同标签的串行外部调用互相等待。`frame.screenshot` 参数是元素选择器；截图差分输入须显式使用 PNG。网页默认权限拒绝与原生 CDP 的显式权限／坐标模拟是不同路径；模拟定位不代表系统真实定位授权，观察结果见[后续验收记录](archive/browser-recovery-state-2026-10-29.md)。

## 构建与依赖

[准备器](../scripts/browser_runtime.py)把固定 CefSwift 提交 `ba6ebff9e232529289662a84704ade1240563031` 和 [wrapper 补丁](../config/browser/cefswift.patch)放在本 worktree 的 `build.noindex/browser`。其 manifest 固定 CEF 154.0.34 / Chromium 154.0.8037.98，arm64 minimal 下载大小 132,210,884 字节；校验后转换 versioned framework、编译 helper。Xcode 使用这个本地 Swift package，构建阶段把 framework、五个 helper app 和许可证嵌入产物。

`make build` 自动准备依赖，仅编译未签名的本地 Dev 应用。首次直接打开 Xcode 前先运行 `python3 scripts/browser_runtime.py prepare`。所有下载、源码副本、helper 和构建缓存均在该 worktree 内，`make clean` 可清除。准备器不启动应用或访问用户 profile。

应用在 SwiftUI 之前安装 CEFApplication，实际 CEF 初始化仍是懒加载，Chromium sandbox 保持启用。退出先完成原有 OMP 保存／排空，取消并排空正在进行的 Cookie 导入，再关闭所有页面，等待 `on_before_close` 后在后续主循环执行 CEF shutdown。异常关闭超过 5 秒时让进程退出，不在仍有活跃 client 时调用 `cef_shutdown`。签名构建使用项目的 Developer ID、hardened runtime 和安全时间戳，按动态库、framework、helpers、主应用顺序签名；不调用上游 ad-hoc bundler。发布前仍须满足[打包前置条件](packaging.md)。

## 验证边界

功能检查 `workspace-browser` 不启动 CEF，检查 profile 列表／选择恢复、启动时固定配置、空白创建与损坏偏好恢复，以及应用网页链接的精确分类／默认打开方式／窗口归属／各原生入口派发／文件引用保留、地址规则、搜索编码／引擎偏好恢复、界面语言解析／偏好恢复／运行中语言保持、已打包的中英文文案和 CEF 语言资源、当前标签搜索及空／超限输入、同 URL 不同标签、会话／窗口归属、关闭、持久状态和资源上限；`settings` 检查浏览器设置的主窗口导航与草稿保留。`browser-bridge` 使用隔离 fixture 验证 SDK 副本与辅助模块、并发准备、版本／缓存拒绝、精确目标选择、旧目标、取消、有界恢复、焦点恢复及 Cookie 目标 context／回读。host tool 回归选 `workers`，静态检查选 `documentation harness syntax`。独立的 `native:browser-sdk` 只在 SDK 接入改动时显式选择，使用指定安装和隔离目录核对真实模块解析、Browser worker 导入、frame 调用执行、状态文件往返、实际 Eval 内核的远端 rejection／变量保留、意外重启提示及原始文件哈希，不启动 GUI 或模型会话。

`browser-cookie-import` 使用隔离的合成 Chrome SQLite/WAL、独立密码学向量和注入密钥，核对一致性快照、域名哈希、分区／安全属性、逐条跳过、明确拒收批次拆分、回读及清理被改写条目、统一跳过计数、整体故障／Keychain 拒绝／取消、来源命名、偏好恢复及扩展资源移除；不读取个人 Chrome 数据或钥匙串，不启动 Chrome、CEF 或 OMP。`workspace-browser settings` 覆盖配置及设置导航的相邻行为。真实系统权限／钥匙串授权、生产设置选择、CEF 实际接收新字段与进程重启后的登录仍需单独的现场验收。

`browser-downloads` 直接调用生产下载标记器，在隔离目录核对实际持久化的网页下载隔离、字节不变、无关本地产物不受影响和文件缺失错误；不访问网络、不执行下载内容。主应用及子进程不再自动给本地产物打标的进程级行为，需要以更新后的应用配置单独启动隔离探针或授权的实际应用验证，不能由这项文件级检查替代。

[原生导入交付记录](archive/native-chrome-cookie-import-2026-10-28.md)记录本轮构建、隔离功能检查、首次 fixture 失败及未完成的系统／浏览器验收边界。

[提示与配置删除记录](archive/browser-profile-settings-2026-10-28.md)记录完整文字的中英文宽窄离屏检查，以及配置删除、持久清理和符号链接保护的隔离证据；不替代可见窗口或真实进程重启验收。

[原型验收](archive/cef-browser-prototype-2026-10-27.md)及[iframe／弹窗修复验收](archive/cef-browser-repairs-2026-10-27.md)保留此前真实 OMP → CEF 的证据。[窗口关闭修复验收](archive/browser-window-close-2026-10-27.md)覆盖生产面板在 sandbox 开启下的首次创建、跨窗口移交、关闭和进程重启。中英文窄／宽布局、IME composition、VoiceOver、外部登录／上传、真实 OMP 会话连接与恢复、完整应用现场重启、Developer ID 包和能耗仍需单独验收。

[共享 profile 验收](archive/browser-shared-profiles-2026-10-27.md)通过本机 HTTP 表单登录及五次真实 CEF 进程启动，核对 HttpOnly 持久／会话 Cookie 的服务端认证、localStorage、IndexedDB、跨会话共享、重启切换、空白隔离和双向切回恢复，并用 CUA 实际操作中文设置页。该结果不代表外部网站 OAuth 或签名 Keychain 已验收。

[Chrome 迁移评估](archive/chrome-profile-migration-2026-10-27.md)记录独立临时 Chrome profile 的目录复用／复制与公开接口迁移实验。[旧扩展流程验收](archive/chrome-cookie-import-2026-10-28.md)保留已移除方案的真实 Chrome／CEF 历史证据，不能代替当前原生源读取、系统权限及新增属性的现场验收。

自动化修复的确定性证据与剩余现场范围见[首轮记录](archive/browser-automation-repairs-2026-10-28.md)及[恢复配置、下载与证书记录](archive/browser-recovery-state-2026-10-29.md)。生产面板的 OMP 定向验收使用 `tests/acceptance/workspace_browser.py --automation`；加 `--run --omp /absolute/path/to/omp` 才会启动，须取得 owner 明确授权，步骤见[验收入口](../tests/acceptance/README.md)。
