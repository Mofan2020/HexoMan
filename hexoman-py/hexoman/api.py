"""前端桥接层：暴露成 ``window.hexoman``。

对应 Swift 侧 ``HexoManModel`` 的角色，但边界更窄——SwiftUI 那边是
「视图直接调 model 的方法」，这边是「JS 通过 JSON 调这里的方法」。

## 方法名为什么是 camelCase

pywebview 把 Python 的方法名**原样**暴露给 JS（``get_state`` 就叫
``get_state``）。但这一层的使用者是 JS，命名统一成 camelCase 更顺，
也让前后端对接口的写法一致。

所以这里的约定是：

- **公开方法一律 camelCase**，它们就是 JS API 的全部。
- **内部状态一律加下划线前缀**（``_settings``、``_site_list``……）。
  pywebview 会递归暴露「可调用之外的对象属性」，不加下划线的话
  ``_settings`` 里的站点列表也会变成 JS 可访问的方法，看起来像后门。

- 每个方法都自己兜住异常，返回 ``{ok: false, error: ...}``。
  JS 那边不需要 try/catch 就能拿到结果。
"""

from __future__ import annotations

import os
import threading
from pathlib import Path
from typing import Any

from . import (
    backup as backup_module,
    config_file as config_file_module,
    config_schema as config_schema_module,
    config_sync as config_sync_module,
    custom_content as custom_content_module,
    environment_docs as environment_docs_module,
    frontmatter,
    hexo_bootstrap as hexo_bootstrap_module,
    i18n,
    markdown_render,
    page_assets as page_assets_module,
    page_reference as page_reference_module,
    pages as pages_module,
    site_creator as site_creator_module,
    site_media as site_media_module,
    site_settings as site_settings_module,
    snippet_library as snippet_library_module,
    theme_installer as theme_installer_module,
    theme_manager as theme_manager_module,
    theme_registry as theme_registry_module,
)
from . import posts as posts_module
from . import sites as sites_module
from .asset_server import AssetServer
from .config_file import ConfigFile, ConfigStore
from .config_schema import ConfigSchema
from .config_sync import ConfigSync
from .custom_content import CustomContent, CustomContentStore, detected_inject_scripts
from .environment_docs import EnvironmentDocs
from .git_service import GitService
from .hexo_cli import HexoService, resolve_invocation
from .hexo_environment import HexoEnvironment
from .model import Site
from .pages import PageStore
from .process import CommandRunner
from .settings import AppSettings, SettingsStore
from .shell_environment import ShellEnvironment, ShellEnvironmentResolver
from .site_media import SiteMedia
from .snippet_library import SnippetLibrary
from .system_integration import (
    choose_directory,
    choose_images,
    open_path,
    open_url,
    platform_name,
    reveal_in_file_manager,
)
from .theme_manager import ThemeManager
from .theme_registry import ThemeRegistry
from .yaml_path import YamlDocument

__all__ = ["HexoManAPI"]


class HexoManAPI:
    """``window.hexoman`` 的实现。

    持有全部应用状态：站点列表、当前站点、设置、预览进程。
    """

    def __init__(
        self,
        settings_store: SettingsStore | None = None,
        runner: CommandRunner | None = None,
        environment: ShellEnvironment | None = None,
        backup_directory: str = "",
    ) -> None:
        self._settings_store = settings_store or SettingsStore()
        self._runner = runner or CommandRunner()
        self._settings: AppSettings = self._settings_store.load()
        self._site_list = sites_module.SiteList(
            self._settings.sites, self._settings.last_site_path
        )
        self._server_process = None
        self._server_preview = ""
        self._lock = threading.Lock()

        #: 用户真实的 shell 环境。**默认不探测**——探测要跑一次 zsh（1~2 秒），
        #: 单元测试里更是一次都不该跑。main.py 启动时调 ``prepareEnvironment()``
        #: 显式填进来；没填时子进程退回继承环境。
        self._environment: ShellEnvironment | None = environment

        #: 备份目录（测试注入临时目录，绝不写进用户真实的备份夹）
        self._backup_directory = backup_directory

        self._theme_registry = ThemeRegistry()
        self._config_drafts: dict[str, ConfigFile] = {}

        #: 预览用的本地静态资源服务。文章里的图片是站点内的相对路径，
        #: 界面从 ``file://`` 打开时加载不到，得靠它转成可访问的地址。
        self._assets = AssetServer()

    # -- 状态 ---------------------------------------------------------

    def getState(self) -> dict[str, Any]:
        """前端启动时的初始状态。

        一次性把所有东西给过去，前端不用连着问十几个接口。
        """
        current = self._site_list.current
        return {
            "ok": True,
            "language": self._settings.language,
            "languages": i18n.available_languages(),
            "strings": i18n.get_strings(self._settings.language),
            "sites": [site.to_dict() for site in self._site_list.sites],
            "currentSitePath": self._site_list.current_path,
            "serverPort": self._settings.server_port,
            "previewDrafts": self._settings.preview_drafts,
            "platform": platform_name(),
            "siteInfo": sites_module.inspect_site(current).to_dict() if current else None,
            "serverRunning": self._server_process is not None,
            "settings": self._settings.to_dict(),
        }

    def setLanguage(self, language: str) -> dict[str, Any]:
        """切换界面语言。

        **不重启、不重新加载页面**：前端拿到新的文案字典后自己重绘。
        """
        if language not in i18n.STRINGS:
            return {"ok": False, "error": f"unknownLanguage:{language}"}

        self._settings.language = language
        self._persist()
        return {
            "ok": True,
            "language": language,
            "strings": i18n.get_strings(language),
        }

    def getStrings(self) -> dict[str, Any]:
        """取当前语言的文案字典。"""
        return {"ok": True, "strings": i18n.get_strings(self._settings.language)}

    # -- 站点 ---------------------------------------------------------

    def listSites(self) -> dict[str, Any]:
        return {
            "ok": True,
            "sites": [site.to_dict() for site in self._site_list.sites],
            "currentSitePath": self._site_list.current_path,
        }

    def addSite(self, path: str) -> dict[str, Any]:
        """添加站点目录。

        判定标准：有 ``package.json``（声明了 hexo 依赖）+ 有 ``_config.yml``。
        """
        if not path or not path.strip():
            return {"ok": False, "error": "pathEmpty"}

        ok = self._site_list.add(path.strip())
        self._persist()

        if not ok:
            return {"ok": False, "error": "notHexoSite"}

        return {
            "ok": True,
            "sites": [site.to_dict() for site in self._site_list.sites],
            "currentSitePath": self._site_list.current_path,
            "siteInfo": self._current_info(),
        }

    def removeSite(self, path: str) -> dict[str, Any]:
        """从列表移除。**不删磁盘文件。**

        当前站点不能直接移除——先切到别的站点。这一条和 Swift 版一致：
        移除当前站点会让右侧内容区瞬间清空，用户容易以为应用崩了。
        """
        if not path:
            return {"ok": False, "error": "pathEmpty"}

        if self._site_list.current_path == path:
            return {"ok": False, "error": "cannotRemoveCurrent"}

        self._site_list.remove(path)
        self._persist()
        return {
            "ok": True,
            "sites": [site.to_dict() for site in self._site_list.sites],
            "currentSitePath": self._site_list.current_path,
        }

    def selectSite(self, path: str) -> dict[str, Any]:
        """切换当前站点并重新采集数据。"""
        if not path:
            return {"ok": False, "error": "pathEmpty"}

        self._site_list.select(path)
        self._persist()

        return {
            "ok": True,
            "sites": [site.to_dict() for site in self._site_list.sites],
            "currentSitePath": self._site_list.current_path,
            "siteInfo": self._current_info(),
        }

    def chooseSiteDirectory(self) -> dict[str, Any]:
        """弹系统目录选择框。"""
        chosen = choose_directory("选择站点目录")
        if not chosen:
            return {"ok": False, "error": "cancelled"}
        return {"ok": True, "path": chosen}

    def revealSiteDirectory(self, path: str = "") -> dict[str, Any]:
        """在文件管理器里显示站点目录。"""
        target = path or self._site_list.current_path
        if not target:
            return {"ok": False, "error": "noSite"}
        reveal_in_file_manager(target)
        return {"ok": True}

    # -- 文章 ---------------------------------------------------------

    def listPosts(self) -> dict[str, Any]:
        """站点全部文章。搜索和筛选在前端做——数据量不大，省一次往返。"""
        site = self._site_list.current
        if not site:
            return {"ok": True, "posts": [], "tags": [], "categories": []}

        loaded = posts_module.load_posts(site)
        return {
            "ok": True,
            "posts": [post.to_dict() for post in loaded],
            "tags": posts_module.collect_tags(loaded),
            "categories": posts_module.collect_categories(loaded),
        }

    def getPost(self, path: str) -> dict[str, Any]:
        """读一篇文章的完整内容（含正文）。"""
        post = posts_module.read_post(path) if path else None
        if not post:
            return {"ok": False, "error": "notFound"}
        return {"ok": True, "post": post.to_dict()}

    def createPost(
        self,
        title: str,
        tags: list[str] | None = None,
        categories: list[str] | None = None,
        body: str = "",
        isDraft: bool = False,
    ) -> dict[str, Any]:
        """新建文章。"""
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}
        if not title or not title.strip():
            return {"ok": False, "error": "titleEmpty"}

        post = posts_module.create_post(
            site,
            title=title.strip(),
            body=body,
            tags=tags or [],
            categories=categories or [],
            is_draft=isDraft,
        )
        return {"ok": True, "post": post.to_dict()}

    def savePost(
        self,
        path: str,
        title: str = "",
        body: str = "",
        date: str = "",
        tags: list[str] | None = None,
        categories: list[str] | None = None,
        isDraft: bool | None = None,
    ) -> dict[str, Any]:
        """保存文章：标题、日期、标签、分类、草稿开关、正文一起写回。"""
        post = posts_module.read_post(path) if path else None
        if not post:
            return {"ok": False, "error": "notFound"}

        if title:
            post.front.set("title", title.strip())

        if date:
            parsed = frontmatter.parse_date(date)
            if parsed:
                post.front.set("date", frontmatter.format_date(parsed))

        if tags is not None:
            post.front.set("tags", tags)
        if categories is not None:
            post.front.set("categories", categories)
        if isDraft is not None:
            post.front.set("draft", True if isDraft else False)

        post.body = body

        saved = posts_module.save_post(post)
        return {"ok": True, "post": saved.to_dict()}

    def deletePost(self, path: str) -> dict[str, Any]:
        """删除文章（移到废纸篓）。"""
        post = posts_module.read_post(path) if path else None
        if not post:
            return {"ok": False, "error": "notFound"}

        posts_module.delete_post(post)
        return {"ok": True}

    def revealPost(self, path: str) -> dict[str, Any]:
        """在文件管理器里显示文章文件。"""
        if not path:
            return {"ok": False, "error": "pathEmpty"}
        reveal_in_file_manager(path)
        return {"ok": True}

    # -- Markdown -----------------------------------------------------

    def renderMarkdown(self, text: str, path: str = "") -> dict[str, Any]:
        """渲染 Markdown，返回 HTML。

        front matter 会被切掉再渲染——它是 YAML 头部，不是正文。
        ``path`` 是文章文件路径，用来定位同目录下的图片。
        """
        result = markdown_render.render_markdown_document(
            text or "", resolver=self._asset_resolver(path)
        )
        return {"ok": True, **result.to_dict()}

    def _asset_resolver(self, path: str = ""):
        """做一个「图片地址 → 预览能加载的地址」的解析函数。

        文章里写的是站点内的相对路径（``/images/2026/11/a.png``）。界面从
        ``file://`` 打开，这种地址指不到站点目录，必然裂图——所以要换成
        本地资源服务的地址。

        找不到文件的地址原样返回：预览里显示裂图，比悄悄换成别的东西
        诚实。
        """
        site = self._site_list.current
        if site is None:
            return None

        root = Path(site.path).resolve()
        post_dir: Path | None = None
        if path:
            try:
                post_dir = Path(path).resolve().parent
            except OSError:
                post_dir = None

        self._assets.set_root(root)
        self._assets.start()

        def resolve(src: str) -> str | None:
            if not src:
                return None
            if src.startswith(("http://", "https://", "data:")):
                return src

            clean = src.split("#")[0].split("?")[0]
            if not clean:
                return None

            candidates: list[Path] = []
            if clean.startswith("/"):
                candidates.append(root / "source" / clean.lstrip("/"))
                candidates.append(root / "public" / clean.lstrip("/"))
            else:
                if post_dir is not None:
                    candidates.append(post_dir / clean)
                candidates.append(root / "source" / clean)
                candidates.append(root / "public" / clean)

            for candidate in candidates:
                try:
                    resolved = candidate.resolve()
                    relative = resolved.relative_to(root)
                except (OSError, ValueError):
                    continue
                if not relative.parts:
                    continue
                if relative.parts[0] not in ("source", "public"):
                    continue
                if not resolved.is_file():
                    continue
                return self._assets.url_for(str(relative).replace("\\", "/"))

            return None

        return resolve

    # -- 总览 ---------------------------------------------------------

    def getOverview(self) -> dict[str, Any]:
        """总览页数据：站点信息 + hexo 来源 + 最近提交。"""
        site = self._site_list.current
        if not site:
            return {
                "ok": True,
                "siteInfo": None,
                "hexoSource": "",
                "hexoSourceKey": "hexoSource.path",
                "commandPreview": "",
                "commits": [],
                "gitStatus": None,
                "serverRunning": self._server_process is not None,
                "previewUrl": "",
            }

        info = sites_module.inspect_site(site)
        invocation = resolve_invocation(
            site, self._settings.custom_hexo_path, self._runner, self._environment
        )
        service = self._hexo_service(site)

        commits: list[dict[str, Any]] = []
        git_status = None
        if info.is_git_repository:
            git = GitService(site, self._runner)
            git_status = git.status()
            commits = [commit.to_dict() for commit in git.log(limit=5)]

        return {
            "ok": True,
            "siteInfo": info.to_dict(),
            "hexoSource": invocation.source,
            "hexoSourceKey": invocation.to_dict()["sourceKey"],
            "commandPreview": service.command_preview("generate"),
            "commits": commits,
            "gitStatus": git_status.to_dict() if git_status else None,
            "serverRunning": self._server_process is not None,
            "previewUrl": service.preview_url(self._settings.server_port),
        }

    # -- 构建与预览 ---------------------------------------------------

    def runGenerate(self) -> dict[str, Any]:
        """执行 ``hexo generate``。"""
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}

        service = self._hexo_service(site)
        result = service.run_generate()
        return {
            "ok": result.success,
            "exitCode": result.exit_code,
            "output": result.output,
            "error": result.error_summary,
        }

    def runClean(self) -> dict[str, Any]:
        """执行 ``hexo clean``。"""
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}

        service = self._hexo_service(site)
        result = service.run_clean()
        return {
            "ok": result.success,
            "exitCode": result.exit_code,
            "output": result.output,
            "error": result.error_summary,
        }

    def startPreview(self) -> dict[str, Any]:
        """启动本地预览服务（``hexo server``）。"""
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}

        with self._lock:
            if self._server_process is not None:
                return {"ok": True, "alreadyRunning": True}

            service = self._hexo_service(site)
            process, preview = service.start_server(
                self._settings.server_port, self._settings.preview_drafts
            )
            if process is None:
                return {"ok": False, "error": "spawnFailed", "commandPreview": preview}

            self._server_process = process
            self._server_preview = preview

        return {
            "ok": True,
            "commandPreview": preview,
            "previewUrl": service.preview_url(self._settings.server_port),
        }

    def stopPreview(self) -> dict[str, Any]:
        """停止预览服务。"""
        site = self._site_list.current
        with self._lock:
            process = self._server_process
            self._server_process = None

        if site:
            service = self._hexo_service(site)
            service.stop_server(process)

        return {"ok": True}

    def openPreviewPage(self) -> dict[str, Any]:
        """在浏览器打开预览页。"""
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}
        service = self._hexo_service(site)
        open_url(service.preview_url(self._settings.server_port))
        return {"ok": True, "url": service.preview_url(self._settings.server_port)}

    def refreshGit(self) -> dict[str, Any]:
        """刷新 Git 状态与最近提交。"""
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}

        git = GitService(site, self._runner)
        status = git.status()
        commits = [commit.to_dict() for commit in git.log(limit=5)]
        return {
            "ok": True,
            "gitStatus": status.to_dict() if status else None,
            "commits": commits,
        }

    # -- 其它 ---------------------------------------------------------

    def openPath(self, path: str) -> dict[str, Any]:
        """用系统默认程序打开路径。"""
        if not path:
            return {"ok": False, "error": "pathEmpty"}
        open_path(path)
        return {"ok": True}

    def shutdown(self) -> dict[str, Any]:
        """退出前清理：停预览、停资源服务、落盘设置。"""
        with self._lock:
            process = self._server_process
            self._server_process = None

        if process is not None:
            try:
                process.terminate()
                process.wait(timeout=1.5)
            except Exception:
                try:
                    process.kill()
                except OSError:
                    pass

        self._assets.stop()
        self._persist()
        return {"ok": True}

    # -- 设置 ---------------------------------------------------------

    def prepareEnvironment(self) -> dict[str, Any]:
        """启动时探测一次用户真实的 shell 环境。

        **只在应用启动时调一次**。探测要跑一次登录 shell（1~2 秒），
        每条命令都付这个代价不可接受。
        """
        if not self._settings.uses_shell_environment:
            self._environment = None
            return {"ok": True, "environment": None}

        self._environment = ShellEnvironmentResolver.resolve(
            custom_rc_path=self._settings.custom_rc_path
        )
        return {
            "ok": self._environment is not None,
            "environment": self._environment.to_dict() if self._environment else None,
        }

    def getSettings(self) -> dict[str, Any]:
        """当前设置。"""
        return {
            "ok": True,
            "settings": self._settings.to_dict(),
        }

    def updateSettings(self, patch: dict[str, Any]) -> dict[str, Any]:
        """改设置。只认已知的键，未知键忽略。"""
        if not isinstance(patch, dict):
            return {"ok": False, "error": "invalidPatch"}

        if "serverPort" in patch:
            try:
                port = int(patch["serverPort"])
            except (TypeError, ValueError):
                port = self._settings.server_port
            if 1 <= port <= 65535:
                self._settings.server_port = port

        for key, attribute in (
            ("previewDrafts", "preview_drafts"),
            ("autoScrollLog", "auto_scroll_log"),
            ("usesShellEnvironment", "uses_shell_environment"),
            ("syncsThemeConfig", "syncs_theme_config"),
            ("onlineThemeSearch", "online_theme_search"),
            ("dontAskOnlineConsent", "dont_ask_online_consent"),
        ):
            if key in patch:
                setattr(self._settings, attribute, bool(patch[key]))

        for key, attribute in (
            ("customHexoPath", "custom_hexo_path"),
            ("customRCPath", "custom_rc_path"),
        ):
            if key in patch:
                setattr(self._settings, attribute, str(patch[key] or ""))

        self._persist()
        return {"ok": True, "settings": self._settings.to_dict()}

    # -- 页面 ---------------------------------------------------------

    def listPages(self) -> dict[str, Any]:
        """站点里的全部页面（含文章，带类型标记）。"""
        site = self._site_list.current
        if not site:
            return {"ok": True, "pages": []}

        pages = PageStore.scan(site)
        return {
            "ok": True,
            "pages": [page.to_dict() for page in pages],
            "pageCount": len([page for page in pages if not page.is_post]),
            "postCount": len([page for page in pages if page.is_post]),
        }

    def getPage(self, path: str) -> dict[str, Any]:
        """读一个页面的正文 + 表单字段。"""
        page = self._find_page(path)
        if page is None:
            return {"ok": False, "error": "notFound"}

        front, body = PageStore.load(page)
        fields = PageStore.fields(front)
        return {
            "ok": True,
            "page": page.to_dict(),
            "body": body,
            "fields": [field.to_dict() for field in fields],
        }

    def createPage(
        self,
        slug: str,
        title: str,
        layout: str = "",
        extra: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        """新建页面（``source/<slug>/index.md``）。"""
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}
        if not title or not title.strip():
            return {"ok": False, "error": "titleEmpty"}

        try:
            page = PageStore.create(
                site,
                slug=slug,
                title=title.strip(),
                layout=layout,
                extra_front_matter=extra or {},
            )
        except pages_module.PageStoreError as error:
            return {"ok": False, "error": error.code, "message": error.message}

        return {"ok": True, "page": page.to_dict()}

    def savePage(
        self,
        path: str,
        body: str = "",
        fields: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        """保存页面：只改传进来的字段，其余原样保留。"""
        page = self._find_page(path)
        if page is None:
            return {"ok": False, "error": "notFound"}

        front, _ = PageStore.load(page)

        for item in fields or []:
            if not isinstance(item, dict):
                continue
            key = str(item.get("key") or "").strip()
            if not key:
                continue

            kind = str(item.get("kind") or "text")
            value = item.get("value", "")

            if kind == "list":
                items = item.get("items")
                if isinstance(items, list):
                    front.set(key, [str(entry) for entry in items if str(entry).strip()])
                else:
                    front.set(key, frontmatter.split_inline_list(str(value).strip("[]")))
            elif kind == "boolean":
                lowered = str(value).strip().lower()
                # 传真布尔值：字符串会被加上引号，写出来是 `draft: "true"`，
                # YAML 读回来是字符串，Hexo 不认。
                front.set(key, lowered in ("true", "yes", "1", "on"))
            elif kind == "integer":
                try:
                    front.set(key, int(str(value).strip()))
                except ValueError:
                    front.set(key, 0)
            else:
                front.set(key, str(value))

        try:
            PageStore.save(page, front, body)
        except OSError as error:
            return {"ok": False, "error": "writeFailed", "message": str(error)}

        refreshed = self._find_page(path)
        return {
            "ok": True,
            "page": (refreshed or page).to_dict(),
        }

    def deletePage(self, path: str) -> dict[str, Any]:
        """删除页面文件（目录空了就一并删掉）。"""
        page = self._find_page(path)
        if page is None:
            return {"ok": False, "error": "notFound"}

        try:
            PageStore.delete(page)
        except OSError as error:
            return {"ok": False, "error": "deleteFailed", "message": str(error)}
        return {"ok": True}

    def getPageAssets(self, path: str) -> dict[str, Any]:
        """页面关联的本地资源（样式 / 脚本 / 图片）。"""
        site = self._site_list.current
        page = self._find_page(path)
        if not site or page is None:
            return {"ok": True, "assets": []}

        assets = page_assets_module.PageAssetScanner.scan(site, page)
        return {"ok": True, "assets": [asset.to_dict() for asset in assets]}

    def getPageReferences(self, path: str) -> dict[str, Any]:
        """哪些文章引用了这个页面。"""
        site = self._site_list.current
        page = self._find_page(path)
        if not site or page is None:
            return {"ok": True, "references": []}

        references = page_reference_module.PageReferenceIndex.references(page, site)
        return {"ok": True, "references": [item.to_dict() for item in references]}

    def revealPage(self, path: str) -> dict[str, Any]:
        if not path:
            return {"ok": False, "error": "pathEmpty"}
        reveal_in_file_manager(path)
        return {"ok": True}

    # -- 配置 ---------------------------------------------------------

    def listConfigFiles(self) -> dict[str, Any]:
        """站点根目录下的 ``_config*.yml``。"""
        site = self._site_list.current
        if not site:
            return {"ok": True, "files": []}

        files = ConfigStore.list(site)
        return {"ok": True, "files": [item.to_dict() for item in files]}

    def getConfigFile(self, path: str) -> dict[str, Any]:
        """读一份配置文件（原文 + 顶层键）。"""
        if not path:
            return {"ok": False, "error": "pathEmpty"}
        config = ConfigStore.load(path)
        return {"ok": True, "file": config.to_dict()}

    def saveConfigFile(self, path: str, contents: str) -> dict[str, Any]:
        """保存配置文件。写完会重新读一遍核对。"""
        if not path:
            return {"ok": False, "error": "pathEmpty"}

        config = ConfigFile(
            path=path,
            name=path.rsplit("/", 1)[-1].rsplit("\\", 1)[-1],
            contents=contents,
            original_contents="",
        )
        try:
            ConfigStore.save(config)
        except config_file_module.ConfigStoreError as error:
            return {"ok": False, "error": error.code, "message": error.message}

        return {"ok": True, "file": ConfigStore.load(path).to_dict()}

    def getConfigSchema(self, path: str) -> dict[str, Any]:
        """把一份配置解析成「带说明的表单字段」。"""
        if not path:
            return {"ok": False, "error": "pathEmpty"}

        text = config_file_module.read_text(path) or ""
        document = YamlDocument(text)
        fields = ConfigSchema.fields(document)

        return {
            "ok": True,
            "fields": [field.to_dict() for field in fields],
            "parseError": document.error,
        }

    def getConfigList(self, path: str, keyPath: list[str]) -> dict[str, Any]:
        """列表型配置项的编辑器结构。"""
        if not path or not keyPath:
            return {"ok": False, "error": "invalidArgs"}

        text = config_file_module.read_text(path) or ""
        items = ConfigSchema.list_fields(YamlDocument(text), [str(part) for part in keyPath])
        return {"ok": True, "items": [item.to_dict() for item in items]}

    # -- 常用配置（SiteSettings） -------------------------------------

    def getSiteSettings(self, path: str = "") -> dict[str, Any]:
        """常用配置项的表单结构 + 当前值。

        ``path`` 为空时用当前站点的 ``_config.yml``。
        """
        target = path or self._current_config_path()
        if not target:
            return {"ok": False, "error": "noSite"}

        text = config_file_module.read_text(target) or ""
        values = site_settings_module.SiteSettings.values(text)

        groups: list[dict[str, Any]] = []
        for name in site_settings_module.SiteSettings.groups():
            fields = []
            for field in site_settings_module.SiteSettings.fields(name):
                item = field.to_dict(self._settings.language)
                item["value"] = values.get(field.key, "")
                # 挂着多行块的键不能改——硬改会把整个嵌套结构搞坏。
                item["isNestedBlock"] = site_settings_module.SiteSettings.is_nested_block(
                    field.key, text
                )
                fields.append(item)

            groups.append(
                {
                    "key": name,
                    "label": i18n.t(f"siteSettings.group.{name}", self._settings.language),
                    "fields": fields,
                }
            )

        return {"ok": True, "path": target, "groups": groups}

    def updateSiteSetting(self, path: str, key: str, value: str) -> dict[str, Any]:
        """改一个常用配置项。只动那一行，注释和缩进原样保留。"""
        target = path or self._current_config_path()
        if not target:
            return {"ok": False, "error": "noSite"}
        if not key:
            return {"ok": False, "error": "keyEmpty"}

        text = config_file_module.read_text(target)
        if text is None:
            return {"ok": False, "error": "notFound"}

        try:
            updated = site_settings_module.SiteSettings.set_value(value, key, text)
        except site_settings_module.SiteSettingsError as error:
            # 注意：不能用 ``i18n.t("...", lang, key=...)``——``t()`` 的第一个
            # 形参就叫 ``key``，传同名关键字会 TypeError。这里自己取模板再格式化。
            template = i18n.get_strings(self._settings.language).get(
                "siteSettings.nestedBlock", ""
            )
            return {
                "ok": False,
                "error": error.code,
                "key": error.key,
                "message": template.replace("{key}", error.key) if template else "",
            }

        try:
            ConfigStore.save(ConfigFile(path=target, name="", contents=updated))
        except config_file_module.ConfigStoreError as error:
            return {"ok": False, "error": error.code, "message": error.message}

        return {"ok": True, "path": target, "key": key, "value": value}

    # -- 新建站点（SiteCreator） ---------------------------------------

    def listSiteTemplates(self) -> dict[str, Any]:
        """``hexo init`` 可用的模板。"""
        language = self._settings.language
        templates = [
            {
                "key": item.key,
                "title": i18n.t(item.title_key, language),
                "subtitle": i18n.t(item.subtitle_key, language),
            }
            for item in site_creator_module.SiteCreator.templates()
        ]
        return {"ok": True, "templates": templates}

    def createSite(
        self,
        name: str,
        parentDirectory: str,
        template: str = "standard",
        installDependencies: bool = True,
    ) -> dict[str, Any]:
        """新建一个 Hexo 站点。

        站点建好后会**自动加入列表**并选中——用户不用再去「添加站点」
        那里手动贴一遍路径。
        """
        if not name or not name.strip():
            return {"ok": False, "error": "invalidName"}
        if not parentDirectory or not parentDirectory.strip():
            return {"ok": False, "error": "parentEmpty"}

        result = site_creator_module.SiteCreator.create(
            name.strip(),
            parentDirectory.strip(),
            template=template,
            install_dependencies=bool(installDependencies),
            runner=self._runner,
            environment=self._environment,
            custom_hexo_path=self._settings.custom_hexo_path,
        )

        if not result.ok:
            return {
                "ok": False,
                "error": result.error,
                "message": i18n.t(
                    {
                        "invalidName": "siteWizard.invalidName",
                        "parentEmpty": "siteWizard.parentEmpty",
                        "parentMissing": "siteWizard.parentMissing",
                        "alreadyExists": "siteWizard.alreadyExists",
                        "hexoUnavailable": "siteWizard.hexoUnavailable",
                        "initFailed": "siteWizard.initFailed",
                        "notCreated": "siteWizard.notCreated",
                    }.get(result.error, "result.failed"),
                    self._settings.language,
                    path=result.message,
                    message=result.message,
                ),
            }

        # 校验通过才纳入管理，避免留下「已添加但坏掉」的站点。
        added = self._site_list.add(result.path)
        self._persist()

        if not added:
            return {
                "ok": False,
                "error": "notAdded",
                "path": result.path,
                "message": "站点已生成，但没有通过 Hexo 站点校验，未加入列表",
            }

        return {
            "ok": True,
            "path": result.path,
            "dependencyFailed": result.dependency_failed,
        }

    def installDependencies(self) -> dict[str, Any]:
        """在当前站点目录跑 ``npm install``。"""
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}

        success = site_creator_module.SiteCreator.install_dependencies(
            site, runner=self._runner
        )
        return {"ok": success, "path": site.path}

    # -- 主题安装与迁移（ThemeInstaller） ------------------------------

    def applyTheme(self, packageName: str) -> dict[str, Any]:
        """装主题并切换过去。

        装包用 ``npm install``，只改 ``_config.yml`` 里的 ``theme`` 一行，
        最后算一份跨主题迁移清单给用户确认。
        """
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}

        name = theme_manager_module.ThemeManager.normalize_package_name(packageName)
        if not name:
            return {"ok": False, "error": "invalidName"}

        allowed = set(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./"
        )
        if any(character not in allowed for character in name):
            return {"ok": False, "error": "invalidName"}

        npm = self._runner.which("npm")
        if not npm:
            return {"ok": False, "error": "npmMissing"}

        full_package = theme_manager_module.ThemeManager.full_package_name(name)
        install = self._runner.run(
            [
                npm,
                "install",
                full_package,
                "--no-audit",
                "--no-fund",
                "--loglevel",
                "warn",
            ],
            cwd=site.path,
        )
        if not install.success:
            return {
                "ok": False,
                "error": "installFailed",
                "message": install.error_summary or "",
                "packageName": full_package,
            }

        short_name = theme_manager_module.ThemeManager.short_name(full_package)

        # 顺序不能反：compute_migration 靠「站点配置里的 theme 与目标不同」
        # 去找旧主题的配置文件，所以必须在写新 theme 之前算。先写再算的话
        # 两者已经同名，它会认定没有旧主题可比，永远返回 None。
        migration = theme_installer_module.ThemeInstaller.compute_migration(site, short_name)

        theme_installer_module.ThemeInstaller.write_theme(site, short_name)

        return {
            "ok": True,
            "installed": True,
            "packageName": full_package,
            "activeTheme": short_name,
            "migration": migration.to_dict() if migration else None,
        }

    def getThemeMigration(self, themeName: str) -> dict[str, Any]:
        """算一份跨主题迁移清单（不装、不写）。"""
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}

        name = theme_manager_module.ThemeManager.normalize_package_name(themeName)
        if not name:
            return {"ok": False, "error": "invalidName"}

        plan = theme_installer_module.ThemeInstaller.compute_migration(site, name)
        return {"ok": True, "migration": plan.to_dict() if plan else None}

    def applyThemeMigration(self, keys: list[str]) -> dict[str, Any]:
        """把选中的公共项从旧主题配置搬到站点配置。"""
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}
        if not keys:
            return {"ok": False, "error": "noKeys"}

        from .config_sync import ConfigSync

        active = theme_manager_module.ThemeManager.active_theme_name(site)
        if not active:
            return {"ok": False, "error": "noActiveTheme"}

        old_theme_config = os.path.join(site.path, f"_config.{active}.yml")
        old_text = config_file_module.read_text(old_theme_config)
        if old_text is None:
            return {"ok": False, "error": "notFound"}

        site_config_path = os.path.join(site.path, "_config.yml")
        site_text = config_file_module.read_text(site_config_path)
        if site_text is None:
            return {"ok": False, "error": "notFound"}

        updated = site_text
        applied = 0
        for raw_key in keys:
            value = YamlDocument(old_text).get(str(raw_key))
            if value is None:
                continue
            result = ConfigSync.apply_to_site(str(raw_key), value, updated)
            if result is None:
                continue
            updated = result
            applied += 1

        if applied == 0:
            return {"ok": False, "error": "nothingApplied"}

        try:
            ConfigStore.save(ConfigFile(path=site_config_path, name="", contents=updated))
        except config_file_module.ConfigStoreError as error:
            return {"ok": False, "error": error.code, "message": error.message}

        return {"ok": True, "applied": applied}

    def updateConfigValue(
        self, path: str, keyPath: str, value: str
    ) -> dict[str, Any]:
        """改配置里的一个值（只动那一段文本）。"""
        if not path or not keyPath:
            return {"ok": False, "error": "invalidArgs"}

        text = config_file_module.read_text(path)
        if text is None:
            return {"ok": False, "error": "notFound"}

        updated = YamlDocument(text).set(keyPath, value)
        if updated is None:
            return {"ok": False, "error": "pathNotWritable"}

        try:
            ConfigStore.save(ConfigFile(path=path, name="", contents=updated))
        except config_file_module.ConfigStoreError as error:
            return {"ok": False, "error": error.code, "message": error.message}

        return {"ok": True}

    def getConfigSync(self) -> dict[str, Any]:
        """站点配置 ↔ 当前主题配置的差异。"""
        site = self._site_list.current
        if not site:
            return {"ok": True, "differences": [], "themeOnly": [], "themeConfigPath": ""}

        theme_name = ThemeManager.active_theme_name(site)
        theme_path = f"{site.path}/_config.{theme_name}.yml" if theme_name else ""

        site_text = config_file_module.read_text(site.config_file) or ""
        theme_text = config_file_module.read_text(theme_path) or ""

        if not theme_text:
            return {
                "ok": True,
                "differences": [],
                "themeOnly": [],
                "themeConfigPath": "",
                "themeName": theme_name,
            }

        differences = ConfigSync.differences(site_text, theme_text)
        theme_only = ConfigSync.theme_only_entries(site_text, theme_text)

        return {
            "ok": True,
            "themeName": theme_name,
            "themeConfigPath": theme_path,
            "differences": [item.to_dict() for item in differences],
            "themeOnly": [item.to_dict() for item in theme_only],
        }

    def applyConfigSync(self) -> dict[str, Any]:
        """把站点配置里的值同步到主题配置。"""
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}

        theme_name = ThemeManager.active_theme_name(site)
        theme_path = f"{site.path}/_config.{theme_name}.yml" if theme_name else ""

        site_text = config_file_module.read_text(site.config_file) or ""
        theme_text = config_file_module.read_text(theme_path)
        if theme_text is None:
            return {"ok": False, "error": "noThemeConfig"}

        updated, changed = ConfigSync.sync_all(site_text, theme_text)
        if not changed:
            return {"ok": True, "changed": [], "message": "nothingToSync"}

        try:
            ConfigStore.save(ConfigFile(path=theme_path, name="", contents=updated))
        except config_file_module.ConfigStoreError as error:
            return {"ok": False, "error": error.code, "message": error.message}

        return {"ok": True, "changed": changed}

    def applyThemeOnlyToSite(self, key: str, value: str) -> dict[str, Any]:
        """把只写在主题配置里的键搬回站点配置。"""
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}

        site_text = config_file_module.read_text(site.config_file)
        if site_text is None:
            return {"ok": False, "error": "notFound"}

        updated = ConfigSync.apply_to_site(key, value, site_text)
        if updated is None:
            return {"ok": False, "error": "pathNotWritable"}

        try:
            ConfigStore.save(ConfigFile(path=site.config_file, name="", contents=updated))
        except config_file_module.ConfigStoreError as error:
            return {"ok": False, "error": error.code, "message": error.message}

        return {"ok": True}

    # -- 主题 ---------------------------------------------------------

    def listThemes(self) -> dict[str, Any]:
        """已安装主题 + 当前主题。"""
        site = self._site_list.current
        if not site:
            return {"ok": True, "themes": [], "activeTheme": ""}

        active = ThemeManager.active_theme_name(site)
        themes = ThemeManager.installed(site, active_name=active)
        return {
            "ok": True,
            "activeTheme": active,
            "themes": [theme.to_dict() for theme in themes],
        }

    def searchThemes(self, query: str = "") -> dict[str, Any]:
        """主题市场搜索（离线精选 + 可选联网）。"""
        results = self._theme_registry.search(
            query or "", enabled=self._settings.online_theme_search
        )
        return {
            "ok": True,
            "results": [item.to_dict() for item in results],
            "online": self._settings.online_theme_search,
            "log": self._theme_registry.log.to_dict(),
        }

    def switchTheme(self, packageName: str) -> dict[str, Any]:
        """切换主题：只改 ``_config.yml`` 里的 ``theme`` 键。"""
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}

        name = ThemeManager.normalize_package_name(packageName)
        if not name:
            return {"ok": False, "error": "invalidName"}

        themes = {theme.name: theme for theme in ThemeManager.installed(site, "")}
        theme = themes.get(name)
        if theme is None:
            # 还没装的主题不能直接切——切了就是白屏
            return {"ok": False, "error": "themeNotInstalled", "name": name}

        try:
            ThemeManager.switch_theme(site, theme)
        except theme_manager_module.ThemeManagerError as error:
            return {"ok": False, "error": error.code, "message": error.message}

        return {"ok": True, "activeTheme": name}

    def createThemeConfig(self, packageName: str) -> dict[str, Any]:
        """从主题示例配置生成站点的 ``_config.<name>.yml``。"""
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}

        name = ThemeManager.normalize_package_name(packageName)
        themes = {theme.name: theme for theme in ThemeManager.installed(site, "")}
        theme = themes.get(name)
        if theme is None:
            return {"ok": False, "error": "themeNotInstalled"}

        try:
            path = ThemeManager.create_site_config(site, theme)
        except theme_manager_module.ThemeManagerError as error:
            return {"ok": False, "error": error.code, "message": error.message}

        return {"ok": True, "path": path}

    # -- 备份 ---------------------------------------------------------

    def getBackupPlan(self) -> dict[str, Any]:
        """备份前先算一遍范围，让界面能显示「将打包多少个文件」。"""
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}

        plan = backup_module.BackupManager.plan(site)
        return {"ok": True, "plan": plan.to_dict()}

    def listBackups(self) -> dict[str, Any]:
        site = self._site_list.current
        if not site:
            return {"ok": True, "backups": []}

        entries = backup_module.BackupManager.list_backups(
            site.path, self._backup_directory
        )
        return {"ok": True, "backups": [entry.to_dict() for entry in entries]}

    def createBackup(self) -> dict[str, Any]:
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}

        try:
            entry = backup_module.BackupManager.create_backup(
                site, directory=self._backup_directory
            )
        except backup_module.BackupError as error:
            return {"ok": False, "error": error.code, "message": error.message}

        return {"ok": True, "backup": entry.to_dict()}

    def restoreBackup(self, path: str) -> dict[str, Any]:
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}
        if not path:
            return {"ok": False, "error": "pathEmpty"}

        entry = backup_module.BackupEntry(path=path, site_path=site.path)
        try:
            backup_module.BackupManager.restore_backup(entry, site.path)
        except backup_module.BackupError as error:
            return {"ok": False, "error": error.code, "message": error.message}

        return {"ok": True}

    def deleteBackup(self, path: str) -> dict[str, Any]:
        if not path:
            return {"ok": False, "error": "pathEmpty"}

        entry = backup_module.BackupEntry(path=path)
        try:
            backup_module.BackupManager.delete_backup(entry)
        except backup_module.BackupError as error:
            return {"ok": False, "error": error.code, "message": error.message}

        return {"ok": True}

    # -- 自定义内容 / 片段 --------------------------------------------

    def getCustomContent(self) -> dict[str, Any]:
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}

        content = CustomContentStore.load(site)
        scripts = detected_inject_scripts(site)
        return {
            "ok": True,
            "content": content.to_dict(),
            "installed": CustomContentStore.is_installed(site),
            "scripts": [script.to_dict() for script in scripts],
        }

    def saveCustomContent(self, head: str = "", body: str = "") -> dict[str, Any]:
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}

        try:
            CustomContentStore.save(CustomContent(head=head, body=body), site)
        except OSError as error:
            return {"ok": False, "error": "writeFailed", "message": str(error)}

        return {"ok": True, "installed": True}

    def removeCustomContent(self) -> dict[str, Any]:
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}

        CustomContentStore.remove(site)
        return {"ok": True, "installed": False}

    def listSnippets(self) -> dict[str, Any]:
        return {"ok": True, "snippets": [item.to_dict() for item in SnippetLibrary.ALL]}

    def instantiateSnippet(self, snippetId: str, values: dict[str, str]) -> dict[str, Any]:
        snippet = SnippetLibrary.find(snippetId)
        if snippet is None:
            return {"ok": False, "error": "notFound"}

        code, missing = SnippetLibrary.instantiate(snippet, values or {})
        return {"ok": True, "code": code, "missing": missing, "target": snippet.target}

    # -- 环境 ---------------------------------------------------------

    def inspectEnvironment(self, refresh: bool = False) -> dict[str, Any]:
        """工具链体检。``refresh=True`` 时重新读一遍用户的 rc 文件。"""
        if refresh or self._environment is None:
            self._environment = ShellEnvironmentResolver.resolve(
                custom_rc_path=self._settings.custom_rc_path
            )

        info = HexoEnvironment.inspect(
            runner=self._runner,
            environment=self._environment,
            uses_shell_environment=self._settings.uses_shell_environment,
            custom_rc_path=self._settings.custom_rc_path,
        )
        return {"ok": True, "toolchain": info.to_dict()}

    def getEnvironmentDocs(self) -> dict[str, Any]:
        return {"ok": True, "sections": EnvironmentDocs.to_list()}

    # -- Git 动作 -----------------------------------------------------

    def commitGit(self, message: str) -> dict[str, Any]:
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}
        if not message or not message.strip():
            return {"ok": False, "error": "messageEmpty"}

        result = GitService(site, self._runner).commit(message.strip())
        return {
            "ok": result.success,
            "exitCode": result.exit_code,
            "output": result.output,
            "error": result.error_summary,
        }

    def pushGit(self) -> dict[str, Any]:
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}

        result = GitService(site, self._runner).push()
        return {
            "ok": result.success,
            "exitCode": result.exit_code,
            "output": result.output,
            "error": result.error_summary,
        }

    def pullGit(self) -> dict[str, Any]:
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}

        result = GitService(site, self._runner).pull()
        return {
            "ok": result.success,
            "exitCode": result.exit_code,
            "output": result.output,
            "error": result.error_summary,
        }

    def stageGitFile(self, path: str) -> dict[str, Any]:
        """暂存单个文件。"""
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}
        if not path:
            return {"ok": False, "error": "pathEmpty"}

        result = GitService(site, self._runner).add(path)
        return {
            "ok": result.success,
            "exitCode": result.exit_code,
            "output": result.output,
            "error": result.error_summary,
        }

    def unstageGitFile(self, path: str) -> dict[str, Any]:
        """取消暂存单个文件（保留工作区改动）。"""
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}
        if not path:
            return {"ok": False, "error": "pathEmpty"}

        result = GitService(site, self._runner).unstage(path)
        return {
            "ok": result.success,
            "exitCode": result.exit_code,
            "output": result.output,
            "error": result.error_summary,
        }

    def diffGitFile(self, path: str) -> dict[str, Any]:
        """对单文件跑对比。

        站点配了 ``diff.tool`` 就用它；没配就把文件本身交给系统处理
        （在 VSCode / Xcode 这类自带 diff 的编辑器里效果等同）。
        """
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}
        if not path:
            return {"ok": False, "error": "pathEmpty"}

        result = GitService(site, self._runner).difftool(path)
        if result is None:
            # 没配置 diff.tool：打开文件本身。
            absolute = os.path.join(site.path, path)
            if os.path.exists(absolute):
                open_path(absolute)
            else:
                reveal_in_file_manager(site.path)
            return {"ok": True, "usedTool": False}

        return {
            "ok": result.success,
            "usedTool": True,
            "exitCode": result.exit_code,
            "output": result.output,
            "error": result.error_summary,
        }

    # -- 插图 ---------------------------------------------------------

    def chooseImages(self) -> dict[str, Any]:
        """让用户挑几张图片，返回选中的文件路径。

        没有窗口时（无头环境、单元测试）返回空列表，界面据此什么都不做。
        """
        return {"ok": True, "paths": choose_images()}

    def storeImages(self, paths: list[str], base: str = "") -> dict[str, Any]:
        """把磁盘上的几张图存进当前站点，返回能直接插进正文的 Markdown。

        单张失败不影响其余的：拖十张进来，坏的那张跳过，剩下的照插。
        """
        site = self._site_list.current
        if not site:
            return {"ok": False, "error": "noSite"}
        if not paths:
            return {"ok": True, "markdown": [], "failed": 0}

        lines: list[str] = []
        failed = 0
        for path in paths:
            data = site_media_module.SiteMedia.read_file(path)
            if data is None:
                failed += 1
                continue
            try:
                stored = site_media_module.SiteMedia.store(
                    data=data,
                    filename=os.path.basename(path),
                    site=site.path,
                    base=base,
                )
            except OSError:
                failed += 1
                continue
            lines.append(stored.markdown)

        return {"ok": True, "markdown": lines, "failed": failed}

    # -- 内部 ---------------------------------------------------------

    def _hexo_service(self, site: Site) -> HexoService:
        """带上了用户真实 shell 环境的 hexo 服务。

        不传环境的话，从 Dock 启动的应用拿到的 PATH 只有系统那几个目录，
        brew 装的 node 根本找不到。
        """
        return HexoService(
            site,
            self._settings.custom_hexo_path,
            self._runner,
            environment=self._environment,
        )

    def _find_page(self, path: str):
        """按绝对路径在站点里找一个页面。"""
        site = self._site_list.current
        if not site or not path:
            return None

        normalized = path.replace("\\", "/")
        for page in PageStore.scan(site):
            if page.path.replace("\\", "/") == normalized:
                return page
        return None

    def _current_info(self) -> dict[str, Any] | None:
        site = self._site_list.current
        return sites_module.inspect_site(site).to_dict() if site else None

    def _current_config_path(self) -> str:
        """当前站点的 ``_config.yml`` 路径。没有站点时返回空串。"""
        site = self._site_list.current
        return site.config_file if site else ""

    def _persist(self) -> None:
        """把当前状态写回 settings.json。"""
        self._settings.sites = self._site_list.sites
        self._settings.last_site_path = self._site_list.current_path
        self._settings_store.save(self._settings)
