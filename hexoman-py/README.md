# HexoMan（Python + PyWebView 版）

用 Python + [PyWebView](https://pywebview.flowrl.com/) 重写的 Hexo 站点管理工具，
**同时支持 macOS 和 Windows**。

Swift 版还在仓库根目录的 `HexoMan/` 下（macOS 26+ / SwiftUI）。
这里是并行的第二个实现，不替代它——Swift 版仍然是功能规格的权威来源。

## 这一版做了什么

**已完成**

- **站点管理**：添加站点目录（判定标准：有 `package.json` 且声明了 hexo 依赖 +
  `_config.yml`）、切换站点、从列表移除（**只从列表移除，不删磁盘文件**）、
  按上次打开时间排序
- **文章**：左侧列表 + 右侧详情；按标题/正文/标签搜索；按「全部/已发布/草稿」筛选；
  新建文章；编辑标题、日期、标签、分类、草稿开关、正文；实时字数
- **页面**：扫描 `source/` 下除文章外的内容（`about/index.md`、
  `friends/index.md` 这类）；按**文件里实际有的字段**生成表单；
  新建 / 编辑 / 删除；显示关联的本地资源（css/js/图片）与被哪些文章引用
- **配置**：`_config*.yml` 列表；按 YAML 形状自动生成表单（标量→输入框、
  true/false→开关、纯数字→数字框、有候选项→下拉）；原始文件编辑；
  **站点配置 → 主题配置同步**（只同步含义一致的键，修掉「改了头像没反应」）
- **主题**：扫描 `node_modules/hexo-theme-*` 与 `themes/`；切换主题（只改
  `theme` 一行）；生成主题配置文件；市场搜索（内置精选 + 可选联网）
- **构建与预览**：生成 / 清理 / 启动·停止预览 / 打开预览页；
  `hexo server --draft` 开关
- **Git**：状态、最近提交、提交全部改动、推送、拉取
- **备份**：遍历时按目录名剪枝（不碰 `node_modules` / `.git` / `public`）、
  备份前预估范围、创建 / 列出 / 恢复 / 删除
- **环境**：node / npm / npx / hexo / git 体检 + 人话诊断 + 内置安装说明
- **Markdown 预览**：编辑器旁边实时渲染，带 pygments 语法高亮。
  front matter 是 YAML 头部，**不会渲染进正文**
- **总览**：站点路径、Hexo 版本、主题及版本、文章数、依赖是否已安装、最近 5 条提交
- **界面**：左侧站点切换器 + 功能栏，右侧内容区；深浅色跟随系统；
  中英双语，**切换立即生效**（不重启、不重载页面）

**刻意没做**

- **创建新站点**：Swift 版也没有。创建站点要装依赖、跑 `hexo init`，
  属于另一条产品线。
- **装 / 卸主题**：市场里只做搜索和「装好后切换」，不代跑 `npm install`——
  在别人的仓库里执行包管理器是很容易出事的操作，交给用户自己在终端里做。
- **主题预览网页**：Swift 版用 WKWebView 内嵌预览，需要一个真实的站点地址；
  Python 版还没做，市场里只显示描述和主页链接。
- **文章插图**：`SiteMedia` 的逻辑都迁过来了（存 `source/images/<年>/`、
  同名不覆盖、HEIC 转 PNG），但界面还没接「粘贴/拖拽插图」的入口。

## 跑起来

```bash
cd hexoman-py
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python3 main.py
```

Windows 上把 `source .venv/bin/activate` 换成 `.venv\Scripts\activate`。

## 目录结构

```
hexoman-py/
  main.py                 入口：起 pywebview 窗口
  hexoman/
    __init__.py
    api.py                暴露成 window.hexoman 的 JS API
    model.py              数据模型（Site / BlogPost / SiteInfo）
    sites.py              站点管理：判定、探测、增删切换
    posts.py              文章：读写、搜索、筛选
    pages.py              页面：扫描、按字段生成表单、新建/编辑/删除
    page_assets.py        页面关联的本地资源（css/js/图片）
    page_reference.py     哪些文章引用了某个页面
    frontmatter.py        front-matter 解析与保真回写
    yamlutil.py           YAML 读取（含手写兜底解析、标量渲染）
    yaml_path.py          YAML 按路径读写（带源码坐标，只动改到的那一段）
    config_file.py        _config*.yml 读写与写后核对
    config_schema.py      把 YAML 形状变成表单控件
    config_docs.py        每个配置项的填写文档（含枚举值的后果说明）
    config_sync.py        站点配置 → 主题配置同步
    theme_manager.py      主题扫描、切换、配置生成
    theme_registry.py     主题市场（内置精选 + npm 搜索）
    backup.py             备份 / 恢复（遍历时剪枝）
    custom_content.py     往每页注入自定义 head/body 内容
    snippet_library.py    常用代码片段
    environment_docs.py   环境安装文档数据
    shell_environment.py  抓用户真实 shell 环境（macOS）
    shell_runner.py       子进程执行 + 日志面板
    hexo_environment.py   node/npm/hexo/git 工具链体检
    site_media.py         插图：存 source/images/<年>/，同名不覆盖
    markdown_render.py    Markdown 渲染 + 代码高亮
    hexo_cli.py           定位 hexo 可执行文件、组装命令
    git_service.py        git status / log / commit / push / pull
    process.py            子进程执行（平台差异集中处之一）
    system_integration.py 平台差异集中处：打开文件/目录/浏览器、剪贴板
    settings.py           settings.json 读写
    i18n.py               中英文案
    ui/
      index.html
      style.css
      app.js
  tests/                  pytest
  tools/
    preview.py            本地预览服务器（假后端，开浏览器就能看界面）
    verify_ui_headless.py 无头界面验证（playwright，不开窗口）
```

## 设计要点

### 界面不碰文件系统

所有读写在 `hexoman/` 里完成，`ui/app.js` 只通过 `window.hexoman` 拿数据。
这和 Swift 版「界面不碰文件系统」的原则一致。

### JS API 的命名

pywebview 把 Python 的方法名**原样**暴露给 JS。这一层是给 JS 用的，
所以公开方法统一 camelCase（`getState` / `listPosts` / `renderMarkdown`…），
内部状态统一加下划线前缀（`_settings` / `_site_list`…）。

加下划线不只是风格问题：**pywebview 会递归暴露非可调用的对象属性**，
不加前缀的话设置文件里的站点列表也会变成 JS 可访问的东西。
`tests/test_api.py` 里有测试盯着这条。

### 语言切换不重载页面

文案字典在 Python 里（`i18n.py`），切换语言时前端调 `setLanguage()` 拿到新字典，
然后只重绘文本节点。页面不重载，滚动位置、选中状态、编辑中的内容全部保留。

### front matter 保真

`frontmatter.py` 把 front matter 拆成两份：**结构化数据**（PyYAML 解析，供界面读）
和**原始行**（原样保留，供回写时逐行替换）。

回写时只动「我们改过的键」，其它行一个字节都不动。
用 `yaml.dump` 序列化回去会洗掉注释、引号风格和键顺序——
用户只是改了个标题，文件却面目全非。

### `_config.yml` 也保真：只替换改到的那一段

`yaml_path.py` 用 PyYAML 的 `compose()` 拿带源码坐标的节点树——每个节点都
知道自己在原文里占了哪一段字符。改一个值就只替换那一段：

```
theme: yun          →   theme: landscape
```

注释、缩进、键顺序全部原样保留。代价是**不合法的 YAML 拒绝写入**（只读），
因为改坏的配置文件很难恢复。

### 子进程必须继承用户真实的 shell 环境

从 Dock / 访达 / 开始菜单启动的图形程序**不读** `~/.zshrc`。后果是
「终端里 `hexo -v` 好好的，HexoMan 里说找不到」——用户完全不知道问题在哪。

`shell_environment.py` 起一个 zsh，把 `.zshenv` / `.zprofile` / `.zshrc`
按 zsh 的加载顺序 source 一遍，抓下真实的 PATH，缓存一次给所有子进程用。
Windows 不需要这一步（图形进程已经拿到用户级和系统级 PATH）。

### 平台差异集中

`system_integration.py` 和 `process.py` 是仅有的两处碰平台差异的地方：

| 事情 | macOS | Windows |
| --- | --- | --- |
| 在文件管理器中显示 | `open -R` | `explorer.exe /select,` |
| 用默认程序打开 | `open` | `os.startfile` |
| 复制到剪贴板 | `pbcopy` | `clip` |
| 配置目录 | `~/Library/Application Support/HexoManPy` | `%APPDATA%/HexoManPy` |
| 全局 hexo 候选路径 | `/usr/local/bin`、`/opt/homebrew/bin`、`~/.nvm/...` | `%APPDATA%/npm`、`%PROGRAMFILES%/nodejs` |

**不支持 Linux**，代码里也没有 Linux 分支。

配置目录**刻意不跟 Swift 版共用**（Swift 用 `HexoMan/`，这里用 `HexoManPy/`）——
两边字段语义不完全一样，共用一个文件会互相覆盖对方的设置。

## 测试

```bash
python3 -m pytest -q
```

当前 **472 条**，覆盖全部业务模块。规矩：

- **单元测试不联网、不跑真 hexo / git 命令。**
  `process.NullCommandRunner` 是个假 runner，记录调用、返回假结果；
  主题市场的联网测试注入假的 fetch 函数。
- **测试不碰用户的真实站点目录、真实设置、真实备份夹。**
  站点都在 `tmp_path` 里造，`SettingsStore` 和 `BackupManager` 的目录
  都显式传临时路径。
- 有一个测试专门盯着「前端用到的文案 key 必须都存在」——
  key 写错时界面会显示 `posts.split` 这种字符串，肉眼很难发现。
- 有几个测试盯着「改坏了会出事」的地方：
  `_after_html_render` 必须注册（`after_generate` 在 Hexo 8 里拿不到 HTML）、
  注入脚本任何分支都要返回非空、配置写盘后要重新读一遍核对、
  主题市场的 `publisher` 字段对象和字符串两种形状都要认。

## 无头验证界面

```bash
python3 tools/verify_ui_headless.py
```

用 playwright 的 headless chromium 跑一遍界面，检查：页面能加载、没有 JS 报错、
各页面能渲染、预览有高亮、切语言立刻生效且不重载页面。
跑完就退出，不留进程、不占端口。

产出两张截图到 `docs/`。

## 已知限制

- pywebview 的窗口在 macOS 上需要手动激活一次才上前台
  （从终端 ``python3 main.py`` 启动时）。从 Finder / 启动器启动正常。
- 预览服务（`hexo server`）的输出没有做实时日志面板，
  只在操作完成后显示结果。
- 目录选择框用 Tk 的原生对话框。精简安装的 Python 可能没有 Tk，
  这时会退回「手动粘贴路径」。
- **Windows 没有在真机上验证过。** 带 `.cmd` 的 `node_modules/.bin/hexo`
  识别、`explorer.exe /select,` 的路径引号、`%APPDATA%` 目录权限都属于
  「写对了但没跑过」的状态。
- HEIC 转 PNG 依赖可选的 Pillow。没装时按「转不动也照写」处理
  （扩展名给 png、内容原样），插进去仍然是一张裂图。
