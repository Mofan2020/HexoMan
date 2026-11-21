"""找出哪些文章引用了某个页面。

对应 Swift 侧的 ``PageReferenceIndex.swift``。

## 判定方法

扫描每篇文章的正文 + front-matter，找：

1. 相对链接 ``/about/``、``./about/``、``../about/`` —— 对应
   ``source/about.md`` 或 ``source/about/index.md``（Hexo 默认行为）。
2. ``[text](permalink)`` 形式，permalink 是页面 front-matter 里 ``permalink:``
   字段的值。
3. 标签交集：文章和页面有共同标签。

## 复杂度

这是一个 O(N×M) 的扫描。Hexo 站点文章数量通常 < 1000，每次切换选中页时跑
一次没问题。如果未来要支持 10000+ 文章，再考虑缓存。
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from . import frontmatter
from .model import Site, read_text
from .pages import PageFile

__all__ = ["PageReference", "PageReferenceIndex"]


@dataclass
class PageReference:
    """一篇文章对某个页面的引用。"""

    post_title: str
    post_file_path: str
    #: pathLink / permalink / tag
    match_kind: str = "pathLink"
    match_snippet: str = ""

    @property
    def id(self) -> str:
        return f"{self.post_file_path}#{self.match_snippet}"

    @property
    def match_kind_label(self) -> str:
        return {
            "pathLink": "路径链接",
            "permalink": "固定链接",
            "tag": "共同标签",
        }.get(self.match_kind, "")

    def to_dict(self) -> dict[str, Any]:
        return {
            "postTitle": self.post_title,
            "postFilePath": self.post_file_path,
            "matchKind": self.match_kind,
            "matchKindLabel": self.match_kind_label,
            "matchSnippet": self.match_snippet,
        }


class PageReferenceIndex:
    """引用索引。"""

    @staticmethod
    def references(to_page: PageFile, site: Site) -> list[PageReference]:
        """找出所有引用了 ``page`` 的文章。"""
        # 延迟导入：sites 在模块层导入 posts，这里反向依赖只能延迟解析。
        from .sites import resolve_paths

        _, posts_dir = resolve_paths(site)

        try:
            entries = sorted(os.listdir(posts_dir))
        except OSError:
            return []

        # 计算 page 在 source 下的相对路径（不含 .md 后缀）。
        page_rel_path = _relative_source_path(to_page.path, site.path)

        page_loaded = _load(to_page.path)
        page_front = page_loaded[0] if page_loaded else frontmatter.FrontMatter()

        page_permalink = ""
        for entry in frontmatter.raw_entries(page_front):
            if entry.key == "permalink":
                page_permalink = entry.value.strip()
                break

        # 这个 page 自己拥有的标签——任何带这些标签的文章都算「关联」。
        page_tags = {tag.lower() for tag in page_front.tags}

        results: list[PageReference] = []
        posts_root = Path(posts_dir)

        for entry in entries:
            if not entry.endswith(".md"):
                continue
            post_path = str(posts_root / entry)
            loaded = _load(post_path)
            if loaded is None:
                continue
            post_front, body = loaded
            # 跳过自己（页面文件如果恰好被放在 _posts 里）
            if os.path.normpath(post_path) == os.path.normpath(to_page.path):
                continue

            title = _title_from(post_front, entry)

            # 1. 路径链接
            if page_rel_path and page_rel_path in body:
                results.append(
                    PageReference(
                        post_title=title,
                        post_file_path=post_path,
                        match_kind="pathLink",
                        match_snippet=page_rel_path,
                    )
                )
                continue

            # 2. permalink
            if page_permalink and page_permalink in body:
                results.append(
                    PageReference(
                        post_title=title,
                        post_file_path=post_path,
                        match_kind="permalink",
                        match_snippet=page_permalink,
                    )
                )
                continue

            # 3. 标签交集
            post_tags = {tag.lower() for tag in post_front.tags}
            shared = page_tags & post_tags
            if page_tags and shared:
                results.append(
                    PageReference(
                        post_title=title,
                        post_file_path=post_path,
                        match_kind="tag",
                        match_snippet=sorted(shared)[0],
                    )
                )

        return results


def _relative_source_path(page_path: str, site_root: str) -> str:
    """把页面的绝对路径转成 ``source/`` 下的相对路径，去掉 ``.md``。

    ``/path/to/site/source/about.md`` → ``about``
    ``/path/to/site/source/about/index.md`` → ``about``
    """
    source_dir = os.path.join(site_root, "source")
    normalized = os.path.normpath(page_path)
    if not normalized.startswith(os.path.normpath(source_dir)):
        return ""

    relative = os.path.relpath(normalized, source_dir).replace(os.sep, "/")
    if relative.endswith(".md"):
        relative = relative[:-3]
    if relative.endswith("/index"):
        relative = relative[: -len("/index")]
    return relative


def _load(path: str) -> tuple[frontmatter.FrontMatter, str] | None:
    text = read_text(path)
    if text is None:
        return None
    return frontmatter.split(text)


def _title_from(front: frontmatter.FrontMatter, fallback: str) -> str:
    title = front.get_str("title").strip()
    if title:
        return title
    return os.path.splitext(fallback)[0]
