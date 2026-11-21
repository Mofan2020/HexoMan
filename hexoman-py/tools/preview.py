#!/usr/bin/env python3
"""界面预览服务器：给 ``ui/`` 挂一个假的后端，用浏览器看界面。

**只给开发用**，不是应用的一部分。真实运行时后端是 pywebview 注入的
``window.hexoman``，这里用一份假数据顶替，方便在没有装 hexo 的机器上
检查界面。

用法：

    python3 tools/preview.py          # 起服务器，按提示打开 http://127.0.0.1:8765
"""

from __future__ import annotations

import json
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UI_DIR = ROOT / "hexoman" / "ui"

sys.path.insert(0, str(ROOT))

from hexoman import i18n  # noqa: E402
from hexoman.markdown_render import render_markdown_document  # noqa: E402

DEMO_POSTS = [
    {
        "path": "/tmp/demo-blog/source/_posts/hello.md",
        "filename": "hello.md",
        "slug": "hello",
        "title": "用 PyWebView 重写 HexoMan",
        "date": "2026-11-20 10:30:00",
        "timestamp": 1792547400.0,
        "tags": ["python", "hexo"],
        "categories": ["技术"],
        "draft": False,
        "body": (
            "这是一篇用来演示预览的示例文章。\n\n"
            "## 为什么重写\n\n"
            "原来的 SwiftUI 版本只支持 macOS 26+，现在要同时支持 Windows。\n\n"
            "### 代码高亮\n\n"
            "```python\n"
            "def render(text: str) -> str:\n"
            "    \"\"\"渲染 Markdown。\"\"\"\n"
            "    return markdown(text)\n"
            "```\n\n"
            "### 列表与引用\n\n"
            "- 站点管理\n"
            "- 文章编辑\n"
            "- 总览\n\n"
            "> 前 matter 是 YAML 头部，不该渲染进正文。\n\n"
            "| 功能 | 状态 |\n"
            "| --- | --- |\n"
            "| 站点管理 | 已完成 |\n"
            "| 文章 | 已完成 |\n"
            "| 主题 | 计划中 |\n"
        ),
        "wordCount": 128,
        "byteSize": 1024,
        "modifiedAt": 1792547400.0,
        "excerpt": "这是一篇用来演示预览的示例文章。",
    },
    {
        "path": "/tmp/demo-blog/source/_posts/draft.md",
        "filename": "draft.md",
        "slug": "draft",
        "title": "一篇还没写完的草稿",
        "date": "2026-11-19 09:00:00",
        "timestamp": 1792460400.0,
        "tags": ["随笔"],
        "categories": [],
        "draft": True,
        "body": "写到一半。",
        "wordCount": 5,
        "byteSize": 128,
        "modifiedAt": 1792460400.0,
        "excerpt": "写到一半。",
    },
]

DEMO_STATE = {
    "ok": True,
    "language": "zh",
    "languages": i18n.available_languages(),
    "strings": i18n.get_strings("zh"),
    "sites": [
        {"path": "/tmp/demo-blog", "lastOpened": 1792547400.0, "name": "demo-blog"},
        {"path": "/tmp/other-site", "lastOpened": 1792000000.0, "name": "other-site"},
    ],
    "currentSitePath": "/tmp/demo-blog",
    "serverPort": 4000,
    "previewDrafts": False,
    "platform": "macOS",
    "siteInfo": {
        "title": "示例博客",
        "url": "https://example.com",
        "theme": "yun",
        "hexoVersion": "^7.0.0",
        "themeVersion": "^1.0.0",
        "dependenciesInstalled": True,
        "isGitRepository": True,
        "gitRemote": "https://github.com/user/blog.git",
        "postCount": 2,
        "hasBuildOutput": True,
        "buildFileCount": 42,
        "postsDirectory": "/tmp/demo-blog/source/_posts",
        "sourceDirectory": "/tmp/demo-blog/source",
    },
    "serverRunning": False,
}

DEMO_OVERVIEW = {
    "ok": True,
    "siteInfo": DEMO_STATE["siteInfo"],
    "hexoSource": "local",
    "hexoSourceKey": "hexoSource.local",
    "commandPreview": "$ /tmp/demo-blog/node_modules/.bin/hexo generate",
    "commits": [
        {"shortHash": "a1b2c3d", "subject": "更新文章列表", "author": "Mofan", "date": "2026-11-20"},
        {"shortHash": "e4f5g6h", "subject": "修复预览的 front matter 处理", "author": "Mofan", "date": "2026-11-19"},
        {"shortHash": "i7j8k9l", "subject": "初版", "author": "Mofan", "date": "2026-11-18"},
    ],
    "gitStatus": None,
    "serverRunning": False,
    "previewUrl": "http://localhost:4000",
}

MOCK_SCRIPT = """
<script>
// 预览用的假后端。真实运行时由 pywebview 注入 window.hexoman。
(function () {
  var state = %s;
  var overview = %s;
  var posts = %s;

  function respond(value) {
    return Promise.resolve(value);
  }

  window.hexoman = {
    getState: function () { return respond(state); },
    getStrings: function () { return respond({ ok: true, strings: state.strings }); },
    setLanguage: function (code) {
      if (code !== "zh" && code !== "en") {
        return respond({ ok: false, error: "unknown" });
      }
      state.language = code;
      state.strings = %s[code];
      return respond({ ok: true, language: code, strings: state.strings });
    },
    listSites: function () {
      return respond({ ok: true, sites: state.sites, currentSitePath: state.currentSitePath });
    },
    addSite: function (path) { return respond({ ok: true, sites: state.sites, currentSitePath: state.currentSitePath, siteInfo: state.siteInfo }); },
    removeSite: function (path) { return respond({ ok: true, sites: state.sites, currentSitePath: state.currentSitePath }); },
    selectSite: function (path) {
      state.currentSitePath = path;
      return respond({ ok: true, sites: state.sites, currentSitePath: path, siteInfo: state.siteInfo });
    },
    chooseSiteDirectory: function () { return respond({ ok: false, error: "cancelled" }); },
    revealSiteDirectory: function () { return respond({ ok: true }); },
    listPosts: function () {
      return respond({
        ok: true,
        posts: posts,
        tags: ["python", "hexo", "随笔"],
        categories: ["技术"]
      });
    },
    getPost: function (path) {
      var found = posts.filter(function (p) { return p.path === path; })[0];
      return respond(found ? { ok: true, post: found } : { ok: false, error: "notFound" });
    },
    createPost: function (title) {
      var post = {
        path: "/tmp/demo-blog/source/_posts/new.md",
        filename: "new.md", slug: "new", title: title,
        date: "2026-11-20 12:00:00", timestamp: 1792555200,
        tags: [], categories: [], draft: false, body: "",
        wordCount: 0, byteSize: 0, modifiedAt: 1792555200, excerpt: ""
      };
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
    deletePost: function (path) { return respond({ ok: true }); },
    revealPost: function () { return respond({ ok: true }); },
    renderMarkdown: function (text) {
      // 走真实的 Python 渲染器：预览要看的就是它的输出
      return fetch("/render", {
        method: "POST",
        headers: { "Content-Type": "text/plain; charset=utf-8" },
        body: text
      })
        .then(function (r) { return r.json(); })
        .then(function (data) {
          return respond({
            ok: true, html: data.html, title: data.title,
            tags: data.tags, categories: data.categories, draft: data.draft
          });
        });
    },
    getOverview: function () { return respond(overview); },
    runGenerate: function () { return respond({ ok: true, exitCode: 0, output: "INFO  Generated 42 files" }); },
    runClean: function () { return respond({ ok: true, exitCode: 0, output: "INFO  Deleted db.json" }); },
    startPreview: function () { state.serverRunning = true; return respond({ ok: true, previewUrl: "http://localhost:4000" }); },
    stopPreview: function () { state.serverRunning = false; return respond({ ok: true }); },
    openPreviewPage: function () { return respond({ ok: true }); },
    refreshGit: function () { return respond({ ok: true, gitStatus: null, commits: overview.commits }); },
    openPath: function () { return respond({ ok: true }); },
    shutdown: function () { return respond({ ok: true }); }
  };
})();
</script>
"""


def build_mock() -> str:
    strings = {
        "zh": i18n.get_strings("zh"),
        "en": i18n.get_strings("en"),
    }
    return MOCK_SCRIPT % (
        json.dumps(DEMO_STATE, ensure_ascii=False),
        json.dumps(DEMO_OVERVIEW, ensure_ascii=False),
        json.dumps(DEMO_POSTS, ensure_ascii=False),
        json.dumps(strings, ensure_ascii=False),
    )


class PreviewHandler(SimpleHTTPRequestHandler):
    """在 ``index.html`` 里插入假后端脚本。"""

    def do_GET(self) -> None:  # noqa: N802
        # 路径里可能带查询串（``?v=2`` 用来绕缓存），判断前先剥掉
        path = self.path.split("?", 1)[0]

        if path in ("/", "/index.html"):
            html = (UI_DIR / "index.html").read_text(encoding="utf-8")
            html = html.replace(
                '<script src="app.js"></script>',
                build_mock() + '<script src="app.js"></script>',
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
        """``/render`` 走真实的 Python 渲染器。"""
        if self.path.split("?", 1)[0] != "/render":
            self.send_error(404)
            return

        length = int(self.headers.get("Content-Length") or 0)
        text = self.rfile.read(length).decode("utf-8")
        result = render_markdown_document(text)

        body = json.dumps(result.to_dict(), ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args) -> None:  # noqa: A002
        pass


def main() -> int:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    handler = partial(PreviewHandler, directory=str(UI_DIR))
    server = ThreadingHTTPServer(("127.0.0.1", port), handler)
    print(f"预览服务器：http://127.0.0.1:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
