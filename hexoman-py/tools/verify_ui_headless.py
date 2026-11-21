#!/usr/bin/env python3
"""无头界面验证：**不开任何窗口**。

用 playwright 缓存里的 chromium headless 跑一遍界面：
- 页面能加载，没有 JS 报错
- 各页面能渲染出来
- Markdown 预览有高亮
- 切换语言立刻生效（且不重载页面）

跑完就退出，不留进程、不占端口。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from playwright.sync_api import sync_playwright  # noqa: E402

UI_DIR = ROOT / "hexoman" / "ui"


def build_mock_script() -> str:
    """注入一个假后端。

    真的后端跑在 pywebview 里，headless 环境拿不到，所以这里用假数据。
    **渲染 Markdown 走真后端**——那一段用 HTTP 请求打回 Python，
    这样验的是真的渲染器输出，不是另一套实现。
    """
    from tools.preview import DEMO_OVERVIEW, DEMO_POSTS, DEMO_STATE  # noqa: PLC0415

    from hexoman import i18n  # noqa: PLC0415

    strings = {"zh": i18n.get_strings("zh"), "en": i18n.get_strings("en")}

    return """
<script>
(function () {
  var state = %s;
  var overview = %s;
  var posts = %s;
  var strings = %s;

  function respond(value) { return Promise.resolve(value); }

  window.hexoman = {
    getState: function () { return respond(state); },
    getStrings: function () { return respond({ ok: true, strings: state.strings }); },
    setLanguage: function (code) {
      if (!strings[code]) return respond({ ok: false, error: "unknown" });
      state.language = code;
      state.strings = strings[code];
      return respond({ ok: true, language: code, strings: state.strings });
    },
    listSites: function () {
      return respond({ ok: true, sites: state.sites, currentSitePath: state.currentSitePath });
    },
    addSite: function (p) {
      return respond({ ok: true, sites: state.sites, currentSitePath: state.currentSitePath, siteInfo: state.siteInfo });
    },
    removeSite: function (p) {
      return respond({ ok: true, sites: state.sites, currentSitePath: state.currentSitePath });
    },
    selectSite: function (p) {
      state.currentSitePath = p;
      return respond({ ok: true, sites: state.sites, currentSitePath: p, siteInfo: state.siteInfo });
    },
    chooseSiteDirectory: function () { return respond({ ok: false, error: "cancelled" }); },
    revealSiteDirectory: function () { return respond({ ok: true }); },
    listPosts: function () {
      return respond({ ok: true, posts: posts, tags: ["python", "hexo"], categories: ["技术"] });
    },
    getPost: function (p) {
      var f = posts.filter(function (x) { return x.path === p; })[0];
      return respond(f ? { ok: true, post: f } : { ok: false, error: "notFound" });
    },
    createPost: function (title) {
      var post = { path: "/tmp/x/new.md", filename: "new.md", slug: "new", title: title,
        date: "2026-11-20 12:00:00", timestamp: 1792555200, tags: [], categories: [],
        draft: false, body: "", wordCount: 0, byteSize: 0, modifiedAt: 1792555200, excerpt: "" };
      posts.unshift(post);
      return respond({ ok: true, post: post });
    },
    savePost: function (path, title, body, date, tags, categories, draft) {
      posts.forEach(function (p) {
        if (p.path === path) {
          p.title = title; p.body = body; p.date = date;
          p.tags = tags; p.categories = categories; p.draft = draft;
        }
      });
      return respond({ ok: true, post: posts.filter(function (p) { return p.path === path; })[0] });
    },
    deletePost: function () { return respond({ ok: true }); },
    revealPost: function () { return respond({ ok: true }); },
    renderMarkdown: function (text) {
      return fetch("/render", {
        method: "POST",
        headers: { "Content-Type": "text/plain; charset=utf-8" },
        body: text
      })
        .then(function (r) { return r.json(); })
        .then(function (d) {
          return respond({ ok: true, html: d.html, title: d.title,
            tags: d.tags, categories: d.categories, draft: d.draft });
        });
    },
    getOverview: function () { return respond(overview); },
    runGenerate: function () { return respond({ ok: true, exitCode: 0, output: "INFO  Generated 42 files" }); },
    runClean: function () { return respond({ ok: true, exitCode: 0, output: "INFO  Deleted db.json" }); },
    startPreview: function () { state.serverRunning = true; return respond({ ok: true }); },
    stopPreview: function () { state.serverRunning = false; return respond({ ok: true }); },
    openPreviewPage: function () { return respond({ ok: true }); },
    refreshGit: function () {
      return respond({
        ok: true,
        gitStatus: {
          branch: "main", upstream: "origin/main", ahead: 0, behind: 0,
          staged: ["source/_posts/a.md"],
          modified: ["_config.yml"],
          untracked: ["source/_posts/new.md"],
          conflicted: [],
          isClean: false,
          changeCount: 3,
        },
        commits: overview.commits,
      });
    },
    getSiteSettings: function () {
      return respond({
        ok: true,
        path: "/tmp/blog/_config.yml",
        groups: [
          {
            key: "basic",
            label: "站点信息",
            fields: [
              { id: "title", key: "title", label: "站点标题", hint: "显示在标签页的名字", group: "basic", kind: "text", options: [], value: "我的博客", isNestedBlock: false },
              { id: "rss", key: "rss", label: "生成 RSS", hint: "", group: "basic", kind: "boolean", options: [], value: "true", isNestedBlock: false },
              { id: "menu", key: "menu", label: "菜单", hint: "", group: "basic", kind: "text", options: [], value: "", isNestedBlock: true },
            ],
          },
        ],
      });
    },
    updateSiteSetting: function (path, key, value) {
      return respond({ ok: true, key: key, value: value });
    },
    listSiteTemplates: function () {
      return respond({
        ok: true,
        templates: [
          { key: "standard", title: "hexo（默认空白模板）", subtitle: "只生成骨架目录" },
          { key: "starter", title: "hexo-starter（示例模板）", subtitle: "含示例文章" },
        ],
      });
    },
    createSite: function (name, parent) {
      return respond({ ok: true, path: parent + "/" + name, dependencyFailed: false });
    },
    installDependencies: function () { return respond({ ok: true, path: "/tmp/blog" }); },
    applyTheme: function (pkg) {
      return respond({
        ok: true, installed: true, packageName: "hexo-theme-" + pkg, activeTheme: pkg,
        migration: {
          fromTheme: "yun", toTheme: pkg, hasItems: true,
          entries: [{ id: "title", key: "title", label: "站点标题", currentValue: "旧标题" }],
        },
      });
    },
    getThemeMigration: function () { return respond({ ok: true, migration: null }); },
    applyThemeMigration: function (keys) { return respond({ ok: true, applied: keys.length }); },
    stageGitFile: function (p) { return respond({ ok: true, path: p }); },
    unstageGitFile: function (p) { return respond({ ok: true, path: p }); },
    diffGitFile: function (p) { return respond({ ok: true, path: p }); },
    openPath: function () { return respond({ ok: true }); },

    // -- 第二阶段：页面 / 配置 / 主题 / 备份 / 环境 ----------------
    listPages: function () {
      var pages = [
        { path: "/tmp/x/about/index.md", relativePath: "about/index.md", slug: "about",
          title: "关于我", kind: "indexed", kindLabel: "独立页面", isPost: false,
          hasFrontMatter: true, modifiedAt: 1792555200, size: 120, url: "/about/" },
        { path: "/tmp/x/friends/index.md", relativePath: "friends/index.md", slug: "friends",
          title: "友链", kind: "indexed", kindLabel: "独立页面", isPost: false,
          hasFrontMatter: true, modifiedAt: 1792555000, size: 90, url: "/friends/" }
      ];
      return respond({ ok: true, pages: pages, pageCount: 2, postCount: 0 });
    },
    getPage: function (p) {
      return respond({
        ok: true,
        page: { path: p, relativePath: "about/index.md", slug: "about", title: "关于我",
                kind: "indexed", isPost: false, url: "/about/" },
        body: "这是关于页正文\\n",
        fields: [
          { key: "title", label: "标题", hint: "页面显示的标题", kind: "text",
            value: "关于我", items: [], isKnown: true, options: [] },
          { key: "layout", label: "布局", hint: "用哪个模板渲染", kind: "choice",
            value: "about", items: [], isKnown: true,
            options: [{ value: "about", label: "about（关于页）" },
                      { value: "page", label: "page（通用页面）" }] },
          { key: "draft", label: "草稿", hint: "勾上后不会出现在站点里", kind: "boolean",
            value: "false", items: [], isKnown: true, options: [] },
          { key: "my_custom", label: "my_custom", hint: "这个字段 HexoMan 不认识",
            kind: "passthrough", value: "x", items: [], isKnown: false, options: [] }
        ]
      });
    },
    getPageAssets: function () {
      return respond({ ok: true, assets: [
        { sitePath: "/css/about.css", kindLabel: "样式", originLabel: "推断",
          originDescription: "同名推断", sizeDescription: "1.2 KB" }
      ] });
    },
    getPageReferences: function () {
      return respond({ ok: true, references: [
        { postTitle: "你好", postFilePath: "/tmp/x/source/_posts/hello.md",
          matchKind: "pathLink", matchKindLabel: "路径链接", matchSnippet: "about" }
      ] });
    },
    createPage: function (slug, title) {
      return respond({ ok: true, page: { path: "/tmp/x/source/" + slug + "/index.md",
        relativePath: slug + "/index.md", slug: slug, title: title, kind: "indexed",
        isPost: false, url: "/" + slug + "/" } });
    },
    savePage: function (p) { return respond({ ok: true, page: { path: p } }); },
    deletePage: function () { return respond({ ok: true }); },
    revealPage: function () { return respond({ ok: true }); },

    listConfigFiles: function () {
      return respond({ ok: true, files: [
        { path: "/tmp/x/_config.yml", name: "_config.yml", subtitle: "站点主配置",
          contents: "title: 我的博客\\ntheme: yun\\n", isModified: false,
          topLevelKeys: ["theme", "title"] },
        { path: "/tmp/x/_config.yun.yml", name: "_config.yun.yml", subtitle: "主题配置（yun）",
          contents: "avatar:\\n  rounded: true\\n", isModified: false,
          topLevelKeys: ["avatar"] }
      ] });
    },
    getConfigFile: function (p) {
      return respond({ ok: true, file: { path: p, name: "_config.yml",
        subtitle: "站点主配置", contents: "title: 我的博客\\ntheme: yun\\n",
        isModified: false, topLevelKeys: ["theme", "title"] } });
    },
    getConfigSchema: function () {
      return respond({ ok: true, parseError: "", fields: [
        { id: "title", path: ["title"], label: "站点标题", hint: "", kind: "text",
          group: "内容", value: "我的博客", childCount: 0, isKnown: true, options: [],
          doc: { summary: "浏览器标签页显示的名字" }, readOnlyReason: "", isWritable: true },
        { id: "theme", path: ["theme"], label: "主题", hint: "", kind: "text",
          group: "外观", value: "yun", childCount: 0, isKnown: true, options: [],
          doc: null, readOnlyReason: "", isWritable: true },
        { id: "avatar", path: ["avatar"], label: "头像", hint: "2 项设置", kind: "readonly",
          group: "外观", value: "", childCount: 2, isKnown: true, options: [],
          doc: null, readOnlyReason: "分组", isWritable: false }
      ] });
    },
    getConfigList: function () { return respond({ ok: true, items: [] }); },
    updateConfigValue: function () { return respond({ ok: true }); },
    saveConfigFile: function () { return respond({ ok: true }); },
    getConfigSync: function () {
      return respond({ ok: true, themeName: "yun", themeConfigPath: "/tmp/x/_config.yun.yml",
        differences: [{ key: "title", label: "站点标题", note: "", siteValue: "我的博客",
          themeValue: "旧标题", siteDisplay: "我的博客", themeDisplay: "旧标题" }],
        themeOnly: [{ key: "avatar.url", label: "头像地址", value: "/a.png",
          siteState: "missing", siteStateDescription: "站点配置里没有这一项" }] });
    },
    applyConfigSync: function () { return respond({ ok: true, changed: ["站点标题"] }); },
    applyThemeOnlyToSite: function () { return respond({ ok: true }); },

    listThemes: function () {
      return respond({ ok: true, activeTheme: "yun", themes: [
        { name: "yun", packageName: "hexo-theme-yun", version: "1.0.0",
          description: "yun", sampleConfigPath: "", configFileName: "_config.yun.yml",
          isActive: true, hasSiteConfig: true },
        { name: "landscape", packageName: "hexo-theme-landscape", version: "7.0.0",
          description: "landscape", sampleConfigPath: "", configFileName: "_config.landscape.yml",
          isActive: false, hasSiteConfig: false }
      ] });
    },
    searchThemes: function () {
      return respond({ ok: true, online: false, log: {}, results: [
        { name: "hexo-theme-yun", shortName: "yun", version: "", description: "简洁主题",
          author: "yunyoujun", homepage: "", weeklyDownloads: 0, date: "" },
        { name: "hexo-theme-landscape", shortName: "landscape", version: "",
          description: "官方主题", author: "hexo", homepage: "", weeklyDownloads: 0, date: "" }
      ] });
    },
    switchTheme: function (name) { return respond({ ok: true, activeTheme: name }); },
    createThemeConfig: function () { return respond({ ok: true, path: "/tmp/x/_config.yml" }); },

    getBackupPlan: function () {
      return respond({ ok: true, plan: { includedCount: 12, excludedCount: 3,
        approximateBytes: 20480, includedDescription: "20.0 KB" } });
    },
    listBackups: function () {
      return respond({ ok: true, backups: [{ id: "/tmp/b.zip", path: "/tmp/b.zip",
        sitePath: "/tmp/x", date: 1792555200, displayName: "2026-11-20 12:00",
        size: 4096, formattedSize: "4.0 KB", fileCount: 12 }] });
    },
    createBackup: function () { return respond({ ok: true, backup: { path: "/tmp/b.zip" } }); },
    restoreBackup: function () { return respond({ ok: true }); },
    deleteBackup: function () { return respond({ ok: true }); },

    inspectEnvironment: function () {
      return respond({ ok: true, toolchain: {
        node: { name: "node", path: "/opt/homebrew/bin/node", version: "20.1.0",
                isAvailable: true, shortPath: "homebrew/bin/node",
                displayVersion: "20.1.0 · homebrew/bin/node" },
        npm: { name: "npm", path: "/opt/homebrew/bin/npm", version: "10.0.0",
               isAvailable: true, shortPath: "homebrew/bin/npm",
               displayVersion: "10.0.0 · homebrew/bin/npm" },
        npx: { name: "npx", path: "/opt/homebrew/bin/npx", version: "10.0.0",
               isAvailable: true, shortPath: "homebrew/bin/npx",
               displayVersion: "10.0.0 · homebrew/bin/npx" },
        globalHexo: { name: "hexo", path: "", version: "", isAvailable: false,
                      shortPath: "", displayVersion: "未找到" },
        git: { name: "git", path: "/usr/bin/git", version: "2.40.0", isAvailable: true,
               shortPath: "bin/git", displayVersion: "2.40.0 · bin/git" },
        warnings: ["找到 node，但没找到全局 hexo。"],
        environment: { pathSummary: "…/homebrew/bin（共 12 项）", rcSummary: ".zshrc" },
        isUsable: true
      } });
    },
    getEnvironmentDocs: function () {
      return respond({ ok: true, sections: [
        { id: "overview", icon: "info", title: "总览", summary: "HexoMan 不自带任何工具",
          bullets: ["站点管理不依赖外部工具"], commands: [], seeAlso: ["node"] },
        { id: "node", icon: "package", title: "Node.js", summary: "Hexo 跑在 Node.js 上",
          bullets: ["建议 18 以上"], commands: [
            { description: "用 Homebrew 安装", command: "brew install node" }],
          seeAlso: ["shell"] }
      ] });
    },
    listSnippets: function () { return respond({ ok: true, snippets: [] }); },
    getCustomContent: function () {
      return respond({ ok: true, content: { head: "", body: "", isEmpty: true },
        installed: false, scripts: [] });
    },
    getSettings: function () { return respond({ ok: true, settings: {} }); },
    updateSettings: function () { return respond({ ok: true, settings: {} }); },
    shutdown: function () { return respond({ ok: true }); }
  };
})();
</script>
""" % (
        json.dumps(DEMO_STATE, ensure_ascii=False),
        json.dumps(DEMO_OVERVIEW, ensure_ascii=False),
        json.dumps(DEMO_POSTS, ensure_ascii=False),
        json.dumps(strings, ensure_ascii=False),
    )


def _find_chromium() -> str | None:
    """找 playwright 缓存里的 chromium。

    优先用版本号最大的那个。找不到就返回 ``None``，让 playwright 自己
    去找（它下载过的标准版本能用）。
    """
    cache = Path.home() / "Library" / "Caches" / "ms-playwright"
    if not cache.is_dir():
        return None

    candidates: list[tuple[int, Path]] = []
    for entry in cache.iterdir():
        if not entry.name.startswith("chromium_headless_shell-"):
            continue
        version = entry.name.rsplit("-", 1)[-1]
        if not version.isdigit():
            continue
        binary = (
            entry
            / "chrome-headless-shell-mac-arm64"
            / "chrome-headless-shell"
        )
        if binary.is_file():
            candidates.append((int(version), binary))

    if not candidates:
        return None

    candidates.sort()
    return str(candidates[-1][1])


def main() -> int:
    from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
    from functools import partial

    from hexoman.markdown_render import render_markdown_document  # noqa: PLC0415

    class Handler(SimpleHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            path = self.path.split("?", 1)[0]
            if path in ("/", "/index.html"):
                html = (UI_DIR / "index.html").read_text(encoding="utf-8")
                html = html.replace(
                    '<script src="app.js"></script>',
                    build_mock_script() + '<script src="app.js"></script>',
                )
                body = html.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            super().do_GET()

        def do_POST(self) -> None:  # noqa: N802
            if self.path.split("?", 1)[0] != "/render":
                self.send_error(404)
                return
            length = int(self.headers.get("Content-Length") or 0)
            text = self.rfile.read(length).decode("utf-8")
            body = json.dumps(
                render_markdown_document(text).to_dict(), ensure_ascii=False
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format, *args) -> None:  # noqa: A002
            pass

    server = ThreadingHTTPServer(
        ("127.0.0.1", 0), partial(Handler, directory=str(UI_DIR))
    )
    port = server.server_address[1]
    server_thread = __import__("threading").Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    results: dict[str, object] = {}
    errors: list[str] = []

    try:
        with sync_playwright() as playwright:
            # 用缓存里已有的 chromium 版本。playwright 自带的版本号可能和
            # 缓存里的对不上（对不上就报 "Executable doesn't exist"），
            # 所以显式指定可执行文件路径。
            executable = _find_chromium()
            browser = playwright.chromium.launch(headless=True, executable_path=executable)
            page = browser.new_page(viewport={"width": 1440, "height": 900})

            page.on("pageerror", lambda exc: errors.append(str(exc)))
            page.on(
                "console",
                lambda msg: errors.append(f"console.{msg.type}: {msg.text}")
                if msg.type == "error"
                else None,
            )

            page.goto(f"http://127.0.0.1:{port}/", wait_until="networkidle")
            page.wait_for_timeout(800)

            results["page title"] = page.title()
            results["nav item count"] = page.locator(".nav-item").count()
            results["overview title"] = page.locator(".content-title").inner_text()
            results["stat card count"] = page.locator(".stat-card").count()

            # 站点管理
            page.get_by_role("button", name="站点管理").first.click()
            page.wait_for_timeout(400)
            results["site row count"] = page.locator(".site-row").count()

            # 文章页 + 预览
            page.get_by_role("button", name="文章").first.click()
            page.wait_for_timeout(400)
            results["post list count"] = page.locator(".post-list-item").count()
            page.locator(".post-list-item").first.click()
            page.wait_for_timeout(900)
            results["preview html length"] = page.evaluate(
                "document.querySelector('#post-preview').innerHTML.length"
            )
            results["preview code blocks"] = page.locator("#post-preview pre.code").count()
            results["preview pygments tokens"] = page.evaluate(
                "document.querySelectorAll('#post-preview .k, #post-preview .nf, "
                "#post-preview .s').length"
            )
            results["preview tables"] = page.locator("#post-preview table").count()
            results["front matter leaked"] = page.evaluate(
                "document.querySelector('#post-preview').innerHTML.includes('tags:')"
            )
            results["word count text"] = page.locator("#post-wordcount").inner_text()

            # 搜索
            page.locator("#post-search").fill("草稿")
            page.wait_for_timeout(300)
            results["search filtered count"] = page.locator(".post-list-item").count()
            page.locator("#post-search").fill("")
            page.wait_for_timeout(300)

            # 筛选
            page.locator("#post-filter .segmented-button[data-filter='draft']").click()
            page.wait_for_timeout(300)
            results["draft filter count"] = page.locator(".post-list-item").count()
            page.locator("#post-filter .segmented-button[data-filter='all']").click()
            page.wait_for_timeout(300)

            # -- 第二阶段的页面 --
            def open_page(label: str) -> None:
                page.locator(".nav-item", has_text=label).first.click()
                page.wait_for_timeout(600)

            open_page("页面")
            results["page list count"] = page.locator("#page-list .post-list-item").count()
            page.locator("#page-list .post-list-item").first.click()
            page.wait_for_timeout(600)
            results["page field controls"] = page.locator("#page-editor .page-field").count()
            results["page body shown"] = page.locator("#page-body").count()

            open_page("构建与预览")
            results["build buttons"] = page.locator("#build-generate, #build-clean").count()

            open_page("配置")
            results["config tabs"] = page.locator("#config-tabs .segmented-button").count()
            results["config form fields"] = page.locator("#config-form .field").count()
            results["config sync rows"] = page.locator("#config-sync-apply").count()

            open_page("主题")
            results["theme rows"] = page.locator("#theme-root .detail-row").count()
            results["theme search box"] = page.locator("#theme-search").count()

            open_page("备份")
            results["backup rows"] = page.locator("#backup-root .detail-row").count()

            open_page("环境")
            results["env tool rows"] = page.locator("#env-root .detail-row").count()
            results["env doc cards"] = page.locator("#env-root .card").count()

            open_page("站点设置")
            results["settings cards"] = page.locator("#settings-root .section .card").count()
            results["settings fields"] = page.locator("#settings-root .field").count()
            results["settings text inputs"] = page.locator(
                "#settings-root .field input[type=text]"
            ).count()
            results["settings nested hints"] = page.locator(
                "#settings-root .field [data-hint]"
            ).count()
            results["settings title value"] = page.evaluate(
                "(() => { const n = document.querySelector('#settings-root input[type=text]');"
                " return n ? n.value : null; })()"
            )

            open_page("Git")
            results["git file rows"] = page.locator("#git-root .git-file-row").count()
            results["git file buttons"] = page.locator("#git-root .git-file-action").count()
            results["git group labels"] = page.locator("#git-root .git-group-label").count()
            results["git first button text"] = page.evaluate(
                "(() => { const n = document.querySelector('#git-root .git-file-action');"
                " return n ? n.textContent.trim() : null; })()"
            )

            open_page("主题")
            results["theme install button"] = page.locator("#theme-install").count()

            # 新建站点向导：能弹出来、模板有渲染、名称为空时「创建」是禁用的、能关掉
            open_page("站点管理")
            page.locator("#sites-create").click()
            page.wait_for_timeout(400)
            results["wizard open"] = page.locator(".modal-backdrop .modal").count()
            results["wizard name input"] = page.locator("#wizard-name").count()
            results["wizard template radios"] = page.locator(".radio-item").count()
            results["wizard confirm disabled when empty"] = page.evaluate(
                "(() => { const b = document.querySelector('.modal-actions .button.is-primary');"
                " return b ? b.disabled : null; })()"
            )
            page.locator("#wizard-name").fill("my-blog")
            page.locator("#wizard-parent").fill("/tmp")
            page.wait_for_timeout(200)
            results["wizard confirm enabled after fill"] = page.evaluate(
                "(() => { const b = document.querySelector('.modal-actions .button.is-primary');"
                " return b ? b.disabled : null; })()"
            )
            page.evaluate(
                "(() => { const b = document.querySelector('.modal-actions .button:not(.is-primary)');"
                " if (b) b.click(); })()"
            )
            page.wait_for_timeout(300)
            results["wizard closed"] = page.locator(".modal-backdrop").count()

            # 回到文章页，后面还有语言切换检查
            open_page("文章")

            # 语言切换：不重载页面
            page.evaluate("window.__marker = 'alive'")
            page.locator(".lang-button", has_text="EN").click()
            page.wait_for_timeout(700)
            results["nav after EN"] = page.evaluate(
                "Array.from(document.querySelectorAll('.nav-item-label'))"
                ".map(n => n.textContent).join(',')"
            )
            results["page reloaded"] = page.evaluate("window.__marker !== 'alive'")

            page.locator(".lang-button", has_text="中文").click()
            page.wait_for_timeout(700)
            results["nav after ZH"] = page.evaluate(
                "Array.from(document.querySelectorAll('.nav-item-label'))"
                ".map(n => n.textContent).join(',')"
            )

            # 深色模式
            page.emulate_media(color_scheme="dark")
            page.wait_for_timeout(300)
            results["dark bg"] = page.evaluate(
                "getComputedStyle(document.body).backgroundColor"
            )
            page.emulate_media(color_scheme="light")
            page.wait_for_timeout(300)
            results["light bg"] = page.evaluate(
                "getComputedStyle(document.body).backgroundColor"
            )

            # 截图（headless，不弹窗）
            out = ROOT / "docs"
            out.mkdir(exist_ok=True)
            page.screenshot(path=str(out / "screenshot-posts.png"), full_page=False)
            page.get_by_role("button", name="总览").first.click()
            page.wait_for_timeout(600)
            page.screenshot(path=str(out / "screenshot-overview.png"), full_page=False)

            browser.close()
    finally:
        server.shutdown()
        server.server_close()

    results["js errors"] = errors
    print("=== HEADLESS UI VERIFICATION ===")
    print(json.dumps(results, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
