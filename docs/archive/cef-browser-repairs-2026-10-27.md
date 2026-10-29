# CEF iframe 截图与 CDP 对话框修复（2026-10-27）

Owner 要求继续定位并修复[扩展验收](cef-browser-capabilities-2026-10-27.md)中的 iframe 截图错位和对话框阻塞，并推进验证。本轮仍是独立可见原型，未把 CEF 加入生产 GUI target。

结果：两个缺口在明确的原型范围内闭合。[40 项检查及图像证据](../evaluations/2026-10-27-cef-repairs/summary.json)来自三次有范围的运行：六种 frame 组合的 25 项断言、取消／关闭恢复的 5 项断言、对话框和带弹窗退出的 10 项断言。通过证据按相关路径复用，没有为了得到一次全绿而重跑未受影响的完整矩阵。frame 所在运行的后续 dialog 失败不计为通过，JSON 明确区分该运行状态与通过的 frame 子集。

## 交付方式

- OMP 18.12.5 的真实 SDK、Eval、Browser 和 worker 继续执行工具；[依赖补丁](../../tests/acceptance/cef_browser/patches/README.md)在 `build.noindex/cef-prototype/dependencies/` 的独立源码副本应用。没有修改全局安装的 OMP，也没有另写 Browser backend、CDP 代理或覆盖页面的 `alert/confirm/prompt`。
- CefSwift 基于 `ba6ebff9e232529289662a84704ade1240563031`，使用相同的 CEF 154.0.34 / Chromium 154.0.8037.98 二进制。SwiftPM 编译修复后的 wrapper；原型显式启用 `useCDPJavaScriptDialogs`。
- 原始版本和每个补丁输入的 SHA-256 由 manifest 固定；准备器拒绝不匹配的源码。OMP 的 node_modules 只读复用，原始 SDK 文件哈希再次核对一致。副本保留原始许可证，补丁目录也附有 MIT 许可和版权归属。
- 所有页面、上传内容及状态均为 loopback fixture；没有发送模型请求、使用日常账号或启动子代理。运行后未保留打开的原型实例，工作树及证据保留。

## 截图错位

安装版 Puppeteer 25.3.0 的 `ElementHandle.boundingBox()` 给出相对顶层视口的坐标，但子 frame 的 `ElementHandle.screenshot()` 随后加上子 frame 的 `visualViewport.pageLeft/pageTop`。当顶层页面已滚动，生成的 document clip 缺少正确的顶层偏移，可能截到主页面内容。OMP 原来的 frame helper 直接调用该路径。

修复保持 `frame.screenshot(selector)` 接口，改由 OMP helper 使用公开 Page API：目标 bounding box 加顶层 main frame 的 visual viewport 偏移，再调用 `Page.screenshot`。原有信号、图像输出和缩放处理保留。

验证使用有边框／padding、独立滚动及嵌套跨域的 frame。每个目标含四个不同颜色的象限，主页面背景为洋红色；与顶层同色参考图比较四处像素和宽高比，避免仅凭文件存在误判。参考图保留默认 Display P3 色彩管理，未把 CSS sRGB 数值直接当作解码后的颜色值。

| 场景 | DOM DPR 2 | DOM DPR 1 |
| --- | --- | --- |
| 同源 frame，顶层与子 frame 均已滚动 | 四象限正确 | 四象限正确 |
| 跨站 frame，顶层与子 frame 均已滚动 | 四象限正确 | 四象限正确 |
| 嵌套跨站 frame，含边框及 padding | 四象限正确 | 四象限正确 |

同一页上的原始 Puppeteer element 截图作为对照，仍截到洋红背景；修复后的公开 OMP frame 截图包含四象限。两种 DOM DPR 下原生 CEF 仍可能输出相同的物理像素倍率，本记录认证裁剪位置和内容，不把该结果当作输出倍率契约。

![原始路径误截主页面背景](../evaluations/2026-10-27-cef-repairs/upstream-wrong.png)

![修复后的嵌套跨站 frame 目标](../evaluations/2026-10-27-cef-repairs/nested-2.png)

## 对话框和恢复

CefSwift 默认在 CEF UI 回调中同步运行 `NSAlert.runModal()`，阻止后续 CEF 工作。直接返回 CEF 默认弹窗处理也不够：实测 CDP 已答复，但原生 macOS Alert 可残留，不能把页面结果正确视为完整通过。

最终补丁提供显式的 CDP 接管模式：保存真实 CEF callback，返回已接管而不进入 AppKit 模态展示；CDP 完成真实浏览器 dialog，CEF 发出 close/reset 后在后续主队列释放额外引用。强制关闭浏览器时先取消尚未完成的 callback。该顺序对应 [CEF dialog manager](https://raw.githubusercontent.com/chromiumembedded/cef/14c5a08/libcef/browser/javascript_dialog_manager.cc) 和 [Chromium Page handler](https://raw.githubusercontent.com/chromium/chromium/refs/tags/154.0.8037.98/content/browser/devtools/protocol/page_handler.cc) 的共享完成回调及 UI 清理顺序。

另一个恢复阻塞位于 OMP：重开已有标签、改变显式 dialog policy 时，旧 worker 的页面 hook 清理先于新 policy；开放的 prompt 会暂停页面 JS，使清理等待。修复先在已有 worker 应用调用者明确指定的 policy，再执行回收。曾尝试在目标发现／worker 初始化后补处理，但时机仍太晚；最终补丁仅保留实际需要的 worker 回收顺序修复。

| 验收 | 结果 |
| --- | --- |
| confirm accept／dismiss | 页面分别收到 true／false |
| 手动 prompt | 能读取类型和默认值，准确返回固定测试文本；同步 prompt 在同一个 `tab.run` 内并行发起与答复，不先等待被阻塞的 evaluate |
| alert | 接受后页面继续执行 |
| beforeunload | dismiss 阻止导航；accept 完成导航 |
| A 有开放 prompt 时 | B 可继续输入，宿主状态文件持续更新 |
| 真实 AbortSignal | 约 0.6 秒返回中断，后续写 B 的语句未执行；重建 Eval 局部句柄并显式 dismiss 后，A 可继续输入 |
| A 有开放 prompt 时原生关闭／重建 | A 换为 CEF browser ID 3，接受 `REOPENED after prompt`；B 保持 ID 2 和 `B lifecycle baseline` |
| 带 prompt 退出宿主 | OMP 仍附着时原生 quit 完成，最终退出码 0，没有强制终止 |

真实窗口复核确认新 A 的输入和 B 的保留内容，未看到原生 Alert 残留。关闭完成依据改为 CEF `on_before_close` 后的 `isClosed`，不再仅以 nativeView 消失判断。宿主使用独立进程组，避免驱动的交互中断直接传给应用；驱动会将最终宿主退出状态写回结果，异常或强制退出不能获得通过状态。

## 验证和边界

独立 SwiftPM 宿主和图像读取 helper 编译通过。相关静态范围 `documentation harness syntax` 通过；本轮没有改动生产 GUI 编译源码／资源或重建、启动主 GUI。Dev 版本按本地集成约定递增，原型依赖仍不进入生产 target。

CDP 接管模式要求附着的 Page client 负责答复；它不提供未连接工具时面向人的原生弹窗。首次全新 OMP 连接附着到已经被弹窗暂停的页面未认证；验证的是已有工具连接中的 policy 切换及取消恢复。也未认证任意 CSS transform／超大或被祖先裁切的 frame 元素、外部站点及权限、真实 React/WebMCP 动作、剪贴板、视频、IME、发布签名／sandbox／性能。原型仍为关闭 sandbox、mock key storage 的本地开发宿主。
