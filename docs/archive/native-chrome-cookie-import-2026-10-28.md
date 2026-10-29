# 原生 Chrome Cookie 导入（2026-10-28）

本轮将扩展／JSON 导出入口替换为 macOS 原生读取。下列首轮证据保留当时的整批拒绝策略；同日后续的逐条跳过改动见本文后续记录。当前用法以[工作区浏览器](../browser.md#从-chrome-一次性导入-cookie)为准；旧扩展的[可见验收](chrome-cookie-import-2026-10-28.md)保留历史证据，不作为新读取路径的验收。

## 实现与边界

- 明确选择 Chrome profile 后，只读连接其 `Network/Cookies` 或旧 `Cookies`。SQLite 备份 API 将包含已提交 WAL 的固定读事务快照复制到内存；快照结束即释放源连接，系统授权期间不持有源数据库锁。拒绝 profile、数据库及 sidecar 符号链接，并检查复制前后的文件身份。
- 使用 Security API 读取 `Chrome Safe Storage`，通过 CommonCrypto 解密 macOS `v10`。支持已知 schema 23／24；24 必须校验 SHA-256(host_key)，23 不猜测或剥离哈希。未知格式、损坏数据、错误密钥或域名不匹配均拒绝整次导入，仅过期行允许计数后跳过。
- 保留 Cookie 的域／host-only、路径、值、HttpOnly、Secure、SameSite、会话／到期时间、priority、source scheme／port，以及 partition top-level site 和 ancestor bit。目标通过精确页面 context 的公开 CDP 分批写入并回读比较，只有完整确认后才发布新的 `[Chrome]` profile。当前运行 profile 保持原身份，重启才应用新选择。
- 不生成 Cookie JSON 或磁盘快照，不缓存密钥或在偏好／错误中记录 Cookie 值。capture 模式固定使用自身合成源目录，禁止读取真实钥匙串。扩展资源、文件选择入口及对应退休驱动已移除；现有导入配置继续保留。

源格式依据为 [Chromium macOS OSCrypt](https://raw.githubusercontent.com/chromium/chromium/130.0.6723.58/components/os_crypt/sync/os_crypt_mac.mm)、[Cookie SQLite 格式](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/net/extras/sqlite/sqlite_persistent_cookie_store.cc)及[分区键序列化](https://raw.githubusercontent.com/chromium/chromium/main/net/cookies/cookie_partition_key.cc)。快照使用 [SQLite Backup API](https://www.sqlite.org/backup.html)，目标使用 [CDP Network](https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/pdl/domains/Network.pdl)。不依赖 Codex 的私有浏览器导入接口。

## 已执行验证

工作树使用 Swift 6.4、macOS 27.2、固定 CEF 154，Dev 版本 0.1.328 / build 329。一次 `make build` 成功；未启动主应用、Chrome 或 CEF，也未读取个人 Chrome 数据／Keychain。

| 范围 | 结果与含义 |
| --- | --- |
| `browser-cookie-import` | 54 项通过；独立 Node.js 加密向量、真实合成 SQLite/WAL、提交／未提交隔离、快照后续写入隔离、源文件不改写、严格哈希及未知格式失败、不同祖先位／站点分区、目标回读比较、取消与偏好不变 |
| `workspace-browser` | 127 项通过；相邻配置和标签归属，不启动 Chromium |
| `settings` | 34 项通过；设置导航及离屏状态，不启动主应用 |

功能报告位于本 worktree 的 `build.noindex/verification/runs/20261028T031055Z-a295203a/report.json`。首轮 `20261028T030920Z-e46a4975` 失败是 fixture 错误：错误 Cookie 的修改未提交，而独立只读连接正确看不到它；修正为提交变更再断言，未放宽生产行为或断言，并保留了单独的未提交数据隔离用例。应用源码未因此改变，复用了已通过的构建证据。

提交前另选 `make verify TIER=static AREAS="documentation harness syntax"`，覆盖文档链接、登记及工具语法；不追加 native OMP、GUI、兼容矩阵或性能负载。

## 仍需现场验收

本轮的目标回读比较使用合成 CDP 数据，未实际启动 CEF。真实系统文件授权、Keychain 允许／拒绝／取消及退出时系统授权窗口的排空、正式签名包、生产设置来源选择、目标 CEF 对新增 source scheme／port／priority 的实际保留、进程重启后的真实服务端登录仍需 owner 另行授权验证。既有扩展流程的 CEF 证据不能替代这些新增边界。

快照仅覆盖 Chrome 已提交到磁盘的 Cookie，不包含尚在 Chrome 内存中的更新；其他站点存储、设备绑定凭据和服务器状态不在 Cookie 导入范围。此交付不声称任意外部网站完整免登录迁移。

## 同日后续：跳过不可用的单条 Cookie

Dev 0.1.336 / build 337 将行级字段、解密、域名哈希和重复项错误计入跳过数，继续保留其他有效 Cookie；schema、快照、SQLite 查询、Keychain、总量限制与目标连接错误仍终止导入。严格校验及分区属性不降级，全部不可用时不创建空配置。界面只在结果中追加“跳过 xx 个”，不列原因；零跳过时不显示这一项。

目标只使用全新、未发布且初始为空的页面 context。仅 `Network.setCookies` 的明确参数拒收允许二分隔离；其他协议错误不重试。回读按身份和属性筛选实际完整保留的子集；若存在被改写或意外留下的条目，清空该新页面所属 storage partition 并重写已确认子集，再回读核对。已发布、待删除及当前生效的 profile ID 在读取源数据前拒绝。清理范围依据 [Chromium NetworkHandler](https://raw.githubusercontent.com/chromium/chromium/main/content/browser/devtools/protocol/network_handler.cc) 的 `storage_partition_` 实现核对。

首轮 Dev 0.1.335 / build 336 的 `make build` 成功。`make verify AREAS="browser-cookie-import"` 的 85 项检查通过，报告为 `build.noindex/verification/runs/20261028T054841Z-2c5551a9/report.json`。新增覆盖部分损坏／全部不可用、未知加密、字段损坏、重复项、单条超限、schema 故障、明确拒收拆分、静默丢弃／改写后的新 context 清理、传输／回读失败不重试、已有目标不清空及简短计数文案。未启动 GUI、Chrome 或 CEF，未访问个人 Chrome／Keychain；真实系统和浏览器现场验收范围保持如上。

同步 `main` 已有的工具图标更新后，最终 Dev 0.1.336 / build 337 增量构建成功。Cookie 源码和功能测试输入未改变，复用上述 85 项结果；仅对更新后的文档树另选静态链接检查。
