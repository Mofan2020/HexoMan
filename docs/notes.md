# HexoMan 开发笔记

记这里的是「改了会影响其他维护者的判断」的事。不写实现细节（commit 里看），
不写 UI 文案（审查时被覆盖）。

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

- **JP 翻译**：未做。`Localizable.xcstrings` 里 `ja` 项不存在，
  `AppLanguage.ja` 选了之后 xcstrings 查不到就走英文 fallback。
  按 Q1=C 这一版不加。
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