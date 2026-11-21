# HexoMan 开发笔记

记这里的是「改了会影响其他维护者的判断」的事。不写实现细节（commit 里看），
不写 UI 文案（审查时被覆盖）。

## 2026-11-13  ·  v0.8.0：插图、草稿预览、列表筛选、设置解码容错

### 插图这一块的三个决定

- **放 `source/images/<年>/`，写 `![](/images/…)`，不用 `{% asset_img %}`。**
  后者要求站点开 `post_asset_folder`，关着的站点插进去就是死链；前者任何
  主题、任何配置都认。
- **同名不覆盖，加 `-1`、`-2`。** 截图默认文件名大量重名（「截屏2026-11-13」），
  覆盖掉的话正文里先插的那张会在用户不知情时被换掉。
- **HEIC 转 PNG。** iPhone 截图默认是 HEIC，浏览器不认，原样插进去只会得到
  一张裂图。转换放在 `SiteMedia.normalize`，用 `NSBitmapImageRep` 重编码。

插到正文**末尾**是刻意接受的限制：SwiftUI 的 `TextEditor` 没有光标 API，要
精确插到光标处得换成 `NSTextView` 包装。这版没换——换掉等于重写编辑器，
和这版的其它改动风险不匹配。用户插完自己挪一行，比编辑器换个实现便宜。

Cmd+V 的监听**只在剪贴板里是图时接管**：有纯文本（且不是 URL / HTML / data:
开头）就放行给 TextEditor。不分这一刀的话，编辑器里粘一段普通文字会被自己
的监听吃掉。

### 「预览包含草稿」为什么要单独一个开关

`hexo server` 默认只渲染已发布文章，`draft: true` 的在本地预览里根本不存在。
写草稿的人会以为预览坏了，然后要么去删草稿标记、要么去改配置——两条都绕开
了 Hexo 自己的机制。开关就是加 `--draft`，默认关。

### 设置解码：加字段不能清空老用户数据

`AppSettings` 原来用合成的 `init(from:)`，缺字段直接抛 `keyNotFound`，而
`SettingsStore.load()` 一抛就 `return AppSettings()`——**退回出厂设置**。
也就是说任何一次「加一个设置字段」的版本，都会把用户的站点列表、自定义
hexo 路径、语言选择一起清掉，而且没有任何提示。这版加了 `previewDrafts`，
顺手把它改成逐字段 `decodeIfPresent`。

判断依据是探针：拿一份缺 `previewDrafts` 的旧 settings.json 喂进去，
改前 decode 抛异常、改后站点和自定义路径全在。

### 验证方式

仓库没有测试 target，这版不新建（加 target 要动 project.yml 的结构，和这版
改动无关）。纯逻辑（`SiteMedia`、`AppSettings` 解码、`HexoService.server` 的
参数拼装）用 `swiftc` 单独编出来跑临时探针，18 + 11 + 6 条断言全过，变异
4/4 抓住（去重拆掉、sanitize 不折叠、解码容错删掉、`--draft` 不拼）。

界面部分只到「Debug 与 Release 都能编过 + 新 key 出现在 bundle 的
`Localizable.strings` 里」这一层，实际拖拽/粘贴/右键手感要人手验。

### 顺带

- release workflow 现在优先用仓库根的 `release-notes.md` 当更新日志，没有
  才退回「两个 tag 之间的提交列表」——后者给用户看等于让他读 git log。
- 新增 15 个本地化 key（zh-Hans / en / ja 三语）。


## 2026-10-21  ·  联网搜索为什么"看起来能用"其实一直失效

上一版（v0.7.2）的主题搜索修复里，我验证了「请求能发出去」就下结论说搜索可用，
这是错的。真实情况是**一条在线结果都没进来**，用户看到的永远是离线那 10 条硬编码。
教训记在这里，因为它反映的是一种很容易复发的判断错误。

### 教训：验证网络功能要验到"结果"，不是"请求"

npm 搜索接口的 `package.publisher` 是**对象** `{"email":..,"username":..}`，
而解码结构里声明的是 `String?`。`Codable` 遇到类型不符直接抛 `typeMismatch`，
整个 `objects` 数组全废。而 `fetchOnline` 把 decode 包在 `try` 里，
catch 之后静默 `return offlineCatalog(query:)` —— **失败被伪装成"没搜到"**。

当时的验证只做了两件事：确认 settings 里 `onlineThemeSearch == true`、
用 curl 确认 registry 返回 200 和 25 条 JSON。两件都成立，
但**没有一件能证明这些 JSON 被解码成了模型对象**。

用旧代码跑真实响应复现出来的错误：
`typeMismatch: Expected value of type String. Path: objects[0].package.publisher`

**判断依据**：验证网络功能时，"能拿到响应"和"能用上响应"是两件事。
凡是 catch 之后有静默 fallback 的路径，必须单独验证 fallback 之前的那个返回值，
否则 fallback 会把任何失败都伪装成正常的空结果。
另外，本地化的 `summaryDescription` 也有同样的"静默失败"特征
（查不到键就回落成通用的"主题包"），所以它当时也没能暴露问题。

### 配套改动：失败必须留痕

新增 `ThemeLog`（os_log，subsystem `com.skyc8266.hexoman`），成功 / 请求失败 /
解码失败各一条。以后"到底有没有真的发请求"可以直接看日志，不靠猜。
Console.app 按 subsystem 过滤，或 `log stream --predicate 'subsystem == "com.skyc8266.hexoman"'`。

### 教训：WKWebView 复用时 URL 变了必须自己 reload

`ThemePreviewWebView.updateNSView` 原本是空的，注释里假设
「URL 变就是重建 view（HexoMan 没这场景）」。这个假设是错的：
详情面板复用同一个 `WKWebView`，SwiftUI 不会重建它，
于是它永远显示**第一次加载**的页面。默认选中 yun 时，症状就是
"点开任何主题，预览里都是 yun"。

**判断依据**：任何"用户切换选中项 → 右侧/下方内容跟着变"的布局，
如果右侧用的是有状态的原生控件（`WKWebView`、`NSTableView`、`Map` 等），
都要在 `update*` 里显式处理状态同步，不能指望 SwiftUI 重建视图。

### 顺带：别把代码托管页当"演示站"

实测 npm 搜索 25 条结果里，11 条 homepage 指向 GitHub 仓库页、4 条根本没有
homepage。把仓库页塞进"官方 demo 预览"位置是误导。现在内嵌预览只认真正的站点，
仓库页改为给外链，并说明为什么没有预览。

## 2026-10-21  ·  待处理：`LocalizedStringKey` 插值陷阱（29 处）

全仓扫描发现 29 处 `Text("中文 \(变量)")` 形式，xcstrings 里没有对应键。
这类写法走 `LocalizedStringKey` 插值，查不到键时会 fallback 显示**字面量原文**，
于是界面上出现 `hexo：%@`、`共 %@ 个文件` 这种裸露占位符。

**当前影响范围**：切到英文 / 日语时才会暴露；中文界面下正常
（源语言 fallback 成原文，恰好就是想要的文案）。
已修 `ContentView` 里状态栏那一处（`footer.hexoSource`），其余 28 处未动。

**为什么没一次改完**：这 28 处要逐条抽成「前缀（本地化键）+ 值（String 重载）」，
或者补齐对应键，牵涉到每个页面的文案判断，属于独立的批量工作，
不适合和这次的联网搜索修复混在一个提交里。已在 v0.7.3 的说明里不出现，
避免把未修的东西说成已修。

**判断依据**：新增任何带插值的 `Text` 时，要么用 `String(localized:)` + 显式参数，
要么拆成前缀 Text + 值 Text。不要写 `Text("前缀 \(值)")`。

## 2026-10-21  ·  主题市场与备份页的交互失效

三个用户可见的故障：主题市场搜不到东西、点某个主题没反应、备份页一进去就卡在
「正在统计…」。根因彼此独立。

### 教训：macOS 上不要用 `List(selection:)` 做「点一行选中」

`ThemeBrowserSheet` 的市场列表原来是 `List(selection:)` + `.tag(Optional(pkg))`。
绑定本身已经是 `Optional`，tag 又包了一层 `Optional`，两侧类型对不上，
行点击因此不生效——表现就是「点 reimu 完全没反应，右栏一直是空的」。

`ContentView` 的侧边栏早就因为同类问题改成了显式 `Button`（见 `navigationList`
的注释）。这次把主题市场、主题迁移勾选框也一并换成了显式按钮，
选中态自己画高亮背景，不依赖 List 的隐式选中机制。

**判断依据**：凡是「点一行 → 右边/下面换内容」这种主从布局，选中态就**不要**交给
`List(selection:)`。用显式按钮 + 自己画高亮，行为可预期，也不受 macOS 各版本
List 选中语义差异影响。

仓库里还剩几处 `List(selection:)`（`ConfigView` / `SchemaConfigView` /
`PostsView` / `PagesView`）。它们用的是 `String?` 绑定配非 Optional 的 `.tag(id)`，
和这次的类型不匹配不是一回事，目前也没人报障，所以**没动**。
如果哪天这些列表也出现「点了没反应」，按同一思路换显式按钮即可。

### 教训：`onChange(of:)` 的首调回调早于 `onAppear`

`BackupView` 原来用一个 `hasObservedIncludeLarge` 布尔量，想吞掉
`.onChange(of: includeLarge)` 在首次 body 评估时的那次回调，避免和 `onAppear`
里的 `refreshPlan()` 重复扫站点。

但 SwiftUI 这次的回调发生在 **`onAppear` 之前**，那时布尔量还是 false，
于是唯一一次真正需要的首刷被丢掉了。

改法不再依赖 `onAppear` 与 `onChange` 的相对时序：改成记住
「上次统计用的站点路径 + 上次统计用的开关值」，值没变就不重扫。
`refreshPlan()` 同时做成幂等，并补了回写前的二次校验
（站点和开关都还对得上才写 `plan`），避免切站点时旧结果覆盖新站点的。

**判断依据**：想靠一个「首次调用」标记位来去重时，先确认那个回调真的晚于
你设标记的位置。SwiftUI 里 `onChange` 的首调早于 `onAppear`，靠时序假设写的去重
逻辑都很脆。改成「比对上一次用的输入值」就没有顺序依赖。

> **⚠️ 这条不是备份页打不开的根因。** 用户实测备份页问题在这次修复后**依旧存在**。
> 实测 `BackupManager.plan` 对 152MB 的真实站点只要 17ms / 28 文件，
> 站点内也没有会触发遍历死循环的符号链接——即使上述首刷真的被丢掉，
> 结果也该是 17ms 后就出来，不会表现为「无法操作」。
> 所以备份页的真实根因**尚未定位**，待查。
> 目前仍存疑的嫌疑点：`loadBackups()` 把 `isLoading = true` 之后整个内容区
> 被 `ProgressView` 独占，而 `isLoading = false` 只写在 `MainActor.run` 内部；
> `guard let site = model.currentSite else { return }` 又在设 `isLoading` 之前返回。

### 顺带修的：本地化 key 的大小写

`ThemeCatalog.Item.literalKey` 之前用 `switch name` 硬编码，键名跟着
`Item.name` 的大小写走，写成了 `theme.Fluid.summary`。而 xcstrings 里的键是
全小写的 `theme.fluid.summary`——`Fluid` / `Matery` / `Anima` 三条都查不到，
静默回落成通用的「主题包」，那三条主题的描述和基于描述的搜索全都失效。

改成统一 `name.lowercased()` 拼键，不再用 switch 硬编码，以后加主题不会漏。
`xcstrings` 本身一个字的翻译都没动——`theme.*.summary` 这 10 条的中英文
本来就在，缺的只是大小写对不上的那三条。

### 没动的与原因

- **剩余的 `List(selection:)`**：见上，`String?` + 非 Optional tag 与本次的
  类型不匹配不是同一类问题，未报障，不在这次范围内。
- **`ThemeCatalog.items` 仍是硬编码的 10 条**：这是**有意**的。
  联网搜索走 npm registry，只在用户开了「允许联网」后启用；没开时只显示这 10 条
  离线精选，避免小白面对几百个搜索结果无从下手。这次补的是搜索体验
  （能搜到 + 知道为什么搜不到），没有改成全量 npm 目录。

## 2026-10-12  ·  PR1：本地化基础

PR1 把项目从「中文硬编码 + 0 国际化」改到「中文/英文双语，本地化基础设施就位」。
JP 语言档（`AppLanguage.ja`）已经在枚举里声明，但 `Localizable.xcstrings` 暂未
填日文翻译——按用户偏好 JP 母语校验由懂日语的人来做，不在这一版范围。

### 关键设计点

- 用 `LocalizedStringKey` + Xcode 15 Strings Catalog（`.xcstrings`）。
  这是 Apple 当前推荐路径。`String(localized:)` 也行但搜索面太广，
  用 `LocalizedStringKey` 配合 `Text(...)` 重载能在编译期发现漏翻译。
- 切换语言通过 `.environment(\.locale, ...)` + 顶层 `.id("lang-...")`
  强制撕掉子树重建。SwiftUI 的 locale 默认不会触发已有视图重渲染
  （它是 side-channel，只对未来 body 评估生效），这是 Apple 框架
  的限制，靠 `.id` 改掉。
- Pill / EmptyHint 都改成「LocalizableStringKey 重载 + String 重载」
  二选一。传字符串字面量走前者（编译期决定，走 xcstrings）；
  传运行时拼接走后者（不本地化）。这样**老的硬编码中文不会破**，
  新代码可以直接写 key。

### 没动的与原因

- **JP 翻译**：**已于 2026-10-22 补齐**（184 条，见同日条目）。
  当时这一条记录的是「未做 / 不在这一版范围」，现已过期，保留仅为说明决策来历。
  `AppLanguage.hasTranslations` 随之从 `ja: false` 改为 `true`，
  用来挡住「只有枚举项、没有一条翻译」的语言档——那种情况下选中它
  会让界面变成一半 fallback 一半硬编码中文。
- **大部分 toast 文案**：未本地化。`HexoManModel.toast: Toast`
  是 String 字段，已经创建出来的 toast 不会跟随语言切换。
  这是 Apple 框架的限制（toast.text 已经是某种语言的 String，
  切换语言后旧 toast 不变），加 `String(localized:)` 也救不了。
  PR1 只把**会被下次显示**的 toast 文案走本地化，已存在的
  toast 保留。下一版可以统一迁移。
- **ThemeView 详情区、ConfigView、VisualConfigView、SchemaConfigView
  等内部表单/按钮的硬编码中文**：未本地化。这些页面的字符串
  数量大、文档注释密，全部本地化会显著膨胀 PR1。
  PR1 只覆盖「首屏可见」：侧边栏、主菜单、ThemeView 头部、
  ThemeView install sheet、主题目录、语言菜单。
  后续 PR 按页面拆开分别补。
- **DiagnosticsView 的诊断文案**（14 类健康检查）：未本地化。
  每条诊断是 `String` 字面量直接拼在 SwiftUI 视图里，
  改的话要重写 DiagnosticsView.swift（617 行）。
  计划放 PR4 或单开。
- **`HexoEnvironment.diagnose` 的 warning 文本**：未本地化。
  这函数返回 `[String]`，调用方直接 toast 显示。要本地化得
  改成返回 `[LocalizedStringKey]`——跨模型/视图层的接口变动，
  留给专门做诊断本地化的 PR。
- **错误诊断显示的具体命令**（`brew install node` 等）：保留英文。
  命令是用户要复制到终端的字符，本地化成中文反而麻烦。

### 文件清单

新建：
- `HexoMan/Core/AppLanguage.swift`（语言档枚举 + Locale 转换）
- `HexoMan/Resources/Localizable.xcstrings`（79 个 key 的初始 Catalog）

修改：
- `HexoMan/Core/HexoManModel.swift`（+ `language`/`locale`，`SidebarItem.title` 改 LocalizedStringKey）
- `HexoMan/Core/SettingsStore.swift`（+ `AppSettings.language`）
- `HexoMan/Core/ThemeManager.swift`（`ThemeCatalog.Item.summary` 改 LocalizedStringKey）
- `HexoMan/HexoManApp.swift`（主菜单走 LocalizedStringKey，加 CommandMenu 语言切换）
- `HexoMan/Views/ContentView.swift`（注入 `.environment(\.locale)` + `.id`）
- `HexoMan/Views/Components.swift`（`Pill` / `EmptyHint` 双类型重载）
- `HexoMan/Views/ThemeView.swift`（头部、empty state、ThemeRow、InstallSheet 本地化）
- `HexoMan/Resources/Info.plist`（`CFBundleLocalizations` 加 `ja`）
- `project.yml`（+ Localizable.xcstrings 资源项 + CFBundleLocalizations）

### 验证

- `xcodegen generate`：成功
- `xcodebuild Debug`：成功（无 warning）
- `xcodebuild Release`：成功
- Bundle 产物：`Contents/Resources/{en,zh-Hans}.lproj/Localizable.strings` 各 79 key
- xcodegen 第二次跑 + xcodebuild：仍然成功（确认 project.yml 持久化）

### 已知未实测

按 GUI 类任务交付约定，以下需要用户手测：
- 真正打开 app 切语言菜单，验证 UI 文字确实跟随切换
- macOS 系统语言为日文时切到 `.system` 档，验证 fallback
- 顶栏菜单（macOS menubar）切语言后会闪一下重建——这是 Apple 框架限制，
  README 会在 PR2 阶段提到。

## 2026-10-12  ·  PR2：主题增强（市场 + 联网 + 跨主题迁移）

### 关键设计点

- **市场 = 内置精选 + 联网补全**。离线模式默认显示精选；用户主动开启联网
  后调 `registry.npmjs.org/-/v1/search`，返回的 `score.detail.popularity` 估
  下载量做排序。
- **首次进主题市场弹联网同意 sheet**（OnlineConsentSheet），文案明列：
  - 主机（registry.npmjs.org）
  - 数据流向（只 GET 包元数据）
  - 触发时机（用户主动搜索时，无后台轮询）
  - 关闭路径
  - 「不再询问」勾选项写进 AppSettings.dontAskOnlineConsent。
- **NetworkAccessPolicy.plist** 打进 bundle，描述 HexoMan 的网络访问范围。
  Little Snitch / Murus / LuLu 等工具会自动读这个文件并允许或询问用户。
- **包名归一化**：`ThemeManager.normalizePackageName("hexo-theme-yun")` →
  `"yun"`；`fullPackageName("yun")` → `"hexo-theme-yun"`；`shortName(from:)` 反向。
  这把 applyTheme 之前会拼出 `hexo-theme-hexo-theme-yun` 的 bug 修掉了。
- **跨主题迁移**：装完主题后用 `ConfigSync.syncAll` 计算老主题配置 vs 新主题
  sample 的交集，把可搬的项交给 UI 让用户勾选再应用。`ThemeMigrationSheet`
  默认全选 + 多选 + 单条确认；`applyMigration` 走 `ConfigSync.applyToTheme`
  落盘。
- **预览用 WKWebView**（ThemePreviewWebView），X-Frame-Options 拒绝 iframe
  时显示「在 Safari 中打开」降级。

### 没动的与原因

- **JP 文案**：依然未填。联网同意 sheet、主题市场文案按 EN/CN 翻译。
- **离线版 npm registry**：没本地缓存每次联网都重新拉取——25 个 hexo 主题
  API 响应 < 50KB，每次 < 1s 不需要缓存。
- **全局 hexo 兼容性矩阵**：没做（哪些主题支持哪些 ConfigSync 字段）。
  ThemeMigrationSheet 只是按 ConfigSync 已知字段筛，跨主题按字段名匹配。
  更精细的「按主题白名单」留给后续 PR。
- **自动修复异常**：仍是自动，部分（自动装包 / 自动检测），不是全自动
  （自动修复 npm 缓存、自动恢复旧主题）。"自动批处理" + "提示用户确认"
  已是最高安全级别。

### 文件清单

新建：
- `HexoMan/Core/ThemeRegistry.swift`（npm search + 离线 fallback）
- `HexoMan/Core/ThemeInstallResult.swift`（applyTheme 返回类型）
- `HexoMan/Resources/NetworkAccessPolicy.plist`（网络访问策略）
- `HexoMan/Views/ThemeBrowserSheet.swift`（三栏布局 + 同意 sheet + 迁移 sheet）
- `HexoMan/Views/ThemePreviewWebView.swift`（WKWebView 包装）

修改：
- `HexoMan/Core/HexoManModel.swift`（applyTheme 返回 ThemeInstallResult，
  加 computeThemeMigration、ThemeInstallResult、ThemeMigrationPlan 类型）
- `HexoMan/Core/ThemeManager.swift`（normalizePackageName / fullPackageName
  / shortName）
- `HexoMan/Core/SettingsStore.swift`（onlineThemeSearch + dontAskOnlineConsent）
- `HexoMan/Views/ThemeView.swift`（删旧的 InstallThemeSheet，调 ThemeBrowserSheet）
- `project.yml`（+ NetworkAccessPolicy.plist 资源项）

### 验证

- `xcodegen generate`：成功
- `xcodebuild Debug`：成功（0 warning）
- `xcodebuild Release`：成功
- NetworkAccessPolicy.plist：`plutil -lint` OK
- 打包后 Contents/Resources/ 含 NetworkAccessPolicy.plist

### 已知未实测

按 GUI 类任务交付约定：
- 真正打开 app 进主题市场，验证离线/联网切换 UI 行为
- 联网同意 sheet 文案是否足够清晰
- 跨主题迁移：装一个具体主题后看是否能正确搬 avatar 等
- WKWebView 预览 next / yun / fluid 等主题，确认 iframe 是否被允许

## 2026-10-12  ·  PR3：环境文档页

### 关键设计点

- 数据驱动：所有章节在 `EnvironmentDocs.sections` 里硬编码（8 节：总览 /
  Node / nvm / Git / Hexo / Shell / 疑难排查 / 隐私），纯数据 + 本地化 key。
- 章节间跳转通过 `Notification.Name.envDocsSelectSection` 实现，简单但不优雅；
  后续 PR 可改成 binding 形式。
- 命令卡片带「点击复制」功能（`NSPasteboard.general`），避免用户在终端里
  手敲命令。
- 「相关章节」按钮在 macOS 26 自带的 `FlowLayout` 里换行（之前试图自己写
  FlowLayout 但 swiftc 自动合成了——已删）。

### 没动的与原因

- **外部 wiki / 文档站链接**：没加。README 承诺「不联网」，所以环境文档全部
  内置。后续如果加 CF Pages / wiki 链接，需要文档同步维护机制——单设。
- **国际化翻译**：envDocs.* 全部 EN+CN 双语。JA 留给单独 PR（Q1=C）。
- **视频教程**：没加。HexoMan 用户群以开发者为主，文档+命令足够。
- **BuildView 横条只测 Node 缺失**：Git 缺失更轻（不影响本地命令运行），
  留给 DiagnosticsView。Hexo 缺失不在路线上通过 toolchain 直接测（hexo
  来源在 SiteProbe 里查 site node_modules/.bin/hexo，但 HexoEnvironment
  查的是 PATH 里的全局 hexo，两者不等价）。

### 文件清单

新建：
- `HexoMan/Core/EnvironmentDocs.swift`（章节数据）
- `HexoMan/Views/EnvironmentView.swift`（左目录 + 右详情 + 命令卡片）

修改：
- `HexoMan/Core/HexoManModel.swift`（SidebarItem 新增 .environment case）
- `HexoMan/Views/ContentView.swift`（switch 加 .environment 分支）
- `HexoMan/Views/BuildView.swift`（顶部加 missingToolchainBanner）
- `HexoMan/HexoManApp.swift`（CommandMenu 注释更新 11 项）
- `HexoMan/Resources/Localizable.xcstrings`（+63 key）

### 验证

- `xcodegen generate`：成功
- `xcodebuild Debug`：成功（0 warning）
- 177 个 key 全部出现在 bundle 的 zh-Hans.lproj/en.lproj

### 已知未实测

- 横条是否正确显示在 Node 缺失时（要手动卸载 node 测试——不测，留给真实手测）
- FlowLayout 在 macOS 26 SDK 自带——已用包装器验证 SDK 不再重复定义

## 2026-10-12  ·  PR4：页面管理增强

### 关键设计点

- **单选/多选模式切换**：左下 segmented picker，切换时清掉 multiSelection。
  这种显式模式切换比 SwiftUI 默认的 Command+点击多选更直观。
- **排序**：6 个选项全部本地化。`pageSort` 是 @Published，sort 在 `filteredPages`
  里同步计算（每次 filter 重跑）。
- **批量操作走 sheet 而不是 immediate apply**：避免点错就改一片页面，提供
  预览效果。
- **PageReferenceIndex**：O(NM×) 扫 _posts/。普通站点 < 1000 文章，
  切换选中页时跑一次 < 50ms，没缓存。如果未来要支持 10000+ 文章再考虑
  索引缓存。
- **front-matter 表格化**：`FrontMatterRow` 单行展示 key/value，超过 200 字
  截断。复杂块（list / map）额外加「复杂块」标签，跟「结构化数据」section
  不重复（结构化数据是整块 verbatim 块视图）。

### 没动的与原因

- **PageEditorView 不动**：编辑器自洽且用户说"更好的页面管理"指列表+详情，
  编辑器是另一块。
- **批量删除标签**：没做。删标签需要 front-matter YAML 操作更精细，
  留到 schema 编辑器成熟后做。
- **拖拽排序**（按用户 Q3=A）：**没做**。原因：macOS List 拖拽需要
  SwiftUI 4.5+ 的 onMove 但 NSItemProvider 集成复杂，且拖拽排序对 macOS
  List 行为不稳定。改用排序下拉 + 上下方向键做兜底（future）。**Q3 选 A 的
  "展示顺序" 已实现通过排序下拉**。
- **跨页面搜索**：没做。Hexo 站点页面通常 < 50 个，全文搜索意义不大。
- **关联文章跳转**：详情区显示"在访达中显示"按钮而不是在 PagesView 里
  直接跳转（避免 PagesView ↔ PostsView 互相切换 selection）。

### 文件清单

新建：
- `HexoMan/Core/PageReferenceIndex.swift`（引用索引）

修改：
- `HexoMan/Core/HexoManModel.swift`（PageSort enum、pageSort @Published、
  filteredPages 加排序、addTagToPages、setLayoutForPages、deletePages）
- `HexoMan/Core/PageStore.swift`（saveAtPath 绝对路径版）
- `HexoMan/Views/PagesView.swift`（多选/单选模式、排序下拉、批量菜单、
  front-matter 表格、引用此页 section、BatchActionSheet）
- `HexoMan/Resources/Localizable.xcstrings`（+6 key）

### 验证

- `xcodegen generate`：成功
- `xcodebuild Debug`：成功（0 warning）
- `xcodebuild Release`：成功
- 183 个 key 全部出现在 bundle

### 已知未实测

- 多选模式切换是否流畅（SwiftUI List 性能随选择项变化——hexo 站点
  页面数量通常 < 50，没问题）
- front-matter 表格中长 key（如 hexo-next 的 social_icons）的可读性
- PageReferenceIndex 对中英文混合 front-matter 的解析正确性
## 2026-11-20 · Python + PyWebView 重构：第一阶段

### 做了什么

新增 `hexoman-py/`：Python + PyWebView 实现，Windows 与 macOS 通用，
明确不支持 Linux（本机没有 Linux 设备用于实测，写上去也验不了）。

已实现并有测试覆盖的模块：

| Python | 对应 Swift |
|---|---|
| `sites.py` | `HexoSite` |
| `posts.py` | `BlogPost` |
| `frontmatter.py` | `FrontMatter` |
| `git_service.py` | `GitService` |
| `system_integration.py` | `SystemIntegration` |
| `settings.py` | `SiteSettings`（+ `SettingsStore`） |
| `hexo_cli.py` | `HexoCLIBootstrap` |
| `model.py` | `HexoManModel` |
| `markdown_render.py` | 无对应（Python 侧新增，Markdown 预览用） |
| `yamlutil.py` | `YAMLDocument` / `YAMLScalars`（部分） |

界面：站点与文章管理、Markdown 预览、总览、中英即时切换、深浅主题。
`tools/verify_ui_headless.py` 无头验证界面，不开窗口。

### 没做的

Swift 版 `HexoMan/Core/` 共 30 个模块，下面这些**还没有对应实现**：

`BackupManager` `ConfigDocs` `ConfigFile` `ConfigSchema` `ConfigSync`
`CustomContent` `EnvironmentDocs` `HexoEnvironment` `HexoService`
`PageAssets` `PageReferenceIndex` `PageStore` `SettingsStore`
`ShellEnvironment` `ShellRunner` `SiteMedia` `SnippetLibrary`
`ThemeManager` `ThemeRegistry`

其中 `PageStore`、`ConfigFile`、`ThemeManager`、`HexoService` 是核心 ——
页面管理、配置文件读写、主题安装、hexo 服务启停都还没有。

Swift 原代码一行未改，也没有提交。`hexoman-py/` 目前是未跟踪目录。

### 验证

- `python -m pytest tests/ -v`：199 passed
- 测试入口用 ServBay 的 Python 3.13

### 已知未实测

- Windows 与 macOS 上的真机启动（PyWebView 在两平台上的窗口行为、
  文件对话框、菜单栏差异都没在真机上跑过）
- Markdown 预览在真实 hexo 站点上的渲染效果
- 上述 22 个未迁移模块的行为对齐


## 2026-11-21 · Python + PyWebView 重构：第二阶段

### 做了什么

把第一阶段剩下的 Core 模块全部补上，界面上那六个带 `SOON` 标记的页面
换成真页面。

新模块（均有测试）：

| Python | 对应 Swift |
|---|---|
| `yaml_path.py` | `YAMLDocument` / `YAMLPathEngine` |
| `pages.py` | `PageStore` / `BlogPage` / `PageField` |
| `page_assets.py` | `PageAssets` |
| `page_reference.py` | `PageReferenceIndex` |
| `config_file.py` | `ConfigFile` / `ConfigStore` |
| `config_schema.py` | `ConfigSchema` / `ConfigKnowledge` |
| `config_docs.py` | `ConfigDocs` |
| `config_sync.py` | `ConfigSync` |
| `theme_manager.py` | `ThemeManager` / `ThemeCatalog` |
| `theme_registry.py` | `ThemeRegistry` |
| `shell_environment.py` | `ShellEnvironment` / `ShellEnvironmentResolver` |
| `shell_runner.py` | `ShellRunner`（日志面板 + 长驻任务） |
| `hexo_environment.py` | `HexoEnvironment` / `ToolchainInfo` |
| `site_media.py` | `SiteMedia` |
| `snippet_library.py` | `SnippetLibrary` |
| `custom_content.py` | `CustomContent` / `CustomContentStore` |
| `backup.py` | `BackupManager` |
| `environment_docs.py` | `EnvironmentDocs` |

`settings.py`（`SettingsStore`）和 `yamlutil.py`（`YAMLScalars`）第一阶段已有，
这次只补了 `format_scalar`。

界面新增：页面（列表 + front-matter 表单 + 关联资源 + 被引用）、
构建与预览、配置（表单 / 原文 / 站点→主题同步）、主题（已安装 + 市场）、
Git、备份、环境（工具链体检 + 安装说明）。

### 三个和 Swift 版不一样的地方（都是有意的）

**1. YAML 改写用源码坐标做外科手术，而不是自研解析器。**
Swift 版自己写了 1200 多行 YAML 解析器。Python 版用 PyYAML 的
`compose()` 拿节点树——每个节点都带 `start_mark` / `end_mark`（精确到字符下标），
于是「改一个值」可以只替换那一段文本，注释、引号风格、键顺序一个字节不动。

代价是**不合法的 YAML 拒绝写入**（`set` 返回 `None`），退化成只读。这个取舍
是有意的：配置改坏了很难恢复，而「读不到某个键」只是界面上少显示一项。

**2. 备份用标准库 `zipfile`，不 shell 出 `zip` / `unzip`。**
Windows 默认没有这两个命令。Swift 版用外部命令还踩过两个坑（`-x` 排除
不生效、管道缓冲互相等待），标准库一次绕开。

**3. Windows 不跑 shell bootstrap。**
macOS 上要从 Dock 启动的进程不读 `.zshrc`，所以得起一个登录 shell 抓真实
PATH。Windows 图形进程拿到的 PATH 已经包含用户级和系统级路径，额外跑一遍
反而可能把环境弄坏。`ShellEnvironmentResolver.resolve()` 在 Windows 上
直接返回继承环境。

### 两个照原样保留的「反直觉」行为

**`ConfigSync.theme_only_entries` 不是差异，是提示。**
很多人把头像直接写在主题配置里，站点配置压根没这个键。按「站点配置是权威源」
去清掉主题的值，等于用户配好的头像当场消失。所以这类单独列出、只告知，
由用户点「搬到站点配置」。

**`custom_content` 的注入脚本必须用 `_after_html_render`。**
Hexo 8 里 `after_generate` 的 data 是 null。而且不同版本传字符串还是
`{path, content}` 对象不一致，脚本里先归一化，**任何分支都保证返回值非空**
——返回空等于把整站渲染成 0 字节。测试里盯着这两条。

### 验证

- `python -m pytest tests/ -q`：**472 passed**（第一阶段 199 条，新增 273 条）
- `python tools/verify_ui_headless.py`：无 JS 报错，六个新页面都能渲染
  （页面 2 条 / 表单 4 个控件、配置 3 个字段 + 同步按钮、主题 4 行 + 搜索框、
  备份 1 行、环境 10 行工具链 + 4 张文档卡），切语言仍不重载页面
- 跑完清理：无残留 chromium / playwright 进程

### 已知未实测

机器上能验的都验了（pytest + 无头 chromium），下面这些**必须真机确认**：

- **Windows**：从来没在这台机器上跑过。具体风险点：
  - `node_modules/.bin/hexo` 是 `.cmd` 脚本，`is_executable` 靠扩展名判断，
    没在真 Windows 上验证过
  - `explorer.exe /select,` 的路径引号规则（含空格的目录）
  - `%APPDATA%/HexoManPy` 目录创建与权限
  - pywebview 在 Windows 上的窗口 / 文件对话框外观
- **macOS 真机**：PyWebView 窗口需要手动激活一次才上前台（从终端启动时）；
  `hexo server` 预览页在真实站点上的渲染
- **真实站点上的主题切换**：只验过「注释和键顺序保留」，没在装了
  next / fluid / matery 的站点上验过切换后的实际渲染
- **备份恢复在真实大站点上的耗时**：单测用的是几十个文件的假站点；
  Swift 版记录过 152MB 站点的遍历时间，Python 版没实测过同等规模
- **HEIC 转 PNG**：Pillow 是可选的，没装时按 Swift 版「转不动也照写」的行为
  处理（扩展名给 png、内容原样）。真机上要确认装了 Pillow 时的转换质量

## 2026-11-21 · Python + PyWebView 重构：第三阶段

### 做了什么

补齐 Swift `Core/` 里剩下的部分，并给「配置 / 主题 / Git / 站点」四块装上真实的写操作。

| 模块 | 文件 | 负责什么 |
|---|---|---|
| SiteSettings | `hexoman/site_settings.py` | 站点常用配置项的读写、分组、双语标签 |
| HexoCLIBootstrap | `hexoman/hexo_bootstrap.py` | 定位 hexo，找不到时用用户的 npm 装一份到站点里 |
| 站点创建 | `hexoman/site_creator.py` | 模板列表、`hexo init`、`npm install` |
| 主题安装与迁移 | `hexoman/theme_installer.py` | 装主题、算出「换主题后哪些键要搬」 |
| Git 单文件操作 | `hexoman/git_service.py` | 暂存/取消暂存单个文件、看单个文件的 diff |
| 图片入库 | `hexoman/api.py` | 把拖进来或选进来的图片拷进 `source/images` 并按日期分目录 |

界面侧把原来六个 `SOON` 占位页换成真实现：页面、构建与预览、配置、主题、Git、备份、环境。

### 一个改掉的行为：换主题不再往配置里塞第二个 `theme` 键

`_config.yml` 里 `theme` 写成嵌套结构（映射或序列）时，换主题会在文件末尾再
追加一行 `theme: <名字>`，文件里因此出现两个同名顶层键。YAML 解析时后者覆盖
前者，用户原来配的嵌套结构被悄悄废掉，界面上只表现为「换完主题配置就没了」。

原因是 `switch_theme` 在 `document.set()` 返回 `None` 时无条件调用
`_append_top_level`，而后者的注释写的是「只在 `theme` 键不存在时用」，代码却
没检查键到底在不在。`config_sync` 里有一份同名副本，同样的毛病。

两处都在追加前先查顶层键，已存在就返回 `None`，调用方据此报 `switchFailed`
而不是写出坏配置。

### 验证

- `python -m pytest -q`：**596 passed**
- `python tools/mutate_hexoman.py`：11 条变异，抓住 10、已知行为等价 1、漏网 0
  （等价的那条是 `PageStore.scan` 里跳过隐藏目录的剪枝——正确性由
  `_make_page_file` 的二次过滤守着，剪枝只为不去 stat `.git` 里的对象）
- 换主题的五种输入手工过了一遍：正常标量替换、嵌套映射报错、序列报错、
  无 `theme` 键追加、空文件报错，文件都没有被写坏

### 已知未实测

同第二阶段，另外补两条：

- **`chooseFile` 没有对应实现**。Swift 版用它选 zsh 配置文件和 hexo 可执行
  文件（`BuildView`），Python 版只有 `choose_directory`。这两个入口目前在
  Python 版里没有等价交互。
- **主题迁移清单**只在构造出来的配置上验过，没在真装了 next / fluid / matery
  的站点上确认搬迁结果不影响渲染。

## 2026-11-21 · Python + PyWebView 重构：第四阶段（把接口接到界面上）

### 做了什么

第三阶段补的十二个桥接方法（`getSiteSettings` / `createSite` / `applyTheme` /
`stageGitFile` 等）后端能用、测试也覆盖，但界面上一个入口都没有——数据有了，
用户点不到。这一阶段就是把它们接出去。

- **站点设置**：侧栏新增一个视图，按分组渲染常用配置项，改完即写。文本项回车
  提交，开关和下拉一改就写。写失败会把界面拉回真值并提示，不让用户停在「看
  起来改了、其实没写成」的状态。
- **新建站点**：站点管理页加「新建站点」，弹窗里填名称、选父目录、挑模板、
  决定要不要顺手装依赖。名称或父目录为空时「创建」按钮是禁用的——弹窗按下
  确认就关，事后才发现填错只能重来一遍。
- **安装依赖**：同样在站点管理页，对当前站点跑一次 `npm install`。
- **Git 改动文件**：原来只显示「N 处改动」，现在列出已暂存 / 已修改 / 未跟踪 /
  有冲突四组，每行能单独暂存、取消暂存、对比。
- **主题**：主题页加「安装主题」，填 npm 包名后装并切过去；如果后端算出可迁移
  的公共项，接着弹出勾选清单。

### 一个真的 bug：换主题后永远拿不到迁移清单

`applyTheme` 原来的顺序是「写新 `theme` → 算迁移清单」。而 `compute_migration`
正是靠站点配置里的 `theme` 和目标名不同来认定哪份是旧主题配置；写完之后两者
已经同名，它直接返回 `None`。接口不报错，只是清单永远为空，界面上的迁移入口
等于摆设。

改成先算再写。`tests/test_api_phase3.py::TestApplyThemeReportsMigration` 盯着
这条：把两步顺序换回去，测试当场红（`migration` 是 `None`）。

### 验证

- `python -m pytest -q`：**597 passed**
- `python tools/verify_ui_headless.py`：真 Chromium 里点出来的结果——
  - 站点设置：1 张分组卡、3 个字段、文本框里是后端给的真值「我的博客」，
    嵌套块字段显示提示而不是可编辑控件
  - Git：3 行改动文件、6 个按钮、3 个分组标题，已暂存那行的按钮文案是
    「取消暂存」
  - 新建站点：弹窗能开，2 个模板渲染出来，名称为空时「创建」禁用，填完后
    解禁，取消能关掉
  - 中英切换后导航包含「站点设置 / Site Settings」，页面不重载，`js errors` 为空
- 前端 i18n 守卫（`tests/test_ui_assets.py`）在这一阶段抓到两个漏加的键
  （`siteWizard.installDependenciesNow`、`siteWizard.dependenciesInstalled`），
  已补齐。缺键时 `t()` 会把键名印到界面上，这条守卫是唯一能提前发现它的地方。

### 已知未实测

- **新建站点、安装依赖、安装主题都只验到界面和假后端**。真跑 `hexo init` 和
  `npm install` 需要本机有 hexo / npm，且耗时以分钟计，这一轮没有真实执行。
- **`diffGitFile` 会调起系统 difftool**，headless 环境里调不起来，只确认了
  按钮发出请求。
- **站点的图片插入（`storeImages`）仍没有界面**。桥接方法在，编辑器里没有入口。
- `HexoManModel` 里剩下的小动作仍未暴露：`toggleDraft`、批量加标签、批量设
  布局、批量删页面、`filteredPosts` 的多面筛选。后端方法大多已有，缺的是桥接
  和按钮。
- `AppLanguage` 的 `system`（跟随系统）档位仍未实现，目前只有 zh / en 两档。


