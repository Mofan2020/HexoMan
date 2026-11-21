"""文章：读写、搜索、筛选。

对应 Swift 侧的 ``BlogPost.swift``。文章就是站点文章目录下的 Markdown
文件，没有任何数据库。
"""

from __future__ import annotations

import datetime as _dt
import os
import re
import shutil
from pathlib import Path
from typing import Iterable

from . import frontmatter
from .model import BlogPost, Site, read_text, slugify

__all__ = [
    "load_posts",
    "read_post",
    "create_post",
    "save_post",
    "delete_post",
    "set_draft",
    "filter_posts",
    "post_filter_options",
]

_MARKDOWN_SUFFIXES = {".md", ".markdown"}


def load_posts(site: Site) -> list[BlogPost]:
    """读取站点全部文章，按日期倒序（同日按文件名兜底排序）。"""
    directory = Path(_posts_directory(site))

    try:
        entries = sorted(directory.iterdir())
    except OSError:
        return []

    posts: list[BlogPost] = []
    for entry in entries:
        if not entry.is_file():
            continue
        if entry.suffix.lower() not in _MARKDOWN_SUFFIXES:
            continue
        post = read_post(str(entry))
        if post is not None:
            posts.append(post)

    posts.sort(key=lambda item: (item.date, item.filename), reverse=True)
    return posts


def _posts_directory(site: Site) -> str:
    # 延迟导入：sites.py 在模块层导入本模块，反向依赖只能延迟解析。
    from .sites import resolve_paths

    _, posts = resolve_paths(site)
    return posts


def read_post(path: str) -> BlogPost | None:
    """读取单个文件。读不出来返回 ``None``（跳过，不让整个列表失败）。"""
    text = read_text(path)
    if text is None:
        return None

    front, body = frontmatter.split(text)

    try:
        stat = os.stat(path)
        modified_at = stat.st_mtime
        byte_size = stat.st_size
    except OSError:
        modified_at = 0.0
        byte_size = len(text.encode("utf-8"))

    return BlogPost(
        file_path=os.path.abspath(path),
        front=front,
        body=body,
        modified_at=modified_at,
        byte_size=byte_size,
    )


def unique_path(directory: Path, slug: str) -> Path:
    """避免覆盖同名文件。

    同名加 ``-2``、``-3``。用户建了两篇同名文章时，第二篇不能把第一篇
    覆盖掉。
    """
    candidate = directory / f"{slug}.md"
    counter = 2
    while candidate.exists():
        candidate = directory / f"{slug}-{counter}.md"
        counter += 1
    return candidate


def create_post(
    site: Site,
    title: str,
    body: str = "",
    tags: Iterable[str] | None = None,
    categories: Iterable[str] | None = None,
    date: _dt.datetime | None = None,
    is_draft: bool = False,
) -> BlogPost:
    """新建文章。

    ``date`` 和 ``draft`` 一起收进来，是因为编辑器要一次性把新建的元信息
    写全——早先不给这两个参数，调用方只能建完文件再回查路径补写一遍
    front matter。
    """
    directory = Path(_posts_directory(site))
    directory.mkdir(parents=True, exist_ok=True)

    front = frontmatter.FrontMatter(present=True)
    front.set("title", title)
    front.set("date", frontmatter.format_date(date or _dt.datetime.now()))
    front.set("tags", list(tags or []))
    front.set("categories", list(categories or []))
    if is_draft:
        front.set("draft", True)

    path = unique_path(directory, slugify(title))
    path.write_text(frontmatter.render(front, body), encoding="utf-8")

    post = read_post(str(path))
    if post is None:
        raise OSError(f"写入失败：{path.name}")
    return post


def save_post(post: BlogPost) -> BlogPost:
    """保存文章（front matter + 正文一起写回）。"""
    text = frontmatter.render(post.front, post.body)
    path = Path(post.file_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    # 原子写：先写临时文件再替换，避免写到一半崩溃留下半个文件。
    temp = path.with_name(path.name + ".hexoman-tmp")
    temp.write_text(text, encoding="utf-8")
    os.replace(temp, path)

    refreshed = read_post(post.file_path)
    return refreshed or post


def delete_post(post: BlogPost) -> None:
    """删除文章。

    移到系统废纸篓而不是直接 unlink，误删可恢复。回收站目录拿不到时
    退回到 ``.hexoman-trash``，至少文件还在。
    """
    source = Path(post.file_path)
    if not source.exists():
        return

    trash = _trash_directory()
    try:
        trash.mkdir(parents=True, exist_ok=True)
        target = trash / source.name
        counter = 2
        while target.exists():
            target = trash / f"{source.stem}-{counter}{source.suffix}"
            counter += 1
        shutil.move(str(source), str(target))
    except OSError:
        # 连废纸篓都搬不动时，宁可删掉也不要留下半个文件。
        source.unlink(missing_ok=True)


def _trash_directory() -> Path:
    """系统废纸篓路径。

    macOS 是 ``~/.Trash``，Windows 没有等价目录，退回到用户目录下的
    隐藏文件夹。
    """
    if os.name == "nt":
        home = Path(os.path.expanduser("~"))
        return home / ".hexoman-trash"
    return Path(os.path.expanduser("~")) / ".Trash"


def set_draft(post: BlogPost, is_draft: bool) -> BlogPost:
    """切换草稿状态（改 front matter 里的 ``draft``）。"""
    post.front.set("draft", True if is_draft else False)
    return save_post(post)


def post_filter_options() -> list[str]:
    """文章列表的三个筛选项，对应 UI 的分段控件。"""
    return ["all", "published", "draft"]


def filter_posts(
    posts: list[BlogPost],
    search: str = "",
    status: str = "all",
    tag: str = "",
    category: str = "",
) -> list[BlogPost]:
    """按状态、标签、分类、关键字过滤文章。

    搜索覆盖标题、正文、标签 —— 和 Swift 侧 ``filteredPosts`` 一致。

    标签/分类过滤有个「存在性」前提：站里没有这个标签了就把条件当作没筛。
    切站点之后残留的旧条件不该把一个好好的列表筛成空。
    """
    result = list(posts)

    if status == "published":
        result = [post for post in result if not post.is_draft]
    elif status == "draft":
        result = [post for post in result if post.is_draft]

    if tag:
        result = [post for post in result if tag in post.tags]
    if category:
        result = [post for post in result if category in post.categories]

    keyword = search.strip().lower()
    if not keyword:
        return result

    return [
        post
        for post in result
        if keyword in post.title.lower()
        or keyword in post.body.lower()
        or any(keyword in item.lower() for item in post.tags)
    ]


def collect_tags(posts: list[BlogPost]) -> list[str]:
    """站点里出现过的所有标签，按名字排序。"""
    return sorted({tag for post in posts for tag in post.tags})


def collect_categories(posts: list[BlogPost]) -> list[str]:
    """站点里出现过的所有分类，按名字排序。"""
    return sorted({item for post in posts for item in post.categories})
