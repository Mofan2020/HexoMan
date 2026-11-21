"""页面的管理：扫描 source 下的内容、新建、编辑、删除。

对应 Swift 侧的 ``PageStore.swift``。

## 为什么单独做这一块

Hexo 的站点不只有文章。``source/about/index.md``、``source/friends/index.md``
这些「页面」是几乎每个博客都有的一部分，但 HexoMan 早期只能管 ``_posts``
里的文章。用户抱怨「能管理的东西太少」，这是最大的一块缺口。

两类页面都要能管：

1. HexoMan 新建的页面——带上完整的交互式表单（标题 / 布局 / 日期 / 草稿…）
2. 用户已有的页面——扫出来、能编辑，表单按它**实际有的字段**生成，
   缺哪个字段就补哪个，不强迫用户改写成 HexoMan 的格式。

## 与 Swift 版的差异

- **路径分隔符**：Swift 用 ``NSString`` 的路径 API，在 Windows 上会得到
  反斜杠。这里全程用 ``/`` 相对路径，磁盘路径单独处理。
- **扫描**：Swift 依赖 ``FileManager.enumerator``，这里用 ``os.walk``，
  但**跳过隐藏目录**的规则一样（``.git``、``.obsidian`` 之类不该被扫进来）。
"""

from __future__ import annotations

import datetime as _dt
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from . import frontmatter
from .model import Site, read_text

__all__ = [
    "PageKind",
    "PageFile",
    "PageField",
    "PageFieldKnowledge",
    "PageStore",
    "PageStoreError",
    "KNOWN_FIELD_ORDER",
]

#: 支持的页面文件扩展名。
_MARKDOWN_EXTENSIONS = (".md", ".markdown")

#: 主题自带资源的扩展名。它们不是内容，不该当页面编辑。
_ASSET_EXTENSIONS = (".html", ".htm", ".txt")


class PageKind:
    """页面类型。"""

    #: ``about/index.md`` 这种带 index 的，URL 就是目录名
    INDEXED = "indexed"
    #: ``about.md`` 这种，URL 带 .html
    STANDALONE = "standalone"
    #: 主题自带的资源（图片、css 等），不该当内容编辑
    ASSET = "asset"

    LABELS = {
        INDEXED: "独立页面",
        STANDALONE: "单页",
        ASSET: "静态资源",
    }


class PageStoreError(Exception):
    """页面操作出错。"""

    def __init__(self, code: str, message: str = "") -> None:
        super().__init__(message or code)
        self.code = code
        self.message = message or code


@dataclass
class PageFile:
    """一个页面文件。"""

    path: str
    #: 相对 source 的路径，如 ``about/index.md``
    relative_path: str
    #: 从路径推出来的名字，如 ``about``
    slug: str
    title: str
    kind: str = PageKind.INDEXED
    #: 是否在 ``_posts`` 目录里（文章，不是页面）
    is_post: bool = False
    has_front_matter: bool = False
    #: 文件修改时间（Unix 时间戳）
    modified_at: float = 0.0
    #: 文件大小（字节）
    size: int = 0

    @property
    def id(self) -> str:
        return self.path

    @property
    def url(self) -> str:
        """这个页面在站点里的访问路径。"""
        name = os.path.splitext(self.relative_path)[0]
        cleaned = name[: -len("/index")] if name.endswith("/index") else name
        if not cleaned:
            return "/"
        return f"/{cleaned}/"

    @property
    def kind_label(self) -> str:
        return PageKind.LABELS.get(self.kind, "")

    def to_dict(self) -> dict[str, Any]:
        return {
            "path": self.path,
            "relativePath": self.relative_path,
            "slug": self.slug,
            "title": self.title,
            "kind": self.kind,
            "kindLabel": self.kind_label,
            "isPost": self.is_post,
            "hasFrontMatter": self.has_front_matter,
            "modifiedAt": self.modified_at,
            "size": self.size,
            "url": self.url,
        }


@dataclass
class PageField:
    """页面 front matter 里的一个字段描述。

    和 :mod:`hexoman.config_schema` 的区别：页面字段大多不在任何已知键表里
    （各主题自定义的都有），所以这里是「**先看文件里实际有什么**，再决定
    给什么控件」。
    """

    key: str
    label: str = ""
    hint: str = ""
    #: text / multiline / integer / boolean / date / list / choice / passthrough
    kind: str = "text"
    #: 标量当前值
    value: str = ""
    #: 列表当前值
    items: list[str] = field(default_factory=list)
    #: 是不是 HexoMan 认识的字段（决定表单给不给控件）
    is_known: bool = True
    #: ``choice`` 类型的候选项
    options: list[dict[str, str]] = field(default_factory=list)

    @property
    def id(self) -> str:
        return self.key

    @property
    def is_empty(self) -> bool:
        return not self.value and not self.items

    def to_dict(self) -> dict[str, Any]:
        return {
            "key": self.key,
            "label": self.label,
            "hint": self.hint,
            "kind": self.kind,
            "value": self.value,
            "items": list(self.items),
            "isKnown": self.is_known,
            "options": [dict(option) for option in self.options],
        }


class PageFieldKnowledge:
    """页面里字段的中文说明。

    覆盖 Hexo 通用字段 + 常见主题页面字段。
    """

    ENTRIES: dict[str, dict[str, Any]] = {
        "title": {"label": "标题", "hint": "页面显示的标题。", "kind": "text"},
        "date": {"label": "日期", "hint": "页面的创建时间，会影响排序。", "kind": "date"},
        "updated": {"label": "更新时间", "hint": "最后修改时间。", "kind": "date"},
        "layout": {
            "label": "布局",
            "hint": "用哪个模板渲染这个页面。",
            "kind": "choice",
            "options": [
                {"value": "", "label": "（跟随主题默认）"},
                {"value": "page", "label": "page（通用页面）"},
                {"value": "post", "label": "post（按文章渲染）"},
                {"value": "draft", "label": "draft（草稿，不发布）"},
                {"value": "about", "label": "about（关于页）"},
                {"value": "friends", "label": "friends（友链页）"},
                {"value": "links", "label": "links（链接页）"},
            ],
        },
        "permalink": {
            "label": "固定链接",
            "hint": "指定这个页面的 URL。不填就按文件路径生成。",
            "kind": "text",
        },
        "draft": {"label": "草稿", "hint": "勾上后不会出现在站点里。", "kind": "boolean"},
        "published": {
            "label": "已发布",
            "hint": "与「草稿」作用相反，勾上才发布。",
            "kind": "boolean",
        },
        "comments": {"label": "开启评论", "hint": "这个页面要不要显示评论区。", "kind": "boolean"},
        "toc": {"label": "显示目录", "hint": "根据标题自动生成页内目录。", "kind": "boolean"},
        "mathjax": {"label": "数学公式", "hint": "启用 LaTeX 公式渲染。", "kind": "boolean"},
        "mermaid": {"label": "流程图", "hint": "启用 mermaid 图表。", "kind": "boolean"},
        "chart": {"label": "图表", "hint": "启用图表渲染。", "kind": "boolean"},
        "emoji": {"label": "Emoji", "hint": "启用表情渲染。", "kind": "boolean"},
        "password": {
            "label": "访问密码",
            "hint": "留空表示不加密。填了之后访问要输密码。",
            "kind": "text",
        },
        "excerpt": {"label": "摘要", "hint": "列表页显示的摘要文字。", "kind": "text"},
        "description": {"label": "描述", "hint": "SEO 描述。", "kind": "text"},
        "keywords": {
            "label": "关键词",
            "hint": "SEO 关键词，多个用逗号分隔。",
            "kind": "text",
        },
        "sticky": {"label": "置顶", "hint": "数字越大越靠前。", "kind": "integer"},
        "order": {"label": "排序权重", "hint": "数字越小越靠前。", "kind": "integer"},
        "cover": {"label": "封面图", "hint": "页面顶部大图的地址。", "kind": "text"},
        "banner": {"label": "横幅图", "hint": "部分主题用的横幅背景。", "kind": "text"},
        "avatar": {"label": "头像", "hint": "部分主题支持单独的头像。", "kind": "text"},
        "type": {"label": "类型", "hint": "部分主题用它区分页面种类。", "kind": "text"},
        "sidebar": {"label": "侧边栏", "hint": "是否显示侧边栏。", "kind": "boolean"},
        "comments_count": {"label": "评论数", "hint": "部分主题手动指定。", "kind": "integer"},
        "extend": {
            "label": "扩展字段",
            "hint": "主题自定义配置，可能是多行。",
            "kind": "multiline",
        },
        # 文章专有，页面里出现时一并显示
        "tags": {"label": "标签", "hint": "页面的标签。", "kind": "list"},
        "categories": {"label": "分类", "hint": "页面的分类。", "kind": "list"},
    }

    @classmethod
    def lookup(cls, key: str) -> dict[str, Any] | None:
        return cls.ENTRIES.get(key)


#: 常用字段的排序。**HexoMan 认识的常用字段排前面**，用户自己加的排后面。
KNOWN_FIELD_ORDER = (
    "title",
    "layout",
    "date",
    "updated",
    "permalink",
    "draft",
    "published",
    "cover",
    "banner",
    "description",
    "excerpt",
    "keywords",
    "sticky",
    "order",
    "toc",
    "comments",
    "mathjax",
    "mermaid",
    "chart",
    "emoji",
    "password",
    "sidebar",
)


class PageStore:
    """页面管理。"""

    # -- 扫描 ---------------------------------------------------------

    @staticmethod
    def scan(site: Site) -> list[PageFile]:
        """扫描站点 source 下所有页面。

        会连 ``_posts`` 里的文章一起扫出来（文章也是「页面」的一种），
        这样用户在一个列表里能看到全部内容，不用先想「这是文章还是页面」。

        排序：文章在前，其余按修改时间倒序。
        """
        source_root = Path(site.path) / "source"
        results: list[PageFile] = []

        if not source_root.is_dir():
            return results

        for directory, subdirectories, filenames in os.walk(source_root):
            # 跳过隐藏目录（.git / .obsidian / .github …）
            subdirectories[:] = [
                name for name in subdirectories if not name.startswith(".")
            ]

            for filename in filenames:
                if filename.startswith("."):
                    continue

                full = Path(directory) / filename
                relative = full.relative_to(source_root).as_posix()
                page = PageStore._make_page_file(relative, source_root)
                if page is not None:
                    results.append(page)

        results.sort(
            key=lambda item: (not item.is_post, -item.modified_at, item.relative_path)
        )
        return results

    @staticmethod
    def pages_only(site: Site) -> list[PageFile]:
        """只取页面（不含文章）。"""
        return [page for page in PageStore.scan(site) if not page.is_post]

    @staticmethod
    def _make_page_file(relative: str, source_root: Path) -> PageFile | None:
        """把扫描到的一个相对路径转成 PageFile。不是内容文件就返回 None。"""
        # 跳过隐藏文件与依赖目录
        if relative.startswith(".") or "/." in relative:
            return None

        full = source_root / relative
        if not full.is_file():
            return None

        extension = os.path.splitext(relative)[1].lower()
        is_markdown = extension in _MARKDOWN_EXTENSIONS

        if not is_markdown:
            # 有同名 markdown 的不重复收录（用户想编辑的是 md 那个）
            sibling = full.with_suffix(".md")
            if sibling.is_file():
                return None
            if extension not in _ASSET_EXTENSIONS:
                return None

        try:
            stat = full.stat()
            modified = stat.st_mtime
            size = stat.st_size
        except OSError:
            modified = 0.0
            size = 0

        is_post = relative.startswith("_posts/")

        title = PageStore.default_title(relative)
        has_front = False

        if is_markdown:
            text = read_text(full)
            if text is not None:
                front, _ = frontmatter.split(text)
                has_front = front.present
                if front.title:
                    title = front.title

        name = os.path.splitext(relative)[0]
        if not is_markdown:
            kind = PageKind.ASSET
        elif name.endswith("/index") or name == "index":
            kind = PageKind.INDEXED
        else:
            kind = PageKind.STANDALONE

        return PageFile(
            path=str(full),
            relative_path=relative,
            slug=PageStore.slug_from(relative),
            title=title,
            kind=kind,
            is_post=is_post,
            has_front_matter=has_front,
            modified_at=modified,
            size=size,
        )

    @staticmethod
    def slug_from(relative: str) -> str:
        """从相对路径推出 slug。"""
        name = os.path.splitext(relative)[0]
        if name.endswith("/index"):
            name = name[: -len("/index")]
        if name == "index":
            name = ""
        return name if name else "首页"

    @staticmethod
    def default_title(relative: str) -> str:
        """没有 title 时的兜底显示名。

        路径里可能有中文，直接拿来当标题比转拼音友好。
        """
        return PageStore.slug_from(relative)

    # -- 新建 ---------------------------------------------------------

    @staticmethod
    def sanitize(raw: str) -> str:
        """把用户输入的路径片段洗成安全的目录名。

        小白很容易在名字里打空格、中文、甚至 ``../``。这里统一处理：
        中文和字母数字保留，其余换成短横线，``..`` 一律拒绝。
        """
        trimmed = raw.strip()
        if not trimmed:
            return ""
        if ".." in trimmed:
            return ""

        cleaned = re.sub(r"[^0-9A-Za-z一-鿿_-]", "-", trimmed)
        cleaned = re.sub(r"-{2,}", "-", cleaned)
        return cleaned.strip("-")

    @staticmethod
    def is_valid_slug(raw: str) -> bool:
        """文件名是否合法。"""
        cleaned = PageStore.sanitize(raw)
        if not cleaned:
            return False
        return cleaned == raw.strip() or PageStore.sanitize(cleaned) == cleaned

    @staticmethod
    def create(
        site: Site,
        slug: str,
        title: str,
        layout: str = "",
        extra_front_matter: dict[str, str] | None = None,
    ) -> PageFile:
        """新建页面。

        默认建成 ``source/<slug>/index.md``（``about/index.md``），
        这是「关于」「友链」这类页面最常见的写法，URL 就是 ``/about/``，
        比 ``about.md`` 生成 ``/about.html`` 好看得多。
        """
        clean_slug = PageStore.sanitize(slug)
        if not clean_slug:
            raise PageStoreError(
                "invalidSlug",
                "页面名不合法。只能用中英文、数字、短横线和下划线。"
                "试试「about」「关于」「friends」这样的名字。",
            )

        directory = Path(site.path) / "source" / clean_slug
        file_path = directory / "index.md"

        if file_path.exists():
            raise PageStoreError(
                "alreadyExists", f"已经有一个 {clean_slug}/index.md 了，换个名字或者直接去编辑它。"
            )

        directory.mkdir(parents=True, exist_ok=True)

        front = frontmatter.FrontMatter(present=True)
        front.set("title", title)
        front.set("date", frontmatter.format_date(_dt.datetime.now()))
        if layout:
            front.set("layout", layout)
        for key, value in sorted((extra_front_matter or {}).items()):
            front.set(key, value)

        body = "\n在这里写页面内容，支持 Markdown。\n"
        file_path.write_text(frontmatter.render(front, body), encoding="utf-8")

        try:
            stat = file_path.stat()
            modified = stat.st_mtime
            size = stat.st_size
        except OSError:
            modified = 0.0
            size = 0

        return PageFile(
            path=str(file_path),
            relative_path=f"{clean_slug}/index.md",
            slug=clean_slug,
            title=title,
            kind=PageKind.INDEXED,
            is_post=False,
            has_front_matter=True,
            modified_at=modified,
            size=size,
        )

    # -- 读 -----------------------------------------------------------

    @staticmethod
    def load(page: PageFile) -> tuple[frontmatter.FrontMatter, str]:
        """读一个页面的完整内容。"""
        text = read_text(page.path)
        if text is None:
            return frontmatter.FrontMatter(), ""
        return frontmatter.split(text)

    @staticmethod
    def fields(front: frontmatter.FrontMatter) -> list[PageField]:
        """生成页面的交互式表单字段。

        顺序策略：**HexoMan 认识的常用字段排前面**，用户自己加的字段排后面。
        这样打开一个已有页面，最需要改的几项一屏可见，不用往下翻。
        """
        known: list[PageField] = []
        unknown: list[PageField] = []

        for entry in frontmatter.raw_entries(front):
            info = PageFieldKnowledge.lookup(entry.key)
            value = entry.value

            if entry.is_block_list:
                list_items = [
                    line.strip().lstrip("- ").strip()
                    for line in entry.verbatim_block.splitlines()
                    if line.strip()
                ]
            else:
                list_items = frontmatter.split_inline_list(value.strip("[]"))

            kind = info["kind"] if info else ("list" if entry.is_block_list else "passthrough")
            options = list(info.get("options", [])) if info else []

            field = PageField(
                key=entry.key,
                label=info["label"] if info else entry.key,
                hint=info["hint"]
                if info
                else "这个字段 HexoMan 不认识，会原样保留。你可以直接改它的值。",
                kind=kind,
                value="" if entry.is_block_list else value,
                items=list_items,
                is_known=info is not None,
                options=options,
            )

            if info is not None:
                known.append(field)
            else:
                unknown.append(field)

        order = {key: index for index, key in enumerate(KNOWN_FIELD_ORDER)}
        known.sort(key=lambda item: order.get(item.key, len(order)))

        return known + unknown

    # -- 写 -----------------------------------------------------------

    @staticmethod
    def save(page: PageFile, front: frontmatter.FrontMatter, body: str) -> None:
        """保存页面。

        策略是**只改被显式修改的字段**：``updates`` 里没出现的键一律保持
        原样。整份 front-matter 重新渲染的话，块状列表会被洗成内联、
        注释会丢，用户改一个标题却看到整个文件都变了——这是最招人烦的
        一类体验。
        """
        text = frontmatter.render(front, body)
        path = Path(page.path)
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_name(path.name + ".hexoman-tmp")
        temp.write_text(text, encoding="utf-8")
        os.replace(temp, path)

    @staticmethod
    def save_at_path(path: str, front: frontmatter.FrontMatter, body: str) -> None:
        """接受绝对路径的 save。

        用于 model 拿到自己（已经从 in-memory 编辑过）后落盘——批量改标签 /
        布局时不想为每个 page 都重新 scan 一遍目录找 PageFile。
        """
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        temp = target.with_name(target.name + ".hexoman-tmp")
        temp.write_text(frontmatter.render(front, body), encoding="utf-8")
        os.replace(temp, target)

    @staticmethod
    def update_field(
        page: PageFile, key: str, value: str, kind: str = "text"
    ) -> None:
        """只改一个 front-matter 字段，正文完全不动。

        这是最安全的改法：只重渲染 front-matter 那几行，正文一个字节都不碰，
        也不存在「把别的键洗掉」的风险。
        """
        front, body = PageStore.load(page)
        updated = frontmatter.FrontMatter(
            present=front.present,
            data=dict(front.data),
            raw_lines=list(front.raw_lines),
        )
        updated.updates = dict(front.updates)
        updated.removals = set(front.removals)

        if kind == "list":
            items = frontmatter.split_inline_list(value.strip("[]"))
            updated.set(key, items)
        elif kind == "boolean":
            lowered = value.strip().lower()
            # 传 Python bool 而不是 "true"/"false" 字符串：字符串会被
            # frontmatter 的标量渲染加上引号（`draft: "true"`），
            # YAML 读回来就是字符串而不是布尔，Hexo 不认。
            updated.set(key, lowered in ("true", "yes", "1", "on"))
        elif kind == "integer":
            try:
                updated.set(key, int(value.strip()))
            except ValueError:
                updated.set(key, 0)
        else:
            updated.set(key, value)

        PageStore.save(page, updated, body)

    @staticmethod
    def remove_field(page: PageFile, key: str) -> None:
        """删除 front-matter 里的某个键。"""
        front, body = PageStore.load(page)
        updated = frontmatter.FrontMatter(
            present=front.present,
            data=dict(front.data),
            raw_lines=list(front.raw_lines),
        )
        updated.updates = dict(front.updates)
        updated.removals = set(front.removals)
        updated.remove(key)
        PageStore.save(page, updated, body)

    @staticmethod
    def add_field(page: PageFile, key: str, value: str) -> None:
        """新增一个 front-matter 字段。"""
        front, body = PageStore.load(page)
        updated = frontmatter.FrontMatter(
            present=front.present,
            data=dict(front.data),
            raw_lines=list(front.raw_lines),
        )
        updated.updates = dict(front.updates)
        updated.removals = set(front.removals)
        updated.set(key, value)
        PageStore.save(page, updated, body)

    # -- 删除 ---------------------------------------------------------

    @staticmethod
    def delete(page: PageFile) -> None:
        """删除页面文件。

        连带删掉它独占的目录——``source/about/index.md`` 删了之后，留一个空的
        ``source/about/`` 目录在仓库里很难看。但目录里还有别的文件就不动，
        避免误删。
        """
        path = Path(page.path)
        directory = path.parent

        path.unlink(missing_ok=True)

        # 只有 source 的直接子目录才删（``source/about/`` 可以，
        # ``source/about/deep/`` 不行——那层可能还有别的东西）
        source_root = directory.parent
        if source_root.name != "source":
            return

        try:
            remaining = list(directory.iterdir())
        except OSError:
            return

        if not remaining:
            try:
                directory.rmdir()
            except OSError:
                pass
