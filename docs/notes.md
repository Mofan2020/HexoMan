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
- 顶栏菜单（macOS menubar）切语言后会闪一下——这是 Apple 框架限制，
  README 会在 PR2 阶段提到。