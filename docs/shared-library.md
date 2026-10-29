# 数据、配置与 edition 隔离

Release 与 Dev 各自拥有 GUI 库和偏好；两版均使用外部活动 OMP profile。文件夹名来自 [AppInfo](../OMPGUI/Core/Support/Text.swift)，不是继承的 Tivano 名称。

## 数据归属

| 内容 | Release | Dev |
| --- | --- | --- |
| Bundle ID / 偏好域 | `dev.ompgui.mac` | `dev.ompgui.mac.dev` |
| GUI 库 | `~/Library/Application Support/OMP GUI Native` | `~/Library/Application Support/OMP GUI Native Dev` |
| GUI state | `~/.omp-gui-native` | `~/.omp-gui-native-dev` |
| GUI GitHub token 的 Keychain service | `OMP GUI Native` | `OMP GUI Native Dev` |
| OMP 配置、模型账号和 MCP 凭据 | 外部活动 OMP profile | 同一外部活动 OMP profile |

`AppKeychain`仅保存 GUI GitHub 连接所用 token；没有 GUI 自管的模型 API key 或 MCP 凭据。切换 Dev 不会隔离项目文件、系统账号、OMP profile 或外部服务。实验使用独立项目和隔离 profile。

[Storage](../OMPGUI/Services/Store/Storage.swift)保存 GUI 数据：
- `library.json`：项目、会话索引及界面元数据。
- `threads/<UUID>.json`、`threads/<UUID>.turns/`：GUI 会话头、分段轮次、时间线及显示状态。
- `tasks/<UUID>/workspace/`：独立任务的持久工作目录，不作为虚拟项目写入项目列表。
- `attachments/`：显式导入的附件；`file-previews.json`：有界预览状态。
- `omp/sessions/`：通过 `--session-dir`交给 OMP 保存的原生会话及产物；GUI 的 resume 身份是原生 `sessionFile`。
- `omp/requests/`：未来请求的私有采集 sidecar，保存有界、脱敏的上下文／载荷／响应／输出和进程租约；以原生日志路径、会话头 ID 与当前分支锚点关联，原子保存并按数量、容量及 30 天期限清理。失败标记按会话规范化路径命名，只标记该会话并在 24 小时后失效。详见[会话记录](file-preview.md)。
- `omp/runtime/`：每个进程的私有 config overlay 和扩展文件，正常释放时删除。
- `wallpaper/`和 token 活动文件：GUI 附属数据。

state 中保留 `worktrees/`、`patches/`兼容路径；它们不能说明当前原生 worker 的实际隔离位置。worker 路径和应用结果以 OMP 报告为准。

## 索引恢复与保存

每次成功读取资料库后保留 `library-previous.json`。少量索引条目损坏时，原文件先备份为 `library-before-recovery-*.json`，不可读及重复身份的原始记录另存为 `library-quarantine-*.json`；其余记录恢复后只安排一次正常保存。文件整体损坏时尝试上次启动的可读副本。核心列表缺失、疑似不兼容格式或备份失败仍阻止覆盖原索引，沿用独立 recovery 文件和人工修复提示。

第一次把包含独立任务的索引写入已有 `library.json` 前，原子保留 `library-before-standalone.json`；历史轮次与附件不迁移。损坏的轮次文件先移到 `threads/Unreadable/` 再写新版本。同步退出／历史操作保存会合并排队中尚未写出的 dirty 轮次，避免只保存最新快照时丢失前一轮。空闲会话回收使用原有异步保存路径，保存成功后重新核对运行时身份、选中状态及未保存修改，再释放；失败保持会话可恢复。

## 长期记忆

设置 → 记忆默认关闭，需手动开启 Mnemopi。开关及召回/保存、语言和预算保存在当前 GUI edition 的偏好中，通过原生会话覆盖生效，不改写外部 profile。数据仍由 OMP 保存在原生 Mnemopi 数据库；若两版使用同一 OMP profile 和数据库路径，开启后会访问同一份记忆。

默认采用项目记忆＋全局共享召回。同仓 worktree 的稳定身份是规范化后的 Git 公共目录；独立克隆隔离。非 Git 项目按规范化目录区分。旧的按 cwd 分区的记忆库保留，不自动搬迁。全局偏好由原生工具以 global scope 显式保存。

全局记忆文件与所选会话是否属于项目无关；独立任务首次发送前也可读取列表与预览。读取继续复用当前会话的原生 OMP 连接，启动前会准备应用自有的任务工作目录，不发送输入、不清除草稿，也不将任务添加为项目。用户项目目录缺失时仍报告原生连接错误，不自动重建用户目录。

更改前需等所有会话空闲，OMP 完成保存并退出连接后才持久化新设置。下次请求使用新配置。关闭保留已保存记忆和历史会话，但移除新请求中的记忆工具和原生记忆提示词；再次开启不追溯保存关闭期间的轮次。记忆设置页首次打开时自动读取文件列表，内存中缓存所选会话/配置对应的全局共享库文件元数据；重开页面复用缓存。列表不提供刷新按钮；首次加载时，「记忆文件」文字右侧显示小 spinner，文件列表出现后停止，空结果或失败也结束加载状态。读取期间保留控件外观，不插入等待文案；更改配置仍受原生空闲与保存排空检查保护。列表只展示全局库，运行时仍使用项目＋全局记忆。预览从按钮处弹出，使用原生只读文本阅读器显示来源、日期和正文，不提供搜索。刷新按钮保留在预览窗口内，重新读取当前文件内容，加载期间保留已显示的正文与阅读位置。预览通过 OMP 公共 SDK 的数据库句柄列出近期保存条目（含历史记录），最多 50 条、正文总计 64 KiB。GUI 不执行数据库写入语句。切换会话或配置会关闭预览并清除缓存；关闭设置仅关闭预览，保留文件元数据缓存。迟到回复不能重新填充旧会话或关闭状态的缓存。OMP 自动保留的对话片段也属于记忆，可能被原生召回。具体接入边界见[原生指南](OMP_INTEGRATION.md#native-mnemopi-memory)。

## OMP 配置范围

[原生设置服务](../OMPGUI/Services/Providers/OMPNativeSettings.swift)通过 `omp config path`识别活动 agent 目录，使用 `omp config list --json`与 `omp config set`读写允许的设置。表单写入活动 profile；项目、环境及聊天 overlay 可能覆盖实际生效值。GUI 不切换外部活动 profile。

模型与账号属于 OMP 的 `models.yml`、认证存储及原生登录流程。不要把配置或凭据复制到 GUI 库，也不要将用户 profile 放入仓库。原生 discovery/profile 规则由安装的 OMP 决定。

| GUI 编辑入口 | 原生目标与保护 |
| --- | --- |
| 模型角色、task 参数 | 原生 CLI；核对 profile、可执行文件/环境身份和配置指纹；保留未知字段 |
| 自定义附加提示 | 原生 shared-config base 的 `APPEND_SYSTEM.md`；UTF-8、原子保存、外部修改与 symlink 重定向检查 |
| MCP | 设置仅管理通过 `omp config path` 定位的活动 profile `mcp.json`，不读取或修改项目 MCP；快捷目录保存普通原生定义，显式登录由 OMP 公共 SDK 完成，token 及 DCR 密钥留在原生凭据库，GUI 只保存引用；保留未知字段、环境/header/OAuth 定义，校验原始字节和 profile 身份后原子私有写入 |

`APPEND_SYSTEM.md`使用 OMP 的 shared-config base：profile / `PI_CONFIG_DIR`参与定位，单独的 `PI_CODING_AGENT_DIR`覆盖不会将该文件重定向过去。编辑在下次原生会话启动时生效。[接入指南](OMP_INTEGRATION.md)说明具体写入边界。

## 启动、租约与恢复

[LibraryAccess](../OMPGUI/App/LibraryAccess.swift)在读取偏好/库前检查目录并取得 edition 的独占 lease；[LegacyMigration](../OMPGUI/App/LegacyMigration.swift)只创建当前目录、拒绝库/state symlink，不导入 Tivano、Tivano Dev 或 Droppy Code 数据。历史 `scripts/separate_data.py`已不存在，不能用于本 fork。

租约文件仍沿用 `Application Support`下的 `.tivano-library.lock`、`.tivano-migration.lock`和 `.tivano-{dev,release}-library.lock`兼容命名。这不读取旧产品数据，但可能与旧版进程的锁冲突。按确切进程定位问题；不要删除持锁文件，避免产生第二个 inode 并失去互斥。

主窗口每次切换会话时在当前 edition 的偏好中保存所选会话，重新启动后优先恢复退出前选中的会话；后台更新或中断状态不会抢占选择。库加载期间已明确选择的会话保持不变。首次使用、保存的会话已删除/归档或仅在浮动面板中显示时，回退到上次项目中最近活跃的普通会话；没有可用会话则显示空状态，不自动新建。

GUI 文件读取失败不等于新空白会话。[Storage.setAside](../OMPGUI/Services/Store/Storage.swift)及运行时恢复路径尝试保留原字节；无法安全保留时阻止后续发送/保存，保留可读内容和草稿。排查磁盘/权限后再重开，不用空 JSON 覆盖损坏文件。

备份应在对应实例退出、写入停止后复制整个 edition 库；只复制 `library.json`不足以包含轮次、附件和原生日志。备份不是自动迁移授权。不要从另一个 edition 或其他产品恢复数据，不扫描旧会话进行批量回填。

## 清理边界

`make clean`只删除当前 worktree 的 `build.noindex`；不会清除此处的库、state、偏好、Keychain 或 OMP profile。删除 worktree 同样不会清理应用数据。捕获和验收的隔离存储由各驱动明确设置，正常启动应用不会自动进入隔离模式。

原生 profile 的权限、MCP 连接和外部账号问题见[故障排查](troubleshooting.md)。不要为普通构建、测试或文档工作执行用户数据清理。
