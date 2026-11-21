"""页面的「关联资源」识别。

对应 Swift 侧的 ``PageAssets.swift``。

## 要解决的问题

现代 Hexo 页面很少再靠 Markdown 正文了。典型长这样：

    ---
    title: 可爱的女孩子
    layout: girls
    girls:
      - name: 阿蕾奇诺
    ---

    <link rel="stylesheet" href="/css/girls.css">
    <script src="/js/girls.js"></script>

正文只有两行，真正的内容在 front-matter 里（渲染时由主题模板 + JS 读出来）。
于是页面管理里看起来就是「一个空空如也、只有两行的页面」，用户完全不知道
这个页面其实有 53 条数据、还挂着两个本地文件。

## 识别规则

只关联**本地**资源，并且必须在 source 下真实存在：

- ``<link href="/css/girls.css">`` → ``source/css/girls.css``  ✔
- ``<script src="https://cdn.jsdelivr.net/...">``               ✘ 在线，不关联
- ``<link href="/css/theme.css">``（文件不存在）                 ✘ 不关联

另外按「同名约定」补一层：``girls/index.md`` 会去找 ``source/css/girls.css``、
``source/js/girls.js``。页面正文里不写引用、靠主题 layout 自动引入时靠这条兜住。

**在线资源不关联**是刻意的：它们不属于这个仓库，改不动也不该在这里编辑。
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from . import frontmatter
from .model import Site, read_text
from .pages import PageFile

__all__ = ["PageAsset", "PageAssetScanner"]

#: ``href="..."`` / ``src="..."``
_REFERENCE_PATTERN = re.compile(r"""(?:href|src)\s*=\s*["']([^"']+)["']""", re.IGNORECASE)


def _kind_for(path: str) -> str:
    """扩展名 → 类别。"""
    extension = os.path.splitext(path)[1].lower()
    if extension == ".css":
        return "css"
    if extension in (".js", ".mjs", ".cjs"):
        return "js"
    if extension in (".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".avif", ".ico"):
        return "image"
    return "other"


_KIND_LABELS = {"css": "样式", "js": "脚本", "image": "图片", "other": "其他"}


@dataclass
class PageAsset:
    """一个和页面关联的本地资源。"""

    #: 站点内路径，如 ``/css/girls.css``
    site_path: str
    #: 磁盘绝对路径（缺失时为空）
    source_path: str = ""
    #: 相对 source 的路径
    relative_path: str = ""
    kind: str = "other"
    #: explicit（页面里引用）/ convention（同名推断）/ missing（引用了但不存在）
    origin: str = "explicit"
    byte_size: int = 0
    modified_at: float = 0.0

    @property
    def id(self) -> str:
        return self.site_path

    @property
    def kind_label(self) -> str:
        return _KIND_LABELS.get(self.kind, "其他")

    @property
    def origin_label(self) -> str:
        return {"explicit": "引用", "convention": "推断", "missing": "缺失"}.get(
            self.origin, ""
        )

    @property
    def origin_description(self) -> str:
        return {
            "explicit": "页面里引用",
            "convention": "同名推断",
            "missing": "引用了但文件不存在",
        }.get(self.origin, "")

    @property
    def size_description(self) -> str:
        size = self.byte_size
        if size < 1024:
            return f"{size} B"
        if size < 1024 * 1024:
            return f"{size / 1024:.1f} KB"
        return f"{size / 1024 / 1024:.1f} MB"

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "sitePath": self.site_path,
            "sourcePath": self.source_path,
            "relativePath": self.relative_path,
            "kind": self.kind,
            "kindLabel": self.kind_label,
            "origin": self.origin,
            "originLabel": self.origin_label,
            "originDescription": self.origin_description,
            "byteSize": self.byte_size,
            "sizeDescription": self.size_description,
            "modifiedAt": self.modified_at,
        }


class PageAssetScanner:
    """页面资源识别。"""

    @staticmethod
    def scan(site: Site, page: PageFile) -> list[PageAsset]:
        """扫描一个页面的关联资源。"""
        source_root = Path(site.path) / "source"

        # 页面目录名：girls/index.md → girls
        directory = page.path.rsplit(os.sep, 1)[0] if os.sep in page.path else ""
        dir_name = os.path.basename(directory) if directory else ""
        # 单页写法 about.md → about
        if dir_name == "source":
            dir_name = os.path.splitext(os.path.basename(page.path))[0]

        found: dict[str, PageAsset] = {}

        def add(site_path: str, origin: str) -> None:
            existing = found.get(site_path)
            # 已经在「同名推断」阶段收录过，就不要被显式引用降级
            if existing is not None and existing.origin == "convention" and origin == "explicit":
                found[site_path] = PageAsset(
                    site_path=existing.site_path,
                    source_path=existing.source_path,
                    relative_path=existing.relative_path,
                    kind=existing.kind,
                    origin="explicit",
                    byte_size=existing.byte_size,
                    modified_at=existing.modified_at,
                )
                return
            if existing is None:
                found[site_path] = PageAssetScanner._make(site_path, origin, source_root)

        # 1. 正文 + front-matter 里显式引用的本地资源
        front, body = _load(page)
        for reference in PageAssetScanner.local_references(body):
            add(reference, "explicit")
        for entry in frontmatter.raw_entries(front):
            text = entry.verbatim_block or entry.value
            for reference in PageAssetScanner.local_references(text):
                add(reference, "explicit")

        # 2. 同名约定兜底：girls/index.md → /css/girls.css、/js/girls.js
        if dir_name and dir_name != ".":
            add(f"/css/{dir_name}.css", "convention")
            add(f"/js/{dir_name}.js", "convention")

        # 显式引用但文件不存在的，标成「缺失」而不是直接丢掉——
        # 那通常是路径写错了，页面在浏览器里就是白板。藏起来等于帮倒忙。
        for site_path, asset in list(found.items()):
            if not asset.source_path and asset.origin == "explicit":
                found[site_path] = PageAsset(
                    site_path=asset.site_path,
                    source_path="",
                    relative_path=asset.relative_path,
                    kind=asset.kind,
                    origin="missing",
                    byte_size=0,
                    modified_at=0.0,
                )

        items = [
            asset
            for asset in found.values()
            if asset.origin != "convention" or asset.source_path
        ]

        # 缺失的排最后，正常的第一屏
        items.sort(key=lambda item: (item.origin == "missing", item.kind_label, item.site_path))
        return items

    @staticmethod
    def _make(site_path: str, origin: str, source_root: Path) -> PageAsset:
        """造一个 PageAsset；本地文件不存在时 source_path 为空。"""
        # /css/girls.css → source/css/girls.css
        relative = site_path[1:].strip() if site_path.startswith("/") else site_path
        full = source_root / relative

        exists = full.is_file()
        if exists:
            try:
                stat = full.stat()
                return PageAsset(
                    site_path=site_path,
                    source_path=str(full),
                    relative_path=relative,
                    kind=_kind_for(site_path),
                    origin=origin,
                    byte_size=stat.st_size,
                    modified_at=stat.st_mtime,
                )
            except OSError:
                pass

        return PageAsset(
            site_path=site_path,
            source_path="",
            relative_path=relative,
            kind=_kind_for(site_path),
            origin=origin,
        )

    @staticmethod
    def local_references(text: str) -> list[str]:
        """从一段 HTML/Markdown 里挑出**本地**资源引用。

        只认 ``href=`` / ``src=``，且只认以 ``/`` 开头的站内绝对路径。
        ``https://``、``//cdn...``、``data:`` 一律排除——在线内容不属于这个仓库。
        """
        if not text:
            return []

        results: list[str] = []
        for match in _REFERENCE_PATTERN.finditer(text):
            raw = match.group(1).strip()

            # 只要站内绝对路径。// 开头的是协议相对地址，属于在线资源，排除。
            if not raw.startswith("/") or raw.startswith("//"):
                continue
            # 排除路由链接（/archives/ 这种不是资源）
            if _kind_for(raw) == "other":
                continue
            if raw not in results:
                results.append(raw)

        return results


def _load(page: PageFile) -> tuple[frontmatter.FrontMatter, str]:
    text = read_text(page.path)
    if text is None:
        return frontmatter.FrontMatter(), ""
    return frontmatter.split(text)
