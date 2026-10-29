# Markdown 渲染与数学公式接入

> 历史记录：仅代表原文所列日期、版本及验收范围，不是当前操作指南。 当前已移除的收件箱、会话记录、独立 fork 和诊断入口不因本文的历史描述而恢复为功能。 当前入口见[文档索引](../README.md)和[功能状态与验收边界](../status.md)。

OMP GUI 的 Markdown 强化保留当前原生文本和交互链路。按当前需求，行内代码移除底框与额外内边距，使用适配深浅色的灰色等宽字体；第一阶段补齐六项常见语法。数学公式已完整接入原生 SwiftMath 1.7.3，字体固定为 `Asana-Math`。独立测试仓只保留这条方案。

技术核对日期为 2026 年 10 月 13 日。下文区分已完成的语法、剩余缺项和独立公式实验；后续仍先核对成熟方案与现有链路的接入条件。

## 现有渲染结构

`MarkdownParser` 自行解析块级结构，支持 ATX/Setext 标题、段落、围栏/缩进代码、列表、任务列表、嵌套引用、GitHub 提示块、带对齐与转义竖线的表格和分隔线。行内解析使用 Foundation `AttributedString`，由 `MarkdownInline` 统一软硬换行，再由 `RichLink` 处理链接标题和缓存。

已完成的连续正文使用 `ProseRunRepresentable` 和 `LinkTextView`，保留原生选择、链接和头像悬停。流式正文和独立块由 `InlineText` 渲染，流式内容经过 `StreamMend` 和 `StreamVeil`。表格列保持固有宽度并横向滚动。含公式的段落使用 `MathParagraphView` 包裹相同的 `LinkTextView`，块公式使用 `MathBlockView`。新语法需要同时考虑这些路径，以及 `MessageText` 的整条消息复制。

## 成熟渲染技术的适配

下表中的接入成本根据当前代码结构评估。已有库的功能支持不等于能够直接替换现有交互。

| 技术 | 可以复用的能力 | 对当前项目的适配条件 |
| --- | --- | --- |
| SwiftUI TextRenderer | 可根据每行和每个文本 run 的排版结果绘制圆角背景 | 绘制和 displayPadding 本身不为行内字符预留左右间距；还需要解决真实内边距、选择、流式效果及 AppKit 路径的一致性。[Apple API](https://developer.apple.com/documentation/swiftui/textrenderer) |
| MarkdownUI | 完整的 GFM 渲染和主题系统 | code 背景属性为普通 backgroundColor；圆角和内边距仍需扩展。项目已进入维护模式；整体替换还需要重接流式效果、特殊代码卡、链接悬停和缓存。[项目说明](https://github.com/gonzalezreal/swift-markdown-ui)、[背景属性实现](https://github.com/gonzalezreal/swift-markdown-ui/blob/main/Sources/MarkdownUI/Theme/TextStyle/Styles/BackgroundColor.swift) |
| Textual | Foundation 解析、原生选择、附件、图片、数学公式和块级主题 | macOS 15 起，满足本项目 macOS 26 的要求。code 的 backgroundColor 仍是普通属性，完整接入需要迁移文本选择与附件布局。适合作为后续渲染原型，尚不能视为当前链路的无缝替换。[项目说明](https://github.com/gonzalezreal/textual)、[背景实现](https://github.com/gonzalezreal/textual/blob/main/Sources/Textual/TextProperty/Color/BackgroundColorProperty.swift) |
| SwiftMarkdownEngine | AppKit TextKit 2 编辑器，包含图片、公式及代码块桥接产品 | 主要面向编辑器。替换当前 TextKit 1 回复视图会带来布局和交互迁移；其 fitsContent 模式会布局全文，需单独评估长对话成本。[项目说明](https://github.com/nodes-app/swift-markdown-engine) |
| swift-markdown | Swift 官方 Markdown AST，基于 cmark 和 cmark-gfm | 可逐步将 AST 映射为已有 `MarkdownBlock`，保留 UI。它负责语法，不提供公式排版。引用式链接等全局语义会改变流式解析的稳定区边界，需调整缓存策略。[项目说明](https://github.com/swiftlang/swift-markdown) |

当前样式需求只需共享动态文字颜色，不需要额外排版引擎。六项语法先核对 [CommonMark/GFM 规范](https://github.github.com/gfm/) 与 [GitHub 提示块](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax#alerts)。swift-markdown 提供完整 AST，但整体迁移会涉及流式稳定区、原生选择和自定义块；这批范围明确的扩展沿用现有块模型，行内语法继续交给 Foundation。引用式链接等全局语义增加时，应重新评估 AST 接入。

## 行内代码实现

`InlineCodeStyle.foregroundColor` 使用动态 NSColor provider，绘制时按 appearance 返回浅色 0.35、深色 0.72 的 sRGB 灰色。不能仅在首次解析时给缓存的系统颜色修改透明度，否则主题切换可能保留旧颜色。AppKit 与 SwiftUI 共用此颜色；流式淡入叠加透明度时保留原有灰色。

代码仍是原生等宽文字。已移除自定义背景布局管理器、首尾 kerning 内边距和专用富文本导出；行内代码统一向上偏移 0.5 pt，让较小的等宽字体更接近周围正文的视觉中心。SwiftUI 和 AppKit 共用此值，宽度变化仍使用正常文本重排。正文、标题、列表、引用和表格复用同一字体与颜色策略，代码样式链接保留目标和灰色。列表标记的基线继续取实际 TextKit 行片段。

## 第一阶段已完成

| 顺序 | 语法 | 行为与边界 |
| --- | --- | --- |
| 1 | 表格列对齐 | 保留 `:---`、`:---:`、`---:` 并分别应用左、中、右列对齐；保持固有列宽和横向滚动 |
| 2 | Setext 标题 | 段落后纯 `=` 或 `-` 下划线转换为一级或二级标题，支持多行标题；空行后的 `---` 仍为分隔线；适配流式结构变化 |
| 3 | 表格转义竖线 | 扫描真实分隔符与反斜杠奇偶，支持 `x\|y` 和代码片段中的转义竖线；缺失单元格补空，额外单元格按 GFM 忽略 |
| 4 | GitHub 提示块 | 顶层引用首行识别 NOTE、TIP、IMPORTANT、WARNING、CAUTION，复用 Chrome 卡片、颜色和图标；标题已加入 zh-Hans；未知、带额外文字或嵌套标记保留普通引用 |
| 5 | 缩进代码 | 四列空格或 tab 缩进形成代码块；保留内部空行和正文、处理列表相对缩进与 tab 停靠点；缩进代码不打断现有段落 |
| 6 | 换行语义 | 软换行折叠为一个空格，两个尾随 ASCII 空格或反斜杠形成硬换行；原生硬换行保留列表内容缩进且不添加块间距；代码片段交由 Foundation 保留标准空白语义；复制与渲染一致 |

连续正文的分组检查嵌套块，避免列表或引用中的代码、表格、提示块被纯文字路径跳过。分组缓存比较实际块结构，确保 Setext 标题即使文字未变，也会更新字号。

## 剩余缺项：从易到难

按当前架构的预计改动范围排序，不代表完整 CommonMark/GFM 兼容承诺。

| 顺序 | 缺项 | 实现重点 |
| --- | --- | --- |
| 1 | 引用式链接 | 整条消息定义表；后到达的定义使前文链接缓存失效 |
| 2 | 定义列表等扩展 | 明确方言，新增块类型与嵌套缩进规则 |
| 3 | 脚注与标题锚点 | 稳定编号、重复引用、回跳和时间线定位 |
| 4 | Markdown 图片 | Foundation 已提供 imageURL；需要加载、取消、缓存、宽度约束和高度变化后的阅读位置 |
| 5 | HTML 子集与完整 HTML | 小型白名单映射原生样式；完整 HTML 需要独立布局和选择策略 |
| 6 | Mermaid 等图形 | 复用成熟引擎，适配缓存、主题、宽度、缩放和复制。[GitHub 语法](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/creating-diagrams) |

现有列表和引用仍是简化实现。本轮修正了相对缩进与 tab 对齐，但尚未覆盖完整的松散列表、所有 lazy continuation 和容器组合规则。这类全局与嵌套规则继续增加时，成熟 AST 比持续扩展手写解析器更值得评估。

## 原生公式实现

先核对 [SwiftMath 1.7.3 的公开 API](https://github.com/mgriebling/SwiftMath/tree/1.7.3)。稳定版提供 AppKit/CoreText 排版、text/display 模式、`fittingSize` 与 displayList 的 ascent/descent/width 和矢量绘制接口，可以融入现有 TextKit 1 文本附件。依赖固定精确版本，不依赖 main 的未发布宽度 API，也不使用内部 typesetter 或 SPI。

公式只使用 SwiftMath，字体固定 `Asana-Math`。应用没有 Web 公式渲染器、浏览器桥接或运行时选项。该字体随上游原始资源包离线提供；保留 MIT、MathChat、SIL OFL 与上游资源许可证、字形元数据。

SwiftMath 完整替换为 Temml 的取舍另见 [实测评估](swiftmath-temml-evaluation.md)。该评估使用隔离的 Release CLI 与合成样例，涵盖实际 WebKit 布局、PNG/PDF 桥接、进程占用、语法覆盖与原生交互；产品仍使用下述原生路径。

`MarkdownMath` 在 Foundation 解析前保护 TeX，再恢复自定义公式属性。支持 `$...$`、`\(...\)`，以及独立行的 `$$...$$`、`\[...\]` 块公式。代码片段、围栏、缩进代码、转义美元符号、链接目标与网址按原内容处理；单美元符号使用保守的空白与数字边界，`$20 and $30` 不视为公式。表格划分列之前同样保护公式内的竖线。

`MathRendering` 用公开的 `MTMathUILabel` 生成几何，并缓存其 displayList。行内公式作为一个原生矢量附件，与连续正文一起按 TextKit 的基线和行高排版。高分数、根号与上下限使用实际 ascent/descent，而非普通正文行高。绘制时重置 TextKit 的 text matrix，避免字形上下翻转；颜色在每次绘制时按当前外观与流式淡入透明度解析。

块公式在可用宽度中居中。SwiftMath 1.7.3 不自动断行：超宽公式保留原字号和完整宽度，通过原生横向滚动查看。含超宽行内附件的段落只扩展可滚动文档，正文文本容器仍等于可见宽度，不因公式拉宽正文。作者可用 `aligned`、`cases`、矩阵等结构显式排版多行公式。

布局缓存按 TeX、text/display 模式与字号区分；字体固定。宽度与主题不进入缓存键，改变窗口宽度或外观只重排文本、重新绘制，不再解析相同公式。缓存限制 256 条、估算成本 4 MiB；未闭合公式保持原文并跳过引擎，完成后再排版。流式 Markdown 修补不会改动 TeX 内部的反斜杠、下划线或星号。

原生选择复制将附件替换为原始带分隔符的 TeX，保留相邻 Unicode、链接、硬换行与 RTF；整条消息复制与正文 reflow 同样保护公式源码。公式右键菜单提供“复制 LaTeX”，复制不含外层分隔符的内容。附件有原始 TeX 的无障碍标签，但不提供自动数学语音或语义 MathML。

SwiftMath 支持常见数学 LaTeX 子集，不能视为完整 TeX 引擎。未知命令、无效语法、空公式、缺失字形和过于复杂的输入显示原始 TeX；块公式另显示本地化原因。Asana Math 不包含中文，`\text{中文}` 和混合中文公式会整体回退，避免解析成功却丢字。复杂度限制为 16 KiB 源码、64 层花括号嵌套。

## 独立测试仓

测试仓为 `/Users/developer/githubs/omp-math-rendering-lab`。当前任务工作树为 `/Users/developer/.codex/worktrees/swiftmath-lab/omp-math-rendering-lab`，默认预览端口 4319。只保留 SwiftMath 1.7.3、`Asana-Math`、原生离屏渲染和测量程序；旧比较方案、配置、脚本、字体与依赖已从当前树移除，历史仍保存在 Git 中。

9 个样例覆盖上下标、根号、分数、求和、矩阵、aligned、长行内/块公式、中文与未知命令，在 3 个宽度、2 个字号、2 个主题下生成 108 份真实原生 PNG。浏览器只展示这些结果。修改 `fixtures.json` 并执行 `npm run native` 可重建；`npm run verify` 验证图像、滚动、窄窗口、复制与本地资源，`npm run benchmark` 测量原生解析/测量开销。

## 本轮验证

- `make build` 编译 OMP GUI Dev，不安装或启动应用。
- `make verify AREAS="markdown-parser"` 检查六项块语法、嵌套代码、换行、整条消息复制与逐字符流式解析。
- `make verify AREAS="markdown-layout"` 检查 30 组字号/Unicode、640/280/140 pt 宽度往返、基线、RTF 和灰色行内代码。浅色/深色对比度为 6.98:1、8.37:1。
- `make verify AREAS="markdown-math"` 编译真实生产解析器和渲染器，检查公式分隔符、转义/货币/代码/链接、嵌套块、表格竖线、流式、缓存、字号与宽度往返、错误回退、TeX/RTF 复制。生成 本次 `functional/markdown-math/` 结果目录中的 `math-{light,dark}.png`，用于目视核对实际矢量字形、基线、居中与重排。

离屏验证覆盖源码与绘图，真实 OMP GUI 窗口的连续选择、触控板滚动、阅读位置与 VoiceOver 交互仍需应用运行后的验收。
