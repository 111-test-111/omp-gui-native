# Chrome profile 与登录态迁移评估（2026-10-27）

owner 要求先调查、测试系统 Chrome profile 的直接复用与 Cookie／登录态迁移，再决定是否添加设置。本次仅增加独立手动研究驱动及证据，没有修改生产设置、profile 选择、CEF 配置或应用版本。

## 结论

| 方案 | 本次结果 | 产品判断 |
| --- | --- | --- |
| Chrome 与内嵌 CEF 同时打开同一数据根 | 失败，CEF 初始化返回 24，没有创建独立页面 | 不提供“直接使用正在运行的 Chrome profile” |
| 关闭 Chrome 后复制整份 profile | localStorage／IndexedDB 恢复，但 5 个加密 Cookie 均未恢复，服务端登录失效 | 不把复制目录作为可靠登录迁移入口；还有版本与配置兼容成本 |
| 通过公开 Cookie 接口导出并重新写入新 CEF profile | 5 个 Cookie 的 HttpOnly、Secure、SameSite、session、host/path、分区键均保留；登录及重启恢复通过 | 一次性 Cookie 导入具有可行性；源端授权导出入口仍需设计与验收 |
| Cookie 之外的站点存储 | Cookie 导入不带入 localStorage／IndexedDB；分别按 origin 复制测试记录后可恢复且重启保留 | 不承诺“完整登录态迁移”；通用复杂数据结构没有在本次得到验证 |

推荐下一步讨论的是**向新建 OMP GUI profile 一次性导入所选站点的 Cookie**。源端优先使用用户明确授权的 Chrome 扩展公开 API；目标端使用精确页面所属 context 的公开 Cookie 接口并由 CEF 写入自己的存储。实际默认 Chrome profile 的导出、第三方站点及签名 Release 尚未验收，因此本次不添加设置。

## 调查依据

### 原目录直接复用

Chromium 的[用户数据目录](https://chromium.googlesource.com/chromium/src/+/HEAD/docs/user_data_dir.md)包含多个 profile 及安装级状态。CEF 对[数据根](https://cef-builds.spotifycdn.com/docs/154.0/structcef__settings__t.html)实施进程单例锁，官方说明并发写同一数据根可能损坏数据。目录不能简单视为可同时挂载的独立登录文件。

本机安装 Chrome 156.0.8078.48，OMP GUI 固定 Chromium 154.0.8037.98。Google 的[企业目录文档](https://support.google.com/chrome/a/answer/9866158?hl=en)也提示不同版本／渠道使用同一 profile 可能损坏数据。本次没有退出、挂载或写入正在运行的日常 Chrome，只对由本驱动创建的临时 Chrome 数据根测试单例冲突。

### Cookie 加密与文件复制

Chromium 的[macOS Keychain 实现](https://raw.githubusercontent.com/chromium/chromium/main/components/os_crypt/common/keychain_password_mac.mm)按品牌分别使用 `Chrome Safe Storage` 和 `Chromium Safe Storage`。应用的[固定 wrapper 策略](../../OMPGUI/Services/Browser/EmbeddedBrowserRuntime.swift)在 Debug 使用 mock keychain，Release 使用真实 Chromium Keychain。复制数据库不会自动使目标引擎获得源端密钥。

本次源 Chrome 没有使用 mock keychain；它自行加密测试 Cookie，研究驱动未提取 Keychain 密钥。源和目标的 Cookie SQLite schema 均为 24。复制关闭后的临时 Chrome 数据根后，站点的两个存储 API 仍能读出数据，但 CEF 的 Cookie 接口返回空，认证失效。这说明“profile 目录存在／页面能打开”不能作为登录迁移成功的证据；本次结论范围为当前 macOS、Chrome 156 → Debug CEF 154，不能推广为所有版本和签名策略都必然失败。

### 获取默认 Chrome 的 Cookie

Chrome 从 136 起[拒绝对默认用户数据目录启用调试端口／管道](https://developer.chrome.com/blog/remote-debugging-port)，要求非默认 `--user-data-dir`。因此不能把本次测试使用的隔离 CDP 导出路径等同于“无交互读取正在使用的日常 Chrome 登录态”。

[Chrome Cookies 扩展 API](https://developer.chrome.com/docs/extensions/reference/api/cookies)可以表示 HttpOnly、session、hostOnly、SameSite 与 partitionKey，要求 `cookies` 和相应站点 host 权限。**扩展是待评估的公开源端入口，本次没有安装扩展或授权它读取任何个人站点。** 导出 `document.cookie` 无法覆盖 HttpOnly 登录 Cookie。[标准导入导出指南](https://support.google.com/chrome/answer/96816?hl=en)也没有提供可直接依赖的完整站点登录态导出格式。

另一条候选路径是用户授权读取 Chrome Keychain 后对离线 Cookie 数据库解密并重新导入；它依赖内部数据库格式及系统权限，本次未读取密钥、未实现和测试这条路径，不建议作为首版默认方式。

### 登录不一定只由 Cookie 决定

localStorage 和 IndexedDB 必须另行处理；本次只覆盖 JSON 可表示的一组存储记录，未覆盖任意 IndexedDB 索引／事务／Blob／CryptoKey、跨 origin 或分区存储、Service Worker、sessionStorage、浏览器账号同步及 Passkey。网站还可以使用[设备绑定会话](https://developer.chrome.com/docs/web-platform/device-bound-session-credentials)等机制，刷新时需要证明持有原私钥；成功复制 Cookie 不等于能一直续期。这里不判断任一实际站点是否启用了这些机制。

## 真实浏览器测试

环境为 Apple Silicon、macOS 27.2、Swift 6.4、Node 24.14.1。源端使用本机安装的 Google Chrome 156，目标端使用项目固定 CEF 154.0.34 和同一份已审查的 CefSwift 补丁，sandbox 开启。独立探针保持 Debug 的 mock keychain 策略，不编译或安装主应用。

[手动驱动](../../tests/acceptance/chrome_profile/run.py)创建随机端口的本机 HTTP 登录页、独立 Chrome 用户数据根和 CEF profile。源浏览器实际提交登录表单，服务器设置持久／会话、Secure `__Host-`、Partitioned 以及限定路径的五个 Cookie；站点另保存 localStorage 和 IndexedDB。HTTP loopback 被浏览器视作可信本地来源；未忽略证书错误，也未关闭 sandbox。

| 证据 | 实测内容 | 原始位置 |
| --- | --- | --- |
| 目录复用与复制 | 活跃源根阻止独立 CEF；关闭后的副本保留两个站点存储，但丢失全部 Cookie 登录 | `build.noindex/chrome-profile/runs/20261027-233303-522939/` |
| 迁移与重启 | 12 项浏览器行为断言通过：源端真实登录、HttpOnly／Secure／分区 Cookie 导出、目标初始空白、Cookie 导入即恢复服务端认证、独立站点存储、Cookie 属性保留、目标有序关闭及进程重启恢复 | `build.noindex/chrome-profile/runs/20261027-233430-937325/summary.json` |
| 写盘诊断 | 单独核对所选 `Profile-migration`：5 个 Cookie 均为加密值，明文列全部为空；schema 24 | 同目录 `database.json` |

已保存[结构化评估结果](../evaluations/2026-10-27-chrome-profile-migration/summary.json)，其中按证据分别记录成功事实与驱动诊断的失败／修正，未将失败运行冒充整体通过。原始 fixture 和 Cookie 值只存在本 worktree 的隔离生成目录；检入结果仅含测试 Cookie 的属性及数量。

## 驱动修正及停止范围

1. 初始 Node 参数规范化误把 `path.resolve` 直接传给 `Array.map`，导致多传参数；在浏览器启动前修正。
2. `Storage.*` 的 context 参数先误用于 page endpoint，改用 browser endpoint 后，CEF 自定义持久 profile 的 target context ID 又不属于该端点可查找的 context。源端／目标端最终使用附着到确切页面的公开 `Network.getCookies`／`Network.setCookies`，接口定义见[CDP Network](https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/pdl/domains/Network.pdl)。这避免导入全局默认 profile。
3. 12 项浏览器行为断言完成后，末尾数据库探测错误选择全局 `Default/Cookies`，那里为空。修正为具名 `Profile-migration` 后，仅用 `--case database --inspect-run` 重跑离线诊断，确认 5 个加密 Cookie；没有重复通过的浏览器启动／重启负载。原迁移报告保留该诊断失败，独立诊断报告记录修复后的通过。

所有探针均已退出。未迁移真实账号、未改变默认 Chrome 的调试／扩展／Keychain 权限，未对任何外部网站发起登录，也未修改 GUI 设置。外部网站成功率、真实默认 profile 的用户授权导出、正式 Keychain、跨版本／跨平台、复杂站点存储和完整生产 GUI 迁移界面仍是后续验收范围。
