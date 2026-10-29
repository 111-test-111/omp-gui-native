# 浏览器提示及配置删除（2026-10-28）

本轮处理 Chrome Cookie 导入提示省略，以及删除所选浏览器配置的设置入口。当前行为见[浏览器指南](../browser.md#浏览器配置与登录态)，不启动或重启主应用。

## 行为

- 导入表单按本地化文字和字号测量期望宽度，受 1,040 pt 及当前屏幕可用区域限制。显式解除继承的单行限制，固定文字所需的纵向空间；宽屏尽量单行，窄屏完整换行，权限错误可选中复制。设置中的当前配置、导入结果和删除提示也完整显示。
- “删除所选配置”使用原生确认对话框。默认配置不可删除，Cookie 导入期间禁用删除。确认后移除该 UUID，若仍被选中则回到默认配置；不更改本次运行的 profile，不在仍有浏览器持有数据时删除其目录。
- 待清理 UUID 与配置保存在同一个偏好 payload 中，并兼容旧 payload 缺少该字段。下次启动在后台清理，只确认已完成的身份；失败或中断继续保留。清理范围仅为本 edition 的已移除 UUID 目录，保护默认、当前运行及仍发布的配置；不沿库、browser 或 profiles 根符号链接向外遍历，最终 profile 链接只移除链接本身。

## 验证

Dev 版本 0.1.329 / build 330。一次增量 `make build` 通过。仅选择 `make verify AREAS="workspace-browser settings"`，两项首次执行均通过：

| 检查 | 结果 |
| --- | --- |
| `workspace-browser` | 141 项；新增默认／不存在的配置保护、删除后选择、旧偏好兼容、待清理持久化、活跃／保留保护、重启清理、最终及嵌套符号链接不越界、根替换失败保留待办及后续重试 |
| `settings` | 38 项；保留导航／草稿检查，并使用生产表单核对中英文 1,200 pt 和 360 pt 可用宽度。宽布局超过旧 400 pt，窄布局增加高度而不是省略文字 |

报告位于本 worktree 的 `build.noindex/verification/runs/20261028T040811Z-b8e453d1/report.json`。对应 `functional/settings/chrome-import-{en,zh-Hans}-{1200,360}.png` 保留四张离屏图像；已检查中文宽／窄及英文宽图像，完整提示无省略号。合成中文消息使用显式资源 bundle，标题和按钮沿检查进程语言显示，不把它称为完整中文 GUI 验收。

文档变更单独选择 `make verify TIER=static AREAS="documentation"`。未修改执行器／登记表，不追加 harness、native OMP、性能矩阵或未受影响的 Cookie 解密负载。

## 紧凑宽度修订（最终 Dev 0.1.334 / build 335）

导入弹窗的宽度上限由 1,040 pt 收至 640 pt。灰色说明仍按单行测量，长错误按两行计算期望宽度；屏幕更窄时继续完整换行，不限制文字行数。已核对新的中英文宽布局图像，两种语言的红色权限提示均完整显示为两行。

宽度改动先在 Dev 0.1.332 / build 333 下通过增量 `make build` 及 `make verify AREAS="settings"` 的 38 项检查，功能报告为本 worktree 的 `build.noindex/verification/runs/20261028T045030Z-4ce8d162/report.json`，图像保留在其 `functional/settings/` 中。合入前同步 main 独立的行内代码／图标更新，最终版本递增至 Dev 0.1.334 / build 335，并对整合结果再次增量构建；设置行为和检查源码未因此变化，复用前述功能证据。文档单独选择 `make verify TIER=static AREAS="documentation"`；不重复配置删除、Cookie 解密或 native／GUI 负载。

## 剩余现场边界

所有文件清理使用本次 capture 的合成目录及哨兵，不读取／删除个人浏览器数据；布局使用从未显示的 AppKit 窗口，不启动 Chrome、CEF 或主应用。真实屏幕边缘与弹窗材质、键盘／VoiceOver、删除确认、实际进程重启和系统文件权限失败仍需独立现场验收。原生 Cookie 导入的系统授权／Keychain 与登录验证边界继续见[上轮记录](native-chrome-cookie-import-2026-10-28.md)。
