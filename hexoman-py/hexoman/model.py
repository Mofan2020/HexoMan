"""核心数据模型。

对应 Swift 侧的 ``HexoSite.swift`` / ``BlogPost.swift``，但去掉 SwiftUI
依赖：这里的类型是纯数据，界面层（HTML/JS）通过 JSON 拿它们。
"""

from __future__ import annotations

import datetime as _dt
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from . import frontmatter

__all__ = ["Site", "SiteInfo", "BlogPost", "slugify", "word_count", "excerpt"]


@dataclass
class Site:
    """一个被用户纳管的 Hexo 站点。

    ``path`` 就是站点根目录的绝对路径，同时充当唯一 id。
    """

    path: str
    last_opened: float = 0.0

    @classmethod
    def create(cls, path: str) -> "Site":
        """新建站点记录，顺手规整路径。

        去掉尾部斜杠是必须的：``/a/site`` 和 ``/a/site/`` 在 Windows 和
        macOS 上会变成两条不同的记录，列表里就出现了同一个站点两次。
        """
        return cls(path=normalize_path(path), last_opened=now_timestamp())

    @property
    def folder_name(self) -> str:
        return os.path.basename(self.path.rstrip("/\\")) or self.path

    @property
    def config_file(self) -> str:
        return os.path.join(self.path, "_config.yml")

    @property
    def package_file(self) -> str:
        return os.path.join(self.path, "package.json")

    @property
    def public_directory(self) -> str:
        return os.path.join(self.path, "public")

    @property
    def node_modules_bin(self) -> str:
        return os.path.join(self.path, "node_modules", ".bin", "hexo")

    def to_dict(self) -> dict[str, Any]:
        return {"path": self.path, "lastOpened": self.last_opened}

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "Site":
        return cls(
            path=normalize_path(str(data.get("path", ""))),
            last_opened=float(data.get("lastOpened", 0.0) or 0.0),
        )


@dataclass
class SiteInfo:
    """站点体检结果，总览页的指标卡直接吃它。"""

    title: str = ""
    url: str = ""
    theme: str = ""
    hexo_version: str = ""
    theme_version: str = ""
    dependencies_installed: bool = False
    is_git_repository: bool = False
    git_remote: str = ""
    post_count: int = 0
    has_build_output: bool = False
    build_file_count: int = 0
    posts_directory: str = ""
    source_directory: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "title": self.title,
            "url": self.url,
            "theme": self.theme,
            "hexoVersion": self.hexo_version,
            "themeVersion": self.theme_version,
            "dependenciesInstalled": self.dependencies_installed,
            "isGitRepository": self.is_git_repository,
            "gitRemote": self.git_remote,
            "postCount": self.post_count,
            "hasBuildOutput": self.has_build_output,
            "buildFileCount": self.build_file_count,
            "postsDirectory": self.posts_directory,
            "sourceDirectory": self.source_directory,
        }


@dataclass
class BlogPost:
    """一篇文章。

    ``file_path`` 是绝对路径，同时充当唯一 id —— 同一篇文章在列表里
    靠它保持稳定。
    """

    file_path: str
    front: frontmatter.FrontMatter = field(default_factory=frontmatter.FrontMatter)
    body: str = ""
    modified_at: float = 0.0
    byte_size: int = 0

    @property
    def filename(self) -> str:
        return os.path.basename(self.file_path)

    @property
    def slug(self) -> str:
        return os.path.splitext(self.filename)[0]

    @property
    def title(self) -> str:
        """标题：front matter 优先，缺失时退回文件名。"""
        return self.front.title or self.slug

    @property
    def date(self) -> _dt.datetime:
        """文章日期。front matter 没有就用文件修改时间兜底。"""
        return self.front.date or _dt.datetime.fromtimestamp(self.modified_at)

    @property
    def tags(self) -> list[str]:
        return self.front.tags

    @property
    def categories(self) -> list[str]:
        return self.front.categories

    @property
    def is_draft(self) -> bool:
        return self.front.is_draft

    @property
    def word_count(self) -> int:
        return word_count(self.body)

    @property
    def excerpt(self) -> str:
        return excerpt(self.body)

    def to_dict(self) -> dict[str, Any]:
        return {
            "path": self.file_path,
            "filename": self.filename,
            "slug": self.slug,
            "title": self.title,
            "date": self.date.strftime("%Y-%m-%d %H:%M:%S"),
            "timestamp": self.date.timestamp(),
            "tags": self.tags,
            "categories": self.categories,
            "draft": self.is_draft,
            "body": self.body,
            "wordCount": self.word_count,
            "byteSize": self.byte_size,
            "modifiedAt": self.modified_at,
            "excerpt": self.excerpt,
        }


# -- 工具函数 ----------------------------------------------------------


def normalize_path(path: str) -> str:
    """规整路径：展开 ``~``、去掉尾部分隔符、绝对化。

    ``os.path.normpath`` 在 macOS 上会把 ``/`` 留着、在 Windows 上换成
    ``\\``，混用会造出两条不同的站点记录，所以绝对化后再统一斜杠。
    """
    if not path:
        return ""
    expanded = os.path.expanduser(path.strip())
    absolute = os.path.abspath(expanded)
    if len(absolute) > 1 and absolute.endswith(os.sep):
        absolute = absolute[:-1]
    return absolute.replace(os.sep, "/")


def now_timestamp() -> float:
    return _dt.datetime.now().timestamp()


_SLUG_KEEP = re.compile(r"[0-9A-Za-z一-鿿]")
_SLUG_SEPARATORS = re.compile(r"[-_\s]+")


def slugify(title: str) -> str:
    """标题转文件名。

    保留中文、字母数字，其余**全部折叠成连字符**——不只是空格。

    Swift 版只把空格和连字符折叠成 ``-``，其余标点直接丢掉，于是
    ``"a/b"`` 会变成 ``"ab"``：两个词被粘在一起，文件名读不出来。
    这里把所有非字母数字、非汉字的字符都当分隔符，语义更接近注释里
    说的「其余折叠成连字符」。

    中文标题转出来的 slug 仍然是中文——Hexo 生成的中文 URL 才好看。
    """
    result: list[str] = []
    for char in title:
        if _SLUG_KEEP.match(char):
            result.append(char)
        else:
            result.append("-")

    slug = _SLUG_SEPARATORS.sub("-", "".join(result)).strip("-")
    return slug or "untitled"


_CJK = re.compile(r"[一-鿿぀-ヿ가-힯]")


def word_count(body: str) -> int:
    """正文字数。

    中文按字算（一个汉字一个字），西文按词算。这是「中英混排」的合理
    折中：纯按空格切会把一整段中文算成 1 个词，用户看着不像字数。
    """
    if not body:
        return 0

    # 代码块不计入正文字数：读者眼里的文章长度不含代码
    without_code = re.sub(r"```.*?```", "", body, flags=re.DOTALL)
    without_code = without_code.replace("`", "")

    cjk = len(_CJK.findall(without_code))
    latin = len(re.findall(r"[0-9A-Za-z]+", without_code))
    return cjk + latin


def excerpt(body: str, limit: int = 80) -> str:
    """短摘要，用作列表的预览行。"""
    flattened = body.replace("```", " ").replace("\n", " ").strip()
    flattened = re.sub(r"\s+", " ", flattened)
    if not flattened:
        return ""
    if len(flattened) <= limit:
        return flattened
    return flattened[:limit] + "…"


def read_text(path: str | Path) -> str | None:
    """读文本文件，失败返回 ``None``（不抛异常）。

    编码上先试 UTF-8 再试 GBK：Windows ��区的中文站点用 GBK 存文章很常见，
    直接按 UTF-8 读会整篇乱码。
    """
    try:
        raw = Path(path).read_bytes()
    except (OSError, ValueError):
        return None

    for encoding in ("utf-8", "utf-8-sig", "gbk"):
        try:
            return raw.decode(encoding)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")
