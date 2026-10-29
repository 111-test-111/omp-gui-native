# Chrome 扩展一次性 Cookie 导入验收

此记录保留当时已验收的扩展方案。该方案及其驱动现已由[原生 Chrome Cookie 导入](../browser.md#从-chrome-一次性导入-cookie)替换；以下历史结果不代表新源读取、系统授权或新增字段已通过现场验收。


日期：2026-10-28（Asia/Hong_Kong）。Dev 0.1.325 / build 326。Apple Silicon、macOS 27.2、Google Chrome 156.0.8078.48、CEF 154.0.34 / Chromium 154.0.8037.98，sandbox 开启。

本次 owner 要求打通 Chrome 扩展授权导出所选站点、设置导入新 profile、重启生效的完整流程，并补充手动禁止重名、自动创建例外。当前使用方法见[浏览器指南](../browser.md#从-chrome-一次性导入-cookie)；实现及驱动的 SHA-256、字段与检查结果保存在[脱敏证据](../evaluations/2026-10-28-chrome-cookie-import/summary.json)。

## 实现与边界

- 随应用附带 Manifest V3 扩展，通过原生 Chrome 扩展页面加载。必须权限仅 `activeTab`；导出点击时请求 `cookies` 及所选域名的 HTTP／HTTPS 访问，读取后在 `finally` 撤销。可选的 `identity`／`identity.email` 只用于单独点击账号填充，随后撤销；CSP 禁止网页网络连接，无上传端点。
- 导出采用 `chrome.cookies`，保留 HttpOnly、Secure、SameSite、session／expiry、路径与分区键。只保存用户所选域名匹配的 Cookie；Chrome 站点权限覆盖同域的协议／端口范围，Cookie 本身也不按端口隔离。
- 扩展无法读取本地 Chrome profile 显示名称；本次填写合成名称 `OMP Cookie Test`。使用 Chrome 账号功能可填入账号邮箱，未登录 Chrome 或要用自定义名称时手动填写。没有读取系统 Chrome 数据库或解密 Keychain。
- Core 验证版本、大小、数量、域名范围及 Cookie 安全约束。Services 在全新 UUID 的隐藏 CEF profile 中通过精确 page target 的公开 `Network.setCookies` 写入，使用 `Network.getAllCookies` 核对每项值及元数据，关闭并排空宿主。App 成功后才追加配置并保存下次启动的选择。Cookie 不写入偏好、诊断或明文中转库；用户下载的 JSON 本身包含登录凭据。
- 退出取消正在进行的导入并等待关闭；若隐藏宿主 5 秒内未收到关闭完成，不删除仍在使用的目录，并和普通页面关闭超时一样跳过 `cef_shutdown`，交由进程结束释放。后续导入拒绝使用这个未排空的运行时。
- 手动 profile 名称去首尾空白、不区分大小写比较，重复时不创建、不改变选中项。自动导入命名 `来源 [Chrome]`；碰撞时使用 `来源 (2) [Chrome]` 等，每次独立 UUID。旧版已有同名记录保留。

导入仅复制 Cookie。密码、历史、扩展、localStorage、IndexedDB、Chrome 同步及账号状态不迁移；不存在后续双向同步。站点可能依赖设备绑定、其他存储或服务端重新认证。

## 实际可见流程

历史驱动 tests/acceptance/chrome_cookie_import.py（见 Git 提交 62678187b）链接本 worktree 的生产 Dev 模块，以独立 capture 库和偏好 suite 显示中文 `BrowserSettingsPage`；另准备官方已安装 Chrome 的原样 APFS app 副本和全新用户数据根，便于 CUA 按绝对 app 路径准确操作。没有读写日常 Chrome profile、日常 GUI 库或真实账号。

1. CUA 在生产设置中创建 `OMP Cookie Test [Chrome]`。再输入 `  omp cookie test [chrome]  `，界面显示“已存在同名浏览器配置。”且创建按钮禁用，取消后没有新增记录。
2. 点击“保存扩展…”，使用原生目录选择器保存随包资源。在本次 Chrome 的 `chrome://extensions/` 启用开发者模式、加载已解压的文件夹，真实扩展 `OMP GUI Cookie 导出工具` 安装成功，无错误。
3. 本机 HTTP fixture 已通过 Chrome 页面表单登录，响应设置持久、会话、Secure／`__Host-`、分区及限定路径共 5 个 Cookie；另放入未选择的 `localhost` Cookie，验证过滤。
4. 在真实站点点击扩展、填来源名称，点击导出后先拒绝 Chrome 的站点权限。界面显示“未获得 Chrome 访问授权，没有导出 Cookie。”。重试并允许后下载 JSON，状态显示“已导出 1 个所选站点的 5 个 Cookie，并撤销临时访问权限。”；检查真实 `chrome.permissions.getAll()` 确认 Cookie 权限和 origins 均已撤销。JSON 中有完整分区键且无未选域名。
5. 在生产设置的原生文件选择器选择这份真实导出，首次预览显示 `OMP Cookie Test (2) [Chrome]`、1 个站点、5 个有效 Cookie、0 个过期 Cookie。确认后真实设置页显示成功及重启提示。当前页面仍在默认 profile，服务端仍判定未登录，没有将导入 Cookie 写入当前浏览器。
6. 沿生产关闭路径排空隐藏导入宿主及页面，CEF 正常关闭。第二个生产面板进程从同一隔离偏好读取导入配置；本机服务端判定已登录，并逐项核对全部 Cookie 的值、domain、path、HttpOnly、Secure、session、SameSite、有效期（1 秒容差）及 partitionKey。随后再次正常排空退出。

首次真实扩展证据目录为 `build.noindex/chrome-cookie-import/20261028-002144-686818/`。修复预览后，仅重跑受影响的设置导入及重启，复用同一份未过期的真实 Chrome 导出，目录为 `20261028-003028-813365/`。最后源码检查补上关闭超时保护，以 `20261028-004213-786254/` 单独验证启动中取消，再在 `20261028-004224-721529/` 复核最终构建的正常设置导入及重启。最终 `summary.json` 明确记录 `exportReusedFrom`，没有把复用称为第二次扩展导出。所有本次隔离进程均已退出。

## 检查与发现的修复

先选择一次增量构建、`browser-cookie-export browser-cookie-import workspace-browser settings` 功能范围及单独的可见验收；未运行全套检查、OMP 集成或性能负载。

| 检查 | 结果 |
| --- | --- |
| 扩展 API 替身 | 所选站点、授权拒绝、读取失败后撤销、去重／过期、分区与英中文案通过；所在首轮报告后续 Swift 检查失败，不把整份报告标作通过 |
| Cookie 导入功能 | 修复后 33 项断言通过 |
| 共享浏览器回归 | 127 项通过 |
| 设置导航 | 34 项通过 |
| 真实扩展 | 5 组检查通过，另有 CUA 拒绝／允许界面观察 |
| 生产设置导入 | 6 组检查通过 |
| 生产浏览器进程重启 | 5 组检查通过，包含真实服务端登录及全部 Cookie 属性 |
| 原生启动中取消 | 3 组检查通过：不发布配置、关闭后清理新目录、生产退出排空 CEF |

首轮功能检查暴露保存后重新加载配置时丢失 `chromeSourceProfile`，造成配置不相等；生产载入规范化补上来源字段后，仅重跑失败及关联检查并通过。首轮可见文件选择暴露 SwiftUI 惰性 popover 只在弹窗树读取可选 payload，首次出现空白；改为在呈现视图 body 读取 payload，增量构建后首次选择、预览、导入及重启通过。没有放宽断言或绕过实际设置入口。

最后源码检查发现导入关闭超时原先未反馈到 registry，可能在仍有导入 client 时调用 CEF shutdown；改为传播排空结果，目录清理和后续导入同时受保护。启动中真实取消及最终正常导入／退出均通过；没有人为让 CEF helper 挂起，也不把正常取消结果称为强制超时的实测。

功能报告分别在 `build.noindex/verification/runs/20261027T161414Z-75f18121/`（导出通过，随后导入失败）及 `20261027T162011Z-5c818ac4/`（导入／共享浏览器／设置通过）。后续只变更预览状态读取，以修复后可见流程补充验证，复用其未受影响的功能证据。文档与新增验收工具选择 `make verify TIER=static AREAS="documentation harness syntax"`。

## 未扩张的结论

本次证明真实 Chrome 扩展读取授权、生产设置导入与 CEF profile 进程重启可以打通；源账号及 Cookie 均为本机合成 fixture。未测试外部网站、Chrome 账号自动填充、已签名 Developer ID／Keychain 包、完整聊天应用的现场重启、中英文全部尺寸、VoiceOver 或能耗。Chrome 最低版本声明为 130，本机只验证 156，没有追加版本矩阵。扩展目前需要用户加载解压文件夹，没有发布应用店。
