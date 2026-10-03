# HexoMan

面向 macOS 的 Hexo 站点管理工具。把「加站点、写文章、生成预览、改配置、看 Git」这几件每天都要做的事收进一个原生 SwiftUI 窗口，文章和配置始终是你磁盘上那些 Markdown 和 YAML，HexoMan 不另建一套数据。

<!-- 截图：把主窗口截图放到 docs/screenshot-overview.png 后改成
![总览页](docs/screenshot-overview.png) -->

## 功能特性

左侧是站点切换器和功能栏，右侧是内容区。除「站点管理」外，其余页面都需要先选中一个站点。

### 站点管理

- 用「选择站点目录…」或粘贴绝对路径添加站点
- 判定标准是：目录下有 `package.json`（且声明了 hexo 依赖）和 `_config.yml`
- 多个站点可共存，按上次打开时间排序，点一行即切换
- 每个站点可以在访达中打开，或从列表移除（**只从列表移除，不删磁盘文件**）
- 当前站点不能直接移除，需先切到别的站点

### 总览

- 五张指标卡：文章数、Hexo 版本、主题及主题版本、构建产物文件数、依赖是否已安装
- 依赖未安装时给出可操作提示，并提供「打开站点目录」按钮
- 站点详情：站点路径、Hexo 来源、实际命令预览、是否为 Git 仓库、远端地址、预览端口
- 快捷操作：生成站点、清理、启动/停止预览、打开预览页、在访达中显示、刷新 Git 状态
- 最近 5 条提交，可一键跳到完整 Git 页面

### 文章

- 左侧列表 + 右侧详情；支持按标题、正文、标签搜索
- 按「全部 / 已发布 / 草稿」筛选
- 新建文章：填标题、标签、分类后直接进入编辑器
- 编辑器里可改标题、日期、标签、分类、草稿开关和正文，实时显示字数
- 详情页显示日期、字数、文件大小、slug、文件名、最后修改时间、标签与分类
- 一键发布 / 转为草稿（改 front-matter 里的 `draft`）
- 删除走废纸篓，可恢复
- 在访达中显示文章文件

### 构建与预览

- 顶部展示构建环境：站点路径、Hexo 来源、实际会执行的命令行
- 执行 `hexo clean`、`hexo generate`
- 启动/停止本地预览服务，端口可调（1024–65535），显示预览地址
- 一键在浏览器打开预览页、在访达中打开 `public` 目录
- 显示构建产物状态和文件数量
- 下半屏是日志控制台，实时显示命令输出，可清空

### 配置

- 列出并编辑站点根目录下的所有 `_config*.yml`（主配置排第一，主题配置按名字排序）
- 顶部有顶层键快捷跳转，点一下就滚动并选中对应行
- 保存前做基本校验：空内容、含 Tab、缩进不是空格倍数会先提示确认
- 支持放弃改动、重新从磁盘读取、在访达中显示

### Git

- 仓库状态：当前分支、领先/落后提交数、上游分支、`git status` 摘要
- 变更文件按「已暂存 / 已修改 / 未跟踪」分组，点击可在访达中打开站点目录
- 提交信息 + 「提交全部改动」（`git add -A` 后提交，含未跟踪文件）
- 拉取（`git pull --rebase`）、推送（没有待推送提交时按钮禁用）
- 远端列表
- 提交历史列表（短 hash、标题、作者、日期）
- 下方日志控制台显示 git 命令的真实输出
- 站点不是 Git 仓库时，给出 `git init` 命令并可一键复制到剪贴板

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | macOS 26 或更高版本 |
| 从源码构建 | Xcode 26 或更高版本（本工程部署目标为 macOS 26.0） |
| 工程生成 | [XcodeGen](https://github.com/yonaskolb/XcodeGen) |

### 依赖请自己装，HexoMan 一个都不带

HexoMan **不自带** Node.js、npm、git、hexo，也没有任何内嵌运行时。它只调用你系统里已经装好的那一份。

| 命令 | 为什么需要 | 怎么装 |
| --- | --- | --- |
| `node` / `npm` | 跑 hexo、装站点依赖和主题 | `brew install node`，或去 [nodejs.org](https://nodejs.org) 装官方包（建议 18 以上，Hexo 8 需要） |
| `hexo` | 只有「创建新站点」这一步需要 | 不用装。HexoMan 会用你的 npm 在自己的目录里装一份 `hexo-cli`，见下 |
| `git` | 「Git」页面的提交 / 推送 / 拉取 | `xcode-select --install`（Xcode 自带）或 `brew install git` |

「构建与预览」页有一个**运行环境体检**面板，会如实报告每个命令的版本和解析到的绝对路径，缺什么直接给安装命令。点「重新检测」会强制重读一次你的 shell 配置。

### 为什么要读 zsh 配置

从 Dock 或访达启动的图形程序**不会**加载 `~/.zshrc`，而 Homebrew 的环境变量正是靠 `eval $(brew shellenv)` 写进 PATH 的。结果就是：终端里 `node` 是 `/opt/homebrew/bin/node`，HexoMan 里却只有 `/usr/bin:/bin`，什么都找不到。

HexoMan 的做法是启动时跑一次 zsh，按标准顺序 source 你的 `.zshenv` → `.zprofile` → `.zshrc`，把 resulting environment 抓下来缓存，之后所有子进程继承这份环境。这样你终端里能用的 node，HexoMan 里一定能用。

- rc 文件按 `$ZDOTDIR` → `$HOME` 定位，和 zsh 自己的规则一致
- rc 文件的输出和警告会被丢掉，不污染 HexoMan 的日志面板
- 额外把 `/opt/homebrew/bin` 等常见前缀**前置**到 PATH，brew 没写进 rc 文件时也兜得住
- 只付一次代价：实测首次约 2 秒（你的 rc 里有 starship / orbstack / brew shellenv），之后每条命令 0.1~0.8 秒

不想让它读就在体检面板里关掉「读取 zsh 配置」，手动填 rc 文件路径也行。

## 安装与运行

### 方式一：下载 Release

1. 从 [Releases](https://github.com/Mofan2020/HexoMan/releases) 下载 `HexoMan-<版本>-macos.zip`
2. 解压得到 `HexoMan.app`，拖进「应用程序」

**首次打开会被 Gatekeeper 拦住，这是预期行为。** Release 里没有 Apple 开发者证书，app 是 ad-hoc 签名的，也没有经过 Apple 公证，所以 macOS 不允许直接双击打开。两种解决办法，任选其一：

- 右键（或按住 Control 点击）`HexoMan.app` → 选「打开」→ 在弹窗里再点一次「打开」
- 或者在终端里去掉隔离属性：

```bash
xattr -dr com.apple.quarantine /Applications/HexoMan.app
```

去掉之后就可以正常双击启动。

### 方式二：从源码构建

```bash
brew install xcodegen      # 生成工程用，仓库里不含 .xcodeproj
xcodegen generate          # 生成 HexoMan.xcodeproj
open HexoMan.xcodeproj     # 选中 HexoMan scheme 运行
```

命令行出包：

```bash
./scripts/build-release.sh   # 产物在 build/release/HexoMan.app
```

## 使用指南

### 添加站点

打开左侧「站点管理」→ 点「选择站点目录…」→ 选中 Hexo 项目根目录（就是有 `_config.yml` 和 `package.json` 的那一层）。

添加后 HexoMan 会立刻探测站点：读 `title` / `url` / `theme`、从 `package.json` 找 hexo 和主题的版本号、检查 `node_modules` 是否就绪、判断是不是 Git 仓库并从 `.git/config` 里读出远端地址。

### 站点依赖

依赖没装时，总览页和构建页会给出提示。到「站点管理」点「安装依赖」即可，HexoMan 会用你系统里的 npm 在站点目录跑 `npm install`；装好后 hexo 命令就走站点本地的 `node_modules/.bin/hexo`，版本和 `package.json` 严格一致。

### 写文章

「文章」页左上角「新建」→ 填标题（必填）、标签、分类 → 创建后自动进入编辑器写正文 → `⌘S` 保存。

文件会写到站点的文章目录下（见下文「工作原理」），文件名由标题转成 slug，重名自动追加序号。删除文章进的是废纸篓而不是直接删除。

### 生成与预览

「构建与预览」页 →「生成站点」执行 `hexo generate`，产物落在 `public`。想边写边看就点「启动预览」，然后「打开预览页」在浏览器里看。端口改动需要先停止再启动预览才生效。

### 改配置

「配置」页选一个 `_config*.yml`，用顶部键条快速跳转，改完 `⌘S` 保存。保存只写回文件本身，**不会自动跑 generate**，配置生效需要再去构建页跑一次。

### Git 面板

「Git」页填提交信息点「提交全部改动」即可；「拉取」用 `git pull --rebase`，「推送」在没有待推送提交时是禁用的。存在冲突时页面顶部会红框列出冲突文件，需要手动解决后再提交。

### 键盘快捷键

| 快捷键 | 作用 | 位置 |
| --- | --- | --- |
| `⌘N` | 跳到「文章」页（新建按钮在文章页左上角） | 菜单 |
| `⇧⌘O` | 跳到「站点管理」页 | 菜单 |
| `⌘R` | 刷新当前站点的全部数据 | 菜单 |
| `⌘B` | 生成站点（`hexo generate`） | 菜单 |
| `⇧⌘R` | 启动 / 停止预览服务 | 菜单 |
| `⌥⌘P` | 在浏览器打开预览页 | 菜单 |
| `⌘E` | 打开当前选中文章的编辑器 | 文章详情页 |
| `⌘S` | 保存（文章编辑器、配置编辑器） | 编辑器内 |

菜单里带站点的操作在未选中站点时是禁用的。

## 工作原理

这一节说明 HexoMan 到底在你机器上做了什么，方便你判断哪些行为可以信任。

### 怎么找到 hexo 可执行文件

`HexoService.resolveInvocation` 按固定优先级选一个（侧边栏底部会显示当前用的是哪一种）：

1. **自定义路径**：你在「构建与预览」页手填的可执行文件
2. **站点本地依赖**：`<站点>/node_modules/.bin/hexo`，存在且可执行就用它——最准，版本一定和站点 `package.json` 一致
3. **用户 PATH**：你 shell 环境里的 `hexo`（`npm i -g hexo-cli` 装的那种），走上面那套 zsh bootstrap 读到的真实 PATH
4. **常见全局前缀**：`/usr/local/bin/hexo`、`/opt/homebrew/bin/hexo`、`~/.nvm/versions/node/<最新版本>/bin/hexo`
5. **HexoMan 自装**：之前「创建新站点」时自举出来的那份
6. **npx**：以上都没有时退回 `npx hexo`，界面上标注为「npx（将临时下载）」

命令实际执行时会把可执行文件和参数打印在「构建与预览」页的「命令预览」里，可以直接看到会跑什么。

### 创建站点时怎么拿到 hexo-cli

只有 `hexo init` 这一步必须先有 hexo-cli，而让用户自己去 `npm i -g hexo-cli` 太麻烦。所以 HexoMan 会用**你自己的 npm** 在 `~/Library/Application Support/HexoMan/cli` 装一份 `hexo-cli`：

1. 先找现成的：手填路径 → 你 PATH 里的 hexo → HexoMan 之前自装的那份
2. 都找不到才现场 `npm install hexo-cli`，装在 HexoMan 自己的目录下
3. `hexo init` 成功后，在新站点里跑 `npm install`，hexo 就成了站点本地依赖，自装的那份从此不再参与

装在 Application Support 而不是全局，是为了不污染你的全局 `node_modules`：删掉 HexoMan 就等于连它一起删干净，而且不会往任何 shell 配置文件里写东西。

### 文章存在哪

文章就是站点文章目录下的 Markdown 文件，**没有数据库**。目录位置从 `_config.yml` 里读：优先 `new_dir`，其次 `<source_dir>/_posts`，读不到就按默认的 `source/_posts` 算。

每个文件开头用 `---` 包起来的 front-matter 被解析成标题、日期、标签、分类、草稿状态。解析保留原始键值和顺序，目标是「读到什么样，写回去就还什么样」——改一次标题不会把你手写的其他字段格式洗掉。日期支持 `YYYY-MM-DD HH:mm:ss` 和 `YYYY-MM-DD` 两种写法。

配置和文章的读写都直接走文件系统，没有中间缓存或中间数据库。

### HexoMan 不做的事

不联网、不上传任何内容到外部服务、没有账号体系、没有自动更新、没有崩溃上报、没有云同步。配置只落在本机的 `~/Library/Application Support/HexoMan/settings.json`。

## 自定义内容是怎么注入的

「加个 banner 要去哪改」是小白卡住频率最高的问题，答案通常是「不知道」。常见误区是去 `themes/landscape/layout/` 改模板——那在 `npm install` 时会被覆盖，升级主题就白改一次。

HexoMan 的做法是自动在站点里生成一对文件：

| 文件 | 谁维护 | 作用 |
| --- | --- | --- |
| `scripts/hexoman-inject.json` | 你（通过 HexoMan 界面） | 填的 HTML，分 head 和 body |
| `scripts/hexoman-inject.js` | HexoMan | 注入逻辑，读 json 并插到每页 |

注入走 Hexo 的 `_after_html_render` 钩子，在每页 `</head>` / `</body>` 前插入。相比改主题源码有三个好处：

- 升级主题、重新 `npm install` 都不会丢
- 不依赖主题支不支持某个注入目录，**换任何主题都通用**
- 删掉这两个文件就等于彻底关掉这个功能，站点里没有任何残留

> **实现上的一个坑**：`_after_html_render` 的入参在不同 Hexo 版本里不一样——Hexo 8.1.2 实测传的是**字符串**，而传 `{ path, content }` 对象的版本也存在。生成的脚本对两种形态都做了兼容，并且**任何分支都保证返回值非空**。这一条不是洁癖：早期按「对象」写导致 filter 返回 `undefined`，构建不报错、照常显示 `46 files generated`，但产物 HTML 全部变成 0 字节，整个站点被静默清空。

## 配置存放

`~/Library/Application Support/HexoMan/settings.json`，包含：

- `sites`：已知站点列表（路径 + 上次打开时间）
- `lastSitePath`：上次打开的站点
- `serverPort`：预览端口，默认 4000
- `autoScrollLog`：日志是否自动滚动到底
- `customHexoPath`：手填的 hexo 可执行文件路径，空表示自动探测
- `usesShellEnvironment`：是否用 zsh 读取 rc 文件获得真实 PATH，默认 `true`
- `customRCPath`：手填的 zsh rc 文件路径，空表示自动按 `$ZDOTDIR` → `$HOME` 找

应用退到后台或关窗口时会自动落盘。删掉这个文件等于恢复出厂设置，不影响你的站点文件。

## 开发

### 目录结构

```
HexoMan/
├── HexoManApp.swift        应用入口、菜单栏、快捷键
├── Core/                   与界面无关的模型和文件读写
│   ├── HexoManModel.swift  状态中枢，所有界面只跟它打交道
│   ├── HexoSite.swift      站点模型与站点探测
│   ├── BlogPost.swift      文章模型与 source/_posts 下的文件读写
│   ├── FrontMatter.swift   front-matter 解析与回写
│   ├── ConfigFile.swift    _config*.yml 的列出与读写
│   ├── SiteSettings.swift  常用配置项的可视化读写（保真，不动嵌套块）
│   ├── CustomContent.swift head/body 自定义注入的配置与脚本
│   ├── SnippetLibrary.swift 常见代码片段（banner/统计/CSS/JS）
│   ├── GitService.swift    git status / log / commit / push / pull
│   ├── HexoService.swift   hexo 可执行文件定位与命令组装
│   ├── HexoCLIBootstrap.swift  创建站点时用用户的 npm 自举 hexo-cli
│   ├── ShellRunner.swift   子进程执行、实时日志、shell 环境缓存
│   ├── ShellEnvironment.swift   zsh bootstrap，读 .zshenv/.zprofile/.zshrc
│   ├── HexoEnvironment.swift    node/npm/npx/hexo/git 工具链体检
│   ├── YAMLScalars.swift   YAML 顶层标量解析
│   ├── SettingsStore.swift settings.json 读写
│   └── SystemIntegration.swift 访达打开等系统交互
└── Views/                  界面
    ├── ContentView.swift   侧边栏 + 内容区的分发
    ├── SiteManagerView / DashboardView / PostsView
    ├── PostEditorView / BuildView / ConfigView / GitView
    ├── VisualConfigView  配置页的可视化那一半（表单 + 自定义内容）
    └── Components.swift    复用的卡片、标签、空状态、日志控制台
```

划分原则很简单：**界面不碰文件系统**。所有读写在 `Core/` 里完成，`Views/` 只从 `HexoManModel` 取状态、发出动作。

### 工程是生成出来的

`HexoMan.xcodeproj` 不入库，`project.yml` 是唯一真源。改了工程结构就改 `project.yml`，然后：

```bash
xcodegen generate
```

### 加一个新页面

1. 在 `Core/SidebarItem`（`HexoManModel.swift`）里加一个 case，填 `title` 和 `symbolName`
2. 在 `HexoMan/Views/` 下写对应 View
3. 在 `ContentView.content` 的 switch 里加一个分支，页面需要站点就包一层 `siteRequired { ... }`
4. `xcodegen generate` 后运行

界面需要的任何数据，从 `HexoManModel` 上取；需要新增文件读写能力，就在 `Core/` 里加一个新的 Store/Service，再从 model 暴露一个方法。

## 后续计划

- 应用内创建新的 Hexo 项目
- 应用内安装站点依赖
- 主题目录下的配置文件编辑

## License

[MIT](LICENSE) © 2026 Mofan2020
